#+private
package effects

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// -------------------------------- Constants --------------------------------

// ---------------- Package ----------------

USAGE :: `Usage: odin-lint [OPTIONS] [--] [PATH ...]
Check coding-skill policies in saved Odin sources after Odin checks have passed.
All lint rules always run. Without PATH, scan the source root.
Analysis also reads project sources under --root for consumer/type evidence.
This tool does not invoke the compiler.
Relative paths use the current directory, except --source-root uses --root.
--root DIR                       project analysis root (default: .)
--source-root DIR                absolute or project-relative role directory (default: src)
--collection NAME=DIR            import collection (repeatable)
--version                        show version and source revision
-h, --help                       show this help
Exit codes: 0 clean; 1 lint findings; 2 usage, filesystem, or analysis error.
`

VERSION :: string(#load("../../VERSION"))

REVISION :: #config(ODIN_LINT_REVISION, "unknown")

// -------------------------------- Types --------------------------------

// ---------------- File ----------------

@(private="file")
Scan_Scope :: enum {Explicit, Tree, Package}

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

// Preserve lexical paths until lstat can reject encountered symlink entries.
// Accepted files receive canonical identities separately from display paths.
absolute_path :: proc(path, cwd: string) -> string {
	if filepath.is_abs(path) {
		clean, _ := filepath.clean(path)
		return clean
	}
	joined, _ := filepath.join({cwd, path})
	return joined
}

// Do not follow symlinks: this avoids cycles and scanning outside the requested
// tree. Explicit non-Odin files and symlinks are errors rather than silent skips.
collect_files :: proc(path: string, files: ^map[string]string, scope: Scan_Scope, aliases: ^map[string]string) -> (failed: bool) {
	info, err := os.lstat(path, context.allocator)
	if err != nil {
		fmt.eprintf("%s: %v\n", path, err)
		return true
	}
	if info.type == .Directory {
		entries, read_err := os.read_directory_by_path(path, -1, context.allocator)
		if read_err != nil {
			if scope == .Package {
				fmt.eprintf("%s: cannot read package: %v\n", path, read_err)
			} else {
				fmt.eprintf("%s: %v\n", path, read_err)
			}
			return true
		}
		slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		for entry in entries {
			if strings.has_prefix(entry.name, ".") || entry.name == "vendor" ||
			   (scope == .Package && (entry.type == .Directory || entry.type != .Symlink && !strings.has_suffix(entry.name, ".odin"))) {
				continue
			}
			child, _ := filepath.join({path, entry.name})
			child_scope := .Tree if scope == .Explicit else scope
			failed = collect_files(child, files, child_scope, aliases) || failed
		}
	} else if info.type == .Regular && strings.has_suffix(path, ".odin") {
		canonical, resolve_err := filepath.abs(path)
		if resolve_err != nil {
			fmt.eprintf("%s: cannot resolve source filename: %v\n", path, resolve_err)
			return true
		}
		previous, seen := files^[canonical]
		if !seen || path < previous {
			files^[canonical] = path
		}
	} else if info.type == .Symlink && strings.has_suffix(path, ".odin") {
		uses := "package" if scope == .Package else "project"
		fmt.eprintf("%s: cannot establish complete %s uses: symlinked Odin sibling\n", path, uses)
		return true
	} else if info.type == .Symlink && scope != .Explicit {
		// Keep traversal non-following, but retain the canonical identity of a
		// directory alias for import resolution at the pure analysis boundary.
		if os.is_dir(path) {
			if canonical, resolve_err := filepath.abs(path); resolve_err == nil {aliases^[path] = canonical}
		}
	} else if scope == .Explicit {
		fmt.eprintf("%s: expected an Odin file or directory, not a symlink or other file\n", path)
		return true
	}
	return
}
