"""Compiler-backed regressions for the second five-consumer audit."""

import unittest

import test_semantics_cli as semantic


class AuditModelTests(unittest.TestCase):
    setUp = semantic.SemanticTests.setUp
    write = semantic.SemanticTests.write
    inspect = semantic.SemanticTests.inspect
    inspect_borrowed = semantic.SemanticTests.inspect_borrowed
    engine = semantic.SemanticTests.engine


    def test_complete_engine_transaction_has_no_caller_scope_requirement(self):
        self.engine()
        path = self.root / "src/engine/engine.odin"
        path.write_text(path.read_text() + "initialize :: proc(owner: ^Owner) {owner.rows = make(map[int]state.Row)}\n"
                        "closed :: proc(owner: ^Owner) {enter(owner); update(owner); leave(owner)}\n")
        for call, invalid in (("engine.closed(&owner)", False), ("engine.update(&owner)", True)):
            with self.subTest(call=call):
                source = self.write("application", "owner: engine.Owner\nrun :: proc() {engine.initialize(&owner); "
                                    + call + "}\n", 'import "../engine"\n')
                self.assertEqual("OWN002" in self.inspect(source), invalid)

    def test_engine_scalar_row_preconditions_follow_the_actual_owner(self):
        self.write("engine", "Owner :: struct {rows: [4]state.Row, depth: int}\n"
                   "enter :: proc(owner: ^Owner) {owner.depth += 1}\nleave :: proc(owner: ^Owner) {owner.depth -= 1}\n"
                   "update :: proc(row: ^state.Row) {row.value = 1}\n"
                   "closed :: proc(owner: ^Owner) {enter(owner); update(&owner.rows[0]); leave(owner)}\n",
                   'import "../state"\n')
        for body, invalid in (("engine.update(&owner.rows[0])", True),
                              ("engine.enter(&owner); engine.update(&owner.rows[0]); engine.leave(&owner)", False),
                              ("engine.closed(&owner)", False)):
            with self.subTest(body=body):
                source = self.write("application", "owner: engine.Owner\nrun :: proc() {" + body + "}\n",
                                    'import "../engine"\n')
                self.assertEqual("OWN002" in self.inspect(source), invalid)

    def test_engine_scope_is_required_when_mutation_comes_through_a_private_helper(self):
        self.write("functions", "change :: proc(row: ^state.Row) {row.value = 1}\n", 'import "../state"\n')
        self.write("engine", "Owner :: struct {rows: [4]state.Row, depth: int}\n"
                   "enter :: proc(owner: ^Owner) {owner.depth += 1}\nleave :: proc(owner: ^Owner) {owner.depth -= 1}\n"
                   "update :: proc(owner: ^Owner) {functions.change(&owner.rows[0])}\n"
                   "closed :: proc(owner: ^Owner) {enter(owner); update(owner); leave(owner)}\n",
                   'import "../state"\nimport "../functions"\n')
        for call, invalid in (("engine.update(&owner)", True), ("engine.closed(&owner)", False)):
            with self.subTest(call=call):
                source = self.write("application", "owner: engine.Owner\nrun :: proc() {" + call + "}\n",
                                    'import "../engine"\n')
                self.assertEqual("OWN002" in self.inspect(source), invalid)


    def test_builtin_named_destination_does_not_depend_on_argument_order(self):
        for call in ("copy(store.values, source)", "copy(src = source, dst = store.values)",
                     "copy(dst = store.values, src = source)"):
            with self.subTest(call=call):
                source = self.write("functions", "run :: proc(store: ^state.Store, source: []int) {_ = " + call + "}\n",
                                    'import "../state"\n')
                self.assertIn("OWN001", self.inspect_borrowed(source, call="run(&live, nil)"))
        source = self.write("functions", "run :: proc(store: ^state.Store) {output := make([]int, len(store.values)); "
                            "_ = copy(src = store.values, dst = output); delete(output)}\n", 'import "../state"\n')
        self.assertNotIn("OWN001", self.inspect_borrowed(source))

    def test_named_sort_callback_keeps_its_effects_in_any_argument_order(self):
        self.write("functions/hidden", "less :: proc(a, b: int) -> bool {fmt.println(a); return a < b}\n",
                   'import "core:fmt"\n')
        for call in ("slice.sort_by(data, hidden.less)", "slice.sort_by(less = hidden.less, data = data)",
                     "slice.stable_sort_by(data = data, less = hidden.less)"):
            with self.subTest(call=call):
                source = self.write("functions", "run :: proc(data: []int) {" + call + "}\n",
                                    'import "core:slice"\nimport "./hidden"\n')
                self.assertIn("ARCH007", self.inspect(source))

    def test_json_decoder_mutates_only_its_output(self):
        for output, invalid in (("store", True), ("&private", False)):
            with self.subTest(output=output):
                source = self.write("functions", "run :: proc(data: []u8, store: ^state.Store) {private: state.Store; _ = private; "
                                    "_ = json.unmarshal(ptr = " + output + ", data = data)}\n",
                                    'import "../state"\nimport "core:encoding/json"\n')
                self.assertEqual("OWN001" in self.inspect_borrowed(source, call="run(nil, &live)"), invalid)

    def test_implicit_rng_is_ambient_but_explicit_private_generator_is_allowed(self):
        for body, invalid in (("return rand.uint64()", True),
                              ("state := rand.create(1); generator := rand.default_random_generator(&state); return rand.uint64(gen = generator)", False)):
            with self.subTest(body=body):
                source = self.write("functions", "run :: proc() -> u64 {" + body + "}\n", 'import "core:math/rand"\n')
                self.assertEqual("ARCH007" in self.inspect(source), invalid)

    def test_rng_preserves_explicit_state_writes_and_callback_effects(self):
        self.write("state", "Store :: struct {rows: [4]int, rng: rand.Default_Random_State}\n", 'import "core:math/rand"\n')
        source = self.write("functions", "run :: proc(store: ^state.Store) -> u64 {generator := rand.default_random_generator(&store.rng); return rand.uint64(generator)}\n",
                            'import "../state"\nimport "core:math/rand"\n')
        self.assertIn("OWN001", self.inspect_borrowed(source))
        self.write("functions/hidden", "noisy :: proc(data: rawptr, mode: runtime.Random_Generator_Mode, bytes: []u8) {_ = data; _ = mode; _ = bytes; fmt.println(1)}\n",
                   'import "base:runtime"\nimport "core:fmt"\n')
        source = self.write("functions", "run :: proc() -> u64 {generator := rand.Generator{procedure = hidden.noisy}; return rand.uint64(generator)}\n",
                            'import "core:math/rand"\nimport "./hidden"\n')
        self.assertIn("ARCH007", self.inspect(source))

    def test_unknown_rng_callback_is_not_certified_by_a_pure_alternative(self):
        source = self.write("functions", "run :: proc(flag: bool) -> u64 {state := rand.create(1); generator := rand.default_random_generator(&state); "
                            "if flag {generator.procedure = transmute(runtime.Random_Generator_Proc)uintptr(1)}; return rand.uint64(generator)}\n",
                            'import "core:math/rand"\nimport "base:runtime"\n')
        self.assertNotIn("LINT004", self.inspect(source))

    def test_contextual_record_labels_are_not_procedure_uses(self):
        prefix = "Record :: struct {helper: int}\n@(private) helper :: proc() -> int {return 1}\n"
        for body in ("fill :: proc(output: ^Record) {output^ = {helper = 2}; _ = helper()}",
                     "fill :: proc() -> Record {_ = helper(); return ({helper = 2})}",
                     "accept :: proc(value: Record) {_ = value}\nfill :: proc() {_ = helper(); accept(value = {helper = 2})}",
                     "fill :: proc() {output: Record = {helper = 2}; _ = output; _ = helper()}",
                     "Outer :: struct {inner: Record}\nfill :: proc() -> Outer {_ = helper(); return {inner = {helper = 2}}}"):
            with self.subTest(body=body):
                source = self.write("functions", prefix + body + "\n")
                self.assertNotIn("LINT003", self.inspect(source))
        source = self.write("functions", prefix + "fill :: proc() -> map[int]int {return {helper() = 2}}\n")
        source.write_text("#+feature dynamic-literals\n" + source.read_text())
        self.assertIn("SIMPLIFY001", self.inspect(source))

    def test_fixed_array_facts_remain_writable_only_in_private_copies(self):
        self.write("state", "Row :: struct {value: int}\nStore :: struct {rows: [4]Row}\n")
        for parameter, invalid in (("^state.Store", True), ("state.Store", False)):
            with self.subTest(parameter=parameter):
                source = self.write("functions", "run :: proc(store: " + parameter + ") {" + ("store.rows[0].value = 1" if invalid else "working := store; working.rows[0].value = 1") + "}\n",
                                    'import "../state"\n')
                call = "run(&live)" if invalid else "run(live)"
                self.assertEqual("OWN001" in self.inspect_borrowed(source, call=call), invalid)

    def test_cyclic_relation_shapes_keep_their_positive_witness(self):
        for order in ("A :: struct {b: ^B, values: []int}\nB :: struct {a: ^A}\n",
                      "A :: struct {values: []int, b: ^B}\nB :: struct {a: ^A}\n",
                      "B :: struct {a: ^A}\nA :: struct {b: ^B, values: []int}\n"):
            with self.subTest(order=order):
                self.write("state", order)
                source = self.write("functions", "run :: proc(a: ^state.A, b: ^state.B) {a.values[0] = 1; b.a.values[0] = 2}\n",
                                    'import "../state"\n')
                text = self.inspect_borrowed(source, call="run(&a, &b)",
                                             declarations="a: state.A\nb: state.B")
                self.assertEqual(text.count("OWN001:"), 2)


if __name__ == "__main__":
    unittest.main()
