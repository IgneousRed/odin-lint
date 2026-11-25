#+private file
package tests

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

// ---------------- Project ----------------

import "../src/functions"
import "../src/state"

// -------------------------------- Procedures --------------------------------

// ---------------- File ----------------

@(test)
alias_section_kinds :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for example in ([]struct {heading, declaration: string, rejected: bool}{
		{"Types", "Number :: int", false},
		{"Constants", "Number :: int", true},
		{"Types", "Number :: (int)", false},
		{"Types", "Alias :: Number\nNumber :: int", false},
		{"Constants", "Alias :: Number\nNumber :: int", true},
		{"Constants", "Alias :: int\nint :: 3", false},
		{"Constants", "Value :: int(3)", false},
		{"Types", "Value :: int(3)", true},
		{"Types", "Number :: type_of(3)", false},
		{"Constants", "Size :: size_of(int)", false},
		{"Procedures", "Alias :: work\nwork :: proc() {}", false},
		{"Constants", "Alias :: work\nwork :: proc() {}", true},
		{"Types", "Choice :: int when true else f32", false},
		{"Constants", "Choice :: int when true else f32", true},
	}) {
		source := fmt.aprintf("package sample\n// -------------------------------- %s --------------------------------\n// ---------------- Public ----------------\n%s\n", example.heading, example.declaration)
		diagnostics, failure := functions.check_source(source, "/project/src/sample/sample.odin", "/project", nil)
		testing.expect_value(t, failure, "")
		testing.expect(t, (count_rule(diagnostics[:], "SECTION003") > 0) == example.rejected, source)
	}
	for heading in ([]string{"Types", "Constants"}) {
		sources := []state.Source{
			{path = "/project/src/api/api.odin", text = "package api\nNumber :: int\n", selected = false},
			{path = "/project/src/sample/sample.odin", text = fmt.aprintf("package sample\n// -------------------------------- Imports --------------------------------\n// ---------------- Project ----------------\nimport \"../api\"\n// -------------------------------- %s --------------------------------\n// ---------------- Public ----------------\nNumber :: api.Number\n", heading), selected = true},
		}
		diagnostics, failure := functions.check_package(sources, "/project", nil)
		testing.expect_value(t, failure, "")
		testing.expect_value(t, count_rule(diagnostics[:], "SECTION003"), int(heading != "Types"))
	}
}

@(test)
visibility_uses_project_consumers :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for example in ([]struct {attribute, consumer: string, complete, rejected: bool}{
		{"", "same", false, false},
		{"", "same", true, false},
		{"@(private)", "same", false, true},
		{"@(private)", "sibling", false, false},
		{"", "sibling", true, false},
		{"", "external", true, false},
		{"@(export)", "same", true, false},
	}) {
		text := fmt.aprintf("package api\n%s\nvalue :: proc() -> int {{return 1}}\n", example.attribute)
		if example.consumer == "same" {text = strings.concatenate({text, "caller :: proc() {_ = value()}\n"})}
		sources := make([dynamic]state.Source)
		append(&sources, state.Source{path = "/project/src/api/api.odin", text = text, selected = true})
		if example.consumer == "sibling" {append(&sources, state.Source{path = "/project/src/api/caller.odin", text = "package api\ncaller :: proc() {_ = value()}\n"})}
		if example.consumer == "external" {append(&sources, state.Source{path = "/project/src/app/app.odin", text = "package app\nimport \"../api\"\ncaller :: proc() {_ = api.value()}\n"})}
		diagnostics, failure := functions.check_package(sources[:], "/project", nil, "", example.complete)
		testing.expect_value(t, failure, "")
		testing.expect_value(t, count_rule(diagnostics[:], "VIS002"), int(example.rejected))
	}
}

@(test)
broader_ordering_and_cycles :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for example in ([]struct {kind, body: string, rejected: bool}{
		{"Constants", "Count :: 3\nAlias :: Count", true},
		{"Constants", "Alias :: Count\nCount :: 3", false},
		{"Types", "Item :: struct {}\nList :: []Item", true},
		{"Types", "List :: []Item\nItem :: struct {}", false},
		{"Procedures", "helper :: proc() {}\ncaller :: proc() {helper()}", true},
		{"Procedures", "caller :: proc() {helper()}\nhelper :: proc() {}", false},
		{"Procedures", "first :: proc() {second()}\nsecond :: proc() {first()}", false},
		{"Procedures", "helper :: proc() {}\ncaller :: proc(helper: int) {_ = helper}", false},
	}) {
		source := fmt.aprintf("package sample\n// -------------------------------- %s --------------------------------\n// ---------------- Public ----------------\n%s\n", example.kind, example.body)
		diagnostics, failure := functions.check_source(source, "/project/src/sample/sample.odin", "/project", nil)
		testing.expect_value(t, failure, "")
		testing.expect(t, (count_rule(diagnostics[:], "FLOW001") > 0) == example.rejected, source)
	}
}

@(test)
file_structure_and_default_threshold :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for example in ([]struct {path, text, rule: string}{
		{"/project/src/sample/helper.odin", "#+private file\npackage sample\n", "FILE003"},
		{"/project/src/sample/sample.odin", "package wrong\n", "FILE002"},
		{"/project/src/sample/shared.odin", "#+private file\npackage sample\n", "FILE003"},
	}) {
		diagnostics, failure := functions.check_source(example.text, example.path, "/project", nil)
		testing.expect_value(t, failure, "")
		testing.expect_value(t, count_rule(diagnostics[:], example.rule), 1)
	}
	for count in ([]int{59, 60, 61}) {
		builder := strings.builder_make()
		strings.write_string(&builder, "package sample\n")
		for i in 0..<100 {
			if i < count {strings.write_string(&builder, "@(private)\n")}
			fmt.sbprintf(&builder, "Value_%d :: %d\n", i, i)
		}
		diagnostics, failure := functions.check_source(strings.to_string(builder), "/project/src/sample/sample.odin", "/project", nil)
		testing.expect_value(t, failure, "")
		testing.expect_value(t, count_rule(diagnostics[:], "FILE006"), int(count >= 60))
	}
}

@(test)
relational_ownership_tracks_borrows_and_copies :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	for example in ([]struct {body: string, rejected: bool}{
		{"read.rows[1] = {}", true},
		{"read.rows = nil", true},
		{"read.rows[1].status = 2", true},
		{"read.active = true", true},
		{"read^ = {}", true},
		{"rows := read.rows; rows[1] = {}", true},
		{"rows := read.rows; clear(&rows)", true},
		{"rows := read.rows; delete_key(&rows, 1)", true},
		{"rows := read.rows; delete(rows)", true},
		{"rows := &read.rows; rows^ = nil", true},
		{"row := &read.rows[1]; row.status = 2", true},
		{"for _, &row in read.rows {row.status = 2}", true},
		{"rows := read.rows; if true {rows = nil}; rows[1] = {}", false},
		{"row := read.rows[1]; row.status = 2", false},
		{"rows := read.rows; if true {rows = make(map[int]state.Row); rows[1] = {}}", false},
		{"rows := make(map[int]state.Row); if true {rows = read.rows}; rows[1] = {}", true},
		{"scratch := state.Store{rows = make(map[int]state.Row)}; scratch.rows[1] = {}", false},
		{"for _, value in read.rows {row := value; row.status = 2}", false},
		{"rows := read.rows; rows = nil; rows = make(map[int]state.Row); rows[1] = {}", false},
		{"rows := make(map[int]state.Row); rows[1] = {}", false},
		{"scratch := state.Store{}; scratch.active = true", false},
		{"_ = read.rows[1]; _ = read.active", false},
	}) {
		sources := []state.Source{
			{path = "/project/src/state/state.odin", text = "package state\nStore :: struct {rows: map[int]Row, active: bool}\nRow :: struct {status: int}\n"},
			{path = "/project/src/functions/functions.odin", text = fmt.aprintf("package functions\nimport \"../state\"\nprobe :: proc(read: ^state.Store) {{%s}}\n", example.body), selected = true},
			{path = "/project/consumer/consumer.odin", text = "package consumer\nimport target \"../src/functions\"\nimport \"../src/state\"\nlive: state.Store\nrun :: proc() {target.probe(&live)}\n", selected = true},
		}
		diagnostics, failure := functions.check_package(sources, "/project", nil)
		testing.expect_value(t, failure, "")
		testing.expect(t, (count_rule(diagnostics[:], "OWN001") > 0) == example.rejected, example.body)
		// The same writes are legal inside their engine owner.
		sources[1].path = "/project/src/engine/engine.odin"
		sources[2].text, _ = strings.replace_all(sources[2].text, "../src/functions", "../src/engine")
		diagnostics, failure = functions.check_package(sources, "/project", nil)
		testing.expect_value(t, failure, "")
		testing.expect_value(t, count_rule(diagnostics[:], "OWN001"), 0)
	}
}
