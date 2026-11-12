#+private file
package tests

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:fmt"
import "core:os"
import "core:testing"

// ---------------- Project ----------------

import "../src/effects"

// -------------------------------- Procedures --------------------------------

// ---------------- File ----------------

// Run in-process so the allocator detects leaked invocation/project metadata.
// A complete tiny package exercises graph allocation without repeating self-lint
// of this entire repository twice inside the memory tracker.
@(test)
invocation_releases_sources :: proc(t: ^testing.T) {
	root, error := os.make_directory_temp(".work", "invocation-*", context.allocator)
	testing.expect_value(t, error, nil)
	if error != nil {return}
	defer delete(root)
	defer os.remove_all(root)
	directory := fmt.aprintf("%s/src/functions", root)
	defer delete(directory)
	testing.expect_value(t, os.make_directory_all(directory), nil)
	for name, i in ([2]string{"functions", "helper"}) {
		path := fmt.aprintf("%s/%s.odin", directory, name)
		defer delete(path)
		source := "package functions\n// -------------------------------- Procedures --------------------------------\n// ---------------- Public ----------------\nrun :: proc() -> int {return helper()+helper()}\n" if i == 0 else "#+private\npackage functions\n// -------------------------------- Procedures --------------------------------\n// ---------------- Package ----------------\nhelper :: proc() -> int {return 1}\n"
		testing.expect_value(t, os.write_entire_file(path, source), nil)
	}
	for _ in 0 ..< 2 {testing.expect_value(t, effects.run({"--root", root}), 0)}
}
