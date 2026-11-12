#+private file
package tests

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:mem"
import "core:testing"

// ---------------- Project ----------------

import "../src/functions"

// -------------------------------- Procedures --------------------------------

// ---------------- File ----------------

@(test)
metadata_literals :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	cases := []struct {literal, expected: string, valid: bool}{
		{"\"../effects\"", "../effects", true},
		{"`../effects`", "../effects", true},
		{"\"\"\"../effects\"\"\"", "../effects", true},
		{"```../effects```", "../effects", true},
		{"\"\"\"\n\t../effects\n\t\"\"\"", "../effects", true},
		{"```\r\n  ../effects\r\n  ```", "../effects", true},
		{"\"\"\"../eff\\x65cts\"\"\"", "../effects", true},
		{"\"\\056\\056/effects\"", "../effects", true},
		{"\"\"\"\\056\\056/effects\"\"\"", "../effects", true},
		{"\"\\3770\"", "\xff0", true},
		{"\"a\\\"b\"", "a\"b", true},
		{"\"\"\"\\u03bb\"\"\"", "λ", true},
		{"\"\"\"\\xff\"\"\"", "\xff", true},
		{"```a\\nb```", `a\nb`, true},
		{"\"\"\"a\"b\"\"\"", "a\"b", true},
		{"\"\"\"\n  a\n \t\n  b\n  \"\"\"", "a\n\nb", true},
		{"\"\"\"text\n  path\n  \"\"\"", "", false},
		{"\"\"\"\n path\n  \"\"\"", "", false},
		{"\"\"\"\n\tpath\n  \"\"\"", "", false},
		{"\"\"\"bad\\q\"\"\"", "", false},
		{"\"\\400rest\"", "", false},
		{"\"\\05\"", "", false},
		{"\"a\"b\"", "", false},
	}
	for item in cases {
		value, ok := functions.metadata_string(item.literal)
		testing.expect(t, ok == item.valid, item.literal)
		if ok {
			testing.expect_value(t, value, item.expected)
		}
	}
}
