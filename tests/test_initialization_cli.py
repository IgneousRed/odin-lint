"""Compiler/runtime-backed checks for private slots and contextual zero values."""

import os
import subprocess
import unittest

from test_cli import BINARY, section
import test_ownership_cli as ownership


class InitializationTests(unittest.TestCase):
    setUp = ownership.OwnershipTests.setUp
    write = ownership.OwnershipTests.write

    def fixture(self):
        self.write("src/catalog/catalog.odin", "package catalog\n"
                   "Catalog :: struct {rows: [2]int}\npublished: Catalog\n")
        self.write("src/engine/engine.odin", 'package engine\nimport cat "../catalog"\n'
                   "Owner :: struct {catalog: ^cat.Catalog, rows: map[int]int}\n"
                   "Defaults :: struct {catalog: ^cat.Catalog, value: int}\n"
                   "Wrapper :: struct {config: Defaults}\n"
                   "initialize :: proc(owner: ^Owner) {attach(owner, nil); owner.rows = make(map[int]int); owner.rows[1] = 3}\n"
                   "reset :: proc(owner: ^Owner) {owner^ = {}}\n"
                   "attach :: proc(owner: ^Owner, catalog: ^cat.Catalog) {owner.catalog = catalog}\n"
                   "forward :: proc(owner: ^Owner, catalog: ^cat.Catalog) {attach(owner, catalog)}\n"
                   "invoke :: proc(action: proc(^Owner, ^cat.Catalog), owner: ^Owner, catalog: ^cat.Catalog) {action(owner, catalog)}\n"
                   "read_catalog :: proc(owner: ^Owner) -> int {return owner.catalog.rows[0]}\n"
                   "mutate_catalog :: proc(owner: ^Owner) {owner.catalog.rows[0] = 9}\n"
                   "release_catalog :: proc(owner: ^Owner) {free(owner.catalog); owner.catalog = nil}\n"
                   "named_zero :: proc() -> (owner: Owner) {release_catalog(&owner); return}\n"
                   "returned_zero :: proc() -> Owner {return {}}\n"
                   "defaults :: proc(value: int = 7) -> Defaults {return {catalog = &cat.published, value = value}}\n"
                   "forward_defaults :: proc() -> Defaults {return defaults()}\n"
                   "reset_default :: proc(owner: ^Defaults, value: int = 7) {owner^ = {catalog = &cat.published, value = value}}\n"
                   "mutate_default :: proc(owner: ^Defaults) {owner.catalog.rows[0] = 9}\n"
                   "release_default :: proc(owner: ^Defaults) {free(owner.catalog); owner.catalog = nil}\n")

    def program(self, body, expected):
        source = self.write("main/main.odin", "package main\n" + section("Imports", "Project")
                            + 'import "../src/engine"\nimport "../src/catalog"\n'
                            + section("Procedures", "Public") + "main :: proc() {\n"
                            + "".join("\t" + line + "\n" for line in body.splitlines()) + "}\n")
        flags = ["-thread-count:1", "-vet", "-vet-tabs", "-vet-using-param",
                 "-vet-nil-deref", "-vet-uninitialized", "-vet-atomic-access",
                 "-strict-style", "-warnings-as-errors",
                 "-strict-style-packages:main,state,engine,catalog"]
        odin = os.environ.get("ODIN", "odin")
        commands = (
            [odin, "check", str(source.parent), *flags, "-vet-packages:main,state,engine,catalog"],
            [odin, "check", str(source.parent), *flags, "-vet-unused-procedures", "-vet-packages:main"],
            [odin, "run", str(source.parent), *flags, "-vet-packages:main,state,engine,catalog",
             "-debug", "-o:none", "-out:" + str(self.root / "probe")],
        )
        for command in commands:
            checked = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        linted = subprocess.run([str(BINARY), "--root", str(self.root), str(source.parent)],
                                capture_output=True, text=True)
        self.assertEqual(linted.returncode, 1 if expected else 0, linted.stderr)
        findings = [line for line in linted.stderr.splitlines() if "OWN001:" in line]
        self.assertEqual(len(findings), expected, linted.stderr)

    def test_private_slot_writes_survive_helpers_and_callbacks(self):
        self.fixture()
        initialized = ("engine.initialize(&owner)\ndefer delete(owner.rows)\n"
                       "assert(owner.catalog == nil && owner.rows[1] == 3)\n"
                       "assert(catalog.published.rows[0] == 0)")
        borrowed = "owner: engine.Owner\nowner.catalog = &catalog.published\n"
        nil_consume = ("engine.release_catalog(&owner)\nassert(owner.catalog == nil)\n"
                       "assert(catalog.published.rows[0] == 0)")
        cases = (
            ("stack", "owner: engine.Owner\n" + initialized, 0),
            ("literal", "owner := engine.Owner{}\n" + initialized, 0),
            ("reset", "owner: engine.Owner\nowner = {}\n" + initialized, 0),
            ("helper_reset", "owner: engine.Owner\nengine.reset(&owner)\n" + initialized, 0),
            ("heap", "owner := new(engine.Owner)\ndefer free(owner)\n"
             "engine.initialize(owner)\ndefer delete(owner.rows)\nassert(owner.catalog == nil && owner.rows[1] == 3)\n"
             "assert(catalog.published.rows[0] == 0)", 0),
            ("rebind", borrowed + "engine.attach(&owner, nil)\nassert(owner.catalog == nil)", 0),
            ("forward", borrowed + "engine.forward(&owner, nil)\nassert(owner.catalog == nil)", 0),
            ("callback", borrowed + "engine.invoke(engine.attach, &owner, nil)\nassert(owner.catalog == nil)", 0),
            ("read", borrowed + "assert(engine.read_catalog(&owner) == 0)", 0),
            ("write", borrowed + "engine.mutate_catalog(&owner)\nassert(catalog.published.rows[0] == 9)", 1),
            ("nil_consume", "owner: engine.Owner\n" + nil_consume, 0),
            ("nil_literal", "owner := engine.Owner{}\n" + nil_consume, 0),
            ("nil_named_result", "owner := engine.named_zero()\n" + nil_consume, 0),
            ("nil_returned_literal", "owner := engine.returned_zero()\n" + nil_consume, 0),
            ("nil_reset", borrowed + "owner = {}\n" + nil_consume, 0),
            ("nil_helper_reset", borrowed + "engine.reset(&owner)\n" + nil_consume, 0),
            ("nil_heap", "owner := new(engine.Owner)\ndefer free(owner)\n"
             "engine.release_catalog(owner)\nassert(owner.catalog == nil && catalog.published.rows[0] == 0)", 0),
            ("saved_borrow", borrowed + "saved := owner.catalog\nengine.reset(&owner)\n"
             "engine.release_catalog(&owner)\nsaved.rows[0] = 9\n"
             "assert(owner.catalog == nil && catalog.published.rows[0] == 9)", 1),
        )
        for name, body, expected in cases:
            with self.subTest(case=name):
                self.program(body, expected)

    def test_supported_defaults_and_explicit_initializers_keep_borrows(self):
        self.fixture()
        mutate = ("assert(owner.catalog == &catalog.published)\nengine.mutate_default(&owner)\n"
                  "assert(catalog.published.rows[0] == 9)")
        cases = (
            ("factory", "owner := engine.defaults()\nassert(owner.value == 7)\n" + mutate, 1),
            ("literal", "owner := engine.Defaults{catalog = &catalog.published}\n" + mutate, 1),
            ("contextual", "owner: engine.Defaults = {catalog = &catalog.published, value = 8}\nassert(owner.value == 8)\n" + mutate, 1),
            ("reset", "owner: engine.Defaults\nowner = {catalog = &catalog.published, value = 7}\n"
             "assert(owner.value == 7)\n" + mutate, 1),
            ("helper_reset", "owner: engine.Defaults\nowner.catalog = nil\nengine.reset_default(&owner)\n" + mutate, 1),
            ("returned", "owner := engine.forward_defaults()\n" + mutate, 1),
            ("heap", "owner := new(engine.Defaults)\ndefer free(owner)\nowner^ = engine.defaults()\n"
             "assert(owner.catalog == &catalog.published)\nengine.mutate_default(owner)\n"
             "assert(catalog.published.rows[0] == 9)", 1),
            ("override", "owner: engine.Defaults = {catalog = nil}\nengine.release_default(&owner)\n"
             "assert(owner.catalog == nil && catalog.published.rows[0] == 0)", 0),
            ("nested", "wrapper: engine.Wrapper = {config = {catalog = &catalog.published, value = 8}}\n"
             "assert(wrapper.config.catalog == &catalog.published && wrapper.config.value == 8)\n"
             "engine.mutate_default(&wrapper.config)\nassert(catalog.published.rows[0] == 9)", 1),
        )
        for name, body, expected in cases:
            with self.subTest(case=name):
                self.program(body, expected)
