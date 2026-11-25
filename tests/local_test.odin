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
local_policies :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root, _ := filepath.abs(".")
	cases := []struct {path, source, rule: string}{
		{"main.odin", "package a\nmain :: proc() {f := proc() {}; f()}\n", "PROC001"},
		{"main.odin", "package a\nmain :: proc() {f := (proc() {}); f()}\n", "PROC001"},
		{"main.odin", "package a\nmain :: proc() {use(proc() {})}\n", ""},
		{"main.odin", "package a\nmain :: proc() {use(callback = (proc() {}))}\n", ""},
		{"main.odin", "package a\nmain :: proc() {use(proc() {use(proc() {})})}\n", ""},
		{"main.odin", "package a\nmain :: proc() {use(proc() {f := proc() {}; f()})}\n", "PROC001"},
		{"main.odin", "#+private file\npackage a\n@(private=\"file\")\nCount :: 1\n", "VIS001"},
		{"main.odin", "#+private file\npackage a\n@(private=\"\"\"file\"\"\")\nCount :: 1\n", "VIS001"},
		{"main.odin", "#+private\npackage a\n@(private)\nCount :: 1\n", "VIS001"},
		{"main.odin", "#+private\npackage a\n@(private=\"file\")\nCount :: 1\n", ""},
		{"main.odin", "package a\nimport \"project\"\nimport \"core:fmt\"\n", "IMPORT001"},
		{"main.odin", "package a\nCount :: 1\nimport \"core:fmt\"\n", "IMPORT001"},
		{"main.odin", "package a\nCount :: 1\nforeign import libc \"system:c\"\n", "IMPORT001"},
		{"main.odin", "package a\nforeign import libc \"system:c\"\nCount :: 1\n", ""},
		{"main.odin", "package a\nimport \"vendor:raylib\"\nimport \"core:fmt\"\nimport \"project\"\n", ""},
		{"functions/a.odin", "package a\nCount := 1\n", "ARCH003"},
		{"functions/a.odin", "package a\nwork :: proc() {count := 1; _ = count}\n", ""},
		{"state/a.odin", "package a\nValue :: struct {number: int}\nHandler :: proc()\n", ""},
		{"state/a.odin", "package a\nwork :: proc() {}\n", "ARCH004"},
		{"state/a.odin", "package a\n@(test)\nwork :: proc() {}\n", ""},
		{"catalog/a.odin", "package a\nwork :: proc() {}\n", ""},
		{"effects/a.odin", "package a\nCount := 1\nwork :: proc() {}\n", ""},
		{"functions/a.odin", "package a\n@(init)\nwork :: proc() {}\n", "ARCH005"},
	}
	for item in cases {
		path, _ := filepath.join({root, "src", item.path})
		diagnostics, failure := functions.check_source(item.source, path, root, nil)
		testing.expect_value(t, failure, "")
		for rule in ([]string{"PROC001", "VIS001", "IMPORT001", "ARCH003", "ARCH004", "ARCH005"}) {
			testing.expect(t, count_rule(diagnostics[:], rule) == int(item.rule == rule), item.source)
		}
	}
}

@(test)
section_policies :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root, _ := filepath.abs(".")
	path, _ := filepath.join({root, "src", "main.odin"})
	cases := []struct {source, rule: string}{
		{"package a\nCount :: 1\n", "SECTION003"},
		{"package a\n// -1 is the invalid sentinel-\nCount :: 1\n", "SECTION003"},
		{"package a\n// ---not a section---\nCount :: 1\n", "SECTION003"},
		{"package a\n// -------------------------------- Constants --------------------------------\n// ---------------- Public ----------------\nCount :: 1\n", ""},
		{"package a\n// -------------------------------- Types --------------------------------\n// ---------------- Public ----------------\nHandler :: proc()\n", ""},
		{"package a\n// -------------------------------- Types --------------------------------\n// ---------------- Public ----------------\nAlias :: struct {} when true else struct {}\n", ""},
		{"package a\n// -------------------------------- Public --------------------------------\n// ---------------- Constants ----------------\nCount :: 1\n", ""},
		{"package a\n// ------------------------------ Constants ------------------------------\nCount :: 1\n", "SECTION001"},
		{"package a\n// -------------------------------- Constants --------------------------------\n// ---------------- Public ----------------\n", "SECTION004"},
		{"package a\n// -------------------------------- Types --------------------------------\n// ---------------- Public ----------------\nCount :: 1\n", "SECTION003"},
		{"package a\n// -------------------------------- Types --------------------------------\n// ---------------- Public ----------------\nA, B :: 1, 2\n", "SECTION003"},
		{"package a\n// -------------------------------- Constants --------------------------------\n// ---------------- Public ----------------\n// -------- Definitions --------\nA, B :: 1, 2\n", ""},
		{"package a\n// -------------------------------- Constants --------------------------------\n// ---------------- Public ----------------\n// -------- First --------\nA :: 1\n// -------- Second --------\nB :: 2\n// ---------------- Package ----------------\n@(private)\nC :: 3\n// -------------------------------- Procedures --------------------------------\n// ---------------- Public ----------------\nmain :: proc() {}\n", ""},
		{"package a\n// -------------------------------- Public --------------------------------\n// ---------------- Constants ----------------\n// -------- First --------\nA :: 1\n// -------- Second --------\nB :: 2\n// ---------------- Procedures ----------------\nmain :: proc() {}\n// -------------------------------- Package --------------------------------\n// ---------------- Constants ----------------\n@(private)\nC :: 3\n", ""},
		{"package a\n// -------------------------------- Types --------------------------------\n// ---------------- Public ----------------\nA :: struct {}\n// -------------------------------- Constants --------------------------------\n// ---------------- Public ----------------\nCount :: 1\n", "SECTION002"},
		{"package a\n// -------------------------------- Constants --------------------------------\n// ---------------- Public ----------------\nA :: 1\n// ---------------- Public ----------------\nB :: 2\n", "SECTION002"},
		{"package a\nmain :: proc() {\n// ------- Bogus -------\n}\ntext :: `// ------- Bogus -------`\n", "SECTION003"},
	}
	for item in cases {
		diagnostics, failure := functions.check_source(item.source, path, root, nil)
		testing.expect_value(t, failure, "")
		for rule in ([]string{"SECTION001", "SECTION002", "SECTION003", "SECTION004"}) {
			if item.rule == "" {
				testing.expect_value(t, count_rule(diagnostics[:], rule), 0)
			} else if item.rule == rule {
				testing.expect(t, count_rule(diagnostics[:], rule) > 0, item.source)
			}
		}
	}
}

@(test)
file_visibility_policy :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root, _ := filepath.abs(".")
	cases := []struct {name, source: string, clean: bool}{
		{"main.odin", "package a\n", true},
		{"main.odin", "#+private\npackage a\n", false},
		{"shared.odin", "#+private file\npackage a\n", true},
		{"shared.odin", "package a\n", false},
		{"helper.odin", "#+private file\npackage a\n", true},
		{"helper.odin", "package a\n", false},
	}
	for item in cases {
		path, _ := filepath.join({root, "src", item.name})
		diagnostics, failure := functions.check_source(item.source, path, root, nil)
		testing.expect_value(t, failure, "")
		testing.expect_value(t, count_rule(diagnostics[:], "FILE001"), int(!item.clean))
	}
}
