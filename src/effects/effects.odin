package effects

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// ---------------- Project ----------------

import "../functions"
import "../state"

// -------------------------------- Procedures --------------------------------

// ---------------- Public ----------------

run :: proc(args: []string) -> int {
	// Invocation metadata and the project graph share one arena, released on return.
	metadata: mem.Dynamic_Arena
	mem.dynamic_arena_init(&metadata)
	defer mem.dynamic_arena_destroy(&metadata)
	context.allocator = mem.dynamic_arena_allocator(&metadata)
	root := "."
	collections := make(map[string]string)
	paths: [dynamic]string
	source_root := ""
	options := true
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if options && arg == "--" {
			options = false
		} else if options && (arg == "--help" || arg == "-h") {
			fmt.print(USAGE)
			return 0
		} else if options && arg == "--version" {
			fmt.printf("odin-lint %s (%s)\n", strings.trim_space(VERSION), REVISION)
			return 0
		} else if options && (arg == "--root" || arg == "--source-root" || arg == "--collection") {
			if i+1 == len(args) {
				fmt.eprintf("%s needs a value\n%s", arg, USAGE)
				return 2
			}
			i += 1
			if arg == "--root" {
				root = args[i]
			} else if arg == "--source-root" {
				source_root = args[i]
			} else {
				parts := strings.split_n(args[i], "=", 2)
				if len(parts) != 2 || parts[0] == "" || parts[1] == "" || parts[0] == "core" || parts[0] == "base" || parts[0] == "vendor" {
					fmt.eprintln("--collection requires NAME=DIR with a non-builtin name")
					return 2
				}
				name, dir := parts[0], parts[1]
				collections[name] = dir
			}
		} else if options && strings.has_prefix(arg, "-") {
			fmt.eprintf("unknown option %s\n%s", arg, USAGE)
			return 2
		} else {
			append(&paths, arg)
		}
	}
	cwd, cwd_err := os.get_working_directory(context.allocator)
	if cwd_err != nil {
		fmt.eprintf("cannot read working directory: %v\n", cwd_err)
		return 2
	}
	absolute_root := absolute_path(root, cwd)
	if !os.is_dir(absolute_root) {
		fmt.eprintf("invalid project root %s\n", root)
		return 2
	}
	canonical_root, root_err := filepath.abs(absolute_root)
	if root_err != nil {
		fmt.eprintf("%s: cannot resolve project root: %v\n", root, root_err)
		return 2
	}
	source_root = absolute_path("src" if source_root == "" else source_root, absolute_root)
	if len(paths) == 0 {
		append(&paths, source_root)
	}
	// One file fact per canonical path; the value retains its selected spelling.
	files := make(map[string]string)
	import_aliases := make(map[string]string)
	analysis_error := false
	for path in paths {
		absolute := absolute_path(path, cwd)
		analysis_error = collect_files(absolute, &files, .Explicit, &import_aliases) || analysis_error
	}
	// A default source root may be absent for a standalone file. Explicit
	// collection roots must exist, matching compiler setup, even when unused.
	source_root = filepath.abs(source_root) or_else source_root
	for name, directory in collections {
		absolute := absolute_path(directory, cwd)
		if !os.is_dir(absolute) {fmt.eprintf("invalid collection root %s=%s\n", name, directory); return 2}
		collections[name] = filepath.abs(absolute) or_else absolute
	}
	// Visibility and ownership need consumers and imported type definitions, even
	// for a single selected file. One project graph owns the parsed saved sources.
	analysis_files := make(map[string]string)
	analysis_error = collect_files(canonical_root, &analysis_files, .Tree, &import_aliases) || analysis_error
	packages := make(map[string]bool)
	for canonical, spelling in files {
		analysis_files[canonical] = spelling
		packages[filepath.dir(canonical)] = true
	}
	package_paths: [dynamic]string
	for directory in packages {append(&package_paths, directory)}
	slice.sort(package_paths[:])
	complete := true
	for directory in package_paths {
		complete = !collect_files(directory, &analysis_files, .Package, &import_aliases) && complete
	}
	if !complete {return 2}
	// Referenced packages are analysis evidence, including explicitly mapped
	// collection packages under vendor. Diagnostic selection stays unchanged.
	{
		pending: [dynamic]string
		for path in analysis_files {append(&pending, path)}
		slice.sort(pending[:])
		queued := make(map[string]bool)
		for path in pending {queued[path] = true}
		import_packages := make(map[string]bool)
		for cursor := 0; cursor < len(pending); cursor += 1 {
			path := pending[cursor]
			data, read_error := os.read_entire_file(path, context.allocator)
			if read_error != nil {fmt.eprintf("%s: %v\n", path, read_error); analysis_error = true; continue}
			imports, failure := functions.source_imports(string(data), path)
			if failure != "" {fmt.eprintln(failure); analysis_error = true; continue}
			for imported in imports {
				parts := strings.split_n(imported, ":", 2)
				target := ""
				if len(parts) == 2 {
					if slice.contains([]string{"core", "base", "vendor"}, parts[0]) {continue}
					collection_root, mapped := collections[parts[0]]
					if !mapped {continue} // Pure analysis reports the missing mapping.
					target, _ = filepath.join({collection_root, parts[1]})
				} else {
					target, _ = filepath.join({filepath.dir(path), imported})
				}
				// Missing targets retain the existing conservative import boundary;
				// a compiler-checked active import supplies an existing directory.
				if !os.is_dir(target) {continue}
				canonical, resolve_error := filepath.abs(target)
				if resolve_error != nil {fmt.eprintf("%s: %v\n", target, resolve_error); analysis_error = true; continue}
				if canonical != target {import_aliases[target] = canonical}
				if import_packages[canonical] {continue}
				import_packages[canonical] = true
				analysis_error = collect_files(canonical, &analysis_files, .Package, &import_aliases) || analysis_error
				added: [dynamic]string
				for source in analysis_files {if !queued[source] {queued[source] = true; append(&added, source)}}
				slice.sort(added[:])
				append(&pending, ..added[:])
			}
		}
	}
	file_paths: [dynamic]string
	for path in analysis_files {append(&file_paths, path)}
	slice.sort(file_paths[:])
	sources: [dynamic]state.Source
	for path in file_paths {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {fmt.eprintf("%s: %v\n", path, err); return 2}
		_, selected := files[path]
		append(&sources, state.Source{path = path, text = string(data), selected = selected})
	}
	diagnostics, failure := functions.check_package(sources[:], canonical_root, collections, source_root, !analysis_error, import_aliases)
	if failure != "" {fmt.eprintln(failure); analysis_error = true}
	for diagnostic in diagnostics {
		path := files[diagnostic.pos.file]
		fmt.eprintf("%s(%d:%d): %s: %s\n", path, diagnostic.pos.line, diagnostic.pos.column, diagnostic.rule, diagnostic.message)
	}
	if analysis_error {
		return 2
	}
	return int(len(diagnostics) > 0)
}
