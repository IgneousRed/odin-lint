"""Local caches keep their role through nested owner slots and saved aliases."""

import unittest

import test_semantics_cli as semantic
from test_cli import section
import test_ownership_052_cli as fixture


class LocalCacheTests(unittest.TestCase):
    setUp = semantic.SemanticTests.setUp
    write = semantic.SemanticTests.write
    check = fixture.Ownership052Tests.check
    lint = fixture.Ownership052Tests.lint

    def fixture(self):
        self.write("views", "Read :: struct {paths: map[string]bool, index: map[int]state.Row}\n",
                   'import "../state"\n')
        self.write("engine", "Owner :: struct {rows: map[int]state.Row, flags: map[string]bool}\n"
                   "Input :: struct {using read: views.Read, meaningful: ^Owner, selected: int, transaction: Transaction}\n"
                   "Transaction :: struct {depth, saved: int}\n"
                   "enter :: proc(input: ^Input) {input.transaction.saved = input.selected; input.transaction.depth += 1}\n"
                   "leave :: proc(input: ^Input) -> bool {input.transaction.depth -= 1; return true}\n"
                   "index_update :: proc(input: ^Input) {input.index[1] = {}}\n"
                   "borrow_cache :: proc(input: ^Input, owner: ^Owner) {input.paths = owner.flags}\n",
                   'import "../state"\nimport "../views"\n')
        self.write("effects", "Session :: struct {input: engine.Input, meaningful: engine.Owner}\n"
                   "session: Session\nshared: engine.Owner\n"
                   "fresh :: proc() -> engine.Input {return {}}\n", 'import "../engine"\n')
        self.write("procedures", "cache :: proc(input: ^engine.Input) {clear(&input.paths); input.paths[\"frame\"] = true}\n"
                   "forward :: proc(input: ^engine.Input) {cache(input)}\n"
                   "invoke :: proc(action: proc(^engine.Input), input: ^engine.Input) {action(input)}\n"
                   "scoped :: proc(input: ^engine.Input) {engine.enter(input); defer assert(engine.leave(input)); input.selected = 3}\n"
                   "index :: proc(input: ^engine.Input) {engine.enter(input); defer assert(engine.leave(input)); input.index[1] = {}}\n"
                   "meaningful :: proc(input: ^engine.Input) {engine.enter(input); defer assert(engine.leave(input)); input.meaningful.rows[1] = {}}\n",
                   'import "../engine"\n')

    def application(self, body):
        source = self.write("application", section("Procedures", "Public")
                            + "run :: proc() {_ = engine.Input{}; _ = effects.Session{}; " + body + "}\n",
                            section("Imports", "Project")
                            + 'import "../effects"\nimport "../engine"\nimport "../procedures"\n')
        self.check(source.parent)
        return self.lint(source)

    def test_nested_global_cache_and_forwarded_aliases_keep_local_role(self):
        self.fixture()
        for setup in ("input := &effects.session.input;", "session: effects.Session; input := &session.input;",
                      "value := effects.fresh(); input := &value;",
                      "value := engine.Input{meaningful = &effects.shared}; input := &value;"):
            for call in ("procedures.cache(input)", "procedures.forward(input)",
                         "procedures.invoke(procedures.cache, input)"):
                with self.subTest(setup=setup, call=call):
                    self.assertEqual(self.application(setup + "alias := input; " + call.replace("input", "alias")), "")

    def test_nested_global_local_transaction_still_authorizes_working_scalar(self):
        self.fixture()
        self.assertEqual(self.application("procedures.scoped(&effects.session.input)"), "")

    def test_local_transaction_does_not_authorize_indexes_or_meaningful_referents(self):
        self.fixture()
        for operation, field in (("index", "read.index"), ("meaningful", "meaningful.rows")):
            for setup in ("input := &effects.session.input;",
                          "value := effects.session.input; input := &value;"):
                with self.subTest(operation=operation, setup=setup):
                    output = self.application(setup + f"procedures.{operation}(input)")
                    self.assertIn("OWN001:", output)
                    self.assertIn("(including field " + field, output)

    def test_local_cache_cannot_launder_an_explicit_meaningful_map_alias(self):
        self.fixture()
        output = self.application("input := &effects.session.input; "
                                  "engine.borrow_cache(input, &effects.shared); procedures.cache(input)")
        self.assertIn("OWN001:", output)
        self.assertIn("(including field read.paths", output)


if __name__ == "__main__":
    unittest.main()
