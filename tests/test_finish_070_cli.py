"""Confirmed finishing regressions for publication proofs and lifecycle scopes."""

import unittest

import test_semantics_cli as semantics
import test_publication_cli as publication


class Finish070Tests(unittest.TestCase):
    setUp = semantics.SemanticTests.setUp
    write = semantics.SemanticTests.write
    inspect = semantics.SemanticTests.inspect
    inspect_borrowed = semantics.SemanticTests.inspect_borrowed
    engine = semantics.SemanticTests.engine
    live_call = publication.PublicationTests.live_call

    def transfer(self):
        self.engine()
        with (self.root / "src/engine/engine.odin").open("a") as stream:
            stream.write("publish :: proc(destination, source: ^Owner) {\n"
                         "assert(source.revision == 0)\ndestination^ = source^\nsource^ = {}\n}\n"
                         "reset :: proc(owner: ^Owner) {owner.revision = 0}\n"
                         "read :: proc(owner: ^Owner) -> u64 {return owner.revision}\n")

    def test_scalar_proofs_do_not_survive_mutating_or_unknown_calls(self):
        self.transfer()
        for reset in ("engine.reset(&prepared)", "mem.zero_item(&prepared.revision)", "reset(&prepared)"):
            with self.subTest(reset=reset):
                source = self.live_call("prepared.revision = 1\n" + reset + "\nengine.publish(&live, &prepared)",
                                        parameters="reset: proc(^engine.Owner)")
                if reset.startswith("mem."):
                    source.write_text(source.read_text().replace('import "../engine"', 'import "../engine"\nimport "core:mem"'))
                self.assertNotIn("OWN005", self.inspect(source))

    def test_actual_contradiction_remains_visible_after_readonly_calls(self):
        self.transfer()
        source = self.live_call("prepared.revision = 1\n_ = engine.read(&prepared)\nengine.publish(&live, &prepared)")
        self.assertIn("OWN005", self.inspect(source))

    def test_unknown_mutation_in_one_branch_keeps_later_proof_inconclusive(self):
        self.transfer()
        source = self.live_call("prepared.revision = 1\nif choose {reset(&prepared)}\nengine.publish(&live, &prepared)",
                                parameters="choose: bool, reset: proc(^engine.Owner)")
        self.assertNotIn("OWN005", self.inspect(source))

    def test_literal_preconditions_remain_fresh_after_an_unknown_call(self):
        publication.PublicationTests.contract(self)
        source = self.live_call("reset(&prepared)\nengine.publish(&live, &prepared, false, 0, 0)",
                                parameters="reset: proc(^engine.Owner)")
        self.assertIn("OWN005", self.inspect(source))

    def test_transfer_clear_requires_an_unchanged_adjacent_alias(self):
        self.engine()
        for rebind in (False, True):
            with self.subTest(rebind=rebind):
                path = self.root / "src/engine/engine.odin"
                original = path.read_text()
                path.write_text(original + "transfer :: proc(destination, source, other: ^Owner, approved: bool) {\n"
                                "assert(approved)\ncurrent := source\ndestination^ = current^\n"
                                + ("current = other\n" if rebind else "") + "current^ = {}\n}\n")
                source = self.live_call("other: engine.Owner\nengine.transfer(&live, &prepared, &other, false)")
                self.assertEqual("OWN005" in self.inspect(source), not rebind)
                path.write_text(original)

    def test_owner_copy_does_not_exempt_another_owner_mutation(self):
        self.engine()
        for scoped in (False, True):
            with self.subTest(scoped=scoped):
                path = self.root / "src/engine/engine.odin"
                original = path.read_text()
                path.write_text(original + "change :: proc(destination, source, other: ^Owner) {\n"
                                "destination^ = source^\n" + ("enter(other)\n" if scoped else "")
                                + "other.rows[1] = {}\n" + ("assert(leave(other))\n" if scoped else "") + "}\n")
                source = self.live_call("engine.change(&live, &prepared, &other)", declarations="other: engine.Owner\n")
                text = self.inspect(source)
                self.assertEqual("OWN002" in text, not scoped, text)
                path.write_text(original)

    def test_owner_copy_before_a_complete_transaction_needs_no_extra_scope(self):
        self.engine()
        with (self.root / "src/engine/engine.odin").open("a") as stream:
            stream.write("change :: proc(destination, source: ^Owner) {\n"
                         "destination^ = source^\nenter(destination)\ndestination.rows[1] = {}\nassert(leave(destination))\n}\n")
        source = self.live_call("engine.change(&live, &prepared)")
        self.assertNotIn("OWN002", self.inspect(source))

    def test_plain_owner_copy_remains_a_lifecycle_operation(self):
        self.engine()
        with (self.root / "src/engine/engine.odin").open("a") as stream:
            stream.write("copy :: proc(destination, source: ^Owner) {destination^ = source^}\n")
        source = self.live_call("engine.copy(&live, &prepared)")
        self.assertNotIn("OWN002", self.inspect(source))


if __name__ == "__main__":
    unittest.main()
