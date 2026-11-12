#+private
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:odin/ast"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// -------------------------------- Constants --------------------------------

// ---------------- Package ----------------

FILE_DEFAULT_CHANGE_PERCENT :: 60

BUILTIN_TYPES :: []string{
	"bool", "b8", "b16", "b32", "b64", "int", "uint", "uintptr", "byte", "rune",
	"i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128",
	"f16", "f32", "f64", "complex32", "complex64", "complex128",
	"quaternion64", "quaternion128", "quaternion256", "string", "cstring", "rawptr", "any", "typeid",
	"i16le", "i32le", "i64le", "i128le", "u16le", "u32le", "u64le", "u128le",
	"i16be", "i32be", "i64be", "i128be", "u16be", "u32be", "u64be", "u128be", "f16le", "f32le", "f64le", "f16be", "f32be", "f64be",
}

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

expression_kind :: proc(r: ^References, expr: ^ast.Expr, scope, depth: int) -> string {
	if expr == nil || depth > len(r.symbols)+len(r.scopes) {return ""}
	if known_external_type(r, expr, scope) {return "Types"}
	expr := expr
	expr = unwrap_parens(expr)
	#partial switch n in expr.derived {
	case ^ast.Proc_Lit, ^ast.Proc_Group: return "Procedures"
	case ^ast.Typeid_Type, ^ast.Helper_Type, ^ast.Distinct_Type, ^ast.Poly_Type,
	     ^ast.Proc_Type, ^ast.Pointer_Type, ^ast.Multi_Pointer_Type, ^ast.Array_Type,
	     ^ast.Dynamic_Array_Type, ^ast.Fixed_Capacity_Dynamic_Array_Type,
	     ^ast.Struct_Type, ^ast.Union_Type, ^ast.Enum_Type, ^ast.Bit_Set_Type,
	     ^ast.Map_Type, ^ast.Relative_Type, ^ast.Matrix_Type, ^ast.Bit_Field_Type: return "Types"
	case ^ast.Ident, ^ast.Selector_Expr:
		ids, certain := expression_symbols(r, expr, scope, expr.pos.offset)
		if !certain {
			if selector, ok := expr.derived.(^ast.Selector_Expr); ok {
				type := reference_type(r, selector.expr, scope, true, depth+1)
				if type != nil {if _, enumerant := type.derived.(^ast.Enum_Type); enumerant {return "Constants"}}
			}
			return ""
		}
		if len(ids) == 0 {
			if name, ok := binding_name(expr); ok {
				if slice.contains(BUILTIN_TYPES, name) {return "Types"}
				if name == "true" || name == "false" || name == "nil" {return "Constants"}
			}
			return ""
		}
		kind := ""
		for id in ids {
			symbol := r.symbols[id]
			candidate := expression_kind(r, symbol.value, symbol.scope, depth+1)
			// A compiler-valid type use is evidence even when its imported body
			// is outside this project's analysis graph.
			if candidate == "" && used_as_type(r, {id}) {candidate = "Types"}
			if candidate == "" || kind != "" && kind != candidate {return ""}
			kind = candidate
		}
		return kind
	case ^ast.Ternary_If_Expr:
		left, right := expression_kind(r, n.x, scope, depth+1), expression_kind(r, n.y, scope, depth+1)
		if left == right {return left}
		return ""
	case ^ast.Ternary_When_Expr:
		left, right := expression_kind(r, n.x, scope, depth+1), expression_kind(r, n.y, scope, depth+1)
		if left == right {return left}
		return ""
	case ^ast.Call_Expr:
		if directive, ok := unwrap_parens(n.expr).derived.(^ast.Basic_Directive); ok && directive.name == "config" && len(n.args) == 2 {
			return expression_kind(r, n.args[1], scope, depth+1)
		}
		if name, ok := binding_name(n.expr); ok {
			ids, certain := lookup(r, name, scope, n.pos.offset)
			if certain && len(ids) == 0 {
				if name == "type_of" {return "Types"}
				if slice.contains([]string{"size_of", "align_of", "offset_of", "len", "cap", "swizzle"}, name) {return "Constants"}
			}
		}
		if expression_kind(r, n.expr, scope, depth+1) == "Types" {
			type := reference_type(r, n.expr, scope, true, depth+1)
			if type != nil {
				#partial switch value in type.derived {
				case ^ast.Struct_Type: if value.poly_params != nil {return "Types"}
				case ^ast.Union_Type: if value.poly_params != nil {return "Types"}
				}
			}
			return "Constants"
		}
		callee, callee_scope := n.expr, scope
		for _ in 0..<len(r.symbols) {
			ids, certain := expression_symbols(r, callee, callee_scope, callee.pos.offset)
			if !certain || len(ids) != 1 {break}
			symbol := r.symbols[ids[0]]
			if symbol.value == nil || symbol.written {break}
			if procedure, ok := unwrap_parens(symbol.value).derived.(^ast.Proc_Lit); ok {
				if procedure.type.results != nil && len(procedure.type.results.list) == 1 {
					result := procedure.type.results.list[0].type
					if ident, named := result.derived.(^ast.Ident); named && ident.name == "typeid" {return "Types"}
				}
				break
			}
			callee, callee_scope = symbol.value, symbol.scope
		}
		return ""
	}
	return "Constants"
}

used_as_type :: proc(r: ^References, symbols: []int) -> bool {
	for use in r.uses {
		if !use.is_type {continue}
		expr := use.qualified if use.qualified != nil else use.expr
		ids, certain := expression_symbols(r, expr, use.scope, use.pos.offset)
		if !certain {continue}
		for id in ids {if slice.contains(symbols, id) {return true}}
	}
	return false
}

expression_symbols :: proc(r: ^References, expr: ^ast.Expr, scope, offset: int, available := Availability{}) -> (ids: [dynamic]int, certain: bool) {
	if expr == nil {return nil, false}
	available := available
	if !available.supplied {available = availability_at(r, scope, offset)}
	#partial switch n in unwrap_parens(expr).derived {
	case ^ast.Ident:
		return lookup(r, n.name, scope, offset, available)
	case ^ast.Selector_Expr:
		bases, known := expression_symbols(r, n.expr, scope, offset, available)
		certain = known && len(bases) == 1
		for base_id in bases {
			base := r.symbols[base_id]
			if base.import_path == "" {certain = false; continue}
			package_scope, _, loaded := import_scope(r, base.file, base.import_path)
			if !loaded {certain = false; continue}
			targets, bound := lookup(r, n.field.name, package_scope, offset, available)
			certain = certain && bound
			for id in targets {
				if r.symbols[id].visibility != 0 {certain = false; continue}
				if !slice.contains(ids[:], id) {append(&ids, id)}
			}
		}
		certain = certain && len(ids) > 0
		return
	}
	return nil, false
}

import_scope :: proc(r: ^References, file_index: int, import_path: string) -> (scope: int, path: string, loaded: bool) {
	path = import_path
	parts := strings.split_n(path, ":", 2)
	if len(parts) == 2 {
		root, supplied := r.collections[parts[0]]
		if !supplied {return -1, "", false}
		path, _ = filepath.join({root, parts[1]})
	} else {path, _ = filepath.join({filepath.dir(r.files[file_index].file.fullpath), path})}
	// A rewritten suffix can expose another directory alias. Canonical facts
	// consume a suffix component on each rewrite; bound malformed caller maps
	// as well as checking repeated paths, without doing filesystem I/O here.
	if len(r.import_aliases) > 0 {
		normalized, _ := strings.replace_all(path, "\\", "/")
		limit := len(strings.split(normalized, "/"))+len(r.import_aliases)+1
		seen := make(map[string]bool)
		for step in 0..<limit {
			if seen[path] {return -1, path, false}
			seen[path] = true
			rewritten := false
			ancestor := path
			for {
				if canonical, aliased := r.import_aliases[ancestor]; aliased {
					suffix, _ := filepath.rel(ancestor, path)
					target, _ := filepath.join({canonical, suffix})
					if target != path {path, rewritten = target, true}
					break
				}
				parent := filepath.dir(ancestor)
				if parent == ancestor {break}
				ancestor = parent
			}
			if !rewritten {break}
			if step+1 == limit {return -1, path, false}
		}
	}
	scope, loaded = r.packages[path]
	loaded = loaded && scope >= 0
	return
}

// One section/default group must describe every name of a declaration. Mixed
// privacy is not a majority vote based on whichever alias was written first.
declaration_group :: proc(r: ^References, decl: ^ast.Value_Decl) -> (visibility: int, homogeneous: bool) {
	ids := r.declaration_symbols[decl]
	if len(ids) == 0 {return}
	visibility = r.symbols[ids[0]].visibility
	for id in ids {if r.symbols[id].visibility != visibility {return visibility, false}}
	return visibility, true
}

required_declaration :: proc(decl: ^ast.Value_Decl, name: string) -> bool {
	return name == "main" || has_non_visibility_attribute(decl)
}

has_non_visibility_attribute :: proc(decl: ^ast.Value_Decl) -> bool {
	for attribute in decl.attributes {
		for element in attribute.elems {
			name := element
			if field, ok := element.derived.(^ast.Field_Value); ok {name = field.field}
			if ident, ok := name.derived.(^ast.Ident); !ok || ident.name != "private" {return true}
		}
	}
	return false
}
