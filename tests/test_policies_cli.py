"""Compiler-checked integration examples for project-wide policy analysis."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_cli import BINARY, PROJECT, section
from consumer_fixture import borrowed_consumer


class ProjectPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=PROJECT / ".work")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        return target

    def check(self, directory):
        result = subprocess.run(
            [os.environ.get("ODIN", "odin"), "check", str(directory), "-no-entry-point",
             "-thread-count:2", "-vet", "-strict-style", "-warnings-as-errors"],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def lint(self, *paths):
        result = subprocess.run([str(BINARY), "--root", str(self.root), *map(str, paths)], capture_output=True, text=True)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        return result.stderr

    def test_narrowing_reads_unselected_consumers_and_aliases(self):
        api = self.write("src/api/api.odin", "package api\n" + section("Procedures", "Public")
                         + "entry :: proc() -> int {return value()}\nvalue :: proc() -> int {return 1}\n")
        consumer = self.write("tools/tools.odin", 'package tools\nimport "../src/api"\n'
                              'invoke :: proc() -> int {return api.value()}\n')
        self.check(api.parent)
        self.check(consumer.parent)
        self.assertNotIn("VIS002", self.lint(api))
        consumer.write_text('package tools\nimport "../src/api"\n'
                            'Alias :: api.value\ninvoke :: proc() -> int {return Alias()}\n', encoding="utf-8")
        self.check(consumer.parent)
        self.assertNotIn("narrow value", self.lint(api))
        consumer.write_text('package tools\nimport "../src/api"\n'
                            'invoke :: proc() -> int {return api.entry()}\n', encoding="utf-8")
        self.check(consumer.parent)
        findings = self.lint(api)
        self.assertNotIn("VIS002", findings)
        self.assertNotIn("FILE005", findings)
        self.assertNotIn(str(consumer), findings)

    def test_alias_sections_include_imported_types_and_type_factories(self):
        self.write("src/api/api.odin", "package api\nNumber :: int\n"
                   "Box :: struct($T: typeid) {value: T}\n")
        source = self.write("src/sample/sample.odin", "")
        for kind, declaration, rejected in (
            ("Types", "Alias :: api.Number", False),
            ("Constants", "Alias :: api.Number", True),
            ("Types", "Alias :: api.Box(int)", False),
            ("Constants", "Alias :: api.Box(int)", True),
            ("Constants", "Value :: api.Number(3)", False),
            ("Types", "Value :: api.Number(3)", True),
        ):
            with self.subTest(kind=kind, declaration=declaration):
                source.write_text('package sample\n' + section("Imports", "Project") + 'import "../api"\n'
                                  + section(kind, "Public") + declaration + "\n", encoding="utf-8")
                self.check(source.parent)
                self.assertEqual("SECTION003" in self.lint(source), rejected)

    def test_exact_interface_and_public_helper_policies(self):
        interface = self.write("src/sample/sample.odin", "package sample\n")
        helper = self.write("src/sample/helper.odin", "package sample\n" + section("Constants", "Public") + "VALUE :: 1\n")
        self.check(interface.parent)
        self.assertIn("FILE004", self.lint(helper))
        helper.write_text("#+private file\npackage sample\n", encoding="utf-8")
        extra = self.write("src/sample/main.odin", "package sample\n")
        self.check(interface.parent)
        self.assertIn("FILE003", self.lint(interface))
        extra.unlink()
        interface.unlink()
        self.check(helper.parent)
        self.assertIn("FILE003", self.lint(helper))

    def test_majority_defaults_override_filename_without_shared_special_case(self):
        interface = self.write("src/sample/sample.odin", "package sample\n")
        shared = self.write("src/sample/shared.odin", "#+private file\npackage sample\n")
        self.check(interface.parent)
        self.assertEqual(self.lint(interface, shared), "")
        declarations = section("Constants", "Public") + "A :: C+D+E\nB :: C*D*E\n"
        declarations += "// ---------------- Package ----------------\n"
        declarations += "@(private) C :: 3\n@(private) D :: 4\n@(private) E :: 5\n"
        interface.write_text("package sample\n" + declarations, encoding="utf-8")
        consumer = self.write("tools/tools.odin", 'package tools\nimport "../src/sample"\n'
                              'read :: proc() -> int {return sample.A+sample.B}\n')
        self.check(consumer.parent)
        findings = self.lint(interface, shared)
        self.assertIn("FILE006: reorganize visibility groups", findings)
        self.assertIn("preserve public exports", findings)
        self.assertIn("3/5 declarations meet the 60% threshold", findings)
        # Apply the visibility-preserving split to this same mixed package.
        interface.write_text("package sample\n" + section("Constants", "Public")
                             + "A :: C+D+E\nB :: C*D*E\n", encoding="utf-8")
        shared.write_text("#+private\npackage sample\n" + section("Constants", "Package")
                          + "C :: 3\nD :: 4\nE :: 5\n", encoding="utf-8")
        self.check(consumer.parent)
        self.assertNotIn("FILE006", self.lint(interface, shared))
        self.assertNotIn("VIS002", self.lint(interface, shared))
        # A wholly private interface still uses the agreed majority override.
        consumer.unlink()
        shared.write_text("#+private file\npackage sample\n", encoding="utf-8")
        interface.write_text("#+private\npackage sample\n" + section("Constants", "Package") + "A :: 1\nB :: 2\nC :: 3\n", encoding="utf-8")
        self.check(interface.parent)
        self.assertNotIn("FILE001", self.lint(interface))
        self.assertNotIn("FILE006", self.lint(interface))

    def test_owned_relations_with_generic_tables_borrows_and_private_work(self):
        self.write("src/state/state.odin", "package state\nRow :: struct {status: int}\n"
                   "Table :: struct($Key, $Row: typeid) {rows: map[Key]Row}\n"
                   "Store :: struct {using table: Table(int, Row), active: bool, pending: [dynamic]int}\n")
        source = self.write("src/functions/functions.odin", "")
        cases = (
            ("read.rows[1] = {}", True),
            ("rows := read.rows; rows[1] = {}", True),
            ("rows := read.rows; clear(&rows)", True),
            ("rows := read.rows; delete_key(&rows, 1)", True),
            ("rows := read.rows; delete(rows)", True),
            ("row := &read.rows[1]; row.status = 2", True),
            ("for _, &row in read.rows {row.status = 2}", True),
            ("row := read.rows[1]; row.status = 2", False),
            ("for _, value in read.rows {row := value; row.status = 2}", False),
            ("rows := read.rows; rows = make(map[int]state.Row); rows[1] = {}", False),
            ("rows := read.rows; if read.active {rows = make(map[int]state.Row); rows[1] = {}}", False),
            ("rows := make(map[int]state.Row); if read.active {rows = read.rows}; rows[1] = {}", True),
            ("pending := read.pending; append(&pending, 1)", True),
            ("using read; active = true", True),
            ("using value := read^; rows[1] = {}", True),
            ("slice.fill(read.pending[:], 1)", True),
        )
        for body, rejected in cases:
            with self.subTest(body=body):
                source.write_text('#+feature using-stmt\npackage functions\n' + ('import "core:slice"\n' if 'slice.' in body else '') + 'import "../state"\nprobe :: proc(read: ^state.Store) {' + body + '}\n', encoding="utf-8")
                self.check(source.parent)
                consumer = borrowed_consumer(self.root, source)
                self.check(consumer.parent)
                findings = self.lint(source, consumer)
                self.assertEqual("OWN001" in findings, rejected, findings)
        engine = self.write("src/engine/engine.odin", 'package engine\nimport "../state"\n'
                            'write :: proc(read: ^state.Store) {read.rows[1] = {}}\n')
        self.check(engine.parent)
        self.assertNotIn("OWN001", self.lint(engine))

    def test_uncertain_map_keys_keep_package_visibility(self):
        api = self.write("src/api/api.odin", "package api\n" + section("Procedures", "Public")
                         + "entry :: proc() -> int {return helper()}\n"
                         + "// ---------------- Package ----------------\n"
                         + "@(private) helper :: proc() -> int {return 1}\n")
        self.write("src/api/keys.odin", "#+feature dynamic-literals\npackage api\n"
                   "ByProc :: type_of(map[proc() -> int]int{})\n"
                   "use :: proc() {values := ByProc{helper = 1}; _ = values}\n")
        self.check(api.parent)
        findings = self.lint(api)
        self.assertNotIn("VIS002: narrow helper", findings)
        self.assertNotIn("FILE005", findings)

    def test_private_target_aliases_remain_visible_to_siblings(self):
        self.write("src/api/api.odin", "package api\n")
        aliases = self.write("src/api/aliases.odin", "package api\n"
                             '@(private="file") hidden :: proc() {}\n'
                             "Alias :: hidden\nSecond :: Alias\n")
        self.write("src/api/caller.odin", "package api\ncall :: proc() {Alias(); Second()}\n")
        self.check(aliases.parent)
        findings = self.lint(aliases)
        self.assertNotIn("VIS002: narrow Alias", findings)
        self.assertNotIn("VIS002: narrow Second", findings)
        self.assertNotIn("FILE004", findings)

    def test_value_and_type_aliases_keep_public_visibility(self):
        api = self.write("src/api/api.odin", 'package api\n'
                         '@(private="file") Hidden_Value :: 3\n'
                         '@(private="file") Hidden_Type :: struct {}\n'
                         'Value :: Hidden_Value\nType :: Hidden_Type\n'
                         'Kind :: enum {A}\nFlag :: Kind.A\n')
        consumer = self.write("tools/tools.odin", 'package tools\nimport "../src/api"\n'
                              'use :: proc() {x: api.Type; _ = x; _ = api.Value; _ = api.Flag}\n')
        self.check(consumer.parent)
        findings = self.lint(api)
        self.assertNotIn("VIS002: narrow Value", findings)
        self.assertNotIn("VIS002: narrow Type", findings)
        # Enum aliases also receive the correct kind section.
        api.write_text('package api\n' + section("Types", "Public") + 'Kind :: enum {A}\n'
                       + section("Constants", "Public") + 'Flag :: Kind.A\n', encoding="utf-8")
        consumer.write_text("package tools\n", encoding="utf-8")
        self.check(api.parent)
        self.assertNotIn("SECTION003", self.lint(api))

    def test_unparseable_analysis_only_consumer_is_an_error(self):
        api = self.write("src/api/api.odin", "package api\nentry :: proc() {helper()}\nhelper :: proc() {}\n")
        self.check(api.parent)
        self.write("tools/tools.odin", "not an Odin file")
        result = subprocess.run([str(BINARY), "--root", str(self.root), str(api)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("cannot parse source", result.stderr)
        self.assertNotIn("VIS002", result.stderr)

    def test_ownership_branch_merges_preserve_binding_metadata(self):
        self.write("src/state/state.odin", "package state\nRow :: struct {value: int}\n"
                   "Store :: struct {rows: map[int]Row, active: bool}\n")
        body = "rows := make(map[int]state.Row)\n"
        for branch in range(32):
            body += "if read.active {\n"
            for local in range(4):
                body += f"scratch_{local} := {branch + local}; _ = scratch_{local}\n"
            body += "rows = read.rows\n}\n"
        body += "rows[1] = {}\n"
        source = self.write("src/functions/functions.odin", 'package functions\nimport "../state"\n'
                            'probe :: proc(read: ^state.Store) {\n' + body + '}\n')
        self.check(source.parent)
        consumer = borrowed_consumer(self.root, source)
        self.check(consumer.parent)
        findings = self.lint(source, consumer)
        self.assertIn("OWN001", findings)

    def test_unmapped_analysis_consumer_collection_is_an_error(self):
        api = self.write("src/api/api.odin", "package api\n" + section("Procedures", "Public")
                         + "entry :: proc() -> int {return value()}\nvalue :: proc() -> int {return 1}\n")
        consumer = self.write("tools/tools.odin", 'package tools\nimport "app:api"\n'
                              'use :: proc() -> int {return api.value()}\n')
        result = subprocess.run([os.environ.get("ODIN", "odin"), "check", str(consumer.parent),
                                 "-no-entry-point", "-thread-count:2", "-vet", "-strict-style", "-warnings-as-errors",
                                 f"-collection:app={self.root / 'src'}"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run([str(BINARY), "--root", str(self.root), str(api)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("unknown collection app", result.stderr)
        self.assertNotIn("VIS002", result.stderr)
        self.assertEqual(self.lint("--collection", f"app={self.root / 'src'}", api), "")

    def test_imported_using_namespace_counts_unselected_consumers(self):
        api = self.write("src/api/api.odin", "package api\n" + section("Procedures", "Public")
                         + "entry :: proc() -> int {return value()}\nvalue :: proc() -> int {return 1}\n")
        consumer = self.write("tools/tools.odin", '#+feature using-stmt\npackage tools\nimport "../src/api"\n'
                              'invoke :: proc() -> int {using api; return value()}\n')
        self.check(consumer.parent)
        self.assertNotIn("VIS002: narrow value", self.lint(api))
        self.assertNotIn("FILE005", self.lint(api))

    def test_multi_name_procedure_cycles_keep_their_owners(self):
        source = self.write("src/api/api.odin", "package api\n" + section("Procedures", "Public")
                            + "A, B :: proc() {}, proc() {Y()}\nY :: proc() {B()}\n")
        self.check(source.parent)
        self.assertNotIn("FLOW001", self.lint(source))

    def test_multi_name_alias_sections_use_visibility_consensus(self):
        source = self.write("src/api/api.odin", "package api\n" + section("Procedures", "Package")
                            + 'Alias, Second :: hidden, hidden\n// ---------------- File ----------------\n'
                            + '@(private="file") hidden :: proc() {}\n')
        self.check(source.parent)
        self.assertNotIn("SECTION003", self.lint(source))

    def test_mixed_visibility_defaults_do_not_depend_on_name_order(self):
        self.write("src/api/helpers.odin", "package api\n@(private) hidden :: proc() {}\npublic_proc :: proc() {}\n")
        api = self.write("src/api/api.odin", "")
        consumer = self.write("tools/tools.odin", 'package tools\nimport "../src/api"\nuse :: proc() {api.Public_Alias()}\n')
        for declaration in ("Private_Alias, Public_Alias :: hidden, public_proc", "Public_Alias, Private_Alias :: public_proc, hidden"):
            with self.subTest(declaration=declaration):
                api.write_text("package api\n" + section("Procedures", "Public") + declaration + "\n", encoding="utf-8")
                self.check(consumer.parent)
                findings = self.lint(api)
                self.assertNotIn("FILE006", findings)
                self.assertIn("split declarations", findings)

    def test_conditional_using_namespace_keeps_possible_consumers(self):
        api = self.write("src/api/api.odin", "package api\n" + section("Procedures", "Public")
                         + "entry :: proc() -> int {return value()}\nvalue :: proc() -> int {return 1}\n")
        consumer = self.write("tools/tools.odin", '#+feature using-stmt\npackage tools\nimport "../src/api"\n'
                              'invoke :: proc() {when #config(USE_API, true) {using api; _ = value()}}\n')
        self.check(consumer.parent)
        self.assertNotIn("VIS002: narrow value", self.lint(api))

    def test_relative_import_aliases_keep_architecture_roles(self):
        effect = self.write("src/effects/effects.odin", "package effects\nVALUE :: 1\n")
        (self.root / "shortcut").symlink_to(effect.parent, target_is_directory=True)
        source = self.write("src/functions/functions.odin", 'package functions\nimport "../../shortcut"\n'
                            'probe :: proc() -> int {return effects.VALUE}\n')
        self.check(source.parent)
        self.assertIn("ARCH001", self.lint(source))
        self.write("src/effects/io/io.odin", "package io\nVALUE :: 1\n")
        source.write_text('package functions\nimport "../../shortcut/io"\n'
                          'probe :: proc() -> int {return io.VALUE}\n', encoding="utf-8")
        self.check(source.parent)
        self.assertIn("ARCH001", self.lint(source))

    def test_relative_import_aliases_count_consumers_with_package_names(self):
        api = self.write("src/api/api.odin", "package api\n" + section("Procedures", "Public")
                         + "entry :: proc() -> int {return value()}\nvalue :: proc() -> int {return 1}\n")
        (self.root / "shortcut").symlink_to(api.parent, target_is_directory=True)
        consumer = self.write("tools/tools.odin", 'package tools\nimport "../shortcut"\n'
                              'invoke :: proc() -> int {return api.value()}\n')
        self.check(consumer.parent)
        self.assertEqual(self.lint(api), "")

    def test_nested_import_aliases_resolve_until_stable(self):
        effect = self.write("src/effects/effects.odin", "package effects\nVALUE :: 1\n")
        real = self.root / "real"
        real.mkdir()
        (self.root / "shortcut").symlink_to(real, target_is_directory=True)
        (real / "nested").symlink_to(real, target_is_directory=True)
        (real / "leaf").symlink_to(effect.parent, target_is_directory=True)
        source = self.write("src/functions/functions.odin", 'package functions\n'
                            'import "../../shortcut/nested/nested/leaf"\n'
                            'probe :: proc() -> int {return effects.VALUE}\n')
        self.check(source.parent)
        self.assertIn("ARCH001", self.lint(source))

    def test_default_narrowing_does_not_invoke_compiler(self):
        source = self.write("src/sample/sample.odin", "package sample\n" + section("Procedures", "Public")
                            + "caller :: proc() {helper()}\n" + f"// {'-' * 16} Package {'-' * 16}\n@(private) helper :: proc() {{}}\n")
        self.check(source.parent)
        result = subprocess.run([str(BINARY), "--root", str(self.root), str(source)],
                                capture_output=True, text=True, env={**os.environ, "PATH": ""})
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("VIS002", result.stderr)
