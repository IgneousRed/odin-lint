"""Compiler-backed transformations that must preserve other lint contracts."""

import os
import subprocess
import unittest

from test_cli import section
import test_policies_cli as policies


class ConflictTests(unittest.TestCase):
    setUp = policies.ProjectPolicyTests.setUp
    write = policies.ProjectPolicyTests.write
    check = policies.ProjectPolicyTests.check
    lint = policies.ProjectPolicyTests.lint

    def check_strict(self, directory):
        result = subprocess.run([os.environ.get('ODIN', 'odin'), 'check', str(directory),
                                 '-no-entry-point', '-thread-count:2', '-vet', '-vet-tabs',
                                 '-vet-using-param', '-vet-nil-deref', '-vet-uninitialized',
                                 '-vet-atomic-access', '-strict-style', '-warnings-as-errors',
                                 '-vet-packages:api,tools', '-strict-style-packages:api,tools'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def transaction(self, body, helpers="", other=False):
        self.write("src/state/state.odin", "package state\n" + section("Types", "Public")
                   + "Row :: struct {value: int}\n")
        engine = self.write("src/engine/engine.odin", "package engine\n" + section("Imports", "Project")
                            + 'import "../state"\n' + section("Types", "Public")
                            + "Owner :: struct {rows: map[int]state.Row, depth: int}\n"
                            + section("Procedures", "Public")
                            + "closed :: proc(owner" + (", other" if other else "") + ": ^Owner, flag := true) { _ = flag; "
                            + body + "}\n" + helpers)
        app = self.write("src/application/application.odin", "package application\n"
                         + section("Imports", "Project") + 'import "../engine"\n'
                         + section("Globals", "Public") + "owner, other: engine.Owner\n"
                         + section("Procedures", "Public") + "run :: proc() {engine.closed(&owner"
                         + (", &other" if other else "") + ")}\n")
        self.check(app.parent)
        return self.lint(engine, app)

    def test_complete_scope_survives_partial_full_and_deferred_inlining(self):
        for inline_enter in (False, True):
            for inline_leave in (False, True):
                for deferred in (False, True):
                    with self.subTest(enter=inline_enter, leave=inline_leave, deferred=deferred):
                        enter = "owner.depth += 1" if inline_enter else "enter(owner)"
                        leave = "owner.depth -= 1" if inline_leave else "leave(owner)"
                        helpers = ""
                        if not inline_enter:
                            helpers += '@(private="file") enter :: proc(owner: ^Owner) {owner.depth += 1}\n'
                        if not inline_leave:
                            helpers += '@(private="file") leave :: proc(owner: ^Owner) {owner.depth -= 1}\n'
                        if helpers:
                            helpers = "// ---------------- File ----------------\n" + helpers
                        body = enter + "\n" + ("defer {" + leave + "}\n" if deferred else "")
                        body += "owner.rows[1] = {value = 2}" + ("" if deferred else "\n" + leave)
                        text = self.transaction(body, helpers)
                        self.assertNotIn("OWN002", text)
                        self.assertEqual(text.count("SIMPLIFY001:"), 2-inline_enter-inline_leave)

    def test_scope_counter_effects_survive_resolved_callbacks(self):
        helpers = "// ---------------- File ----------------\n" \
                  '@(private="file") enter :: proc(owner: ^Owner) {owner.depth += 1}\n' \
                  '@(private="file") leave :: proc(owner: ^Owner) {owner.depth -= 1}\n' \
                  '@(private="file") invoke :: proc(action: proc(^Owner), owner: ^Owner) {action(owner)}\n'
        text = self.transaction("invoke(enter, owner); owner.rows[1] = {value = 2}; invoke(leave, owner)", helpers)
        self.assertNotIn("OWN002", text)

    def test_unfinished_scopes_still_fail_at_the_caller(self):
        helpers = "// ---------------- File ----------------\n" \
                  '@(private="file") leave :: proc(owner: ^Owner) {owner.depth -= 1}\n'
        text = self.transaction("owner.depth += 1; owner.rows[1] = {value = 2}", helpers)
        self.assertIn("OWN002", text)
        self.assertIn("without a matching finish/rollback", text)

    def test_conditional_and_repeated_counter_changes_remain_unbalanced(self):
        for body in ("owner.depth += 1; owner.rows[1] = {value = 2}; if flag {owner.depth -= 1}",
                     "owner.depth += 1; owner.depth += 1; owner.rows[1] = {value = 2}; owner.depth -= 1"):
            with self.subTest(body=body):
                self.assertIn("OWN002", self.transaction(body))

    def test_writes_before_or_after_a_complete_scope_still_need_a_caller_scope(self):
        for body in ("owner.rows[1] = {value = 2}; owner.depth += 1; owner.depth -= 1",
                     "owner.depth += 1; owner.depth -= 1; owner.rows[1] = {value = 2}"):
            with self.subTest(body=body):
                self.assertIn("OWN002", self.transaction(body))

    def test_counter_scope_does_not_authorize_another_owner(self):
        text = self.transaction("owner.depth += 1; other.rows[1] = {value = 2}; owner.depth -= 1", other=True)
        self.assertIn("OWN002", text)
        self.assertIn("requires a matching transaction", text)

    def test_public_procedure_exports_survive_majority_reorganization(self):
        public = "one :: proc() -> int {return first()+second()+third()}\n" \
                 "two :: proc() -> int {return first()+second()+third()}\n"
        support = "first :: proc() -> int {return 1}\nsecond :: proc() -> int {return 2}\nthird :: proc() -> int {return 3}\n"
        api = self.write("src/api/api.odin", "package api\n" + section("Procedures", "Public") + public
                         + "// ---------------- Package ----------------\n"
                         + "".join("@(private) " + line + "\n" for line in support.splitlines()))
        consumer = self.write("tools/tools.odin", 'package tools\nimport "../src/api"\n'
                              'read :: proc() -> int {return api.one()+api.two()}\n')
        self.check(consumer.parent)
        self.assertIn("FILE006: reorganize visibility groups", self.lint(api))
        api.write_text("package api\n" + section("Procedures", "Public") + public, encoding="utf-8")
        helper = self.write("src/api/support.odin", "#+private\npackage api\n" + section("Procedures", "Package") + support)
        self.check(consumer.parent)
        self.assertNotIn("FILE006", self.lint(api, helper))
        self.assertNotIn("FILE004", self.lint(api, helper))
        self.assertNotIn("VIS002", self.lint(api, helper))

    def test_mixed_visibility_advice_protects_file_private_support(self):
        api = self.write("src/api/api.odin", "package api\n" + section("Procedures", "Public")
                         + "one :: proc() -> int {return first()+second()+third()}\n"
                         + "two :: proc() -> int {return first()+second()+third()}\n"
                         + "// ---------------- File ----------------\n"
                         + '@(private="file") first :: proc() -> int {return 1}\n'
                         + '@(private="file") second :: proc() -> int {return 2}\n'
                         + '@(private="file") third :: proc() -> int {return 3}\n')
        consumer = self.write("tools/tools.odin", 'package tools\nimport "../src/api"\n'
                              'read :: proc() -> int {return api.one()+api.two()}\n')
        self.check_strict(consumer.parent)
        text = self.lint(api)
        self.assertNotIn("FILE006", text)
        self.assertNotIn("FILE005", text)
        self.assertNotIn("VIS002", text)
        self.assertNotIn("FILE004", text)
        self.assertEqual(text, "")

    def test_transitive_file_private_closure_preserves_its_required_public_default(self):
        api = self.write("src/api/api.odin", "package api\n" + section("Procedures", "Public")
                         + "one :: proc() -> int {return first()}\ntwo :: proc() -> int {return first()}\n"
                         + "// ---------------- File ----------------\n"
                         + '@(private="file") first :: proc() -> int {return second()+second()}\n'
                         + '@(private="file") second :: proc() -> int {return third()+third()}\n'
                         + '@(private="file") third :: proc() -> int {return 1}\n')
        consumer = self.write("tools/tools.odin", 'package tools\nimport "../src/api"\n'
                              'read :: proc() -> int {return api.one()+api.two()}\n')
        self.check_strict(consumer.parent)
        self.assertEqual(self.lint(api), "")

    def test_package_private_gate_still_allows_a_visibility_preserving_split(self):
        public = 'one :: proc() -> int {return gate()}\ntwo :: proc() -> int {return gate()}\n'
        names = ('first', 'second', 'third', 'fourth', 'fifth')
        gate = 'gate :: proc() -> int {return ' + '+'.join(name+'()' for name in names*2) + '}\n'
        support = ''.join(name + ' :: proc() -> int {return 1}\n' for name in names)
        api = self.write('src/api/api.odin', 'package api\n' + section('Procedures', 'Public') + public
                         + '// ---------------- Package ----------------\n@(private) ' + gate
                         + '// ---------------- File ----------------\n'
                         + ''.join('@(private="file") '+line+'\n' for line in support.splitlines()))
        consumer = self.write('tools/tools.odin', 'package tools\nimport "../src/api"\n'
                              'read :: proc() -> int {return api.one()+api.two()}\n')
        self.check_strict(consumer.parent)
        self.assertIn('FILE006: reorganize visibility groups', self.lint(api))
        api.write_text('package api\n' + section('Procedures', 'Public') + public)
        helper = self.write('src/api/support.odin', '#+private file\npackage api\n'
                            + section('Procedures', 'Package') + '@(private) '+gate
                            + '// ---------------- File ----------------\n' + support)
        self.check_strict(consumer.parent)
        self.assertEqual(self.lint(api, helper), '')

    def test_unanchored_private_majority_still_receives_reorganization_advice(self):
        api = self.write('src/api/api.odin', 'package api\n' + section('Procedures', 'Public')
                         + 'one :: proc() -> int {return 1}\ntwo :: proc() -> int {return 2}\n'
                         + '// ---------------- File ----------------\n'
                         + '@(private="file") first :: proc() -> int {return 1}\n'
                         + '@(private="file") second :: proc() -> int {return 2}\n'
                         + '@(private="file") third :: proc() -> int {return 3}\n')
        consumer = self.write('tools/tools.odin', 'package tools\nimport "../src/api"\n'
                              'read :: proc() -> int {return api.one()+api.two()}\n')
        self.check_strict(consumer.parent)
        self.assertIn('FILE006: reorganize visibility groups', self.lint(api))

    def test_default_change_preserves_package_visibility_for_siblings(self):
        interface = self.write("src/sample/sample.odin", "#+private\npackage sample\n"
                               + section("Constants", "Package") + "A :: C+D+E\nB :: C*D*E\n"
                               + "// ---------------- File ----------------\n"
                               + '@(private="file") C :: 3\n@(private="file") D :: 4\n@(private="file") E :: 5\n')
        sibling = self.write("src/sample/other.odin", "#+private file\npackage sample\n"
                             + section("Procedures", "File") + "read :: proc() -> int {return A+B}\n")
        self.check(interface.parent)
        self.assertIn("preserving other declarations' visibility with explicit private attributes", self.lint(interface))
        interface.write_text("#+private file\npackage sample\n" + section("Constants", "Package")
                             + "@(private) A :: C+D+E\n@(private) B :: C*D*E\n"
                             + "// ---------------- File ----------------\nC :: 3\nD :: 4\nE :: 5\n", encoding="utf-8")
        self.check(interface.parent)
        self.assertNotIn("FILE006", self.lint(interface, sibling))
        self.assertNotIn("VIS001", self.lint(interface, sibling))

    def test_conditional_exports_are_preserved_even_when_excluded_from_the_vote(self):
        api = self.write("src/api/api.odin", 'package api\nEXPORT_API :: #config(EXPORT_API, true)\n'
                         'when EXPORT_API {one :: proc() -> int {return first()+second()+third()}}\n'
                         '@(private) first :: proc() -> int {return 1}\n'
                         '@(private) second :: proc() -> int {return 2}\n'
                         '@(private) third :: proc() -> int {return 3}\n')
        consumer = self.write("tools/tools.odin", 'package tools\nimport "../src/api"\n'
                              'read :: proc() -> int {return api.one()}\n')
        self.check(consumer.parent)
        self.assertIn("preserve public exports", self.lint(api))


if __name__ == "__main__":
    unittest.main()
