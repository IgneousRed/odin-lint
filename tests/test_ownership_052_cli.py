"""Compiler-backed FRP working copies and local transaction permissions."""

import os
import subprocess
import unittest

from test_cli import BINARY, section
import test_semantics_cli as semantic


class Ownership052Tests(unittest.TestCase):
    setUp = semantic.SemanticTests.setUp
    write = semantic.SemanticTests.write

    def check(self, directory, *, entry=False, run=False):
        odin = os.environ.get("ODIN", "odin")
        flags = ["-thread-count:1", "-vet", "-vet-tabs", "-vet-using-param",
                 "-vet-nil-deref", "-vet-uninitialized", "-vet-atomic-access",
                 "-strict-style", "-warnings-as-errors",
                 "-strict-style-packages:main,application,catalog,effects,engine,functions,procedures,state,views"]
        commands = [[odin, "check", str(directory), *flags,
                     "-vet-packages:main,application,catalog,effects,engine,functions,procedures,state,views",
                     *([] if entry else ["-no-entry-point"])]]
        if entry:
            commands.append([odin, "check", str(directory), *flags, "-vet-unused-procedures", "-vet-packages:main"])
        if run:
            commands.append([odin, "run", str(directory), *flags, "-debug", "-o:none", "-out:" + str(self.root / "probe")])
        for command in commands:
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def lint(self, *sources):
        result = subprocess.run([str(BINARY), "--root", str(self.root), *map(str, sources)],
                                capture_output=True, text=True)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        return result.stderr

    def test_fixed_array_element_reset_preserves_owner_and_borrowed_siblings(self):
        self.write("state", "Row :: struct {bonus: [8]f32}\n"
                   "Facts :: struct {rows: [2][2]Row, scores: [8]f32, count: [2]int, borrowed: []int}\n")
        self.write("engine", "Owner :: struct {facts: state.Facts}\n"
                   '@(private="file")\nlive: Owner\n'
                   "prepare :: proc() {live.facts.borrowed = make([]int, 1); live.facts.rows[0][0].bonus[0] = 2; live.facts.scores[0] = 10}\n"
                   "destroy :: proc() {delete(live.facts.borrowed); live = {}}\n"
                   "snapshot :: proc() -> Owner {return live}\n"
                   "borrow :: proc() -> ^Owner {return &live}\n", 'import "../state"\n')
        source = self.write("procedures", section("Procedures", "Public")
                            + "reset :: proc(owner: ^engine.Owner, i, j: int) {\n"
                            "\tcell := &owner.facts.rows[i][j]\n"
                            "\tfor value, index in cell.bonus {pointer := &owner.facts.scores[index]; pointer^ -= value}\n"
                            "\tcell^ = {}\n\towner.facts.count[i] += 1\n}\n",
                            section("Imports", "Project") + 'import "../engine"\n')
        cases = (
            ("private", "owner := engine.snapshot()\nprocedures.reset(&owner, 0, 0)\n"
             "assert(owner.facts.rows[0][0].bonus[0] == 0 && owner.facts.scores[0] == 8)\n"
             "assert(owner.facts.count[0] == 1 && engine.snapshot().facts.count[0] == 0)", 0),
            ("heap", "owner := new(engine.Owner)\ndefer free(owner)\n"
             "owner^ = engine.snapshot()\n"
             "procedures.reset(owner, 0, 0)\nassert(owner.facts.count[0] == 1 && engine.snapshot().facts.count[0] == 0)", 0),
            ("heap_borrowed_sibling", "owner := new(engine.Owner)\ndefer free(owner)\n"
             "owner^ = engine.snapshot()\nprocedures.reset(owner, 0, 0)\n"
             "owner.facts.borrowed[0] = 7\nassert(engine.snapshot().facts.borrowed[0] == 7)", 1),
            ("borrowed_owner", "procedures.reset(engine.borrow(), 0, 0)\nassert(engine.snapshot().facts.count[0] == 1)", 1),
            ("borrowed_sibling", "owner := engine.snapshot()\nprocedures.reset(&owner, 0, 0)\n"
             "owner.facts.borrowed[0] = 7\nassert(engine.snapshot().facts.borrowed[0] == 7)", 1),
        )
        for name, body, expected in cases:
            with self.subTest(case=name):
                main = self.root / "main/main.odin"
                main.parent.mkdir(exist_ok=True)
                main.write_text("package main\n" + section("Imports", "Project")
                                + 'import "../src/engine"\nimport "../src/procedures"\n'
                                + section("Procedures", "Public") + "main :: proc() {\n"
                                "\tengine.prepare()\n\tdefer engine.destroy()\n"
                                + "".join("\t" + line + "\n" for line in body.splitlines()) + "}\n")
                self.check(main.parent, entry=True, run=True)
                findings = self.lint(main, source)
                self.assertEqual(sum("OWN001:" in line for line in findings.splitlines()), expected, findings)


    def test_local_reference_slots_use_their_owner_transaction(self):
        self.write("engine", "Owner :: struct {rows: map[int]int}\n"
                   "Local :: struct {meaningful: ^Owner, text: string, transaction: Transaction}\n"
                   "Transaction :: struct {depth: int, saved: string}\n"
                   "enter_local :: proc(local: ^Local) {local.transaction.saved = local.text; local.transaction.depth += 1}\n"
                   "leave_local :: proc(local: ^Local) -> bool {local.transaction.depth -= 1; return true}\n")
        cases = (
            ('engine.enter_local(local); defer assert(engine.leave_local(local)); local.text = ""', False),
            ('local.text = ""', True),
            ('engine.enter_local(other); defer assert(engine.leave_local(other)); local.text = ""', True),
            ('selected := local; if choose {selected = other}; engine.enter_local(local); '
             'defer assert(engine.leave_local(local)); selected.text = ""', True),
            ('engine.enter_local(local); defer assert(engine.leave_local(local)); '
             'mem.zero(raw_data(local.text), len(local.text))', True),
        )
        for body, invalid in cases:
            with self.subTest(body=body):
                source = self.write("procedures", "run :: proc(local, other: ^engine.Local, choose: bool) {_ = other; _ = choose; " + body + "}\n",
                                    'import "../engine"\n' + ('import "core:mem"\n' if "mem.zero" in body else ""))
                caller = self.write("application", "left, right: engine.Local\nrun :: proc() {procedures.run(&left, &right, true)}\n",
                                    'import "../engine"\nimport "../procedures"\n')
                self.check(caller.parent)
                findings = self.lint(caller, source)
                self.assertEqual("OWN001:" in findings, invalid, findings)
