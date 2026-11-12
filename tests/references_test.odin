#+private file
package tests

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:mem"
import "core:path/filepath"
import "core:testing"

// ---------------- Project ----------------

import "../src/functions"

// -------------------------------- Procedures --------------------------------

// ---------------- File ----------------

@(test)
private_helper_suggestions :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root, _ := filepath.abs(".")
	path, _ := filepath.join({root, "src", "main.odin"})
	cases := []struct {source, wanted: string, count: int}{
		{"package a\nmain :: proc() {_ = helper()}\n@(private=\"file\") helper :: proc() -> int {return 1}\n", "SIMPLIFY001", 1},
		{"package a\nValue :: struct {number: int}\nRecord :: struct {using value: Value}\nmain :: proc() {_ = helper()}\n@(private=\"file\") helper :: proc() -> int {return 1}\n", "SIMPLIFY001", 1},
		{"package a\nmain :: proc() {_ = (helper)()}\n@(private=\"file\") helper :: proc() -> int {return 1}\n", "SIMPLIFY001", 1},
		{"package a\nmain :: proc() {_ = helper(); _ = helper()}\n@(private=\"file\") helper :: proc() -> int {return 1}\n", "SIMPLIFY001", 0},
		{"package a\nmain :: proc() {use(helper)}\n@(private=\"file\") helper :: proc() -> int {return 1}\n", "SIMPLIFY001", 0},
		{"package a\nmain :: proc() {helper()}\n@(private=\"file\") helper :: proc() {helper()}\n", "SIMPLIFY001", 0},
		{"package a\nmain :: proc() {first()}\n@(private=\"file\") first :: proc() {second()}\n@(private=\"file\") second :: proc() {first()}\n", "SIMPLIFY001", 0},
		{"package a\nmain :: proc() {helper := proc() {}; helper()}\n@(private=\"file\") helper :: proc() {}\n", "SIMPLIFY001", 0},
		{"package a\nmain :: proc() {x := map[int]int{helper()=1}; _ = x; _ = helper()}\n@(private=\"file\") helper :: proc() -> int {return 1}\n", "SIMPLIFY001", 0},
		{"package a\nmain :: proc() {_ = obj.helper()}\n@(private=\"file\") helper :: proc() -> int {return 1}\n", "SIMPLIFY001", 0},
		{"package a\n@(private=\"file\") helper :: proc() {}\n@(private=\"file\") caller :: proc() {helper()}\nmain :: proc() {caller()}\n", "FLOW001", 2},
		{"package a\n@(private=\"file\") helper :: proc(value: int) -> int {return value}\n@(private=\"file\") convert :: proc($helper: typeid, value: int) {_ = helper(value)}\nmain :: proc() {_ = helper(1); convert(int, 2)}\n", "FLOW001", 2},
		{"package a\nValue :: struct {number: int}\nwork :: proc(using value: Value) {}\nmain :: proc() {work({})}\n", "LINT003", 0},
		{"package a\nwhen false {f :: proc() {}}\n", "LINT003", 0},
		{"package a\nmain :: proc() {when #config(FLAG, false) {helper :: proc() {}}; helper()}\nwork :: proc() {helper()}\n@(private) helper :: proc() {}\n", "SIMPLIFY001", 0},
		{"package a\nmain :: proc() {when #config(FLAG, false) {helper :: proc() {}}; helper()}\nwork :: proc() {helper()}\n@(private) helper :: proc() {}\n", "LINT003", 0},
		{"package a\nmain :: proc() {alias :: helper; {when #config(FLAG, false) {alias :: other}; alias()}}\nother :: proc() {}\n@(private) helper :: proc() {}\n", "SIMPLIFY001", 0},
		{"package a\nmain :: proc() {when false {helper :: proc() {}}; helper()}\nwork :: proc() {helper()}\n@(private) helper :: proc() {}\n", "SIMPLIFY001", 0},
		{"package a\nmain :: proc() {when true {helper :: proc() {}}; helper()}\nwork :: proc() {helper()}\n@(private) helper :: proc() {}\n", "SIMPLIFY001", 1},
		{"package a\nmain :: proc() {{helper :: proc() {}; helper()}; helper()}\n@(private) helper :: proc() {}\n", "SIMPLIFY001", 1},
	}
	for item in cases {
		diagnostics, failure := functions.check_source(item.source, path, root, nil)
		testing.expect_value(t, failure, "")
		testing.expect(t, count_rule(diagnostics[:], item.wanted) == item.count, item.source)
	}
}

@(test)
ambient_clock_effects :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root, _ := filepath.abs(".")
	path, _ := filepath.join({root, "src", "functions", "a.odin"})
	cases := []struct {source: string, count: int}{
		{"package a\nimport \"core:time\"\nwork :: proc() {_ = time.now()}\n", 1},
		{"package a\nimport \"core:time\"\nValue :: struct {number: int}\nRecord :: struct {using value: Value}\nwork :: proc() {_ = time.now()}\n", 1},
		{"package a\nimport \"\"\"core:time\"\"\"\nwork :: proc() {_ = time.now()}\n", 1},
		{"package a\nimport clock \"core:time\"\nwork :: proc() {clock.sleep(1)}\n", 1},
		{"package a\nimport \"core:time\"\nwork :: proc() {_ = time.Second}\n", 0},
		{"package a\nimport \"core:time\"\nwork :: proc(time: struct {now: proc()}) {time.now()}\n", 0},
		{"package a\nimport \"another/time\"\nwork :: proc() {_ = time.now()}\n", 0},
	}
	for item in cases {
		diagnostics, failure := functions.check_source(item.source, path, root, nil)
		testing.expect_value(t, failure, "")
		testing.expect(t, count_rule(diagnostics[:], "ARCH006") == item.count, item.source)
	}
}
