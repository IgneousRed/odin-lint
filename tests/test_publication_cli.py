"""Only established live-publication contracts produce OWN005 findings."""

import unittest

import test_semantics_cli as semantics


class PublicationTests(unittest.TestCase):
    setUp = semantics.SemanticTests.setUp
    write = semantics.SemanticTests.write
    inspect = semantics.SemanticTests.inspect
    inspect_borrowed = semantics.SemanticTests.inspect_borrowed
    engine = semantics.SemanticTests.engine

    def contract(self):
        self.engine()
        with (self.root / "src/engine/engine.odin").open("a") as stream:
            stream.write("publish :: proc(destination, source: ^Owner, approved: bool, base, current: int) {\n"
                         "assert(approved)\nassert(base == current)\n"
                         "destination^ = source^\nsource^ = {}\n}\n")

    def live_call(self, body, declarations="", parameters=""):
        return self.write("effects", "live: engine.Owner\n" + declarations
                          + f"run :: proc({parameters}) {{\nprepared: engine.Owner\n{body}\n}}\n",
                          'import "../engine"\n')

    def test_only_contradicted_preconditions_at_live_destinations_fail(self):
        self.contract()
        # Two nonzero values are not evidence of equal integer revisions.
        for args, violation in (("false, 0, 0", True), ("true, 0, 1", True),
                                ("true, 1, 0", True), ("true, 0, 0", False),
                                ("true, 1, 2", False), ("approved, 0, 0", False)):
            with self.subTest(args=args):
                source = self.live_call(f"engine.publish(&live, &prepared, {args})", parameters="approved: bool")
                text = self.inspect(source)
                self.assertEqual("OWN005" in text, violation, text)
                self.assertNotIn("OWN001", text)

    def test_private_transfer_does_not_become_an_assertion_checker(self):
        self.contract()
        source = self.write("effects", "run :: proc() {\nowner, prepared: engine.Owner\n"
                            "engine.publish(&owner, &prepared, false, 0, 1)\n}\n",
                            'import "../engine"\n')
        self.assertNotIn("OWN005", self.inspect(source))

    def test_diagnostic_identifies_each_failed_condition_and_source_location(self):
        self.contract()
        path = self.root / "src/engine/engine.odin"
        lines = path.read_text().splitlines()
        for arguments, expression in (("false, 0, 0", "approved"), ("true, 0, 1", "base == current")):
            with self.subTest(expression=expression):
                source = self.live_call(f"engine.publish(&live, &prepared, {arguments})")
                text = self.inspect(source)
                line = lines.index(f"assert({expression})") + 1
                findings = [entry for entry in text.splitlines() if "OWN005:" in entry]
                self.assertEqual(len(findings), 1, text)
                self.assertIn(f'publication via publish contradicts precondition "{expression}" must be true', findings[0])
                self.assertIn(f"{path}({line}:8)", findings[0])

    def test_negated_and_repeated_requirements_keep_precise_evidence_without_duplicates(self):
        self.engine()
        path = self.root / "src/engine/engine.odin"
        with path.open("a") as stream:
            stream.write("transfer :: proc(destination, source: ^Owner, rejected: bool) {\n"
                         "assert(!rejected)\nassert(rejected == false)\n"
                         "destination^ = source^\nsource^ = {}\n}\n")
        source = self.live_call("engine.transfer(&live, &prepared, true)")
        text = self.inspect(source)
        findings = [entry for entry in text.splitlines() if "OWN005:" in entry]
        self.assertEqual(len(findings), 1, text)
        self.assertIn('precondition "rejected" must be false', findings[0])

    def test_diagnostic_uses_original_assertion_position_after_parser_recovery(self):
        self.engine()
        path = self.root / "src/engine/engine.odin"
        with path.open("a") as stream:
            stream.write("range_probe :: proc() {\nvalues := [1]int{1}\n"
                         "for value, index in values {item := value + index\n_ = item\n}\n}\n"
                         "publish :: proc(destination, source: ^Owner, approved: bool) {\n"
                         "assert(\n    approved,\n)\ndestination^ = source^\nsource^ = {}\n}\n")
        line = path.read_text().splitlines().index("    approved,") + 1
        source = self.live_call("engine.publish(&live, &prepared, false)")
        text = self.inspect(source)
        findings = [entry for entry in text.splitlines() if "OWN005:" in entry]
        self.assertEqual(len(findings), 1, text)
        self.assertIn('precondition "approved" must be true', findings[0])
        self.assertIn(f"{path}({line}:5)", findings[0])

    def test_named_arguments_and_unknown_callback_protocols(self):
        self.contract()
        callback = "invoke :: proc(callback: proc(^engine.Owner, ^engine.Owner, bool, int, int), destination, source: ^engine.Owner, approved: bool, base, current: int) {callback(destination, source, approved, base, current)}\n"
        for approved in ("false", "true"):
            for direct in (False, True):
                with self.subTest(approved=approved, direct=direct):
                    body = (f"engine.publish(current = 0, source = &prepared, base = 0, approved = {approved}, destination = &live)"
                            if direct else f"invoke(engine.publish, &live, &prepared, {approved}, 0, 0)")
                    source = self.live_call(body, callback)
                    text = self.inspect(source)
                    self.assertEqual("OWN005" in text, direct and approved == "false", text)

    def test_unknown_or_branch_local_contracts_remain_inconclusive(self):
        self.engine()
        for prelude, ending in (("assert(approved)", ""),
                                ("assert(approved)", "if approved {source^ = {}}"),
                                ("if approved {assert(approved)}", "source^ = {}"),
                                ("assert(approved || base == current)", "source^ = {}")):
            with self.subTest(prelude=prelude, ending=ending):
                path = self.root / "src/engine/engine.odin"
                original = path.read_text()
                path.write_text(original + "transfer :: proc(destination, source: ^Owner, approved: bool, base, current: int) {\n"
                                + prelude + "\ndestination^ = source^\n" + ending + "\n}\n")
                source = self.live_call("engine.transfer(&live, &prepared, false, 0, 0)")
                self.assertNotIn("OWN005", self.inspect(source))
                path.write_text(original)

    def test_wrappers_do_not_invent_contracts_from_conditional_origins(self):
        self.contract()
        for body in (
            "if !approved {return}\nengine.publish(owner, &prepared, approved, 0, 0)",
            "engine.publish(owner, &prepared, approved if choose else true, 0, 0)",
            "approval := approved\nif !choose {approval = true}\nengine.publish(owner, &prepared, approval, 0, 0)",
        ):
            with self.subTest(body=body):
                source = self.write("procedures", "run :: proc(owner: ^engine.Owner, approved, choose: bool) {\n"
                                    "prepared: engine.Owner\n" + body + "\n}\n", 'import "../engine"\n')
                text = self.inspect_borrowed(source, call="run(&live, false, false)",
                                             declarations="live: engine.Owner", modules=("engine",))
                self.assertNotIn("OWN005", text)

    def test_negation_and_conjunction_keep_their_actual_polarity(self):
        self.engine()
        with (self.root / "src/engine/engine.odin").open("a") as stream:
            stream.write("transfer :: proc(destination, source: ^Owner, rejected: bool, base, current: int) {\n"
                         "assert(!rejected && base == current)\ndestination^ = source^\nsource^ = {}\n}\n")
        for args, violation in (("true, 0, 0", True), ("false, 0, 1", True), ("false, 0, 0", False)):
            with self.subTest(args=args):
                source = self.live_call(f"engine.transfer(&live, &prepared, {args})")
                self.assertEqual("OWN005" in self.inspect(source), violation)

    def test_side_effecting_assertion_does_not_create_entry_value_contracts(self):
        self.engine()
        with (self.root / "src/engine/engine.odin").open("a") as stream:
            stream.write("reset :: proc(owner: ^Owner) -> bool {owner.revision = 0; return true}\n"
                         "transfer :: proc(destination, source: ^Owner) {\n"
                         "assert(reset(source))\nassert(source.revision == 0)\n"
                         "destination^ = source^\nsource^ = {}\n}\n")
        source = self.live_call("prepared.revision = 1\nengine.transfer(&live, &prepared)")
        self.assertNotIn("OWN005", self.inspect(source))

    def test_private_copy_does_not_require_clearing_its_source(self):
        self.engine()
        with (self.root / "src/engine/engine.odin").open("a") as stream:
            stream.write("copy :: proc(destination, source: ^Owner) {destination^ = source^}\n")
        source = self.write("effects", "run :: proc() {owner, prepared: engine.Owner; engine.copy(&owner, &prepared)}\n",
                            'import "../engine"\n')
        self.assertNotIn("OWN005", self.inspect(source))


if __name__ == "__main__":
    unittest.main()
