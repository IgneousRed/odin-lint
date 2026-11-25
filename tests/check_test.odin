#+private file
package tests

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:fmt"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// ---------------- Project ----------------

import "../src/functions"

// -------------------------------- Procedures --------------------------------

// ---------------- File ----------------

@(test)
diagnostics_outlive_inference_work :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root, _ := filepath.abs(".")
	path, _ := filepath.join({root, "src", "catalog", "catalog.odin"})
	source := "package catalog\nCatalog :: struct {values: []int}\nmutate :: proc(value: ^Catalog) {value.values[0] = 1}\n@(rodata)\nsaved: Catalog\nrun :: proc() {mutate(&saved)}\n"
	diagnostics, failure := functions.check_source(source, path, root, nil)
	testing.expect_value(t, failure, "")
	found := false
	for diagnostic in diagnostics {
		if diagnostic.rule != "OWN001" || !strings.has_prefix(diagnostic.message, "mutate mutates") {continue}
		found = true
		for _ in 0..<4 {
			_, next_failure := functions.check_source(source, path, root, nil)
			testing.expect_value(t, next_failure, "")
		}
		testing.expect_value(t, diagnostic.message, "mutate mutates protected state through parameter 1 (including field values.[])")
		testing.expect_value(t, diagnostic.pos.file, path)
	}
	testing.expect(t, found)
}

@(test)
role_dependencies :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root, _ := filepath.abs(".")
	// Exercise every pair with actual Odin imports. Expected edges are written
	// independently of the implementation's enum, including composition roles.
	roles := []string{"catalog", "effects", "engine", "functions", "procedures", "state", "views", "ui", "application", "migrations"}
	allowed := []string{"", " procedures engine functions views state catalog ", " functions views state catalog ", " views state catalog migrations ", " engine functions views state catalog ", " catalog ", " state catalog ", " procedures engine functions views state catalog ", " ui effects procedures engine functions views state catalog migrations ", " state catalog "}
	for from, i in roles {
		for to in roles {
			path, _ := filepath.join({root, "src", from, "example.odin"})
			source := fmt.aprintf("package example\nimport dep \"../%s\"\n", to)
			diagnostics, failure := functions.check_source(source, path, root, nil)
			testing.expect_value(t, failure, "")
			permitted := from == to || strings.contains(allowed[i], fmt.aprintf(" %s ", to))
			testing.expect(t, count_rule(diagnostics[:], "ARCH001") == int(!permitted), fmt.aprintf("%s -> %s", from, to))
			for diagnostic in diagnostics {
				if diagnostic.rule == "ARCH001" {
					testing.expect_value(t, diagnostic.pos.line, 2)
					testing.expect_value(t, diagnostic.pos.column, 12)
				}
			}
		}
	}
}

@(test)
source_cases :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root, _ := filepath.abs(".")
	collections := make(map[string]string)
	collections["app"], _ = filepath.join({root, "src"})
	cases := []struct {path, source, rule: string}{
		{"functions/a.odin", "package a\nimport x \"../effects\"\n", "ARCH001"},
		{"functions/a.odin", "package a\nimport \"../effects/../state\"\n", ""},
		{"functions/nested/a.odin", "package a\nimport \"../../engine\"\n", "ARCH001"},
		{"functions/a.odin", "package a\nimport \"app:engine\"\n", "ARCH001"},
		{"functions/a.odin", "package a\nimport \"app:state\"\n", ""},
		{"functions/a.odin", "package a\nimport \"../../external/effects\"\n", ""},
		{"functions/a.odin", "package a\nimport \"../effects_extra\"\n", "ARCH001"},
		{"functions/a.odin", "package a\nimport \"..\"\n", "ARCH001"},
		{"functions/a.odin", "package a\nimport \"../eff\\x65cts\"\n", "ARCH001"},
		{"functions/a.odin", "package a\nimport `../effects`\n", "ARCH001"},
		{"functions/a.odin", "package a\nwhen false {import \"../effects\"}\n", "ARCH001"},
		{"functions/a.odin", "package a\n/* import \"../effects\" */\ntext :: `import \"../effects\"`\n", ""},
		{"functions/a.odin", "package a\nimport file \"core:os\"\n", ""},
		{"views/a.odin", "package a\nimport \"core:net/http\"\n", ""},
		{"state/a.odin", "package a\nimport \"core:os/process\"\n", ""},
		{"catalog/a.odin", "package a\nimport \"core:net\"\n", ""},
		{"functions/a.odin", "package a\nimport \"core:os\"\nrun :: proc() {_ = os.exists(\"file\")}\n", "ARCH002"},
		{"functions/a.odin", "package a\nimport \"core:net_extra\"\n", ""},
		{"functions/a.odin", "package a\nimport \"core:fmt\"\n", ""},
		{"effects/a.odin", "package a\nimport \"core:os\"\n", ""},
		{"main.odin", "package a\nimport \"core:os\"\n", ""},
	}
	for item in cases {
		path, _ := filepath.join({root, "src", item.path})
		diagnostics, failure := functions.check_source(item.source, path, root, collections)
		testing.expect_value(t, failure, "")
		for rule in ([]string{"ARCH001", "ARCH002"}) {
			testing.expect(t, count_rule(diagnostics[:], rule) == int(item.rule == rule), item.source)
		}
	}
}

@(test)
unparseable_sources :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	root, _ := filepath.abs(".")
	path, _ := filepath.join({root, "src", "functions", "a.odin"})
	sources := []string{"not a package", "package a\nx :: proc( {", "package a\nimport \"unterminated", "package a\n/* unterminated"}
	for source in sources {
		diagnostics, failure := functions.check_source(source, path, root, nil)
		testing.expect_value(t, len(diagnostics), 0)
		testing.expect(t, strings.contains(failure, "cannot parse source"), source)
		testing.expect(t, strings.contains(failure, "policy analysis failed"), failure)
	}
}
