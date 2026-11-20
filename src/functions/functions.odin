package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// ---------------- Project ----------------

import "../state"

// -------------------------------- Constants --------------------------------

// ---------------- Package ----------------

@(private)
PURE_ROLES :: bit_set[Role]{.Catalog, .Functions, .State, .Views, .Migrations}

// State_Flow maps commonly exceed the default arena out-of-band threshold.
// Batch those allocations so releasing a pass does not free each map separately.
@(private)
INFERENCE_BLOCK_SIZE :: 1024*1024

// -------------------------------- Types --------------------------------

// ---------------- Package ----------------

@(private)
Parsed_Source :: struct {
	file: ast.File,
	imports: map[^ast.Import_Decl]string,
	selected, has_role: bool,
	role: Role,
	role_path: string,
}

@(private)
Role :: enum {Catalog, Effects, Engine, Functions, Procedures, State, Views, UI, Application, Migrations}

// -------------------------------- Procedures --------------------------------

// ---------------- Public ----------------

// All paths are absolute and lexically normalized by the caller. No filesystem
// access occurs here. Allocations, including ASTs and diagnostics, belong to the
// caller's allocator; use an arena for the complete analysis lifetime.
// Odin checks must already have passed. Parsing supports policy analysis only;
// unsupported input/configuration returns a failure separately from lint findings.
// Convenience for a complete single-file package; supply all sibling sources
// to check_package when analyzing a multi-file package.
check_source :: proc(source, path, root: string, collections: map[string]string, source_root := "") -> ([dynamic]state.Diagnostic, string) {
	return check_package({{path = path, text = source, selected = true}}, root, collections, source_root)
}

// Read only reachable top-level imports using the same recovery and metadata
// decoding as policy analysis. Unknown build conditions retain both branches.
source_imports :: proc(text, path: string) -> ([]string, string) {
	parsed, failure := parse_source(state.Source{path = path, text = text})
	if failure != "" {return nil, failure}
	collector := Import_Collector{imports = parsed.imports}
	visitor := ast.Visitor{visit = visit_imports, data = &collector}
	for declaration in parsed.file.decls {ast.walk(&visitor, declaration)}
	return collector.paths[:], ""
}

// Supply complete packages and any project consumers as analysis-only sources.
// Only selected files receive diagnostics. Public exports remain API boundaries;
// package-private checks require supplied siblings. complete_project is retained
// for source compatibility and no longer permits export narrowing.
// One arena owns the entire project graph and its ASTs.
check_package :: proc(sources: []state.Source, root: string, collections: map[string]string, source_root := "", complete_project := false, import_aliases: map[string]string = nil) -> (diagnostics: [dynamic]state.Diagnostic, failure: string) {
	_ = complete_project
	diagnostics = make([dynamic]state.Diagnostic)
	source_root := source_root
	if source_root == "" {
		source_root, _ = filepath.join({root, "src"})
	} else if !filepath.is_abs(source_root) {
		source_root, _ = filepath.join({root, source_root})
	}
	files := make([]Parsed_Source, len(sources))
	for source, i in sources {
		parsed := &files[i]
		value, parse_failure := parse_source(source)
		if parse_failure != "" {return nil, parse_failure}
		parsed^ = value
		parsed.role, parsed.has_role = source_role(source.path, source_root)
		parsed.role_path, _ = filepath.rel(source_root, source.path)
		parsed.role_path, _ = strings.replace_all(parsed.role_path, "\\", "/")
	}
	r := References{files = files, collections = collections, import_aliases = import_aliases, packages = make(map[string]int), node_scopes = make(map[^ast.Node]int), declaration_symbols = make(map[^ast.Value_Decl][dynamic]int), groups = make(map[^ast.Value_Decl]string), owner = -1, foreign_visibility = -1, by_literal = make(map[^ast.Proc_Lit]int), type_scopes = make(map[^ast.Expr]int), contexts = make(map[^ast.Expr]Literal_Context), file_scopes = make([]int, len(files)), caller = -1, default_scope = -1}
	r.file_availability = make([]Availability, len(files))
	packages := make(map[string]int)
	for &file, i in files {
		// A directory can contain distinct package names in compiler-selected files.
		key := fmt.aprintf("%s:%s", filepath.dir(file.file.fullpath), file.file.pkg_name)
		package_scope, exists := packages[key]
		if !exists {
			package_scope = new_scope(&r, -1, -1)
			packages[key] = package_scope
		}
		directory := filepath.dir(file.file.fullpath)
		previous, registered := r.packages[directory]
		r.packages[directory] = package_scope if !registered || previous == package_scope else -1
		r.file_scopes[i] = new_scope(&r, package_scope, i)
	}
	reference_visitor := ast.Visitor{visit = visit_references, data = &r}
	for &file, i in files {
		r.scope, r.file, r.caller, r.top_level = r.file_scopes[i], i, -1, true
		available := availability_all()
		tags := parser.parse_file_tags(file.file)
		if tags.ignore {available = {supplied = true}}
		if len(tags.build) > 0 {
			line := Availability{supplied = true}
			for kind in tags.build {
				if kind == parser.BUILD_KIND_NEWLINE_MARKER {
					available = availability_and(available, line)
					line = {supplied = true}
				} else {line = availability_or(line, Availability{clauses = slice.clone([]Availability_Clause{{os = kind.os, arch = kind.arch}}), supplied = true})}
			}
			available = availability_and(available, line)
		}
		if len(tags.build_project_name) > 0 {
			projects := Availability{supplied = true}
			for names in tags.build_project_name {
				tests: [dynamic]Availability_Test
				for name in names {
					negative := strings.has_prefix(name, "!")
					append(&tests, Availability_Test{atom = strings.concatenate({"project:", name[1:] if negative else name}), value = !negative})
				}
				projects = availability_or(projects, Availability{clauses = slice.clone([]Availability_Clause{{runtime.ALL_ODIN_OS_TYPES, runtime.ALL_ODIN_ARCH_TYPES, tests[:]}}), supplied = true})
			}
			available = availability_and(available, projects)
		}
		r.availability, r.file_availability[i] = available, available
		for statement in file.file.decls {
			ast.walk(&reference_visitor, statement)
		}
	}
	// Literal inactive branches create no bindings. Check only imports that can
	// participate in the graph, so an inactive import cannot hide unrelated APIs.
	for symbol in r.symbols {
		path := symbol.import_path
		if path == "" {continue}
		parts := strings.split_n(path, ":", 2)
		if len(parts) == 2 {
			if slice.contains([]string{"core", "base", "vendor"}, parts[0]) {continue}
			if _, supplied := collections[parts[0]]; !supplied {
				return nil, fmt.aprintf("unknown collection %s; supply --collection NAME=DIR for project analysis", parts[0])
			}
		}
	}
	// Expand known using providers into their actual member names. Unresolved
	// providers affect only lookups that pass through that lexical scope.
	for provider in r.providers {
		type := reference_type(&r, provider.expr, provider.scope, provider.is_type, 0)
		if !promote_members(&r, type, provider.scope, provider.visible_from, provider.conditional, 0, provider.expr if !provider.is_type else nil) {
			append(&r.scopes[provider.scope].unknown_using_from, provider.visible_from)
		}
	}
	for use in r.uses {
		if use.kind == .Write {
			if name, ok := binding_name(use.expr); ok {
				ids, _ := lookup(&r, name, use.scope, use.pos.offset)
				for id in ids {
					r.symbols[id].written = true
				}
			}
		}
	}
	// Procedure aliases cannot export a private procedure, but their bindings
	// remain visible to siblings. Value/type aliases keep their declared visibility.
	for _ in r.symbols {
		changed := false
		for &symbol in r.symbols {
			if !symbol.alias || symbol.mutable || symbol.value == nil || expression_kind(&r, symbol.value, symbol.scope, 0) != "Procedures" {continue}
			ids, certain := expression_symbols(&r, symbol.value, symbol.scope, symbol.value.pos.offset)
			if certain && len(ids) == 1 && min(r.symbols[ids[0]].visibility, 1) > symbol.visibility {
				symbol.visibility = min(r.symbols[ids[0]].visibility, 1)
				changed = true
			}
		}
		if !changed {break}
	}
	role_names, role_dependencies := ROLE_NAMES, ROLE_DEPENDENCIES
	for &parsed, file_index in files {
		if !parsed.selected {
			continue
		}
		file := &parsed.file
		from, has_role := parsed.role, parsed.has_role
		local_policies: {
			output := &diagnostics
			visibility := int(parser.parse_file_tags(file^).private)
			check := Local_Check{
				diagnostics = output, callbacks = make(map[^ast.Proc_Lit]bool),
				default_visibility = visibility, role = from, has_role = has_role,
			}
			visitor := ast.Visitor{visit = visit_local, data = &check}
			last_import := -1
			seen_declaration := false
			for statement in file.decls {
				is_import := false
				#partial switch decl in statement.derived {
				case ^ast.Import_Decl:
					is_import = true
					rank := import_rank(parsed.imports[decl])
					if !seen_declaration && rank < last_import {
						append(output, state.Diagnostic{decl.pos, "IMPORT001", "group imports in Vendor, Odin, Project order"})
					}
					last_import = max(last_import, rank)
				case ^ast.Foreign_Import_Decl:
					is_import = true
				case ^ast.Value_Decl, ^ast.Foreign_Block_Decl, ^ast.When_Stmt:
					seen_declaration = true
				}
				if is_import && seen_declaration {
					append(output, state.Diagnostic{statement.pos, "IMPORT001", "place imports before declarations"})
				}
				ast.walk(&visitor, statement)
			}
			section_policies: {
				// Accept kind-first and visibility-first layouts. Only file-scope
				// line comments introduce headers, never strings or nested comments.
				headers: [dynamic]Section
				for group in file.comments {
					for comment in group.list {
						if comment.pos.column != 1 || !strings.has_prefix(comment.text, "// ") {
							continue
						}
						nested := false
						for statement in file.decls {
							if comment.pos.offset >= statement.pos.offset && comment.pos.offset < statement.end.offset {
								nested = true
								break
							}
						}
						body := strings.trim_space(comment.text[3:])
						left := len(body) - len(strings.trim_left(body, "-"))
						right := len(body) - len(strings.trim_right(body, "-"))
						if nested || left == 0 || right == 0 || left+right+2 >= len(body) ||
						   body[left] != ' ' || body[len(body)-right-1] != ' ' {
							continue
						}
						section_name := body[left+1:len(body)-right-1]
						if strings.trim_space(section_name) != section_name {
							continue
						}
						if left != right || left & (left-1) != 0 {
							append(output, state.Diagnostic{comment.pos, "SECTION001", "section sides must have matching power-of-two dash counts"})
						}
						append(&headers, Section{pos = comment.pos, name = section_name, level = left, parent = -1})
					}
				}
				slice.sort_by(headers[:], proc(a, b: Section) -> bool {return a.pos.offset < b.pos.offset})
				kind_first := true
				if len(headers) > 0 {
					kind_first = !slice.contains(SECTION_VISIBILITIES, headers[0].name)
				}
				last_rank := make(map[int]int)
				seen := make(map[struct {parent: int, name: string}]bool)
				for &header, i in headers {
					header.parent = i-1
					for header.parent >= 0 && headers[header.parent].level <= header.level {
						header.parent = headers[header.parent].parent
					}
					if header.level > 32 || header.level < 1 || header.level == 32 && header.parent >= 0 ||
					   header.level < 32 && (header.parent < 0 || headers[header.parent].level != header.level*2) {
						append(output, state.Diagnostic{header.pos, "SECTION001", "start with a 32-dash major section and descend one power-of-two level at a time"})
					}
					key := struct {parent: int, name: string}{header.parent, header.name}
					if seen[key] {
						append(output, state.Diagnostic{header.pos, "SECTION002", "section is duplicated under the same parent"})
					}
					seen[key] = true
					names := SECTION_KINDS
					if header.level == 32 && !kind_first || header.level == 16 && kind_first {
						names = SECTION_VISIBILITIES
					}
					if header.parent >= 0 && headers[header.parent].name == "Imports" {
						names = SECTION_IMPORTS
					}
					if header.level == 32 || header.level == 16 {
						rank, _ := slice.linear_search(names, header.name)
						previous, has_previous := last_rank[header.parent]
						if rank < 0 || has_previous && rank < previous {
							append(output, state.Diagnostic{header.pos, "SECTION002", "section name or order does not match the detected layout"})
						}
						last_rank[header.parent] = max(rank, previous) if has_previous else rank
					}
				}
				header_cursor := 0
				collector := Section_Collector{visibility = visibility}
				section_visitor := ast.Visitor{data = &collector, visit = visit_section_items}
				for statement in file.decls {ast.walk(&section_visitor, statement)}
				for item in collector.items {
					statement := item.statement
					// The most recent header owns this declaration. Its parent chain
					// supplies the enclosing sections without storing overlapping ranges.
					for header_cursor < len(headers) && headers[header_cursor].pos.offset < statement.pos.offset {
						header_cursor += 1
					}
					major, minor := "", ""
					for index := header_cursor-1; index >= 0; index = headers[index].parent {
						header := &headers[index]
						header.items += 1
						if header.level == 32 {
							major = header.name
						} else if header.level == 16 {
							minor = header.name
						}
					}
					if imported, ok := statement.derived.(^ast.Import_Decl); ok {
						names := SECTION_IMPORTS
						if kind_first && (major != "Imports" || minor != names[import_rank(parsed.imports[imported])]) || !kind_first && major != "" {
							append(output, state.Diagnostic{statement.pos, "SECTION003", "place import in its Vendor/Odin/Project group before declarations"})
						}
					}
					if _, ok := statement.derived.(^ast.Foreign_Import_Decl); ok {
						_, grouped := slice.linear_search(SECTION_IMPORTS, minor)
						if kind_first && (major != "Imports" || !grouped) || !kind_first && major != "" {
							append(output, state.Diagnostic{statement.pos, "SECTION003", "place foreign import in an import group before declarations"})
						}
					}
					decl, ok := statement.derived.(^ast.Value_Decl)
					if !ok {
						continue
					}
					scope := r.file_scopes[file_index]
					if ids := r.declaration_symbols[decl]; len(ids) > 0 {scope = r.symbols[ids[0]].scope}
					kind := ""
					if decl.is_mutable {kind = "Globals"} else {
						for value in decl.values {
							candidate := expression_kind(&r, value, scope, 1)
							ids := r.declaration_symbols[decl]
							if candidate == "" && used_as_type(&r, ids[:]) {candidate = "Types"}
							if candidate == "" || kind != "" && candidate != kind {kind = ""; break}
							kind = candidate
						}
					}
					r.groups[decl] = fmt.aprintf("%s/%s", major, minor)
					names := SECTION_VISIBILITIES
					effective := item.visibility
					if resolved, homogeneous := declaration_group(&r, decl); homogeneous {effective = resolved} else if len(r.declaration_symbols[decl]) > 0 {
						append(output, state.Diagnostic{statement.pos, "SECTION003", "split declarations whose bindings have different effective visibilities"})
					}
					expected_major, expected_minor := kind, names[effective]
					if !kind_first {
						expected_major, expected_minor = expected_minor, expected_major
					}
					if major == "" || minor == "" || expected_major != "" && major != expected_major || expected_minor != "" && minor != expected_minor {
						append(output, state.Diagnostic{statement.pos, "SECTION003", "place declaration under its kind and effective visibility sections"})
					}
				}
				for header in headers {
					if header.items == 0 {
						append(output, state.Diagnostic{header.pos, "SECTION004", "remove empty section"})
					}
				}
			}
		}
		if !has_role {
			continue
		}
		for decl in file.imports {
			import_path := parsed.imports[decl]
			parts := strings.split_n(import_path, ":", 2)
			if len(parts) == 2 {
				collection := parts[0]
				if _, known := collections[collection]; !known {
					if collection != "core" && collection != "base" && collection != "vendor" {
						return nil, fmt.aprintf("unknown collection %s; supply --collection NAME=DIR for role analysis", collection)
					}
					continue
				}
			}
			_, target, _ := import_scope(&r, file_index, import_path)
			to, target_has_role := source_role(target, source_root)
			if !target_has_role {
				rel, err := filepath.rel(source_root, target)
				rel, _ = strings.replace_all(rel, "\\", "/")
				if err == .None && rel != ".." && !strings.has_prefix(rel, "../") {
					append(&diagnostics, state.Diagnostic{
						decl.relpath.pos, "ARCH001",
						fmt.aprintf("%s must not depend on unassigned source path %s", role_names[from], rel),
					})
				}
			}
			if target_has_role && to != from && !(to in role_dependencies[from]) {
				append(&diagnostics, state.Diagnostic{
					decl.relpath.pos, "ARCH001",
					fmt.aprintf("%s must not depend on %s; move the dependency to an allowed source role", role_names[from], role_names[to]),
				})
			}
		}
	}
	// Alias definitions are edges, not extra runtime uses. Procedure aliases
	// cannot export private targets; public mutable aliases can escape.
	for symbol, id in r.symbols {
		if symbol.alias && (symbol.written || symbol.mutable && symbol.top_level && symbol.visibility == 0) {
			resolved := resolve_symbol(&r, id)
			for target in resolved.targets {
				r.procedures[target].escaped = true
			}
		}
	}
	for use in r.uses {
		if use.kind == .Write || use.kind == .Alias {
			continue
		}
		if use.member != "" {
			continue
		}
		unknown_key := false
		if use.literal != nil {
			type := reference_type(&r, &use.literal.node, use.scope, false, 0)
			if type != nil {
				if _, is_map := type.derived.(^ast.Map_Type); !is_map {continue}
			} else {
				unknown_key = true
			}
		}
		resolved := resolve_expr(&r, use.expr, use.scope, use.pos.offset)
		resolved.certain = resolved.certain && !unknown_key
		// Ambiguity limits positive advice; it is not a source-code violation.
		for target in resolved.targets {
			// All configuration targets contribute effects, but the existing
			// inlining criterion still requires one concrete target at this use.
			if use.kind == .Call && resolved.certain && len(resolved.targets) == 1 {
				r.procedures[target].calls += 1
				append(&r.edges, Call_Edge{use.caller, target, use.pos})
			} else {
				r.procedures[target].escaped = true
			}
		}
	}
	for &procedure, i in r.procedures {
		pending := make([dynamic]int)
		seen := make(map[int]bool)
		append(&pending, i)
		for len(pending) > 0 && !procedure.cyclic {
			caller := pop(&pending)
			if seen[caller] {continue}
			seen[caller] = true
			for edge in r.edges {
				if edge.caller != caller {continue}
				if edge.callee == i {procedure.cyclic = true; break}
				append(&pending, edge.callee)
			}
		}
		if procedure.candidate && files[procedure.file].selected && procedure.calls == 1 && !procedure.escaped && !procedure.cyclic {
			append(&diagnostics, state.Diagnostic{procedure.decl.pos, "SIMPLIFY001", fmt.aprintf("inline %s: one call within the package", procedure.name)})
		}
	}
	declaration_policies: {
		// Alias edges participate in visibility and ordering even though they are not
		// extra runtime calls for SIMPLIFY001. No-use declarations belong to Odin.
		visibility_names := SECTION_VISIBILITIES
		required := make([]int, len(r.symbols))
		used := make([]bool, len(r.symbols))
		uncertain := make([]bool, len(r.symbols))
		for &visibility in required {visibility = 2}
		edges: [dynamic]struct {caller, target: int, pos: tokenizer.Pos}
		potential_edges: [dynamic][2]int
		for use in r.uses {
			unknown_key := false
			if use.literal != nil {
				type := reference_type(&r, &use.literal.node, use.scope, false, 0)
				if type == nil {unknown_key = true} else if _, map_key := type.derived.(^ast.Map_Type); !map_key {continue}
			}
			expr := use.qualified if use.qualified != nil else use.expr
			ids, certain := expression_symbols(&r, expr, use.scope, use.pos.offset)
			certain = certain && !unknown_key
			pending := make([dynamic]int)
			append(&pending, ..ids[:])
			seen := make(map[int]bool)
			for len(pending) > 0 {
				id := pop(&pending)
				if seen[id] {continue}
				seen[id] = true
				symbol := r.symbols[id]
				if symbol.top_level && symbol.decl != nil {
					used[id] = true
					uncertain[id] = uncertain[id] || !certain
					if symbol.file != use.file {
						same_package := r.scopes[r.file_scopes[symbol.file]].parent == r.scopes[r.file_scopes[use.file]].parent
						required[id] = min(required[id], 1 if same_package else 0)
					}
					if use.owner >= 0 && use.owner != id {
						append(&potential_edges, {use.owner, id})
						if certain {append(&edges, {use.owner, id, use.pos})}
					}
				}
				if symbol.alias && !symbol.written && symbol.value != nil {
					targets, known := expression_symbols(&r, symbol.value, symbol.scope, symbol.value.pos.offset)
					certain = certain && known
					append(&pending, ..targets[:])
				}
			}
		}
		for symbol, id in r.symbols {
			if !symbol.top_level || symbol.decl == nil || !r.files[symbol.file].selected || symbol.conditional {continue}
			if used[id] && !uncertain[id] && required[id] > symbol.visibility &&
			   symbol.visibility > 0 && !required_declaration(symbol.decl, symbol.name) {
				append(&diagnostics, state.Diagnostic{symbol.pos, "VIS002", fmt.aprintf("narrow %s to %s visibility: all project references permit it", symbol.name, visibility_names[required[id]])})
			}
		}
		ordered := make(map[[2]int]bool)
		for edge in edges {
			key := [2]int{edge.caller, edge.target}
			if ordered[key] {continue}
			ordered[key] = true
			caller, target := r.symbols[edge.caller], r.symbols[edge.target]
			if caller.decl == nil || target.decl == nil || caller.file != target.file || !r.files[caller.file].selected ||
			   target.pos.offset >= caller.pos.offset || r.groups[caller.decl] != r.groups[target.decl] {continue}
			// Cycles have no topological reading order. Suppress only their own edges.
			pending := make([dynamic]int)
			append(&pending, edge.target)
			seen := make(map[int]bool)
			cyclic := false
			for len(pending) > 0 && !cyclic {
				id := pop(&pending)
				if seen[id] {continue}
				seen[id] = true
				for next in edges {
					if next.caller != id {continue}
					if next.target == edge.caller {cyclic = true; break}
					append(&pending, next.target)
				}
			}
			if !cyclic {append(&diagnostics, state.Diagnostic{edge.pos, "FLOW001", fmt.aprintf("place declaration %s before dependency %s within its section", caller.name, target.name)})}
		}
		anchored := make(map[int]bool)
		for symbol, id in r.symbols {
			if symbol.decl != nil && (required_declaration(symbol.decl, symbol.name) || required[id] < 2 || symbol.visibility == 0) {anchored[id] = true}
		}
		for {
			changed := false
			for edge in potential_edges {if anchored[edge[0]] && !anchored[edge[1]] {anchored[edge[1]] = true; changed = true}}
			if !changed {break}
		}
		// Package structure is checked once, with diagnostics owned by a selected file.
		checked := make(map[int]bool)
		for file, file_index in r.files {
			if !file.selected {continue}
			folder := filepath.base(filepath.dir(file.file.fullpath))
			package_scope := r.scopes[r.file_scopes[file_index]].parent
			if file.file.pkg_name != folder && file.file.pkg_name != "main" {
				// The compiler uses package names as ABI namespaces. A directory-
				// matching name can collide anywhere in the reachable import graph.
				namespace_conflict := false
				pending := make([dynamic]int)
				seen := make(map[int]bool)
				append(&pending, package_scope)
				for len(pending) > 0 && !namespace_conflict {
					current := pop(&pending)
					if seen[current] {continue}
					seen[current] = true
					for symbol in r.symbols {
						if symbol.import_path == "" || r.scopes[r.file_scopes[symbol.file]].parent != current {continue}
						imported, _, loaded := import_scope(&r, symbol.file, symbol.import_path)
						if loaded {
							for other, index in r.files {if r.scopes[r.file_scopes[index]].parent == imported && other.file.pkg_name == folder {namespace_conflict = true; break}}
							append(&pending, imported)
						} else {
							parts := strings.split_n(symbol.import_path, ":", 2)
							namespace_conflict = filepath.base(parts[len(parts)-1]) == folder
						}
						if namespace_conflict {break}
					}
				}
				if !namespace_conflict {append(&diagnostics, state.Diagnostic{file.file.pkg_token.pos, "FILE002", fmt.aprintf("package name must match directory %s", folder)})}
			}
			if !checked[package_scope] {
				checked[package_scope] = true
				interfaces, fragments := 0, 0
				for other, i in r.files {
					if r.scopes[r.file_scopes[i]].parent != package_scope {continue}
					switch interface_kind(other, folder) {
					case .Canonical: interfaces += 1
					case .Fragment: fragments += 1
					case .Helper:
					}
				}
				if interfaces > 1 || interfaces == 0 && fragments == 0 {append(&diagnostics, state.Diagnostic{file.file.pkg_token.pos, "FILE003", "package requires one conventional interface or a build-conditioned interface family; preserve compile conditions and private dependency closure"})}
			}
			interface := interface_kind(file, folder) != .Helper
			visibility := int(parser.parse_file_tags(file.file).private)
			counts: [3]int
			public_exports := false
			counted := make(map[^ast.Value_Decl]bool)
			for symbol, symbol_id in r.symbols {
				if symbol.file != file_index || !symbol.top_level || symbol.decl == nil {continue}
				public_exports = public_exports || symbol.visibility == 0
				if symbol.conditional {continue}
				if !counted[symbol.decl] {
					if group, homogeneous := declaration_group(&r, symbol.decl); homogeneous {counts[group] += 1}
					counted[symbol.decl] = true
				}
				if !interface && symbol.visibility == 0 {
					append(&diagnostics, state.Diagnostic{symbol.pos, "FILE004", "make internal declarations private when their consumers permit it, or move exports with their private dependency closure to a configuration-preserving interface; preserve test-only and platform conditions"})
				}
				if interface && symbol.visibility > 0 && used[symbol_id] && required[symbol_id] == 2 && !anchored[symbol_id] && !uncertain[symbol_id] && !required_declaration(symbol.decl, symbol.name) {
					append(&diagnostics, state.Diagnostic{symbol.pos, "FILE005", "move this implementation and its file-private dependencies together into a helper file"})
				}
			}
			expected := 0 if interface else 2
			total := counts[0]+counts[1]+counts[2]
			majority := false
			for count, candidate in counts {
				if total > 0 && count*100 >= total*FILE_DEFAULT_CHANGE_PERCENT {expected, majority = candidate, true}
			}
			if interface && expected == 2 && public_exports {
				// A File-private dependency cannot leave its retained public caller
				// or be widened. If their minimum visibility-preserving group still
				// has a File majority, no reorganization can realize that default.
				// Package-private gates may relocate with their support. Public
				// exports stay anchored regardless of locally saved consumers.
				closure := make(map[int]bool)
				public_declarations := make(map[^ast.Value_Decl]bool)
				for symbol, id in r.symbols {
					if symbol.file != file_index || !symbol.top_level || symbol.decl == nil || symbol.visibility != 0 {continue}
					closure[id], public_declarations[symbol.decl] = true, true
				}
				for {
					changed := false
					for edge in potential_edges {
						if !closure[edge[0]] || closure[edge[1]] {continue}
						target := r.symbols[edge[1]]
						if target.file == file_index && target.visibility == 2 {closure[edge[1]], changed = true, true}
					}
					if !changed {break}
				}
				private_declarations := make(map[^ast.Value_Decl]bool)
				for symbol, id in r.symbols {
					if symbol.file != file_index || !closure[id] || symbol.visibility != 2 || symbol.decl == nil || symbol.conditional {continue}
					if group, homogeneous := declaration_group(&r, symbol.decl); homogeneous && group == 2 {private_declarations[symbol.decl] = true}
				}
				minimum := len(private_declarations)+len(public_declarations)
				// All possible public declarations remain in the denominator;
				// conditional private support cannot establish the lower bound.
				if len(public_declarations) > 0 && len(private_declarations)*100 >= minimum*FILE_DEFAULT_CHANGE_PERCENT {expected, majority = 0, false}
			}
			if visibility != expected {
				rule := "FILE006" if majority else "FILE001"
				message := fmt.aprintf("use %s default visibility", visibility_names[expected])
				if expected > 0 && public_exports {
					// Odin has no public attribute to undo a private file default.
					// The majority remains policy evidence, never permission to hide
					// minority exports or widen their private supporting declarations.
					message = fmt.aprintf("reorganize visibility groups before selecting %s default visibility; preserve public exports in a Public-default interface and preserve private dependency closure; changing only the directive would remove exports", visibility_names[expected])
				} else {
					for symbol in r.symbols {
						if symbol.file != file_index || !symbol.top_level || symbol.decl == nil {continue}
						after, _ := declaration_visibility(symbol.decl, expected)
						if after != symbol.visibility {
							message = fmt.aprintf("use %s default visibility after preserving other declarations' visibility with explicit private attributes", visibility_names[expected])
							break
						}
					}
				}
				if majority {message = fmt.aprintf("%s: %d/%d declarations meet the %d%% threshold", message, counts[expected], total, FILE_DEFAULT_CHANGE_PERCENT)}
				append(&diagnostics, state.Diagnostic{file.file.pkg_token.pos, rule, message})
			}
		}
	}
	ownership_policies: {
		r.authorities = make(map[^ast.Expr]bool)
		r.relation_containers = make(map[^ast.Expr]bool)
		r.relational_types = make(map[Type_Scope]bool)
		r.local_types = make(map[Type_Scope]bool)
		for symbol in r.symbols {
			file := r.files[symbol.file]
			if symbol.top_level && file.has_role && file.role == .Engine && expression_kind(&r, symbol.value, symbol.scope, 0) == "Types" {
				mark_authority(&r, symbol.value, symbol.scope)
			}
		}
		model := Semantics{r = &r, facts = make([]Procedure_Facts, len(r.procedures))}
		r.semantics = &model
		model.pending = make([]bool, len(r.procedures))
		model.dependents = make([]map[int]bool, len(r.procedures))
		for &dependents in model.dependents {dependents = make(map[int]bool)}
		for procedure, id in r.procedures {
			scope := r.node_scopes[&procedure.literal.type.node]
			for fields, is_result in ([2]^ast.Field_List{procedure.literal.type.params, procedure.literal.type.results}) {
				if fields == nil {continue}
				for field in fields.list {
					if is_result == 1 && len(field.names) == 0 {
						append(&model.facts[id].result_types, field.type)
						append(&model.facts[id].result_bindings, -1)
					}
					for name in field.names {
						if identifier, named := binding_name(name); named {
							ids, certain := lookup(&r, identifier, scope, max(int))
							if certain && len(ids) == 1 {
								if is_result == 1 {
									append(&model.facts[id].result_types, field.type)
									append(&model.facts[id].result_bindings, ids[0])
								} else {append(&model.facts[id].parameters, ids[0])}
							} else if is_result == 1 {
								// The parser represents unnamed tuple results with blank
								// identifiers, which deliberately have no lexical binding.
								append(&model.facts[id].result_types, field.type)
								append(&model.facts[id].result_bindings, -1)
								} else {append(&model.facts[id].parameters, -1)}
						}
					}
				}
			}
			resize(&model.facts[id].results, len(model.facts[id].result_types))
			// Definite nil is a meet over actual return paths, not a capability
			// granted to an unknown value or a procedure without a saved body.
			if procedure.literal.body != nil {for &result in model.facts[id].results {result.nil_value = true}}
		}
		// Inference owns transient bindings separately from its retained summaries.
		// Heap-backed arenas must really release discarded passes, even when the
		// caller itself supplied an arena that does not free individual blocks.
		caller_allocator := context.allocator
		heap := runtime.heap_allocator()
		summaries: [2]mem.Dynamic_Arena
		for &arena in summaries {mem.dynamic_arena_init(&arena, block_allocator = heap, array_allocator = heap, block_size = INFERENCE_BLOCK_SIZE, out_band_size = INFERENCE_BLOCK_SIZE/8)}
		defer {for &arena in summaries {mem.dynamic_arena_destroy(&arena)}}
		generation := 0
		for phase in 0..<2 {
			model.contracts = phase == 1
			for &pending in model.pending {pending = true}
			for {
				model.changed = false
				transient: mem.Dynamic_Arena
				mem.dynamic_arena_init(&transient, block_allocator = heap, array_allocator = heap, block_size = INFERENCE_BLOCK_SIZE, out_band_size = INFERENCE_BLOCK_SIZE/8)
				{
					context.allocator = mem.dynamic_arena_allocator(&transient)
					model.facts = slice.clone(model.facts)
					analyze_semantics(&model, &diagnostics, true)
				}
				context.allocator = caller_allocator
				generation = 1-generation
				mem.dynamic_arena_free_all(&summaries[generation])
				{
					context.allocator = mem.dynamic_arena_allocator(&summaries[generation])
					model.facts = clone_semantic_facts(model.facts)
				}
				context.allocator = caller_allocator
				mem.dynamic_arena_destroy(&transient)
				if !model.changed {break}
			}
			if phase == 0 {
				for &facts, procedure_id in model.facts {
					file := r.files[r.procedures[procedure_id].file]
					if !file.has_role || file.role != .Engine {continue}
					// Match fresh/zero stores once, instead of scanning every store for
					// every access. Destructive writes remain independent effects.
					fresh := make(map[Access_Origin]bool)
					for parameter in facts.copies {fresh[Access_Origin{parameter = parameter}] = true}
					for stored in facts.stores {
						if stored.conditional || strings.contains(stored.destination.path, "[]") {continue}
						if !stored.value.immutable && (len(stored.value.origins) > 0 || stored.value.protected) {continue}
						if stored.initializes || stored.value.nil_value || stored.value.immutable {fresh[stored.destination] = true}
					}
					eligible := make(map[int]bool)
					for access in facts.accesses {
						if access.kind != .Write && access.kind != .Destroy {continue}
						valid, seen := eligible[access.origin.parameter]
						if !seen {valid = true}
						eligible[access.origin.parameter] = valid && (fresh[access.origin] || access.kind == .Destroy && fresh[Access_Origin{parameter = access.origin.parameter}])
					}
					for parameter in facts.parameters {if eligible[parameter] {append(&facts.lifecycle, parameter)}}
				}
				// Protocol identity is owner type plus counter field, independent of
				// which wrappers happen to remain after simplification.
				directions := make(map[struct {owner_type: ^ast.Expr, path: string}]int)
				for facts, id in model.facts {
					file := r.files[r.procedures[id].file]
					if !file.has_role || file.role != .Engine {continue}
					for change in facts.counters {
						if change.origin.parameter < 0 {continue}
						symbol := r.symbols[change.origin.parameter]
						owner := access_type(&r, symbol.type, symbol.scope, 0)
						if owner.type == nil {continue}
						key := struct {owner_type: ^ast.Expr, path: string}{owner.type, change.origin.path}
						directions[key] |= 1 if change.delta == 1 else 2
					}
				}
				for channel, signs in directions {
					if signs == 3 {append(&model.transactions, Transaction_Fact{owner_type = channel.owner_type, counter_path = strings.clone(channel.path)})}
				}
				for facts, id in model.facts {
					file := r.files[r.procedures[id].file]
					if !file.has_role || file.role != .Engine {continue}
					for change in facts.counters {
						if change.delta != 1 || change.origin.parameter < 0 || slice.contains(facts.counters[:], Counter_Change{change.origin, -1}) {continue}
						symbol := r.symbols[change.origin.parameter]
						owner := access_type(&r, symbol.type, symbol.scope, 0)
						for &transaction in model.transactions {
							if transaction.owner_type != owner.type || transaction.counter_path != change.origin.path {continue}
							for snapshot in facts.snapshots {
								if snapshot.parameter == change.origin.parameter && !slice.contains(transaction.working[:], snapshot.path) {append(&transaction.working, strings.clone(snapshot.path))}
							}
						}
					}
				}
				// Phase zero discovers lifecycle/counter metadata before scoped
				// permissions exist. Rebuild access requirements in phase one so
				// provisional unscoped writes cannot survive as stale requirements.
				for &facts in model.facts {
					// Callback identity does not depend on scope permission. Keep
					// complete invocation facts so the first contract pass executes
					// callback counter changes before deriving scope requirements.
					retained := 0
					for access in facts.accesses {
						if access.kind != .Invoke {continue}
						facts.accesses[retained] = access
						retained += 1
					}
					resize(&facts.accesses, retained)
				}
			}
		}
		transient: mem.Dynamic_Arena
		mem.dynamic_arena_init(&transient, block_allocator = heap, array_allocator = heap, block_size = INFERENCE_BLOCK_SIZE, out_band_size = INFERENCE_BLOCK_SIZE/8)
		{
			context.allocator = mem.dynamic_arena_allocator(&transient)
			analyze_semantics(&model, &diagnostics, false)
			// Complete effects and capability requirements already include actual
			// callees and callbacks; no syntactic call-graph approximation is needed.
			for procedure, id in r.procedures {
				file := r.files[procedure.file]
				if !file.selected || !file.has_role || file.role != .Catalog || !procedure.top_level || procedure.decl == nil || procedure.decl.is_mutable || procedure.literal.body == nil || has_attribute(procedure.decl, "test") {continue}
				facts := model.facts[id]
				pure := facts.effects - {.Unknown} == {} && len(facts.stores) == 0
				// Unresolved callbacks do not establish impurity. Resolved callback effects still contribute above.
				for access in facts.accesses {if access.kind != .Invoke {pure = false; break}}
				if !pure {append(&diagnostics, state.Diagnostic{procedure.literal.pos, "ARCH004", "catalog procedures must not perform known external effects, input mutation or publication; move this operation to an allowed source role"})}
			}
		}
		context.allocator = caller_allocator
		// The dynamic header and messages may have been allocated by that final
		// walk. Return diagnostics in the caller's allocator before releasing it.
		diagnostics = slice.clone_to_dynamic(diagnostics[:])
		for &diagnostic in diagnostics {
			diagnostic.message = strings.clone(diagnostic.message)
			diagnostic.rule = strings.clone(diagnostic.rule)
			diagnostic.pos.file = strings.clone(diagnostic.pos.file)
		}
		mem.dynamic_arena_destroy(&transient)
	}
	// Local and package-wide phases share a deterministic diagnostic order.
	slice.sort_by(diagnostics[:], proc(a, b: state.Diagnostic) -> bool {
		if a.pos.file != b.pos.file {return a.pos.file < b.pos.file}
		if a.pos.offset != b.pos.offset {return a.pos.offset < b.pos.offset}
		if a.rule != b.rule {return a.rule < b.rule}
		return a.message < b.message
	})
	// Summary paths may reach the same use more than once. Keep one identical
	// finding while preserving distinct positions and distinct policy evidence.
	write := 0
	for diagnostic in diagnostics {
		if write > 0 {
			previous := diagnostics[write-1]
			if previous.pos == diagnostic.pos && previous.rule == diagnostic.rule && previous.message == diagnostic.message {continue}
		}
		diagnostics[write] = diagnostic
		write += 1
	}
	resize(&diagnostics, write)
	return
}

// Decode import/visibility metadata, not arbitrary constant expressions.
// Ordinary and triple delimiters share escape processing. Their indentation
// and escape rules follow Odin dev-2026-10 src/string.cpp.
metadata_string :: proc(literal: string) -> (string, bool) {
	text, _ := strings.replace_all(literal, "\r", "")
	if len(text) < 2 || (text[0] != '"' && text[0] != '`') {
		return "", false
	}
	quote := text[0]
	delimiter_width := 1
	if len(text) >= 3 && text[1] == quote && text[2] == quote {
		delimiter_width = 3
	}
	if len(text) < delimiter_width*2 || !strings.has_suffix(text, text[:delimiter_width]) {
		return "", false
	}
	body := text[delimiter_width:len(text)-delimiter_width]
	first := strings.index_byte(body, '\n')
	if first >= 0 && delimiter_width == 1 && quote == '"' {
		return "", false
	}
	if first >= 0 && delimiter_width == 3 {
		last := strings.last_index_byte(body, '\n')
		indent := body[last+1:]
		if strings.trim(body[:first], " \t") != "" || strings.trim(indent, " \t") != "" {
			return "", false
		}
		// At least one content line is required for multiline metadata.
		if first == last {
			return "", false
		}
		lines := strings.split(body[first+1:last], "\n")
		for &line in lines {
			if strings.trim(line, " \t") == "" {
				line = ""
			} else if strings.has_prefix(line, indent) {
				line = line[len(indent):]
			} else {
				return "", false
			}
		}
		body = strings.join(lines, "\n")
	}
	if quote == '`' {
		return body, true
	}
	escaped_quote := quote
	if delimiter_width == 3 {
		escaped_quote = 0 // Bare quotes are permitted inside triple delimiters.
	}
	bytes := make([dynamic]byte, 0, len(body))
	for len(body) > 0 {
		segment := body
		if len(body) >= 2 && body[0] == '\\' && body[1] >= '0' && body[1] <= '7' {
			if len(body) < 4 {
				return "", false
			}
			// dev-2026-10's octal branch inspects its entire remaining input,
			// rather than just two further digits. Bound it to one escape.
			segment = body[:4]
		}
		r, multiple_bytes, tail, ok := strconv.unquote_char(segment, escaped_quote)
		if !ok {
			return "", false
		}
		body = body[len(segment)-len(tail):]
		if multiple_bytes {
			encoded, width := utf8.encode_rune(r)
			append(&bytes, ..encoded[:width])
		} else {
			append(&bytes, byte(r))
		}
	}
	return string(bytes[:]), true
}
