"""Compiler-checked ownership regressions for copies and control-flow joins."""

import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_cli import BINARY, PROJECT, section
from consumer_fixture import borrowed_consumer


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=PROJECT / ".work")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.write("src/state/state.odin", "package state\n"
                   "Row :: struct {status: int}\n"
                   "Table :: struct {rows: map[int]Row}\n"
                   "Store :: struct {table: Table, rows: map[int]Row, active: bool}\n")

    def write(self, relative, text):
        target = self.root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        return target

    def findings(self, source):
        checked = subprocess.run(
            [os.environ.get("ODIN", "odin"), "check", str(source.parent),
             "-no-entry-point", "-thread-count:2", "-vet", "-strict-style",
             "-warnings-as-errors"], capture_output=True, text=True,
        )
        self.assertEqual(checked.returncode, 0, checked.stderr)
        paths = [source]
        names = re.findall(r"(\w+) :: proc\((?:using )?read: \^state.Store\)", source.read_text())
        if names:
            # Keep the borrowed negative concrete; a formal is only a requirement.
            consumer = borrowed_consumer(self.root, source, "; target.".join(name + "(&live)" for name in names))
            checked = subprocess.run([os.environ.get("ODIN", "odin"), "check", str(consumer.parent),
                                      "-no-entry-point", "-thread-count:2", "-vet", "-strict-style", "-warnings-as-errors"],
                                     capture_output=True, text=True)
            self.assertEqual(checked.returncode, 0, checked.stderr)
            paths.append(consumer)
        linted = subprocess.run(
            [str(BINARY), "--root", str(self.root), *map(str, paths)],
            capture_output=True, text=True,
        )
        self.assertIn(linted.returncode, (0, 1), linted.stderr)
        return [line for line in linted.stderr.splitlines() if "OWN001:" in line]

    def test_copies_keep_only_reference_bearing_fields_borrowed(self):
        cases = (
            ("row := read.rows[1]; pointer := &row; pointer.status = 2", 0),
            ("for _, value in read.rows {row := value; pointer := &row; pointer.status = 2}", 0),
            ("row := &read.rows[1]; row.status = 2", 1),
            ("copy := read^; pointer := &copy; pointer.active = true", 0),
            ("copy := read^; pointer := &copy; pointer.rows[1] = {}", 1),
            ("copy := read^; pointer := &copy; pointer.rows = make(map[int]state.Row); pointer.rows[1] = {}", 0),
            ("fresh := state.Store{table = state.Table{rows = make(map[int]state.Row)}}; fresh.table.rows[1] = {}", 0),
            ("fresh := state.Store{table = state.Table{rows = read.rows}}; fresh.table.rows[1] = {}", 1),
            ("using copy := read^; rows[1] = {}", 1),
            ("copy := read^; copy.rows = make(map[int]state.Row); copy.rows[1] = {}", 0),
            ("fresh: state.Store = {}; fresh.table.rows[1] = {}", 0),
            ("copy := read^; copy = {}; copy.rows[1] = {}", 0),
            ("copy := state.Store{}; copy = {rows = read.rows}; copy.rows[1] = {}", 1),
            ("rows := []map[int]state.Row{read.rows}; rows[0][1] = {}", 1),
            ("rows := []map[int]state.Row{read.rows}; rows[0] = make(map[int]state.Row)", 0),
            ("fresh: state.Store; fresh.table.rows[1] = {}", 0),
            ("rows := []state.Row{read.rows[1]}; rows[0].status = 2", 0),
            ("copy := read^; copy.table.rows = make(map[int]state.Row); copy.table.rows[1] = {}", 0),
            ("copy := read^; if read.active {copy.rows = make(map[int]state.Row)}; copy.rows[1] = {}", 1),
            ("copy := state.Store{}; if read.active {copy.rows = read.rows}; copy.rows[1] = {}", 1),
        )
        for body, expected in cases:
            with self.subTest(body=body):
                source = self.write("src/functions/functions.odin", "#+feature using-stmt\n"
                                    'package functions\nimport "../state"\n'
                                    "probe :: proc(read: ^state.Store) {" + body + "}\n")
                findings = self.findings(source)
                self.assertEqual(len(findings), expected, "\n".join(findings))

    def test_back_edges_and_expression_branches_retain_borrows(self):
        cases = (
            ("rows := make(map[int]state.Row); for _ in 0..<2 {rows[1] = {}; rows = read.rows}; _ = rows", 1),
            ("rows := make(map[int]state.Row); for i := 0; i < 2; i += 1 {rows[1] = {}; rows = read.rows}; _ = rows", 1),
            ("rows := make(map[int]state.Row); for _ in 0..<2 {rows = make(map[int]state.Row); rows[1] = {}}", 0),
            ("rows := read.rows if read.active else make(map[int]state.Row); rows[1] = {}", 1),
            ("rows := make(map[int]state.Row) if read.active else read.rows; rows[1] = {}", 1),
            ("rows := read.rows when true else make(map[int]state.Row); rows[1] = {}", 1),
            ("rows := read.rows when false else make(map[int]state.Row); rows[1] = {}", 0),
        )
        for body, expected in cases:
            with self.subTest(body=body):
                source = self.write("src/functions/functions.odin", 'package functions\nimport "../state"\n'
                                    "probe :: proc(read: ^state.Store) {" + body + "}\n")
                findings = self.findings(source)
                self.assertEqual(len(findings), expected, "\n".join(findings))

    def test_nested_resets_keep_inline_working_data_private(self):
        self.write("src/state/state.odin", "package state\n"
                   "Chunk :: struct {rows: [2]int, day: int}\n"
                   "Text :: struct {bytes: [16]u8, count: int}\n"
                   "Facts :: struct {chunk: Chunk, notice: Text}\n")
        self.write("src/engine/engine.odin", 'package engine\nimport "../state"\n'
                   "Frame :: struct {facts: state.Facts, link: ^state.Chunk, slice: []int}\n"
                   '@(private="file")\nlive: Frame\n'
                   "begin :: proc() -> Frame {return live}\n"
                   "borrow :: proc() -> ^Frame {return &live}\n"
                   "peek :: proc() -> ^state.Chunk {return &live.facts.chunk}\n"
                   "peek_slice :: proc() -> []int {return live.facts.chunk.rows[:]}\n")
        self.write("src/procedures/procedures.odin", 'package procedures\nimport "../engine"\n'
                   "reset :: proc(tx: ^engine.Frame) {tx.facts = {}}\n"
                   "change :: proc(tx: ^engine.Frame) {\n"
                   "\ttx.facts.chunk.day += 1\n\ttx.facts.notice.count += 1\n}\n"
                   "change_link :: proc(tx: ^engine.Frame) {tx.link.rows[0] += 1}\n"
                   "change_slice :: proc(tx: ^engine.Frame) {tx.slice[0] += 1}\n")
        private = ("assert(tx.facts.chunk.day == 1)\n"
                   "assert(tx.facts.notice.count == 1)\n"
                   "assert(engine.begin().facts.chunk.day == 0)\n"
                   "assert(engine.begin().facts.notice.count == 0)")
        cases = (
            ("copy", "tx := engine.begin()\nprocedures.change(&tx)\n" + private, 0),
            ("copy_reset", "tx := engine.begin()\nprocedures.reset(&tx)\nprocedures.change(&tx)\n" + private, 0),
            ("heap", "tx := new(engine.Frame)\ndefer free(tx)\nprocedures.change(tx)\n" + private, 0),
            ("heap_reset", "tx := new(engine.Frame)\ndefer free(tx)\nprocedures.reset(tx)\nprocedures.change(tx)\n" + private, 0),
            ("borrow", "tx := engine.borrow()\nprocedures.change(tx)\n"
             "assert(engine.begin().facts.chunk.day == 1)", 1),
            ("borrow_reset", "tx := engine.borrow()\nprocedures.reset(tx)\nprocedures.change(tx)\n"
             "assert(engine.begin().facts.chunk.day == 1)", 2),
            ("borrowed_pointer", "tx := engine.begin()\nprocedures.reset(&tx)\n"
             "tx.link = engine.peek()\nprocedures.change_link(&tx)\n"
             "assert(engine.begin().facts.chunk.rows[0] == 1)", 1),
            ("borrowed_slice", "tx := engine.begin()\nprocedures.reset(&tx)\n"
             "tx.slice = engine.peek_slice()\nprocedures.change_slice(&tx)\n"
             "assert(engine.begin().facts.chunk.rows[0] == 1)", 1),
        )
        flags = ["-thread-count:1", "-vet", "-vet-tabs", "-vet-using-param",
                 "-vet-nil-deref", "-vet-uninitialized", "-vet-atomic-access",
                 "-strict-style", "-warnings-as-errors"]
        packages = "main,state,engine,procedures"
        odin = os.environ.get("ODIN", "odin")
        for name, body, expected in cases:
            with self.subTest(case=name):
                source = self.write("main/main.odin", "package main\n" + section("Imports", "Project")
                                    + 'import "../src/engine"\nimport "../src/procedures"\n'
                                    + section("Procedures", "Public") + "main :: proc() {\n"
                                    + "".join("\t" + line + "\n" for line in body.splitlines()) + "}\n")
                commands = (
                    [odin, "check", str(source.parent), *flags,
                     "-vet-packages:" + packages, "-strict-style-packages:" + packages],
                    [odin, "check", str(source.parent), *flags, "-vet-unused-procedures",
                     "-vet-packages:main", "-strict-style-packages:" + packages],
                    [odin, "run", str(source.parent), *flags, "-debug", "-o:none",
                     "-out:" + str(self.root / "probe"),
                     "-vet-packages:" + packages, "-strict-style-packages:" + packages],
                )
                for command in commands:
                    checked = subprocess.run(command, capture_output=True, text=True)
                    self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
                linted = subprocess.run([str(BINARY), "--root", str(self.root), str(source.parent)],
                                        capture_output=True, text=True)
                self.assertEqual(linted.returncode, 1 if expected else 0, linted.stderr)
                findings = [line for line in linted.stderr.splitlines() if "OWN001:" in line]
                self.assertEqual(len(findings), expected, linted.stderr)

    def test_using_parameters_use_their_own_procedure_scope(self):
        source = self.write("src/functions/functions.odin", '#+feature using-stmt\npackage functions\nimport "../state"\n'
                            'first :: proc(using read: ^state.Store) {rows[1] = {}}\n'
                            'second :: proc(using read: ^state.Store) {copy := rows[1]; copy.status = 2}\n')
        self.assertEqual(len(self.findings(source)), 1)

    def test_procedure_order_does_not_change_global_borrows(self):
        self.write("src/engine/engine.odin", 'package engine\nimport "../state"\nstore: state.Store\n')
        declarations = (
            "reset :: proc() {rows = make(map[int]state.Row)}\n",
            "mutate :: proc() {rows[1] = {}}\n",
        )
        for typed in (False, True):
            for reverse in (False, True):
                with self.subTest(typed=typed, reverse=reverse):
                    binding = "rows: map[int]state.Row = engine.store.rows\n" if typed else "rows := engine.store.rows\n"
                    procedures = declarations[::-1] if reverse else declarations
                    source = self.write("src/effects/effects.odin", 'package effects\nimport "../state"\n'
                                        'import "../engine"\n' + binding + "".join(procedures))
                    findings = self.findings(source)
                    self.assertEqual(len(findings), 1, "\n".join(findings))
