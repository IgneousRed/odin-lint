"""Deterministic end-to-end checks; fixtures remain in the ignored work area."""

import os
import shlex
import re
from pathlib import Path
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
BINARY = PROJECT / ".work" / "build" / "odin-lint"


def section(kind, visibility):
    return f"// {'-' * 32} {kind} {'-' * 32}\n// {'-' * 16} {visibility} {'-' * 16}\n"


def dependency_source(dependency, literal=None):
    literal = literal if literal is not None else f'"../{dependency}"'
    return (
        "#+private file\npackage functions\n" + section("Imports", "Project")
        + f"import {literal}\n" + section("Procedures", "File")
        + f"value :: proc() -> int {{return {dependency}.VALUE}}\n"
    )


class CliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=PROJECT / ".work")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, path, source=None):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        if source is None:
            visibility = "" if target.stem in ("main", target.parent.name) else "#+private file\n"
            source = visibility + f"package {target.parent.name}\n"
        if target.parent != self.root:
            source = re.sub(r"\bpackage (?:src|example|main)\b", f"package {target.parent.name}", source)
        interface = target.parent / f"{target.parent.name}.odin"
        if target.name == "main.odin" and interface.is_file() and interface.read_text() == f"package {target.parent.name}\n":
            interface.unlink()
        if target.stem not in ("main", target.parent.name) and not interface.exists() and not (target.parent / "main.odin").exists():
            interface.write_text(f"package {target.parent.name}\n", encoding="utf-8")
        target.write_text(source, encoding="utf-8")
        return target

    def write_dependency_packages(self, source_root="src"):
        for role in ("state", "effects"):
            self.write(f"{source_root}/{role}/{role}.odin", f"package {role}\n" + section("Constants", "Public") + "VALUE :: 1\n")

    def lint(self, *args, env=None):
        return subprocess.run(
            [str(BINARY), "--root", str(self.root), *map(str, args)],
            capture_output=True, text=True, check=False, env=env,
        )

    def check(self, package, *args, library=False):
        # Fixture validity is checked separately; the linter assumes Odin passed.
        flags = ["-no-entry-point"] if library else []
        result = subprocess.run(
            [os.environ.get("ODIN", "odin"), "check", str(package), *shlex.split(os.environ.get("ODIN_FLAGS", "-thread-count:2")),
             "-vet", "-strict-style", "-warnings-as-errors", *flags, *map(str, args)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_clean_and_duplicate_paths(self):
        source = self.write("src/functions/a.odin")
        result = self.lint(self.root / "src", source, source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")

    def test_diagnostics_are_sorted_and_deduplicated(self):
        source = "#+private file\npackage src\n" + section("Imports", "Project") + 'import "../effects"\n'
        a = self.write("src/functions/a.odin", source)
        b = self.write("src/functions/b.odin", source)
        result = self.lint(b, a, self.root / "src")
        self.assertEqual(result.returncode, 1, result.stderr)
        lines = result.stderr.splitlines()
        self.assertEqual(len(lines), 2, result.stderr)
        self.assertIn("a.odin(5:8): ARCH001:", lines[0])
        self.assertIn("b.odin(5:8): ARCH001:", lines[1])

    def test_package_findings_remain_grouped_by_canonical_file(self):
        a = self.write("src/a.odin", 'package src\n@(private) first :: proc() {}\n')
        b = self.write("src/b.odin", 'package src\n@(private) second :: proc() {}\n')
        self.write("src/main.odin", 'package src\nmain :: proc() {first(); second()}\n')
        self.check(a.parent)
        result = self.lint(b, a)
        self.assertEqual(result.returncode, 1, result.stderr)
        paths = [line.split("(", 1)[0] for line in result.stderr.splitlines()]
        self.assertEqual(paths, [str(a)] * 3 + [str(b)] * 3, result.stderr)

    def test_compiler_valid_positive_and_negative_examples(self):
        self.write_dependency_packages()
        source = self.write("src/functions/a.odin")
        for dependency, expected in (("state", 0), ("effects", 1)):
            with self.subTest(dependency=dependency):
                source.write_text(dependency_source(dependency), encoding="utf-8")
                self.check(source.parent, library=True)
                result = self.lint(source)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_unknown_collection_requires_mapping(self):
        source = self.write("src/functions/a.odin", dependency_source("engine", '"app:engine"'))
        result = self.lint(source)
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown collection app", result.stderr)
        self.assertIn("--collection NAME=DIR", result.stderr)
        result = self.lint("--collection", f"app={self.root / 'src'}", source)
        self.assertEqual(result.returncode, 1)
        self.assertIn("ARCH001", result.stderr)

    def test_triple_quoted_imports_keep_their_policy_meaning(self):
        self.write_dependency_packages()
        source = self.write("src/functions/a.odin")
        for dependency, expected in (("state", 0), ("effects", 1)):
            for opening, closing in (('"""', '"""'), ('```', '```'), ('"""\n  ', '\n  """'), ('```\r\n\t', '\r\n\t```')):
                with self.subTest(dependency=dependency, opening=opening):
                    source.write_text(dependency_source(dependency, f"{opening}../{dependency}{closing}"), encoding="utf-8")
                    self.check(source.parent, library=True)
                    result = self.lint(source.parent)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    if expected:
                        self.assertIn("ARCH001", result.stderr)

    def test_triple_quoted_import_grouping(self):
        source = self.write(
            "src/main.odin", "package src\n" + section("Imports", "Odin")
            + 'import """core:fmt"""\nimport "core:strings"\n' + section("Procedures", "Public")
            + 'main :: proc() {fmt.println(strings.trim_space("ok"))}\n',
        )
        self.check(source.parent)
        result = self.lint(source.parent)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_octal_escaped_import_paths(self):
        self.write_dependency_packages()
        source = self.write("src/functions/a.odin")
        for dependency, expected in (("state", 0), ("effects", 1)):
            for quote in ('"', '"""'):
                with self.subTest(dependency=dependency, quote=quote):
                    source.write_text(dependency_source(dependency, f"{quote}\\056\\056/{dependency}{quote}"), encoding="utf-8")
                    self.check(source.parent, library=True)
                    result = self.lint(source.parent)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    if expected:
                        self.assertIn("ARCH001", result.stderr)

    def test_missing_path_overrides_lint_exit(self):
        source = self.write("src/functions/a.odin", 'package src\nimport "core:os"\nprobe :: proc() {_ = os.exists("file")}\n')
        result = self.lint(source, self.root / "missing")
        self.assertEqual(result.returncode, 2)
        self.assertIn("ARCH002", result.stderr)
        self.assertIn("missing", result.stderr)

    def test_hidden_vendor_and_symlink_entries_are_skipped(self):
        self.write("src/functions/a.odin")
        self.write("src/.hidden/b.odin", "invalid")
        self.write("src/vendor/b.odin", "invalid")
        (self.root / "src" / "cycle").symlink_to(self.root / "src", target_is_directory=True)
        self.assertEqual(self.lint().returncode, 0)
        self.assertEqual(self.lint(self.root / "src" / "cycle").returncode, 2)

    def test_usage_and_io_failures(self):
        text = self.write("readme.txt", "hello")
        for args in (("--unknown",), ("--root",), ("--collection", "app"),
                     ("--collection", "core=src"), (text,), ()):
            with self.subTest(args=args):
                self.assertEqual(self.lint(*args).returncode, 2)
        result = self.lint("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("All lint rules always run", result.stdout)

    def test_unparseable_source_is_an_analysis_error(self):
        source = self.write("src/functions/a.odin", "package src\nx :: proc( {")
        result = self.lint(source)
        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot parse source", result.stderr)
        self.assertIn("policy analysis failed", result.stderr)
        self.assertNotIn("LINT001", result.stderr)

    def test_blank_files_have_no_package_findings(self):
        source = self.write("src/functions/functions.odin", "")
        for text in ("", " \t\n\n", "\r\n\t\r\n"):
            with self.subTest(text=text):
                source.write_text(text, encoding="utf-8")
                self.check(source.parent, "-vet-tabs", "-vet-using-param", "-vet-nil-deref",
                           "-vet-uninitialized", "-vet-atomic-access", library=True)
                result = self.lint(source)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")

    def test_blank_siblings_do_not_create_another_interface(self):
        source = self.write("src/functions/functions.odin", "package functions\n")
        (source.parent / "main.odin").write_text("", encoding="utf-8")
        (source.parent / "support.odin").write_text(" \t\n", encoding="utf-8")
        self.check(source.parent, library=True)
        for selected in (source, source.parent, source.parent / "main.odin"):
            with self.subTest(selected=selected):
                result = self.lint(selected)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")

    def test_blank_file_cannot_supply_an_interface(self):
        self.write("src/functions/functions.odin", "")
        source = self.write("src/functions/support.odin", "#+private file\npackage functions\n")
        self.check(source.parent, library=True)
        result = self.lint(source.parent)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("FILE003:", result.stderr)
        self.assertIn(f"{source}(2:", result.stderr)
        self.assertNotIn("FILE002:", result.stderr)

    def test_comment_only_file_without_a_package_is_an_analysis_error(self):
        source = self.write("src/functions/functions.odin", "")
        for text in ("// No package yet.\n", "/* outer /* inner */ comment */\n"):
            with self.subTest(text=text):
                source.write_text(text, encoding="utf-8")
                result = self.lint(source)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("cannot parse source", result.stderr)

    def test_all_policies_run_together(self):
        source = self.write(
            "src/functions/a.odin", 'package src\nimport "core:os"\n'
            '@(private="file") helper :: proc() -> int {_ = os.exists("file"); return 1}\n'
            '@(private="file") caller :: proc() -> int {return helper()}\n',
        )
        result = self.lint(source)
        self.assertEqual(result.returncode, 1, result.stderr)
        for rule in ("ARCH002", "FILE006", "SECTION003", "FLOW001", "SIMPLIFY001"):
            self.assertIn(rule, result.stderr)

    def test_definition_roles_cannot_hide_procedure_bodies_in_wrappers(self):
        source = self.write("src/catalog/catalog.odin")
        for declaration, rejected in (
                ("Handler :: proc()", False),
                ("Handler :: proc(callback: proc() = proc() {})", True),
                ("Handlers :: [1]proc(){proc() {}}", True),
                ("Handler :: type_of(proc() {})", True),
                ("@(test) check :: proc(t: ^testing.T) {_ = t}", False)):
            with self.subTest(declaration=declaration):
                imports = 'import "core:testing"\n' if declaration.startswith("@(test)") else ""
                source.write_text("package catalog\n" + imports + declaration + "\n", encoding="utf-8")
                self.check(source.parent, library=True)
                result = self.lint(source)
                self.assertNotEqual(result.returncode, 2, result.stderr)
                self.assertEqual("ARCH004" in result.stderr, rejected, result.stderr)

    def test_compiler_options_are_not_supported(self):
        for option in ("--check", "--compiler-arg", "--odin", "--library", "--unused"):
            with self.subTest(option=option):
                result = self.lint(option)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("unknown option " + option, result.stderr)

    def test_rule_switches_are_not_supported(self):
        for option in ("--strict-effects", "--file-policy", "--local-suggestions", "--sections"):
            with self.subTest(option=option):
                result = self.lint(option)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("unknown option " + option, result.stderr)

    def test_lint_only_checks_policies_without_a_compiler(self):
        source = self.write(
            "src/main.odin", "package src\n" + section("Constants", "Public") + "UNUSED :: 1\n"
            + section("Types", "Public") + "Legacy :: struct #field_align(8) {value: int}\n"
            + section("Procedures", "Public") + "main :: proc() {}\n",
        )
        result = self.lint(source, env={**os.environ, "PATH": ""})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")

    def test_sections_are_required_and_both_layouts_are_detected(self):
        source = self.write("src/main.odin", "package src\nCOUNT :: 1\n")
        result = self.lint(source)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("SECTION003", result.stderr)
        for major, minor in (("Constants", "Public"), ("Public", "Constants")):
            with self.subTest(major=major):
                source.write_text("package src\n" + section(major, minor) + "COUNT :: 1\n", encoding="utf-8")
                result = self.lint(source)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_prose_comments_do_not_count_as_sections(self):
        source = self.write("src/main.odin", "package src\n// -1 is the invalid sentinel-\nmain :: proc() {}\n")
        self.check(source.parent)
        result = self.lint(source.parent)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("SECTION003", result.stderr)
        self.assertNotIn("SECTION001", result.stderr)
        self.assertNotIn("SECTION002", result.stderr)

    def test_multiple_declarations_cannot_bypass_sections(self):
        source = self.write("src/main.odin")
        for heading, expected in (("Types", 1), ("Constants", 0)):
            with self.subTest(heading=heading):
                source.write_text(
                    "package src\n" + section(heading, "Public") + "A, B :: 1, 2\n"
                    + section("Procedures", "Public") + "main :: proc() {_ = A; _ = B}\n", encoding="utf-8",
                )
                self.check(source.parent)
                result = self.lint(source.parent)
                self.assertNotEqual(result.returncode, 2, result.stderr)
                self.assertEqual("SECTION003" in result.stderr, bool(expected), result.stderr)
                if expected:
                    self.assertIn("SECTION003", result.stderr)

    def test_private_helper_suggestions_always_run(self):
        source = self.write(
            "src/main.odin", "package src\n" + section("Procedures", "Public")
            + 'main :: proc() {_ = helper()}\n' + f"// {'-' * 16} File {'-' * 16}\n"
            + '@(private="file") helper :: proc() -> int {return 1}\n',
        )
        self.check(source.parent)
        result = self.lint(source)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("SIMPLIFY001: inline helper: one call within the package", result.stderr)

    def test_inactive_when_does_not_disable_local_analysis(self):
        source = self.write(
            "src/main.odin", "package src\n" + section("Procedures", "Public")
            + "main :: proc() {}\nwhen false {helper :: proc() {}}\n",
        )
        self.check(source.parent)
        result = self.lint(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("LINT003", result.stderr)

    def test_scoped_alias_and_initializer_inlining(self):
        helper = '@(private) helper :: proc() -> int {return 1}\n'
        cases = (
            ("package private", 'main :: proc() {_ = helper()}\n' + helper, 1),
            ("public", 'main :: proc() {_ = helper()}\nhelper :: proc() -> int {return 1}\n', 0),
            ("large procedure", 'main :: proc() {_ = helper()}\n@(private) helper :: proc() -> int {a := 1; a += 2; a += 3; a += 4; a += 5; a += 6; return a}\n', 1),
            ("initializer", 'VALUE := helper()\nmain :: proc() {_ = VALUE}\n' + helper.replace("proc()", 'proc "contextless"()'), 1),
            ("package alias", 'alias :: helper\nmain :: proc() {_ = alias()}\n' + helper, 1),
            ("alias chain", 'main :: proc() {first :: helper; second :: first; _ = second()}\n' + helper, 1),
            ("stable variable", 'main :: proc() {alias := helper; _ = alias()}\n' + helper, 1),
            ("reassigned variable", 'main :: proc() {alias := helper; alias = other; _ = alias()}\nother :: proc() -> int {return 2}\n' + helper, 0),
            ("constant alias visibility", 'EXPORTED :: helper\nmain :: proc() {_ = EXPORTED()}\n' + helper, 1),
            ("exported procedure variable", 'EXPORTED := helper\nmain :: proc() {_ = helper()}\n' + helper, 0),
            ("two alias calls", 'main :: proc() {alias :: helper; _ = alias(); _ = alias()}\n' + helper, 0),
            ("escaping alias", 'main :: proc() {alias :: helper; consume(alias)}\nconsume :: proc(callback: proc() -> int) {_ = callback()}\n' + helper, 0),
            ("extra reference", 'main :: proc() {_ = helper(); consume(helper)}\nconsume :: proc(callback: proc() -> int) {_ = callback()}\n' + helper, 0),
            ("unrelated parameter", 'other :: proc(helper: int) {_ = helper}\nmain :: proc() {other(2); _ = helper()}\n' + helper, 1),
            ("field and enum names", 'Value :: struct {helper: int}\nKind :: enum {helper}\nmain :: proc() {x := Value{helper = 2}; _ = x; _ = Kind.helper; _ = helper()}\n' + helper, 1),
            ("nested shadow", 'other :: proc() -> int {return 2}\nmain :: proc() {{helper := other; _ = helper()}; _ = helper()}\n' + helper, 1),
            ("type switch", 'Value :: union {int, string}\nmain :: proc() {\n\tswitch value in helper() {\n\tcase int:\n\t\t_ = value\n\tcase string:\n\t\t_ = value\n\t}\n}\n@(private) helper :: proc() -> Value {return 1}\n', 1),
            ("deferred call", 'main :: proc() {defer helper()}\n' + helper, 1),
            ("loop variable", 'main :: proc() {for helper in helper() {_ = helper}}\n@(private) helper :: proc() -> [1]int {return {1}}\n', 1),
            ("declaration order", 'other :: proc() -> int {return 2}\nmain :: proc() {_ = helper(); helper := other; _ = helper()}\n' + helper, 1),
            ("named argument", 'other :: proc(helper: int) {_ = helper}\nmain :: proc() {other(helper = 2); _ = helper()}\n' + helper, 1),
            ("map key", 'main :: proc() {values := map[int]int{helper() = 1}; _ = values; _ = helper()}\n' + helper, 0),
            ("selector", 'Value :: struct {helper: proc() -> int}\nother :: proc() -> int {return 2}\nmain :: proc() {x := Value{helper = other}; _ = x.helper(); _ = helper()}\n' + helper, 1),
            ("inactive branch", 'when false {unused :: proc() {_ = helper()}}\nmain :: proc() {_ = helper()}\n' + helper, 1),
            ("unrelated configurable branch", 'when #config(FLAG, false) {VALUE :: 2}\nmain :: proc() {_ = helper()}\n' + helper, 1),
            ("recursive alias", 'alias :: helper\nmain :: proc() {}\n@(private) helper :: proc() -> int {return alias()}\n', 0),
        )
        source = self.write("src/main.odin")
        for name, body, expected in cases:
            with self.subTest(case=name):
                tags = "#+private\n" if name in ("package alias", "recursive alias") else "#+feature dynamic-literals\n" if name == "map key" else ""
                source.write_text(tags + "package src\n" + body, encoding="utf-8")
                self.check(source.parent)
                result = self.lint(source)
                self.assertNotEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stderr.count("SIMPLIFY001: inline helper:"), expected, result.stderr)

    def test_parameter_defaults_use_the_enclosing_scope(self):
        source = self.write("src/main.odin")
        for signature, body in (("helper: proc() = helper", "helper()"),
                                ("callback: proc() = helper, helper: int = 0", "callback(); _ = helper")):
            with self.subTest(signature=signature):
                source.write_text(
                    "package src\n" + section("Procedures", "Public")
                    + f"main :: proc() {{helper(); take()}}\ntake :: proc({signature}) {{{body}}}\n"
                    + f"// {'-' * 16} Package {'-' * 16}\n@(private) helper :: proc() {{}}\n",
                    encoding="utf-8",
                )
                self.check(source.parent)
                result = self.lint(source)
                self.assertNotEqual(result.returncode, 2, result.stderr)
                self.assertNotIn("SIMPLIFY001", result.stderr)

    def test_polymorphic_bindings_do_not_use_package_procedures(self):
        source = self.write("src/main.odin")
        cases = (
            ("", "convert :: proc(value: $helper) -> helper {return helper(1)}\n", "_ = convert(1)"),
            ("", "convert :: proc(value: [$helper]int) -> int {return helper}\n", "_ = convert([1]int{})"),
            ("Value :: struct($helper: typeid) {field: helper}\n", "", "_ = Value(int){}"),
            ("Value :: union($helper: typeid) {helper}\n", "", "_ = Value(int){}"),
        )
        for types, procedures, call in cases:
            with self.subTest(types=types, procedures=procedures):
                source.write_text(
                    "package src\n" + (section("Types", "Public") + types if types else "")
                    + section("Procedures", "Public") + procedures
                    + f"main :: proc() {{_ = helper(); {call}}}\n"
                    + f"// {'-' * 16} Package {'-' * 16}\n@(private) helper :: proc() -> int {{return 1}}\n",
                    encoding="utf-8",
                )
                self.check(source.parent)
                result = self.lint(source)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stderr.count("SIMPLIFY001: inline helper:"), 1, result.stderr)

    def test_foreign_and_conditional_declarations_require_sections(self):
        source = self.write("src/main.odin")
        cases = (
            ("foreign import libc \"system:c\"\n", "foreign libc {puts :: proc \"c\"(text: cstring) -> i32 ---}\n", "Procedures", "Public"),
            ("foreign import libc \"system:c\"\n", "@(private) foreign libc {puts :: proc \"c\"(text: cstring) -> i32 ---}\n", "Procedures", "Package"),
            ("", "when true {VALUE :: 1}\n", "Constants", "Public"),
            ("", "when true {@(private) VALUE :: 1}\n", "Constants", "Package"),
        )
        for imports, declaration, kind, visibility in cases:
            for sectioned in (False, True):
                with self.subTest(declaration=declaration, sectioned=sectioned):
                    source.write_text(
                        "package src\n" + (section("Imports", "Vendor") if sectioned and imports else "")
                        + imports + (section(kind, visibility) if sectioned else "") + declaration,
                        encoding="utf-8",
                    )
                    self.check(source.parent, library=True)
                    result = self.lint(source)
                    self.assertNotEqual(result.returncode, 2, result.stderr)
                    self.assertEqual("SECTION003" in result.stderr, not sectioned, result.stderr)

    def test_conditional_using_preserves_outer_procedure_targets(self):
        source = self.write("src/main.odin")
        for condition, expected in (("#config(FLAG, false)", 0), ("false", 0), ("true", 1)):
            for setup, promotion in (("", "using value := Value{helper = other}; _ = value"),
                                     ("value := Value{helper = other}; _ = value;", "using value")):
                with self.subTest(condition=condition, promotion=promotion):
                    source.write_text(
                        "#+feature using-stmt\npackage src\n" + section("Types", "Public")
                        + "Value :: struct {helper: proc()}\n" + section("Procedures", "Public")
                        + f"main :: proc() {{{setup} when {condition} {{{promotion}}}; helper()}}\n"
                        + "other :: proc() {}\nwork :: proc() {helper()}\n"
                        + f"// {'-' * 16} Package {'-' * 16}\n@(private) helper :: proc() {{}}\n",
                        encoding="utf-8",
                    )
                    self.check(source.parent)
                    result = self.lint(source)
                    self.assertEqual(result.stderr.count("SIMPLIFY001: inline helper:"), expected, result.stderr)
                    self.assertEqual("LINT003" in result.stderr, False, result.stderr)

    def test_compound_literal_keys_use_complete_package_types(self):
        source = self.write("src/main.odin")
        for kind, expected in (("map[proc()]int", 0), ("struct {helper: int}", 1)):
            with self.subTest(kind=kind):
                source.write_text(
                    '#+feature dynamic-literals\npackage src\n'
                    'main :: proc() {values := ByProc{helper = 1}; _ = values; helper()}\n'
                    + f'ByProc :: {kind}\n@(private) helper :: proc() {{}}\n', encoding="utf-8",
                )
                self.check(source.parent)
                result = self.lint(source)
                self.assertEqual(result.stderr.count("SIMPLIFY001: inline helper:"), expected, result.stderr)
        source.write_text(
            '#+feature dynamic-literals\npackage src\n'
            'main :: proc() {values := ByProc{helper = 1}; _ = values; helper()}\n'
            '@(private) helper :: proc() {}\n', encoding="utf-8",
        )
        self.write("src/types.odin", 'package src\nByProc :: map[proc()]int\n')
        self.check(source.parent)
        result = self.lint(source)
        self.assertNotIn("SIMPLIFY001: inline helper:", result.stderr)

    def test_single_file_scan_counts_unselected_package_siblings(self):
        source = self.write("src/helper.odin", '#+private\npackage src\nhelper :: proc() -> int {return 1}\n')
        caller = self.write("src/main.odin")
        for calls, expected in (("_ = helper()", 1), ("_ = helper(); _ = helper()", 0)):
            with self.subTest(calls=calls):
                caller.write_text(f"package src\nmain :: proc() {{{calls}}}\n", encoding="utf-8")
                self.check(source.parent)
                result = self.lint(source)
                self.assertEqual(result.stderr.count("SIMPLIFY001: inline helper:"), expected, result.stderr)
                self.assertNotIn(str(caller), result.stderr)

    def test_symlinked_odin_siblings_prevent_incomplete_package_claims(self):
        source = self.write("src/main.odin", "package src\n" + section("Procedures", "Public")
                            + "main :: proc() {helper(); second()}\n"
                            + f"// {'-' * 16} Package {'-' * 16}\n@(private) helper :: proc() {{}}\n")
        target = self.write("extra.odin", "package src\nsecond :: proc() {helper()}\n")
        sibling = source.parent / "extra.odin"
        sibling.symlink_to(target)
        self.check(source.parent)
        result = self.lint(source)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("symlinked Odin sibling", result.stderr)
        self.assertNotIn("SIMPLIFY001", result.stderr)
        sibling.unlink()
        sibling.write_text(target.read_text(), encoding="utf-8")
        result = self.lint(source)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_package_aliases_and_file_private_names_do_not_cross_files(self):
        source = self.write("src/helper.odin", '#+private\npackage src\nhelper :: proc() -> int {return 1}\n')
        self.write("src/alias.odin", '#+private\npackage src\nalias :: helper\n')
        self.write("src/main.odin", 'package src\nmain :: proc() {_ = alias()}\n')
        self.check(source.parent)
        result = self.lint(source)
        self.assertIn("SIMPLIFY001: inline helper:", result.stderr)
        self.write("src/extra.odin", '#+private file\npackage src\nhelper :: proc "contextless"() -> int {return 2}\nVALUE := helper()\n')
        self.check(source.parent)
        result = self.lint(source)
        self.assertEqual(result.stderr.count("SIMPLIFY001: inline helper:"), 1, result.stderr)

    def test_known_using_members_only_shadow_in_their_scope(self):
        source = self.write(
            "src/main.odin", '#+feature using-stmt\npackage src\n'
            'Value :: struct {helper: int}\n'
            'work :: proc(using value: Value) {_ = helper}\n'
            'main :: proc() {work({}); _ = helper()}\n'
            '@(private) helper :: proc() -> int {return 1}\n',
        )
        self.check(source.parent)
        result = self.lint(source)
        self.assertIn("SIMPLIFY001: inline helper:", result.stderr)
        self.assertNotIn("LINT003", result.stderr)

    def test_unknown_using_only_suppresses_affected_targets(self):
        self.write("lib/lib.odin", 'package lib\nValue :: type_of(struct {number: int}{})\n')
        source = self.write(
            "src/main.odin", '#+feature using-stmt\npackage src\nimport "../lib"\n'
            'work :: proc(using value: lib.Value) {_ = helper()}\n'
            'main :: proc() {work({}); _ = other()}\n'
            '@(private) helper :: proc() -> int {return 1}\n'
            '@(private) other :: proc() -> int {return 2}\n',
        )
        self.check(source.parent)
        result = self.lint(source)
        self.assertNotIn("LINT003", result.stderr)
        self.assertNotIn("SIMPLIFY001: inline helper:", result.stderr)
        self.assertIn("SIMPLIFY001: inline other:", result.stderr)

    def test_cross_package_public_procedures_are_excluded(self):
        api = self.write("lib/api.odin", 'package lib\nhelper :: proc() -> int {return 1}\n')
        main = self.write("src/main.odin", 'package src\nimport "../lib"\nmain :: proc() {_ = lib.helper()}\n')
        self.check(main.parent)
        result = self.lint(api, main)
        self.assertNotIn("SIMPLIFY001", result.stderr)

    def test_custom_source_root(self):
        self.write("app/src/main/odin/functions/a.odin", dependency_source("engine"))
        result = self.lint("--source-root", "app/src/main/odin")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("ARCH001", result.stderr)

    def test_source_aliases_share_one_file_identity(self):
        source = self.write("src/functions/a.odin", dependency_source("effects"))
        alias = self.root / "alias"
        alias.symlink_to(source.parent, target_is_directory=True)
        result = self.lint(source, alias / source.name)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stderr.count("ARCH001"), 1, result.stderr)
        self.assertIn(str(alias / source.name), result.stderr)

    def test_source_roles_match_collection_roots_through_aliases(self):
        self.write_dependency_packages("real/src")
        source = self.write("real/src/functions/a.odin")
        alias = self.root / "alias"
        alias.symlink_to(source.parent.parent.parent, target_is_directory=True)
        for dependency, expected in (("state", 0), ("effects", 1)):
            with self.subTest(dependency=dependency):
                source.write_text(dependency_source(dependency, f'"app:{dependency}"'), encoding="utf-8")
                self.check(alias / "src" / "functions", "-collection:app=" + str(source.parent.parent), library=True)
                result = self.lint("--root", alias, "--collection", f"app={source.parent.parent}", alias / "src" / "functions")
                self.assertEqual(result.returncode, expected, result.stderr)
                if expected:
                    self.assertIn("ARCH001", result.stderr)

    def test_explicit_scan_symlinks_are_rejected(self):
        source = self.write("real/main.odin", "package src\nmain :: proc() {}\n")
        alias = self.root / "alias"
        alias.symlink_to(source.parent, target_is_directory=True)
        result = self.lint(alias)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("expected an Odin file or directory", result.stderr)

    def test_compiler_valid_callback_and_nested_procedure_examples(self):
        source = self.write("src/main.odin")
        for body, expected in (("call(proc() {})", 0), ("f := proc() {}; f()", 1)):
            with self.subTest(body=body):
                source.write_text(
                    "package src\n" + section("Procedures", "Public")
                    + f"main :: proc() {{{body}}}\ncall :: proc(cb: proc()) {{cb()}}\n", encoding="utf-8",
                )
                self.check(source.parent)
                result = self.lint(source.parent)
                self.assertNotEqual(result.returncode, 2, result.stderr)
                self.assertEqual("PROC001" in result.stderr, bool(expected), result.stderr)


if __name__ == "__main__":
    unittest.main()
