"""Compiler/runtime-backed operand captures and ordered aliased-formal reads."""

import os
import re
import subprocess
import unittest

import test_ownership_052_cli as fixture


class EvaluationCaptureTests(unittest.TestCase):
    setUp = fixture.Ownership052Tests.setUp
    write = fixture.Ownership052Tests.write
    lint = fixture.Ownership052Tests.lint

    def check_cases(self, helpers, cases, *, nonreturn=()):
        source = "Box :: struct {callback: proc()}\nLink :: struct {box: ^Box}\n" + helpers
        expected = set()
        for i, (body, effect) in enumerate(cases):
            source += f"case_{i} :: proc() {{\n" + body + "\n}\n"
        path = self.write("functions", source)
        (path.parent / "callbacks.odin").write_text(
            'package functions\nimport "core:fmt"\n'
            'quiet :: proc() {}\nhang :: proc() {hang()}\n'
            'noisy :: proc() {fmt.println("hit")}\n')
        for line, text in enumerate(path.read_text().splitlines(), 1):
            if "// effect" in text:
                expected.add(line)
        main = self.root / "main"
        main.mkdir()
        (main / "main.odin").write_text('package main\nimport "../src/functions"\n'
                                       'main :: proc() {\n' + ''.join(
                                           (f'\tif false {{functions.case_{i}()}}\n' if i in nonreturn else f'\tfunctions.case_{i}()\n') for i in range(len(cases))) + '}\n')
        flags = ["-thread-count:2", "-vet", "-vet-tabs", "-vet-using-param",
                 "-vet-nil-deref", "-vet-uninitialized", "-vet-atomic-access",
                 "-strict-style", "-warnings-as-errors", "-vet-unused-procedures",
                 "-vet-packages:main,functions", "-strict-style-packages:main,functions"]
        for command in (
            [os.environ.get("ODIN", "odin"), "check", str(main), *flags],
            [os.environ.get("ODIN", "odin"), "run", str(main), *flags, "-debug", "-o:none",
             "-out:" + str(self.root / "probe")],
        ):
            result = subprocess.run(command, capture_output=True, text=True, timeout=40)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            if command[1] == "run":
                self.assertEqual(result.stdout, "hit\n" * sum(effect for _, effect in cases))
        diagnostics = self.lint(path)
        actual = {int(line) for line in re.findall(r"functions\.odin\((\d+):\d+\): ARCH007:", diagnostics)}
        self.assertEqual(actual, expected, diagnostics)

    def test_arguments_results_and_inline_copies_capture_in_evaluation_order(self):
        self.check_cases('''
invoke :: proc(callback: proc(), unused: bool) {_ = unused; callback()}
record :: proc(box: Box, unused: bool) {_ = unused; box.callback()}
reference :: proc(box: ^Box, unused: bool) {_ = unused; box.callback()}
linked :: proc(link: Link, unused: bool) {_ = unused; link.box.callback()}
reset :: proc(box: ^Box) -> bool {box.callback = quiet; return true}
halt :: proc(box: ^Box) -> bool {box.callback = hang; return true}
activate :: proc(box: ^Box) -> bool {box.callback = noisy; return true}
identity :: proc(callback: proc()) -> proc() {return callback}
forward :: proc(box: ^Box) -> (proc(), bool) {return pair(box)}
pair :: proc(box: ^Box) -> (proc(), bool) {return box.callback, halt(box)}
rebound :: proc(link: ^Link, other: ^Box) -> bool {link.box = other; return true}
cleanup :: proc(box: ^Box) -> (proc(), bool) {defer box.callback = hang; return box.callback, reset(box)}
''', [
            ('box := Box{noisy}\ninvoke(box.callback, reset(&box)) // effect', 1),
            ('box := Box{quiet}\ninvoke(box.callback, halt(&box))\nnoisy() // effect', 1),
            ('box := Box{quiet}\ninvoke(callback = box.callback, unused = halt(&box))\nnoisy() // effect', 1),
            ('box := Box{noisy}\ninvoke(unused = reset(&box), callback = box.callback)', 0),
            ('box := Box{noisy}\nrecord(box, reset(&box)) // effect', 1),
            ('box := Box{quiet}\nrecord(box, activate(&box))', 0),
            ('box := Box{noisy}\nreference(&box, reset(&box))', 0),
            ('box := Box{quiet}\nlinked(Link{&box}, activate(&box)) // effect', 1),
            ('box := Box{quiet}\nfirst, _ := forward(&box)\nfirst()\nnoisy() // effect', 1),
            ('box := Box{noisy}\nfirst, _ := cleanup(&box)\nfirst() // effect', 1),
            ('box := Box{noisy}\ninvoke(identity(box.callback), reset(&box)) // effect', 1),
            ('box := Box{noisy}\nother := Box{quiet}\nlink := Link{&box}\nreference(link.box, rebound(&link, &other)) // effect', 1),
            ('box := Box{noisy}\nfirst, _ := box.callback, reset(&box)\nfirst() // effect', 1),
            ('box := Box{noisy}\nfirst: proc()\nunused: bool\nfirst, unused = box.callback, reset(&box)\n_ = unused\nfirst() // effect', 1),
        ])

    def test_aliased_formals_read_after_prior_writes_and_preserve_saved_values(self):
        self.check_cases('''
reset :: proc(first, second: ^Box) {first.callback = quiet; first.callback = second.callback}
saved :: proc(first, second: ^Box) {callback := second.callback; first.callback = quiet; first.callback = callback}
copied :: proc(first, second: ^Box) {snapshot := second^; first.callback = quiet; first.callback = snapshot.callback}
inverse :: proc(first, second: ^Box) {first.callback = noisy; first.callback = second.callback}
forward :: proc(first, second: ^Box) {reset(first, second)}
after :: proc(first, second: ^Box) -> proc() {first.callback = quiet; return second.callback}
early :: proc(first, second: ^Box) -> proc() {callback := second.callback; first.callback = quiet; return callback}
deferred :: proc(first, second: ^Box) {defer first.callback = second.callback; first.callback = quiet}
''', [
            ('box := Box{hang}\nreset(&box, &box)\nassert(box.callback == quiet)\nbox.callback()\nnoisy() // effect', 1),
            ('box := Box{noisy}\nreset(&box, &box)\nassert(box.callback == quiet)\nbox.callback()', 0),
            ('box := Box{noisy}\nother := Box{noisy}\nreset(&box, &other)\nbox.callback() // effect', 1),
            ('box := Box{noisy}\nsaved(&box, &box)\nassert(box.callback == noisy)\nbox.callback() // effect', 1),
            ('box := Box{noisy}\ncopied(&box, &box)\nassert(box.callback == noisy)\nbox.callback() // effect', 1),
            ('box := Box{quiet}\ninverse(&box, &box)\nassert(box.callback == noisy)\nbox.callback() // effect', 1),
            ('box := Box{noisy}\nforward(&box, &box)\nassert(box.callback == quiet)\nbox.callback()', 0),
            ('box := Box{noisy}\ndeferred(&box, &box)\nassert(box.callback == quiet)\nbox.callback()', 0),
            ('box := Box{hang}\ncallback := after(&box, &box)\ncallback()\nnoisy() // effect', 1),
            ('box := Box{noisy}\ncallback := early(&box, &box)\ncallback() // effect', 1),
        ])

    def test_callback_invocations_replay_reads_and_writes_in_source_order(self):
        self.check_cases('''
reset :: proc(first, second: ^Box) {first.callback = quiet; second.callback()}
activate :: proc(first, second: ^Box) {first.callback = noisy; second.callback()}
saved :: proc(first, second: ^Box) {callback := second.callback; first.callback = quiet; callback()}
early :: proc(first, second: ^Box) {second.callback(); first.callback = quiet}
forward :: proc(first, second: ^Box) {reset(first, second)}
invoke :: proc(callback: proc(first, second: ^Box), first, second: ^Box) {callback(first, second)}
deferred :: proc(first, second: ^Box) {defer second.callback(); first.callback = quiet}
lifo :: proc(first, second: ^Box) {defer second.callback(); defer first.callback = quiet}
reverse :: proc(first, second: ^Box) {defer first.callback = quiet; defer second.callback()}
silence :: proc(box: ^Box) {box.callback = quiet}
through :: proc(callback: proc(^Box), first, second: ^Box) {callback(first); second.callback()}
maybe :: proc(first, second: ^Box, enabled: bool) {if enabled {first.callback = quiet}; second.callback()}
''', [
            ('box := Box{hang}\nreset(&box, &box)\nnoisy() // effect', 1),
            ('box := Box{noisy}\nreset(&box, &box)', 0),
            ('box := Box{quiet}\nactivate(&box, &box) // effect', 1),
            ('box := Box{quiet}\nother := Box{noisy}\nreset(&box, &other) // effect', 1),
            ('box := Box{noisy}\nother := Box{quiet}\nactivate(&box, &other)', 0),
            ('box := Box{noisy}\nsaved(&box, &box) // effect', 1),
            ('box := Box{noisy}\nearly(&box, &box) // effect', 1),
            ('box := Box{hang}\nforward(&box, &box)\nnoisy() // effect', 1),
            ('box := Box{hang}\ninvoke(reset, &box, &box)\nnoisy() // effect', 1),
            ('box := Box{quiet}\ninvoke(activate, &box, &box) // effect', 1),
            ('box := Box{hang}\ndeferred(&box, &box)\nnoisy() // effect', 1),
            ('box := Box{hang}\nlifo(&box, &box)\nnoisy() // effect', 1),
            ('box := Box{noisy}\nreverse(&box, &box) // effect', 1),
            ('box := Box{noisy}\nmaybe(&box, &box, false) // effect', 1),
            ('box := Box{hang}\nthrough(silence, &box, &box)\nnoisy() // effect', 1),
        ])

    def test_required_callback_nonreturn_uses_the_evaluated_value(self):
        # Nonreturning bodies are compiler checked but excluded from runtime.
        # The returning inverses above execute the same helpers with quiet.
        self.check_cases('''
saved :: proc(first, second: ^Box) {callback := second.callback; first.callback = quiet; callback()}
early :: proc(first, second: ^Box) {second.callback(); first.callback = quiet}
halt :: proc(first, second: ^Box) {first.callback = hang; second.callback()}
forward :: proc(first, second: ^Box) {halt(first, second)}
invoke :: proc(callback: proc(first, second: ^Box), first, second: ^Box) {callback(first, second)}
''', [
            ('box := Box{hang}\nsaved(&box, &box)\nnoisy()', 0),
            ('box := Box{hang}\nearly(&box, &box)\nnoisy()', 0),
            ('box := Box{quiet}\nhalt(&box, &box)\nnoisy()', 0),
            ('box := Box{quiet}\nforward(&box, &box)\nnoisy()', 0),
            ('box := Box{quiet}\ninvoke(halt, &box, &box)\nnoisy()', 0),
        ], nonreturn=range(5))

    def test_exhaustive_callback_store_branches_overwrite_incoming_values(self):
        self.check_cases('''
FLAG :: #config(FLAG, true)
reset :: proc(first, second: ^Box) {
	when FLAG {first.callback = quiet} else {first.callback = quiet}
	second.callback()
}
forward :: proc(first, second: ^Box) {reset(first, second)}
''', [
            ('box := Box{hang}\nreset(&box, &box)\nnoisy() // effect', 1),
            ('box := Box{noisy}\nforward(&box, &box)', 0),
        ])

    def test_compound_elements_capture_values_but_retain_references(self):
        self.check_cases('''
Pair :: struct {callback: proc(), unused: bool}
Record :: struct {box: Box, unused: bool}
Reference :: struct {box: ^Box, unused: bool}
Nested :: struct {pair: Pair}
reset :: proc(box: ^Box) -> bool {box.callback = quiet; return true}
halt :: proc(box: ^Box) -> bool {box.callback = hang; return true}
activate :: proc(box: ^Box) -> bool {box.callback = noisy; return true}
restore :: proc(box: ^Box) -> proc() {box.callback = quiet; return quiet}
''', [
            ('box := Box{quiet}\npair := Pair{box.callback, halt(&box)}\nassert(pair.callback == quiet)\npair.callback()\nnoisy() // effect', 1),
            ('box := Box{noisy}\npair := Pair{box.callback, reset(&box)}\nassert(pair.callback == noisy)\npair.callback() // effect', 1),
            ('box := Box{quiet}\npair := Pair{box.callback, activate(&box)}\nassert(pair.callback == quiet)\npair.callback()', 0),
            ('box := Box{noisy}\npair := Pair{unused = reset(&box), callback = box.callback}\npair.callback()', 0),
            ('box := Box{noisy}\npair: Pair = {callback = box.callback, unused = reset(&box)}\npair.callback() // effect', 1),
            ('box := Box{noisy}\npair := Nested{{box.callback, reset(&box)}}\npair.pair.callback() // effect', 1),
            ('box := Box{noisy}\npair := Record{box, reset(&box)}\npair.box.callback() // effect', 1),
            ('box := Box{noisy}\npair := Reference{&box, reset(&box)}\npair.box.callback()', 0),
            ('box := Box{quiet}\npair := Reference{&box, activate(&box)}\npair.box.callback() // effect', 1),
            ('box := Box{noisy}\ncallbacks := [2]proc(){box.callback, restore(&box)}\ncallbacks[0]() // effect', 1),
        ])

    def test_addressed_fields_keep_component_boundaries(self):
        self.check_cases('''
Pair :: struct {row, rows: Box}
reset :: proc(box: ^Box) {box.callback = quiet}
activate :: proc(box: ^Box) {box.callback = noisy}
''', [
            ('pair := Pair{Box{quiet}, Box{noisy}}\nsaved := &pair.rows.callback\nreset(&pair.row)\nsaved^() // effect', 1),
            ('pair := Pair{Box{quiet}, Box{quiet}}\nsaved := &pair.rows.callback\nactivate(&pair.row)\nsaved^()', 0),
            ('pair := Pair{Box{quiet}, Box{noisy}}\nsaved := &pair.rows.callback\nreset(&pair.rows)\nsaved^()', 0),
            ('pair := Pair{Box{quiet}, Box{noisy}}\nsaved := &pair.rows\nreset(&pair.row)\nsaved.callback() // effect', 1),
        ])

    def test_nested_collection_stores_preserve_unrelated_addressed_fields(self):
        self.check_cases('''
Table :: struct {rows: map[int][dynamic]int}
Group :: struct {tables: [2]Table, box: Box, alias: ^Box}
fill :: proc(table: ^Table) {
	values := table.rows[0]
	append(&values, 1)
	table.rows[0] = values
}
populate :: proc(group: ^Group) {for &table in group.tables {fill(&table)}}
''', [
            ('''group: Group
group.box.callback = noisy
group.alias = &group.box
for &table in group.tables {table.rows = make(map[int][dynamic]int)}
defer {for &table in group.tables {delete(table.rows[0]); delete(table.rows)}}
populate(&group)
for &table in group.tables {fill(&table)}
assert(group.alias == &group.box && group.alias.callback == noisy)
assert(group.alias.callback != quiet)
group.alias.callback() // effect
''', 1),
        ])

    def test_recursive_map_traversal_retains_callbacks_and_finite_nested_indices(self):
        self.check_cases('''
Node :: struct {children: map[string]^Node, callback: proc()}
select_node :: proc(source: Node, path: []string) -> Node {
	result := source
	for component in path {
		if child, found := result.children[component]; found {result = child^}
	}
	return result
}
Layers :: struct {tables: [2]map[int]map[int]Box}
select_box :: proc(layers: ^Layers) -> Box {return layers.tables[1][2][3]}
''', [
            ('''leaf := Node{callback = noisy}
root := Node{children = make(map[string]^Node), callback = noisy}
defer delete(root.children)
root.children["leaf"] = &leaf
selected := select_node(root, []string{"leaf", "absent"})
assert(selected.callback == noisy)
selected.callback() // effect
''', 1),
            ('''leaf := Node{callback = quiet}
root := Node{children = make(map[string]^Node), callback = quiet}
defer delete(root.children)
root.children["leaf"] = &leaf
selected := select_node(root, []string{"leaf"})
assert(selected.callback == quiet)
selected.callback()
''', 0),
            ('''layers: Layers
layers.tables[1] = make(map[int]map[int]Box)
inner := make(map[int]Box)
inner[3] = Box{noisy}
layers.tables[1][2] = inner
defer {delete(layers.tables[1][2]); delete(layers.tables[1])}
selected := select_box(&layers)
assert(selected.callback == noisy)
selected.callback() // effect
''', 1),
        ])

    def test_forwarded_pointer_rebinding_updates_the_slot_not_its_old_referent(self):
        self.check_cases('''
Pair :: struct {first, second: Box, selected: ^Box}
Parent :: struct {pair: Pair}
select_box :: proc(pair: ^Pair, choose: bool) {
	pair.selected = &pair.first
	if choose {pair.selected = &pair.second}
}
forward :: proc(parent: ^Parent) {select_box(&parent.pair, true)}
''', [
            ('''parent: Parent
parent.pair.first.callback = quiet
parent.pair.second.callback = noisy
for _ in 0..<2 {forward(&parent)}
assert(parent.pair.selected == &parent.pair.second)
assert(parent.pair.first.callback == quiet)
parent.pair.first.callback()
parent.pair.second.callback() // effect
''', 1),
        ])

    def test_control_flow_captures_end_with_their_statement(self):
        self.check_cases('''
keep :: proc(value: bool) -> bool {return value}
invoke :: proc(callback: proc(), unused: bool) {_ = unused; callback()}
reset :: proc(box: ^Box) -> bool {
	for value in ([2]bool{false, true}) {
		if keep(value) {box.callback = quiet}
	}
	return true
}
''', [
            ('for value in ([2]bool{false, true}) {if keep(value) {noisy()}} // effect', 1),
            ('for value in ([2]bool{false, true}) {\n\tswitch keep(value) {\n\tcase true: noisy() // effect\n\tcase false:\n\t}\n}', 1),
            ('for value in ([2]bool{false, true}) {if keep(value) && keep(true) {noisy()}} // effect', 1),
            ('for value in ([2]bool{false, true}) {if keep(value) {if keep(true) {noisy()}}} // effect', 1),
            ('box := Box{noisy}\ninvoke(box.callback, reset(&box)) // effect', 1),
            ('box := Box{quiet}\nfor value in ([2]bool{false, true}) {if keep(value) {box.callback = noisy}}\nbox.callback() // effect', 1),
        ])


if __name__ == "__main__":
    unittest.main()
