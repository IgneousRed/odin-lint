"""Compiler-backed regressions from the semantic finishing review."""

import unittest

import test_semantics_cli as semantic_cases


class FinishSemanticTests(unittest.TestCase):
    setUp = semantic_cases.SemanticTests.setUp
    write = semantic_cases.SemanticTests.write
    inspect = semantic_cases.SemanticTests.inspect
    inspect_borrowed = semantic_cases.SemanticTests.inspect_borrowed
    engine = semantic_cases.SemanticTests.engine

    def test_builtin_pop_requires_owned_storage(self):
        self.write("state", "Store :: struct {values: [dynamic]int}\n")
        source = self.write("functions", "run :: proc(store: ^state.Store) {_ = pop(&store.values)}\n",
                            'import "../state"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source))
        source = self.write("functions", "run :: proc() {values := make([dynamic]int); "
                            "append(&values, 1); _ = pop(&values); delete(values)}\n")
        self.assertNotIn("OWN001", self.inspect(source))

    def test_unknown_foreign_callback_is_nonblocking_through_an_invoker(self):
        source = self.write("functions", 'foreign import libc "system:c"\n'
                            'foreign libc {foreign_action :: proc "c" () ---}\n'
                            'invoke :: proc(callback: proc "c" ()) {callback()}\n'
                            'run :: proc() {invoke(foreign_action)}\n')
        self.assertNotIn("LINT004", self.inspect(source))


    def shared_views(self):
        self.write("views", "Read :: struct {paths: map[string]bool}\n")
        self.write("engine", "Owner :: struct {using read: views.Read, rows: map[int]state.Row}\n"
                   "Local :: struct {using read: views.Read, meaningful: ^Owner}\n",
                   'import "../state"\nimport "../views"\n')

    def test_local_embedding_does_not_make_meaningful_view_writable(self):
        self.shared_views()
        source = self.write("procedures", 'change :: proc(owner: ^engine.Owner) {owner.paths["button"] = true}\n',
                            'import "../engine"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source, call='change(&live)', declarations='live: engine.Owner', modules=('engine',)))

    def test_shared_view_still_allows_explicit_local_cache(self):
        self.shared_views()
        source = self.write("procedures", 'change :: proc(local: ^engine.Local) {local.paths["button"] = true}\n',
                            'import "../engine"\n')
        self.assertNotIn("OWN001", self.inspect(source))

    def test_nil_branch_does_not_hide_an_assigned_callback_effect(self):
        self.write("functions/hidden", "noisy :: proc() {fmt.println(1)}\n", 'import "core:fmt"\n')
        source = self.write("functions", "invoke :: proc(callback: proc()) {callback()}\n"
                            "run :: proc(choose: bool) {callback: proc() = nil; "
                            "if choose {callback = hidden.noisy}; invoke(callback)}\n",
                            'import "./hidden"\n')
        self.assertIn("ARCH007", self.inspect(source))


if __name__ == "__main__":
    unittest.main()
