"""Copying a record preserves reference children, not its source container."""

import unittest

import test_ownership_052_cli as fixture
from test_cli import section


class OwnershipCopyingTests(unittest.TestCase):
    setUp = fixture.Ownership052Tests.setUp
    write = fixture.Ownership052Tests.write
    check = fixture.Ownership052Tests.check
    lint = fixture.Ownership052Tests.lint

    def owner(self):
        self.write("state", "Facts :: struct {rows: [2]int, borrowed: []int}\n")
        self.write("engine", "Owner :: struct {facts: state.Facts}\n"
                   '@(private="file")\nlive: Owner\n'
                   "prepare :: proc() {live.facts.borrowed = make([]int, 1)}\n"
                   "destroy :: proc() {delete(live.facts.borrowed); live = {}}\n"
                   "snapshot :: proc() -> Owner {return live}\n"
                   "borrow :: proc() -> ^Owner {return &live}\n", 'import "../state"\n')

    def main(self, body, imports=""):
        path = self.root / "main/main.odin"
        path.parent.mkdir(exist_ok=True)
        path.write_text("package main\n" + section("Imports", "Project")
                        + 'import "../src/engine"\n' + imports
                        + section("Procedures", "Public") + "main :: proc() {\n"
                        "\tengine.prepare()\n\tdefer engine.destroy()\n"
                        + "\n".join("\t" + line for line in body.splitlines()) + "\n}\n")
        return path

    def test_helper_record_copy_keeps_destination_ownership_and_child_borrows(self):
        self.owner()
        helper = self.write("effects/transfer", "copy_into :: proc(destination, source: ^engine.Owner) {destination^ = source^}\n",
                            'import "../../engine"\n')
        for destination, change, invalid in (
            ("destination", "destination.facts.rows[0] = 7", False),
            ("destination", "destination.facts.borrowed[0] = 7", True),
            ("engine.borrow()", "", True),
        ):
            with self.subTest(destination=destination, change=change):
                main = self.main("source := engine.snapshot()\n"
                                 "destination := new(engine.Owner)\ndefer free(destination)\n"
                                 "transfer.copy_into(" + destination + ", &source)\n" + change,
                                 'import "../src/effects/transfer"\n')
                self.check(main.parent, entry=True, run=True)
                self.assertEqual("OWN001:" in self.lint(main, helper), invalid)


    def test_pointer_formal_rebinds_the_supplied_slot_not_its_old_backing(self):
        self.owner()
        helper = self.write("effects/transfer", "clear :: proc(slot: ^[]int) {slot^ = nil}\n")
        for body, invalid in (
            ("owner := engine.snapshot(); transfer.clear(&owner.facts.borrowed); "
             "assert(owner.facts.borrowed == nil && len(engine.snapshot().facts.borrowed) == 1)", False),
            ("transfer.clear(&engine.borrow().facts.borrowed)", True),
        ):
            with self.subTest(body=body):
                main = self.main(body, 'import "../src/effects/transfer"\n')
                self.check(main.parent, entry=True, run=not invalid)
                findings = self.lint(main, helper)
                self.assertEqual("OWN001:" in findings, invalid, findings)
