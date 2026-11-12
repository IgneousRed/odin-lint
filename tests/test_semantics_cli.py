"""Compiler-valid examples of role capabilities and ownership across calls."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_cli import BINARY, PROJECT
from consumer_fixture import borrowed_consumer


class SemanticTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=PROJECT / ".work")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.write("state", "Row :: struct {value: int}\n"
                   "Store :: struct {rows: map[int]Row, values: []int}\n")
        self.write("views", "Cache :: struct {values: [dynamic]int}\n")

    def write(self, role, source, imports=""):
        directory = self.root / "src" / role
        directory.mkdir(parents=True, exist_ok=True)
        package = Path(role).name
        path = directory / f"{package}.odin"
        path.write_text(f"package {package}\n{imports}{source}", encoding="utf-8")
        return path

    def inspect(self, source, *also_selected):
        checked = subprocess.run([os.environ.get("ODIN", "odin"), "check", str(source.parent),
                                  "-no-entry-point", "-thread-count:2", "-vet", "-strict-style",
                                  "-warnings-as-errors"], capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        result = subprocess.run([str(BINARY), "--root", str(self.root), str(source), *map(str, also_selected)],
                                capture_output=True, text=True)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        return result.stderr

    def inspect_borrowed(self, source, call="run(&live)", declarations="live: state.Store", modules=("state",)):
        consumer = borrowed_consumer(self.root, source, call, declarations, modules)
        return self.inspect(consumer, source)

    def engine(self):
        self.write("engine", "Transaction :: struct {depth: int, saved: int}\n"
                   "Owner :: struct {rows: map[int]state.Row, revision: u64, transaction: Transaction}\n"
                   "Local :: struct {rows: map[int]state.Row, meaningful: ^Owner, selected: int, transaction: Transaction}\n"
                   "enter :: proc(owner: ^Owner) -> bool {owner.transaction.depth += 1; return true}\n"
                   "leave :: proc(owner: ^Owner) -> bool {owner.transaction.depth -= 1; return true}\n"
                   "enter_local :: proc(local: ^Local) -> bool {local.transaction.saved = local.selected; local.transaction.depth += 1; return true}\n"
                   "leave_local :: proc(local: ^Local) -> bool {local.transaction.depth -= 1; return true}\n"
                   "update :: proc(owner: ^Owner) {owner.rows[1] = {}}\n"
                   "update_local :: proc(local: ^Local) {local.rows[1] = {}}\n"
                   "take :: proc(destination, source: ^Owner) {destination^ = source^; source^ = {}}\n",
                   'import "../state"\n')

    def test_wide_owner_shapes_do_not_corrupt_recursive_visit_state(self):
        fields = ", ".join(f"field_{i}: int" for i in range(80))
        self.write("engine", "Owner :: struct {rows: map[int]state.Row, " + fields + "}\n",
                   'import "../state"\n')
        source = self.write("procedures", "read :: proc(owner: ^engine.Owner) -> int {return len(owner.rows)}\n",
                            'import "../engine"\n')
        self.assertNotIn("OWN001", self.inspect(source))

    def test_long_stable_alias_chain_retains_call_effects(self):
        aliases = "Alias_0 :: observe\n" + "".join(f"Alias_{i} :: Alias_{i-1}\n" for i in range(1, 40))
        source = self.write("functions", "observe :: proc() {fmt.println(1)}\n" + aliases
                            + "run :: proc() {Alias_39()}\n", 'import "core:fmt"\n')
        self.assertIn("ARCH007", self.inspect(source))

    def test_ui_may_transact_local_singleton_working_fields(self):
        self.engine()
        source = self.write("ui", "input :: proc(local: ^engine.Local) {\n"
                            "engine.enter_local(local)\ndefer assert(engine.leave_local(local))\n"
                            "local.selected = 3\nengine.update_local(local)\n}\n",
                            'import "../engine"\n')
        text = self.inspect_borrowed(source, call='input(&live)', declarations='live: engine.Local', modules=('engine',))
        self.assertNotIn("OWN001", text)
        self.assertNotIn("OWN002", text)

    def test_ui_must_not_transact_meaningful_state(self):
        self.engine()
        source = self.write("ui", "input :: proc(owner: ^engine.Owner) {\n"
                            "engine.enter(owner)\ndefer assert(engine.leave(owner))\nengine.update(owner)\n}\n",
                            'import "../engine"\n')
        self.assertIn("OWN002", self.inspect(source))

    def test_local_owner_does_not_grant_permission_to_its_meaningful_owner(self):
        self.engine()
        source = self.write("ui", "input :: proc(local: ^engine.Local) {\n"
                            "engine.enter(local.meaningful)\ndefer assert(engine.leave(local.meaningful))\n"
                            "engine.update(local.meaningful)\n}\n", 'import "../engine"\n')
        self.assertIn("OWN002", self.inspect(source))

    def test_local_transaction_does_not_authorize_raw_relation_writes(self):
        self.engine()
        source = self.write("ui", "input :: proc(local: ^engine.Local) {\n"
                            "engine.enter_local(local)\ndefer assert(engine.leave_local(local))\nlocal.rows[1] = {}\n}\n",
                            'import "../engine"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source, call='input(&live)', declarations='live: engine.Local', modules=('engine',)))

    def test_local_frame_cache_is_distinct_from_engine_maintained_indexes(self):
        self.write("views", "Read :: struct {paths: map[string]bool, index: map[int]state.Row}\n",
                   'import "../state"\n')
        self.engine()
        engine = self.root / "src/engine/engine.odin"
        text = engine.read_text().replace('import "../state"', 'import "../state"\nimport "../views"')
        text += "Input :: struct {using read: views.Read, meaningful: ^Owner}\n"
        text += "index_update :: proc(input: ^Input) {input.index[1] = {}}\n"
        engine.write_text(text, encoding="utf-8")
        source = self.write("procedures", "frame :: proc(input: ^engine.Input) {clear(&input.paths); input.paths[\"button\"] = true}\n",
                            'import "../engine"\n')
        self.assertNotIn("OWN001", self.inspect_borrowed(source, call='frame(&live)', declarations='live: engine.Input', modules=('engine',)))
        source = self.write("procedures", "frame :: proc(input: ^engine.Input) {input.index[1] = {}}\n",
                            'import "../engine"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source, call='frame(&live)', declarations='live: engine.Input', modules=('engine',)))

    def test_open_transaction_must_have_a_finish_on_exit(self):
        self.engine()
        source = self.write("procedures", "run :: proc(owner: ^engine.Owner) {engine.enter(owner); engine.update(owner)}\n",
                            'import "../engine"\n')
        self.assertIn("OWN002", self.inspect(source))

    def test_transaction_must_finish_on_each_return_path(self):
        self.engine()
        source = self.write("procedures", "run :: proc(owner: ^engine.Owner, stop: bool) {\n"
                            "engine.enter(owner)\nif stop {return}\nassert(engine.leave(owner))\n}\n",
                            'import "../engine"\n')
        self.assertIn("OWN002", self.inspect(source))

    def test_failed_begin_guard_does_not_open_a_transaction(self):
        self.engine()
        source = self.write("procedures", "run :: proc(owner: ^engine.Owner) {\n"
                            "if !engine.enter(owner) {return}\ndefer assert(engine.leave(owner))\nengine.update(owner)\n}\n",
                            'import "../engine"\n')
        self.assertNotIn("OWN002", self.inspect(source))

    def test_worker_private_projection_can_use_engine_transactions(self):
        self.engine()
        source = self.write("effects", "replay :: proc() {\nowner: engine.Owner\n"
                            "owner.rows = make(map[int]state.Row)\nengine.enter(&owner)\n"
                            "defer assert(engine.leave(&owner))\nengine.update(&owner)\n}\n",
                            'import "../engine"\nimport "../state"\n')
        text = self.inspect(source)
        self.assertNotIn("OWN001", text)
        self.assertNotIn("OWN002", text)

    def test_unknown_publication_protocol_does_not_invent_guards(self):
        self.engine()
        for guarded in (False, True):
            with self.subTest(guarded=guarded):
                guards = "if !durable {return false}\nif plan.revision != owner.revision {return false}\n" if guarded else "_ = durable\n"
                source = self.write("procedures", "Plan :: struct {projection: engine.Owner, revision: u64}\n"
                                    "publish :: proc(owner: ^engine.Owner, plan: ^Plan, durable: bool) -> bool {\n"
                                    + guards + "engine.take(owner, &plan.projection)\nreturn true\n}\n",
                                    'import "../engine"\n')
                text = self.inspect(source)
                self.assertNotIn("OWN005", text)

    def test_whole_owner_copy_does_not_imply_source_invalidation(self):
        self.engine()
        with (self.root / "src/engine/engine.odin").open("a") as stream:
            stream.write("unsafe_take :: proc(destination, source: ^Owner) {destination^ = source^}\n")
        source = self.write("procedures", "run :: proc(owner, prepared: ^engine.Owner) {engine.unsafe_take(owner, prepared)}\n",
                            'import "../engine"\n')
        self.assertNotIn("OWN005", self.inspect(source))

    def test_readonly_data_dependencies_and_engine_validators(self):
        self.write("catalog", "Key :: distinct int\nCatalog :: struct {prices: map[Key]int}\n")
        self.write("functions", "valid :: proc(read: ^state.Store) -> bool {return len(read.rows) > 0}\n"
                   "price :: proc(read: ^catalog.Catalog, key: catalog.Key) -> int {return read.prices[key]}\n",
                   'import "../state"\nimport "../catalog"\n')
        source = self.write("engine", "validate :: proc(read: ^state.Store) -> bool {return functions.valid(read)}\n",
                            'import "../state"\nimport "../functions"\n')
        text = self.inspect(source)
        for rule in ["ARCH001", "ARCH007", "OWN001", "LINT004"]:
            self.assertNotIn(rule, text)

    def test_pure_queries_cannot_mutate_through_helpers(self):
        self.write("functions", "write :: proc(input: map[int]state.Row) {values := input; values[1] = {}}\n",
                   'import "../state"\n')
        source = self.write("procedures", "apply :: proc(read: ^state.Store) {functions.write(read.rows)}\n",
                            'import "../state"\nimport "../functions"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source, call='apply(&live)'))

    def test_owned_cache_and_output_buffer_updates(self):
        source = self.write("functions", "fill :: proc(cache: ^views.Cache, output: []int) {\n"
                            "append(&cache.values, 3)\noutput[0] = 4\n}\n"
                            "run :: proc() {cache: views.Cache; output: [1]int; fill(&cache, output[:])}\n",
                            'import "../views"\n')
        self.assertNotIn("OWN001", self.inspect(source))

    def test_catalog_builders_require_exclusive_unpublished_data(self):
        self.write("catalog", "Catalog :: struct {prices: map[int]int}\n")
        source = self.write("functions", "prepare :: proc(catalog: ^catalog.Catalog) {catalog.prices = make(map[int]int); catalog.prices[1] = 2}\n"
                            "build :: proc() {value := new(catalog.Catalog); prepare(value)}\n",
                            'import "../catalog"\n')
        self.assertNotIn("OWN001", self.inspect(source))

    def test_engine_cannot_mutate_published_catalog_data(self):
        self.write("catalog", "Catalog :: struct {prices: map[int]int}\n")
        source = self.write("engine", "Owner :: struct {catalog: ^catalog.Catalog}\n"
                            "mutate :: proc(owner: ^Owner) {owner.catalog.prices[1] = 2}\n",
                            'import "../catalog"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source, call="mutate(&live)", declarations="live: engine.Owner", modules=("engine",)))


    def test_hidden_io_and_clock_propagate_through_aliases(self):
        source = self.write("functions", "Clock :: time.now\n"
                            "observe :: proc() {fmt.println(Clock())}\n"
                            "Alias :: observe\nrun :: proc() {Alias()}\n",
                            'import "core:fmt"\nimport "core:time"\n')
        text = self.inspect(source)
        self.assertIn("ARCH006", text)
        self.assertIn("ARCH007", text)
        self.assertIn("(7:", "\n".join(line for line in text.splitlines() if "ARCH006" in line))

    def test_time_conversions_and_explicit_now_are_computation(self):
        source = self.write("functions", "deadline :: proc(now: i64) -> i64 {return now + 10}\n"
                            "format :: proc(seconds: i64) -> string {return fmt.tprintf(\"%v\", time.unix(seconds, 0))}\n",
                            'import "core:fmt"\nimport "core:time"\n')
        text = self.inspect(source)
        for rule in ["ARCH006", "ARCH007", "LINT004"]:
            self.assertNotIn(rule, text)

    def test_ambient_globals_are_not_explicit_query_inputs(self):
        source = self.write("functions", "current: int\n"
                            "read :: proc() -> int {return current}\n"
                            "wrapped :: proc() -> int {return read()}\n")
        text = self.inspect(source)
        self.assertIn("ARCH003", text)
        self.assertIn("ARCH007", text)

    def test_resolved_callback_effects_follow_the_argument(self):
        source = self.write("functions", "invoke :: proc(callback: proc()) {callback()}\n"
                            "pure :: proc() {}\n"
                            "noisy :: proc() {fmt.println(1)}\n"
                            "good :: proc() {invoke(pure)}\n"
                            "bad :: proc() {invoke(noisy)}\n",
                            'import "core:fmt"\n')
        text = self.inspect(source)
        self.assertNotIn("(6:", "\n".join(line for line in text.splitlines() if "ARCH007" in line))
        self.assertIn("ARCH007", text)

    def test_unknown_foreign_call_is_nonblocking(self):
        self.write("foreign_api", 'foreign import libc "system:c"\nforeign libc {external :: proc "c" () ---}\n')
        source = self.write("functions", "run :: proc() {foreign_api.external()}\n",
                            'import "../foreign_api"\n')
        self.assertNotIn("LINT004", self.inspect(source))

    def test_deferred_alias_uses_execution_time_binding(self):
        source = self.write("functions", "mutate :: proc(read: ^state.Store) {\n"
                            "rows: []int\ndefer rows[0] = 9\nrows = read.values\n}\n",
                            'import "../state"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source, call='mutate(&live)'))

    def test_deferred_write_before_early_return(self):
        source = self.write("functions", "mutate :: proc(read: ^state.Store, stop: bool) {\n"
                            "rows: []int\ndefer rows[0] = 9\n"
                            "if stop {rows = read.values; return}\nrows = make([]int, 1)\n}\n",
                            'import "../state"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source, call='mutate(&live, true)'))

    def test_borrowed_return_provenance_survives_a_wrapper(self):
        source = self.write("functions", "borrow :: proc(read: ^state.Store) -> []int {return read.values}\n"
                            "mutate :: proc(read: ^state.Store) {values := borrow(read); values[0] = 1}\n",
                            'import "../state"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source, call='mutate(&live)'))

    def test_multiple_and_named_returns_preserve_each_result(self):
        source = self.write("functions", "borrow :: proc(read: ^state.Store) -> (ok: bool, values: []int) {ok = true; values = read.values; return}\n"
                            "mutate :: proc(read: ^state.Store) {_, values := borrow(read); values[0] = 1}\n",
                            'import "../state"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source, call='mutate(&live)'))

    def test_callback_mutation_is_checked_with_its_actual_arguments(self):
        source = self.write("functions", "write :: proc(input: map[int]state.Row) {values := input; values[1] = {}}\n"
                            "invoke :: proc(callback: proc(map[int]state.Row), values: map[int]state.Row) {callback(values)}\n"
                            "run :: proc(read: ^state.Store) {invoke(write, read.rows)}\n",
                            'import "../state"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source))

    def test_standard_sort_callback_must_not_hide_io(self):
        source = self.write("functions", "run :: proc() {values := [2]int{1, 2}; slice.sort_by(values[:], proc(a, b: int) -> bool {fmt.println(a); return a < b})}\n",
                            'import "core:slice"\nimport "core:fmt"\n')
        self.assertIn("ARCH007", self.inspect(source))

    def test_imported_procedure_alias_keeps_effects_and_ownership(self):
        self.write("helpers", "write :: proc(input: map[int]state.Row) {values := input; values[1] = {}}\n",
                   'import "../state"\n')
        source = self.write("procedures", "Alias :: helpers.write\nrun :: proc(read: ^state.Store) {Alias(read.rows)}\n",
                            'import "../helpers"\nimport "../state"\n')
        text = self.inspect_borrowed(source)
        self.assertIn("OWN001", text)
        self.assertNotIn("LINT004", text)


    def test_owned_factory_return_does_not_inherit_borrowed_type(self):
        source = self.write("functions", "fresh :: proc() -> state.Store {return {values = make([]int, 1)}}\n"
                            "run :: proc() {copy := fresh(); copy.values[0] = 2}\n",
                            'import "../state"\n')
        self.assertNotIn("OWN001", self.inspect(source))

    def test_shallow_record_copy_keeps_reference_fields_borrowed(self):
        source = self.write("functions", "copy :: proc(read: ^state.Store) -> state.Store {return read^}\n"
                            "run :: proc(read: ^state.Store) {local := copy(read); local.values[0] = 2}\n",
                            'import "../state"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source))

    def test_uncertain_source_clear_does_not_establish_a_transfer_contract(self):
        self.engine()
        with (self.root / "src/engine/engine.odin").open("a") as stream:
            stream.write("early_clear :: proc(destination, source: ^Owner) {source^ = {}; destination^ = source^}\n")
            stream.write("conditional_clear :: proc(destination, source: ^Owner, clear_source: bool) {destination^ = source^; if clear_source {source^ = {}}}\n")
        for operation in ("early_clear(owner, prepared)", "conditional_clear(owner, prepared, true)"):
            with self.subTest(operation=operation):
                source = self.write("procedures", "run :: proc(owner, prepared: ^engine.Owner, durable: bool) {\n"
                                    "if !durable {return}\nif owner.revision != prepared.revision {return}\n"
                                    f"engine.{operation}\n}}\n", 'import "../engine"\n')
                self.assertNotIn("OWN005", self.inspect(source))

    def test_labeled_inner_exit_does_not_execute_outer_defer(self):
        source = self.write("functions", "cleanup :: proc() {}\n"
                            "run :: proc(condition: bool) {\ndefer cleanup()\n"
                            "inner: {if condition {break inner}}\n}\n")
        self.assertNotIn("LINT004", self.inspect(source))

    def test_branch_transfer_cannot_silently_prove_deferred_transaction_safety(self):
        self.engine()
        source = self.write("procedures", "run :: proc(owner: ^engine.Owner) {\n"
                            "for {engine.enter(owner); defer assert(engine.leave(owner)); break}\n}\n",
                            'import "../engine"\n')
        self.assertNotIn("LINT004", self.inspect(source))


    def test_shallow_slice_clone_keeps_borrowed_element_pointers(self):
        self.write("state", "Row :: struct {value: int}\nStore :: struct {rows: []^Row}\n")
        source = self.write("functions", "run :: proc(store: ^state.Store) {\n"
                            "copy := slice.clone(store.rows)\ncopy[0].value = 1\ndelete(copy)\n}\n",
                            'import "core:slice"\nimport "../state"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source))

    def test_cloned_scalar_slice_owns_its_backing_storage(self):
        source = self.write("functions", "run :: proc(store: ^state.Store) {\n"
                            "copy := slice.clone(store.values)\ncopy[0] = 1\ndelete(copy)\n}\n",
                            'import "core:slice"\nimport "../state"\n')
        self.assertNotIn("OWN001", self.inspect(source))


    def test_engine_may_release_its_own_relation_storage(self):
        self.engine()
        with (self.root / "src/engine/engine.odin").open("a") as stream:
            stream.write("destroy :: proc(owner: ^Owner) {delete(owner.rows); owner^ = {}}\n")
        source = self.write("effects", "run :: proc(owner: ^engine.Owner) {engine.destroy(owner)}\n",
                            'import "../engine"\n')
        self.assertNotIn("OWN001", self.inspect(source))

    def test_identical_summary_findings_are_reported_once(self):
        source = self.write("functions", "mutate :: proc(store: ^state.Store) {store.rows[1] = {}; store.values[0] = 2}\n"
                            "run :: proc(store: ^state.Store) {mutate(store)}\n", 'import "../state"\n')
        lines = self.inspect_borrowed(source).splitlines()
        self.assertEqual(len(lines), len(set(lines)))
        call_findings = [line for line in lines if "OWN001: run mutates protected state through parameter 1" in line]
        self.assertEqual(len(call_findings), 1)


    def test_ambiguous_local_owner_does_not_inherit_another_owners_transaction(self):
        self.engine()
        source = self.write("ui", "input :: proc(a, b: ^engine.Local, choose_b: bool) {\n"
                            "selected := a\nif choose_b {selected = b}\n"
                            "engine.enter_local(a)\ndefer assert(engine.leave_local(a))\n"
                            "selected.selected = 2\n}\n", 'import "../engine"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source, call='input(&left, &right, true)', declarations='left, right: engine.Local', modules=('engine',)))


    def test_effects_may_own_runtime_bookkeeping(self):
        source = self.write("effects", "pending: int\nrun :: proc() {pending += 1; fmt.println(pending)}\n",
                            'import "core:fmt"\n')
        text = self.inspect(source)
        self.assertNotIn("ARCH003", text)
        self.assertNotIn("ARCH007", text)

    def test_storage_and_transport_keep_their_io_responsibilities(self):
        source = self.write("effects/network", "run :: proc() -> bool {return os.exists(\"file\")}\n",
                            'import "core:os"\n')
        self.assertIn("ARCH008", self.inspect(source))
        source = self.write("effects/storage", "run :: proc() -> bool {return os.exists(\"file\")}\n",
                            'import "core:os"\n')
        self.assertNotIn("ARCH008", self.inspect(source))

    def test_nested_global_owner_is_still_borrowed(self):
        self.engine()
        source = self.write("effects", "Runtime :: struct {owner: engine.Owner}\n"
                            "runtime: Runtime\nrun :: proc() {runtime.owner.rows[1] = {}}\n",
                            'import "../engine"\n')
        self.assertIn("OWN001", self.inspect(source))

    def test_branch_cannot_grant_transaction_permission_to_another_path(self):
        self.engine()
        source = self.write("ui", "input :: proc(local: ^engine.Local, condition: bool) {\n"
                            "if condition {engine.enter_local(local)}\nlocal.selected = 3\n}\n",
                            'import "../engine"\n')
        text = self.inspect_borrowed(source, call='input(&live, false)', declarations='live: engine.Local', modules=('engine',))
        self.assertIn("OWN001", text)
        self.assertIn("OWN002", text)

    def test_lower_layers_cannot_import_ui_or_application(self):
        self.write("ui", "VALUE :: 1\n")
        source = self.write("functions", "run :: proc() -> int {return ui.VALUE}\n", 'import "../ui"\n')
        self.assertIn("ARCH001", self.inspect(source))


if __name__ == "__main__":
    unittest.main()
