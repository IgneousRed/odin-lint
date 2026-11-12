#+private
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:odin/ast"
import "core:slice"
import "core:strings"

// -------------------------------- Types --------------------------------

// ---------------- File ----------------

// Formal names bind positional/named calls to the same writes and aliases.
// A pipe separates alternative overload parameter names.
@(private = "file")
Call_Operation :: struct {
	known: bool,
	parameters: string,
	write: string,
	destroys, result_alias, decode, rng: bool,
}

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

call_operation :: proc(r: ^References, call: ^ast.Call_Expr, scope: int) -> (operation: Call_Operation) {
	if call.expr == nil {return}
	if ident, direct := unwrap_parens(call.expr).derived.(^ast.Ident); direct {
		ids, certain := lookup(r, ident.name, scope, call.pos.offset)
		if certain && len(ids) == 0 {
			if ident.name == "copy" {return Call_Operation{known = true, parameters = "dst,src", write = "dst"}}
			if ident.name == "free" {return Call_Operation{known = true, parameters = "ptr,allocator,loc", write = "ptr", destroys = true}}
			if ident.name == "delete" {return Call_Operation{known = true, parameters = "array|m|str,allocator,loc", write = "array|m|str", destroys = true}}
			if ident.name == "delete_key" {return Call_Operation{known = true, parameters = "m,key", write = "m"}}
			if slice.contains([]string{"clear", "reserve", "resize", "append", "inject_at", "ordered_remove", "unordered_remove", "pop"}, ident.name) {
				return Call_Operation{known = true, parameters = "array|m,args|arg|index|capacity|length,loc", write = "array|m"}
			}
		}
	}
	if known_external_type(r, call.expr, scope) {return Call_Operation{known = true}}
	path, member := external_target(r, call.expr, scope)
	if path == "core:odin/tokenizer" {
		if member == "init" {return Call_Operation{known = true, parameters = "t,src,path,err", write = "t"}}
		if slice.contains([]string{"scan", "advance_rune", "skip_whitespace", "scan_comment", "scan_file_tag", "scan_identifier", "scan_raw_string", "scan_escape", "scan_rune"}, member) {
			return Call_Operation{known = true, parameters = "t", write = "t"}
		}
		if member == "read_rune" || member == "peek_rune" {return Call_Operation{known = true, parameters = "t,offset", write = "t"}}
		if member == "scan_string" {return Call_Operation{known = true, parameters = "t,quote", write = "t"}}
		if member == "scan_number" {return Call_Operation{known = true, parameters = "t,seen_decimal_point", write = "t"}}
		if member == "error" {return Call_Operation{known = true, parameters = "t,offset,msg,args", write = "t"}}
		if member == "keyword_lut_init" {return Call_Operation{known = true, parameters = "lut", write = "lut"}}
	}
	if path == "core:encoding/endian" {
		if slice.contains([]string{"get_u16", "get_u32", "get_u64", "get_i16", "get_i32", "get_i64", "get_f16", "get_f32", "get_f64"}, member) {
			return Call_Operation{known = true, parameters = "b,order"}
		}
		if slice.contains([]string{"put_u16", "put_u32", "put_u64", "put_i16", "put_i32", "put_i64", "put_f16", "put_f32", "put_f64"}, member) {
			return Call_Operation{known = true, parameters = "b,order,v", write = "b"}
		}
	}
	if path == "core:mem" && member == "free" {return Call_Operation{known = true, parameters = "ptr,allocator,loc", write = "ptr", destroys = true}}
	if path == "core:time/timezone" && member == "region_destroy" {return Call_Operation{known = true, parameters = "region", write = "region", destroys = true}}
	if path == "core:mem" && slice.contains([]string{"zero", "zero_slice", "zero_item", "zero_explicit", "copy", "copy_non_overlapping", "move", "set"}, member) {
		return Call_Operation{known = true, parameters = "dst|item|data,src|value|len,len", write = "dst|item|data", result_alias = true}
	}
	if path == "core:slice" && slice.contains([]string{"fill", "zero", "reverse", "sort", "sort_by", "stable_sort", "stable_sort_by"}, member) {
		return Call_Operation{known = true, parameters = "data|array,less|value", write = "data|array"}
	}
	if path == "core:encoding/json" {
		if slice.contains([]string{"unmarshal", "unmarshal_string", "unmarshal_any"}, member) {
			return Call_Operation{known = true, parameters = "data,ptr|v,spec,allocator,flags", write = "ptr|v", decode = true}
		}
		if member == "make_tokenizer" {return Call_Operation{known = true, parameters = "data,spec,parse_integers"}}
		if slice.contains([]string{"make_parser", "make_parser_from_string", "make_parser_from_bytes"}, member) {
			return Call_Operation{known = true, parameters = "data,spec,parse_integers,allocator"}
		}
		if slice.contains([]string{"get_token", "next_rune"}, member) {return Call_Operation{known = true, parameters = "t", write = "t"}}
		if member == "parse_value" {return Call_Operation{known = true, parameters = "p,loc", write = "p"}}
		if slice.contains([]string{"parse", "parse_string", "parse_bytes"}, member) {
			return Call_Operation{known = true, parameters = "data,spec,parse_integers,allocator,loc"}
		}
	}
	if path == "core:math/rand" {
		if slice.contains([]string{"create", "create_u64", "create_bytes"}, member) {return Call_Operation{known = true}}
		if member == "default_random_generator" {return Call_Operation{known = true, parameters = "state", rng = true}}
		if slice.contains([]string{"uint32", "uint64", "uint128", "int", "int31", "int63", "int127", "float32", "float64", "query_info"}, member) {
			return Call_Operation{known = true, parameters = "gen", rng = true}
		}
		if strings.has_suffix(member, "_range") {return Call_Operation{known = true, parameters = "low|lo,high|hi,gen", rng = true}}
		if strings.has_suffix(member, "_max") {return Call_Operation{known = true, parameters = "n,gen", rng = true}}
		if slice.contains([]string{"reset", "reset_u64", "reset_bytes"}, member) {return Call_Operation{known = true, parameters = "seed|bytes,gen", rng = true}}
		if member == "read" {return Call_Operation{known = true, parameters = "p,gen", write = "p", rng = true}}
		if member == "shuffle" {return Call_Operation{known = true, parameters = "array,gen", write = "array", rng = true}}
		if member == "perm" {return Call_Operation{known = true, parameters = "n,allocator,gen", rng = true}}
		if slice.contains([]string{"choice", "choice_enum", "choice_bit_set"}, member) {return Call_Operation{known = true, parameters = "array|T|set,gen", rng = true}}
	}
	return
}

// These are type declarations in the pinned standard library, not a purity
// grant to arbitrary functions or registered JSON marshal/unmarshal callbacks.
// Recognizing their conversions also retains the argument's backing provenance.
known_external_type :: proc(r: ^References, expression: ^ast.Expr, scope: int) -> bool {
	path, name := external_target(r, expression, scope)
	if path == "core:c" {
		// Exact public type declarations in the pinned core:c. Constants and libc
		// functions remain distinct; non-scalar conversions retain input provenance.
		return slice.contains([]string{
			"char", "schar", "short", "int", "long", "longlong", "uchar", "ushort", "uint", "ulong", "ulonglong",
			"bool", "size_t", "ssize_t", "wchar_t", "float", "double", "complex_float", "complex_double",
			"int8_t", "uint8_t", "int16_t", "uint16_t", "int32_t", "uint32_t", "int64_t", "uint64_t",
			"int_least8_t", "uint_least8_t", "int_least16_t", "uint_least16_t", "int_least32_t", "uint_least32_t", "int_least64_t", "uint_least64_t",
			"int_fast8_t", "uint_fast8_t", "int_fast16_t", "uint_fast16_t", "int_fast32_t", "uint_fast32_t", "int_fast64_t", "uint_fast64_t",
			"intptr_t", "uintptr_t", "ptrdiff_t", "intmax_t", "uintmax_t", "va_list", "FILE",
		}, name)
	}
	return path == "core:encoding/json" && slice.contains([]string{
		"Null", "Integer", "Float", "Boolean", "String", "Array", "Object", "Value", "Specification", "Error",
	}, name)
}
// Procedure type evidence is separate from knowing a particular callback target.
// This permits symbolic callback field stores without granting them pure effects.
known_callback_type :: proc(r: ^References, expression: ^ast.Expr, scope: int) -> bool {
	if expression == nil {return false}
	#partial switch _ in unwrap_parens(expression).derived {
	case ^ast.Proc_Type: return true
	case ^ast.Ident, ^ast.Selector_Expr:
		value := access_type(r, expression, scope, 0)
		if value.type != nil {if _, procedure := value.type.derived.(^ast.Proc_Type); procedure {return true}}
		path, member := external_target(r, expression, scope)
		return path == "core:odin/tokenizer" && member == "Error_Handler"
	}
	return false
}

operation_argument :: proc(operation: Call_Operation, call: ^ast.Call_Expr, parameter: string) -> ^ast.Expr {
	parameters := strings.split(operation.parameters, ",")
	arguments := bind_arguments(parameters, nil, call.args[:])
	for name, index in parameters {if name == parameter && index < len(arguments) {return arguments[index]}}
	return nil
}

bind_arguments :: proc(parameters: []string, defaults, supplied: []^ast.Expr) -> []^ast.Expr {
	result := make([]^ast.Expr, len(parameters))
	for names, index in parameters {
		if index < len(defaults) {result[index] = defaults[index]}
		if index < len(supplied) {if _, named := supplied[index].derived.(^ast.Field_Value); !named {result[index] = supplied[index]}}
		for argument in supplied {
			if field, named := argument.derived.(^ast.Field_Value); named {
				name, _ := binding_name(field.field)
				if slice.contains(strings.split(names, "|"), name) {result[index] = field.value; break}
			}
		}
	}
	return result
}

// Generic output shapes are instantiated at callers. This describes private
// decoded working data without proving allocator or lifetime contracts.
decoded_output :: proc(r: ^References, destination: State_Access, site: ^ast.Expr) -> State_Access {
	shape := destination.type
	known := false
	if shape != nil {
		#partial switch _ in shape.derived {
		case ^ast.Struct_Type, ^ast.Map_Type, ^ast.Array_Type, ^ast.Dynamic_Array_Type: known = true
		case ^ast.Ident:
			if name, named := binding_name(shape); named {known = slice.contains(BUILTIN_TYPES, name)}
		}
	}
	if known {return decoded_access(r, destination, site)}
	return State_Access{decoded = true, resource = State_Location{root = site}}
}

// ---------------- File ----------------

@(private = "file")
decoded_access :: proc(r: ^References, original: State_Access, site: ^ast.Expr, path := "", root := true, seen: ^map[^ast.Expr]bool = nil) -> (result: State_Access) {
	result = access_type(r, original.type, original.scope, 0)
	if root {result.pointer = false}
	result.protected, result.live, result.published, result.immutable = false, false, false, false
	if result.pointer || result.shared {result.resource = State_Location{root = site, path = path}}
	if result.type == nil {return}
	seen := seen
	storage: map[^ast.Expr]bool
	if seen == nil {storage = make(map[^ast.Expr]bool); seen = &storage}
	if seen^[result.type] {result.uncertain = true; return}
	seen^[result.type] = true
	defer delete_key(seen, result.type)
	#partial switch shape in result.type.derived {
	case ^ast.Struct_Type:
		result.fields = make(map[string]State_Access)
		if shape.fields != nil {for field in shape.fields.list {
			for expression in field.names {if name, named := binding_name(expression); named {
				child := field_access(r, result, name, 0)
				result.fields[name] = decoded_access(r, child, site, append_access_field(path, name), false, seen)
			}}
		}}
	case ^ast.Map_Type, ^ast.Array_Type, ^ast.Dynamic_Array_Type:
		result.fields = make(map[string]State_Access)
		repeat := false
		if array, fixed := result.type.derived.(^ast.Array_Type); fixed {repeat = array.len != nil}
		result.fields[""] = decoded_access(r, element_access(r, result, 0), site, append_access_field(path, "[]", repeat), false, seen)
		if table, mapped := result.type.derived.(^ast.Map_Type); mapped {
			result.fields["$key"] = decoded_access(r, access_type(r, table.key, result.scope, 0), site, append_access_field(path, "$key"), false, seen)
		}
	}
	return
}
