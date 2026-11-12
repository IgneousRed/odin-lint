"""Compiler-backed counterexamples from the five-project consumer audit."""

import unittest

import test_semantics_cli as semantic


class AuditRegressions(unittest.TestCase):
    setUp = semantic.SemanticTests.setUp
    write = semantic.SemanticTests.write
    inspect = semantic.SemanticTests.inspect
    inspect_borrowed = semantic.SemanticTests.inspect_borrowed
    engine = semantic.SemanticTests.engine


    def test_fresh_row_assignment_is_not_owner_initialization(self):
        self.engine()
        source = self.write("application", "owner: engine.Owner\nrun :: proc() {engine.update(&owner)}\n", 'import "../engine"\n')
        self.assertIn("OWN002", self.inspect(source))


    def test_conditional_owner_reset_does_not_prove_initialization(self):
        self.engine()
        path = self.root / "src/engine/engine.odin"
        path.write_text(path.read_text() + "maybe_update :: proc(owner: ^Owner, enabled: bool) {if enabled {owner^ = {}}; owner.rows[1] = {}}\n")
        source = self.write("application", "owner: engine.Owner\nrun :: proc() {engine.maybe_update(&owner, false)}\n", 'import "../engine"\n')
        self.assertIn("OWN002", self.inspect(source))

    def test_reset_preserves_destination_write_restrictions(self):
        self.engine()
        path = self.root / "src/engine/engine.odin"
        path.write_text(path.read_text() + "reset :: proc(owner: ^Owner) {owner^ = {}}\n")
        source = self.write("effects", "run :: proc(owner: ^engine.Owner) {engine.reset(owner); owner.rows[1] = {}}\n", 'import "../engine"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source, declarations="live: engine.Owner", modules=("engine",)))


    def test_named_memory_destination_is_found_after_length(self):
        source = self.write("functions", "run :: proc(store: ^state.Store) {mem.zero(len = len(store.values)*size_of(int), data = raw_data(store.values))}\n", 'import "../state"\nimport "core:mem"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source))

    def test_uncertain_interface_dependencies_stay_with_their_callers(self):
        source = self.write("functions", '@(private = "file") VALUE :: 1\n'
                            'when ODIN_OS == .Windows {helper :: proc() -> int {return VALUE}} else {helper :: proc() -> int {return VALUE}}\n'
                            'run :: proc() -> int {return helper()}\n')
        consumer = self.write("application", "run :: proc() -> int {return functions.run()}\n", 'import "../functions"\n')
        self.inspect(consumer)
        self.assertNotIn("FILE005", self.inspect(source))

    def test_root_slice_store_keeps_source_borrow_and_release_identity(self):
        source = self.write("functions", "fill :: proc(slot: ^[]int, source: []int) {slot^ = source}\n"
                            "run :: proc(store: ^state.Store) {values: []int; fill(&values, store.values); values[0] = 1}\n", 'import "../state"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source))
        source = self.write("effects", "fill :: proc(slot: ^[]int, source: []int) {slot^ = source}\n"
                            "run :: proc() {data := make([]int, 1); values: []int; fill(&values, data); delete(data); _ = values[0]}\n")


    def test_private_borrowed_handle_can_be_rebound_through_its_slot(self):
        source = self.write("functions", "fill :: proc(slot: ^[]int, source: []int) {slot^ = source}\n"
                            "run :: proc(store: ^state.Store) {values := store.values; fresh := make([]int, 1); fill(&values, fresh); values[0] = 1}\n", 'import "../state"\n')
        self.assertNotIn("OWN001", self.inspect(source))

    def test_direct_slot_assignment_preserves_borrow_and_temporary_data(self):
        source = self.write("effects", "run :: proc() {values: []int; alias := &values; alias^ = make([]int, 1, context.temp_allocator); free_all(context.temp_allocator); _ = values[0]}\n")
        source = self.write("functions", "run :: proc(store: ^state.Store) {values: []int; alias := &values; alias^ = store.values; values[0] = 1}\n", 'import "../state"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source))


    def test_additional_zeroing_helpers_carry_writes_and_aliases(self):
        for call in ("mem.zero_item(&store.rows[1])", "mem.zero_item(item = &store.rows[1])", "mem.zero_explicit(raw_data(store.values), len(store.values)*size_of(int))"):
            with self.subTest(call=call):
                source = self.write("functions", "run :: proc(store: ^state.Store) {_ = " + call + "}\n", 'import "../state"\nimport "core:mem"\n')
                self.assertIn("OWN001", self.inspect_borrowed(source))

    def test_memory_mutators_and_raw_data_preserve_borrowed_capabilities(self):
        for call in ("mem.zero(&store.rows[1], size_of(state.Row))",
                     "mem.zero(raw_data(store.values), len(store.values)*size_of(int))"):
            with self.subTest(call=call):
                source = self.write("functions", "mutate :: proc(store: ^state.Store) {" + call + "}\n",
                                    'import "../state"\nimport "core:mem"\n')
                self.assertIn("OWN001", self.inspect_borrowed(source, call="mutate(&live)"))

    def test_type_construction_and_raw_data_are_not_unknown_callbacks(self):
        source = self.write("functions", "read :: proc(values: []int, key: Maybe(int) = nil) -> rawptr {\n"
                            "_ = key\nreturn raw_data(values)\n}\n")
        self.assertNotIn("LINT004", self.inspect(source))

    def test_assertions_are_modeled_only_inside_test_procedures(self):
        for attribute, unknown in (("@(test)\n", False), ("", True)):
            with self.subTest(attribute=attribute):
                source = self.write("engine", attribute + "check :: proc(t: ^testing.T) {testing.expect(t, true)}\n",
                                    'import "core:testing"\n')
                self.assertEqual("LINT004" in self.inspect(source), False)

    def test_unmodeled_test_cleanup_cannot_certify_retention(self):
        source = self.write("engine", "clean :: proc(data: rawptr) {_ = data}\n"
                            "@(test)\nrun :: proc(t: ^testing.T) {values := make([]int, 1, context.temp_allocator); testing.cleanup(t, clean, raw_data(values)); free_all(context.temp_allocator)}\n", 'import "core:testing"\n')
        self.assertNotIn("LINT004", self.inspect(source))

    def test_readonly_catalog_globals_are_definitions_but_writes_are_rejected(self):
        source = self.write("catalog", '@(rodata) NAMES := [2]string{"one", "two"}\n')
        self.assertNotIn("ARCH003", self.inspect(source))
        source = self.write("functions", 'read :: proc() -> string {return catalog.NAMES[0]}\n', 'import "../catalog"\n')
        self.assertNotIn("ARCH007", self.inspect(source))
        source = self.write("functions", 'mutate :: proc() {catalog.NAMES[0] = "bad"}\n', 'import "../catalog"\n')
        self.assertIn("OWN001", self.inspect(source))

    def test_migrations_are_pure_downward_dependencies(self):
        self.write("migrations", "convert :: proc(value: state.Row) -> state.Row {return value}\n", 'import "../state"\n')
        source = self.write("functions", "convert :: proc(value: state.Row) -> state.Row {return migrations.convert(value)}\n",
                            'import "../state"\nimport "../migrations"\n')
        self.assertNotIn("ARCH001", self.inspect(source))
        source = self.write("migrations", "read :: proc() {fmt.println(1)}\n", 'import "core:fmt"\n')
        self.assertIn("ARCH007", self.inspect(source))

    def test_owner_initialization_and_private_moves_need_no_existing_transaction(self):
        self.engine()
        path = self.root / "src/engine/engine.odin"
        path.write_text(path.read_text() + "initialize :: proc(owner: ^Owner) {owner.rows = make(map[int]state.Row)}\n")
        source = self.write("application", "owner: engine.Owner\nstart :: proc() {engine.initialize(&owner)}\n", 'import "../engine"\n')
        self.assertNotIn("OWN002", self.inspect(source))
        source = self.write("procedures", "run :: proc() {source, destination: engine.Owner; engine.take(&destination, &source)}\n", 'import "../engine"\n')
        self.assertNotIn("OWN005", self.inspect(source))

    def test_inline_range_recovery_preserves_original_diagnostic_positions(self):
        source = self.write("functions", "run :: proc(data: []int) -> int {\n"
                            "    result := 0\n    for value in data {copy:=value\n"
                            "        result += copy\n    }\n    fmt.println(result)\n    return result\n}\n", 'import "core:fmt"\n')
        text = self.inspect(source)
        self.assertIn(f"{source}(8:5): ARCH007", text)

    def test_ordering_reports_each_dependency_once(self):
        source = self.write("functions", "@(private) helper :: proc() -> int {return 1}\n"
                            "run :: proc() -> int {return helper()+helper()+helper()}\n")
        text = self.inspect(source)
        self.assertEqual(text.count("FLOW001:"), 1, text)

    def test_interface_dependencies_do_not_receive_impossible_relocation_advice(self):
        source = self.write("functions", "@(private = \"file\") VALUE :: 1\nrun :: proc() -> int {return VALUE}\n")
        # A saved consumer anchors the public interface and its private support.
        consumer = self.write("application", "run :: proc() -> int {return functions.run()}\n", 'import "../functions"\n')
        self.inspect(consumer)
        self.assertNotIn("FILE005", self.inspect(source))


if __name__ == "__main__":
    unittest.main()
