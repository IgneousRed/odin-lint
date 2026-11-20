"""Callback inference through procedure dependencies and record fields."""

import re
import unittest

import test_ownership_052_cli as fixture


class InferenceTests(unittest.TestCase):
    setUp = fixture.Ownership052Tests.setUp
    write = fixture.Ownership052Tests.write
    check = fixture.Ownership052Tests.check
    lint = fixture.Ownership052Tests.lint

    def test_returned_callback_chain_revisits_earlier_callers(self):
        source = self.write("functions", "run :: proc() {\n"
                            "callback := first()\ncallback()\n}\n"
                            "first :: proc() -> proc() {return second()}\n"
                            "second :: proc() -> proc() {return noisy}\n"
                            "noisy :: proc() {fmt.println(1)}\n", 'import "core:fmt"\n')
        self.check(source.parent)
        findings = self.lint(source)
        line = source.read_text().splitlines().index("callback()") + 1
        self.assertRegex(findings, re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:")

    def test_nested_summary_changes_revisit_enclosing_body(self):
        source = self.write("functions", "run :: proc() {\n"
                            "nested := proc() {later()}\nnested()\n}\n"
                            "later :: proc() {noisy()}\n"
                            "noisy :: proc() {fmt.println(1)}\n", 'import "core:fmt"\n')
        self.check(source.parent)
        findings = self.lint(source)
        line = source.read_text().splitlines().index("nested()") + 1
        self.assertRegex(findings, re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:")

    def test_grouped_fields_keep_callbacks_in_their_actual_slots(self):
        names = ("head", "left", "right", "tail")
        for named in (False, True):
            for effectful in (*names, None, "unknown"):
                with self.subTest(named=named, effectful=effectful):
                    fallback = "unknown" if effectful == "unknown" else "quiet"
                    values = ["Leaf{" + ("noisy" if name == effectful else fallback) + "}"
                              for name in names]
                    elements = [name + "=" + value if named else value
                                for name, value in zip(names, values)]
                    tree = "Tree{first=pair, second=pair}" if named else "Tree{pair, pair}"
                    source = self.write("functions",
                                        "Leaf :: struct {callback: proc()}\n"
                                        "Pair :: struct {head: Leaf, left, right: Leaf, tail: Leaf}\n"
                                        "Tree :: struct {first, second: Pair}\n"
                                        "pass :: proc(value: Tree) -> Tree {return value}\n"
                                        "run :: proc(unknown: proc()) {\n_ = unknown\n"
                                        "pair := Pair{" + ", ".join(elements) + "}\n"
                                        "tree := pass(" + tree + ")\n"
                                        + "\n".join("tree.second." + name + ".callback()" for name in names)
                                        + "\n}\nquiet :: proc() {}\nnoisy :: proc() {fmt.println(1)}\n",
                                        'import "core:fmt"\n')
                    self.check(source.parent)
                    findings = self.lint(source)
                    lines = source.read_text().splitlines()
                    for name in names:
                        line = lines.index("tree.second." + name + ".callback()") + 1
                        found = re.search(re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:", findings)
                        self.assertEqual(found is not None, name == effectful, findings)


if __name__ == "__main__":
    unittest.main()
