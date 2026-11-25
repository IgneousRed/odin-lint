#+private file
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// -------------------------------- Types --------------------------------

// ---------------- Package ----------------

@(private)
References :: struct {
	files: []Parsed_Source,
	collections: map[string]string,
	import_aliases: map[string]string,
	packages: map[string]int,
	node_scopes: map[^ast.Node]int,
	declaration_symbols: map[^ast.Value_Decl][dynamic]int,
	groups: map[^ast.Value_Decl]string,
	scopes: [dynamic]Scope,
	file_scopes: []int,
	file_availability: []Availability,
	availability_ranges: [dynamic]Availability_Range,
	availability: Availability,
	symbols: [dynamic]Symbol,
	procedures: [dynamic]Procedure,
	by_literal: map[^ast.Proc_Lit]int,
	type_scopes: map[^ast.Expr]int,
	contexts: map[^ast.Expr]Literal_Context,
	uses: [dynamic]Use,
	edges: [dynamic]Call_Edge,
	providers: [dynamic]Using_Provider,
	scope, file, caller, default_scope, owner: int,
	foreign_visibility: int,
	type_context: bool,
	top_level, conditional: bool,
	authorities: map[^ast.Expr]bool,
	relation_containers: map[^ast.Expr]bool,
	relational_types, local_types: map[Type_Scope]bool,
	finite_index_types: map[Type_Scope]bool,
	index_paths: map[State_Location]bool,
	location_types: map[^ast.Expr]struct {source: ^ast.Expr, scope: int, is_type: bool},
	field_paths: map[Field_Path_Key]string,
	path_allocator: mem.Allocator,
	read_cache: ^Read_Cache,
	semantics: ^Semantics,
}

@(private)
Call_Edge :: struct {caller, callee: int, pos: tokenizer.Pos}

@(private)
Literal_Context :: struct {
	expr: ^ast.Expr,
	scope: int,
	is_type: bool,
	member: string,
	element: bool,
	call: ^ast.Call_Expr,
}

@(private)
Type_Scope :: struct {expression: ^ast.Expr, scope: int}

// ---------------- File ----------------

Scope :: struct {
	parent, file: int,
	bindings: map[string][dynamic]int,
	unknown_using_from: [dynamic]int,
}

Symbol :: struct {
	name: string,
	decl: ^ast.Value_Decl,
	pos: tokenizer.Pos,
	file, scope, visible_from, visibility: int,
	value, type: ^ast.Expr,
	written, conditional, alias, top_level, mutable: bool,
	import_path: string,
	available: Availability,
	namespace_member: bool,
	namespace_target: int,
}

Procedure :: struct {
	literal: ^ast.Proc_Lit,
	name: string,
	file, visibility: int,
	decl: ^ast.Value_Decl,
	calls: int,
	candidate, escaped, cyclic, top_level: bool,
}

Use :: struct {
	expr: ^ast.Expr,
	literal: ^ast.Comp_Lit,
	scope, file, caller: int,
	owner: int,
	is_type: bool,
	qualified: ^ast.Expr,
	kind: Use_Kind,
	member: string,
	pos: tokenizer.Pos,
}


Use_Kind :: enum {Value, Call, Write, Alias}

Using_Provider :: struct {scope: int, expr: ^ast.Expr, is_type, conditional: bool, visible_from: int}

Resolution :: struct {targets: [dynamic]int, certain: bool}

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

@(private)
visit_references :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {return visitor}
	r := cast(^References)visitor.data
	r.node_scopes[node] = r.scope
	saved_scope, saved_caller, saved_top, saved_conditional, saved_default, saved_owner, saved_type, saved_foreign := r.scope, r.caller, r.top_level, r.conditional, r.default_scope, r.owner, r.type_context, r.foreign_visibility
	saved_availability := r.availability
	defer {r.scope, r.caller, r.top_level, r.conditional, r.default_scope, r.owner, r.type_context, r.foreign_visibility = saved_scope, saved_caller, saved_top, saved_conditional, saved_default, saved_owner, saved_type, saved_foreign}
	defer {r.availability = saved_availability}
	#partial switch n in node.derived {
	case ^ast.Import_Decl:
		path := r.files[r.file].imports[n]
		name := n.name.text
		if name == "" {
			parts := strings.split_n(path, ":", 2)
			name = filepath.base(parts[len(parts)-1])
			if package_scope, _, loaded := import_scope(r, r.file, path); loaded {
				for file, index in r.files {
					if r.scopes[r.file_scopes[index]].parent == package_scope {name = file.file.pkg_name; break}
				}
			}
		}
		bind(r, r.scope, Symbol{name = name, file = r.file, scope = r.scope, import_path = path, conditional = r.conditional, available = r.availability})
		if n.is_using {
			ident := new(ast.Ident)
			ident.name, ident.pos = name, n.pos
			append(&r.providers, Using_Provider{scope = r.scope, expr = &ident.node, conditional = r.conditional})
		}
		return nil
	case ^ast.Foreign_Block_Decl:
		attributes := ast.Value_Decl{attributes = n.attributes}
		visibility := int(parser.parse_file_tags(r.files[r.file].file).private)
		if r.foreign_visibility >= 0 {visibility = r.foreign_visibility}
		r.foreign_visibility, _ = declaration_visibility(&attributes, visibility)
		if body, ok := n.body.derived.(^ast.Block_Stmt); ok {
			for statement in body.stmts {ast.walk(visitor, statement)}
		}
		return nil
	case ^ast.Value_Decl:
		visibility := int(parser.parse_file_tags(r.files[r.file].file).private)
		if r.foreign_visibility >= 0 {visibility = r.foreign_visibility}
		visibility, _ = declaration_visibility(n, visibility)
		for name_expr, i in n.names {
			name, ok := binding_name(name_expr)
			if !ok {continue}
			value: ^ast.Expr
			if len(n.names) == len(n.values) {value = n.values[i]}
			r.location_types[name_expr] = {n.type if n.type != nil else value, r.scope, n.type != nil}
			alias := false
			if value != nil {_, alias = unwrap_parens(value).derived.(^ast.Ident)}
			namespace := r.scope
			if r.top_level && visibility < 2 {namespace = r.scopes[r.file_scopes[r.file]].parent}
			visible_from := n.end.offset if n.is_mutable && !r.top_level else 0
			id := len(r.symbols)
			bind(r, namespace, Symbol{name = name, decl = n, pos = name_expr.pos, file = r.file, scope = r.scope, value = value, type = n.type,
				visible_from = visible_from, visibility = visibility, conditional = r.conditional, alias = alias, top_level = r.top_level, mutable = n.is_mutable, available = r.availability})
			if len(r.symbols) > id {
				ids := r.declaration_symbols[n]; append(&ids, id); r.declaration_symbols[n] = ids
				if r.top_level && i == 0 {r.owner = id}
			}
			if n.is_using {
				provider := Using_Provider{scope = r.scope, expr = value, conditional = r.conditional, visible_from = n.end.offset}
				if n.type != nil {provider.expr, provider.is_type = n.type, true}
				append(&r.providers, provider)
			}
		}
		candidate := r.top_level && !n.is_mutable && visibility > 0 && !r.conditional && !has_non_visibility_attribute(n)
		for attribute in n.attributes {ast.walk(visitor, attribute)}
		r.type_context = true
		ast.walk(visitor, n.type)
		r.type_context = false
		for value, i in n.values {
			if n.type != nil {r.contexts[unwrap_parens(value)] = Literal_Context{expr = n.type, scope = r.scope, is_type = true}}
			if r.top_level {
				for id in r.declaration_symbols[n] {if r.symbols[id].value == value {r.owner = id; break}}
			}
			_, alias := unwrap_parens(value).derived.(^ast.Ident)
			if !alias || len(n.names) != len(n.values) {ast.walk(visitor, value)} else {
				append(&r.uses, Use{expr = value, scope = r.scope, file = r.file, caller = r.caller, owner = r.owner, kind = .Alias, pos = value.pos})
			}
			if literal, ok := unwrap_parens(value).derived.(^ast.Proc_Lit); ok {
				id := r.by_literal[literal]
				procedure := &r.procedures[id]
				procedure.decl, procedure.top_level, procedure.visibility = n, r.top_level, visibility
				procedure.name, _ = binding_name(n.names[min(i, len(n.names)-1)])
				procedure.candidate = candidate && literal.body != nil
			}
		}
		return nil
	case ^ast.Proc_Lit:
		id := len(r.procedures)
		r.by_literal[n] = id
		append(&r.procedures, Procedure{file = r.file, literal = n})
		if r.caller >= 0 {append(&r.edges, Call_Edge{r.caller, id, n.pos})}
		r.caller, r.top_level = id, false
		r.scope = new_scope(r, r.scope, r.file)
		for fields in ([2]^ast.Field_List{n.type.params, n.type.results}) {
			if fields == nil {continue}
			bind_parameters(r, fields)
			for field in fields.list {
				if .Using in field.flags {append(&r.providers, Using_Provider{scope = r.scope, expr = field.type, is_type = true, conditional = r.conditional})}
			}
		}
		// Default expressions resolve outside the parameter/result bindings;
		// signature types and the body retain their parameter scope.
		r.default_scope = saved_scope
		ast.walk(visitor, n.type)
		r.default_scope = -1
		ast.walk(visitor, n.body)
		for clause in n.where_clauses {ast.walk(visitor, clause)}
		return nil
	case ^ast.Block_Stmt:
		r.scope, r.top_level = new_scope(r, r.scope, r.file), false
		for statement in n.stmts {ast.walk(visitor, statement)}
		return nil
	case ^ast.If_Stmt:
		r.scope, r.top_level = new_scope(r, r.scope, r.file), false
		ast.walk(visitor, n.init); ast.walk(visitor, n.cond); ast.walk(visitor, n.body); ast.walk(visitor, n.else_stmt)
		return nil
	case ^ast.For_Stmt:
		r.scope, r.top_level = new_scope(r, r.scope, r.file), false
		ast.walk(visitor, n.init); ast.walk(visitor, n.cond); ast.walk(visitor, n.post); ast.walk(visitor, n.body)
		return nil
	case ^ast.Range_Stmt:
		r.scope, r.top_level = new_scope(r, r.scope, r.file), false
		ast.walk(visitor, n.init); ast.walk(visitor, n.expr)
		for value in n.vals {if name, ok := binding_name(value); ok {bind(r, r.scope, Symbol{name = name, scope = r.scope, file = r.file, visible_from = n.expr.end.offset})}}
		ast.walk(visitor, n.body)
		return nil
	case ^ast.Unroll_Range_Stmt:
		r.scope, r.top_level = new_scope(r, r.scope, r.file), false
		ast.walk(visitor, n.expr)
		for value in ([2]^ast.Expr{n.val0, n.val1}) {if name, ok := binding_name(value); ok {bind(r, r.scope, Symbol{name = name, scope = r.scope, file = r.file, visible_from = n.expr.end.offset})}}
		for argument in n.args {ast.walk(visitor, argument)}
		ast.walk(visitor, n.body)
		return nil
	case ^ast.Switch_Stmt:
		r.scope, r.top_level = new_scope(r, r.scope, r.file), false
		ast.walk(visitor, n.init); ast.walk(visitor, n.cond); ast.walk(visitor, n.body)
		return nil
	case ^ast.Type_Switch_Stmt:
		r.scope, r.top_level = new_scope(r, r.scope, r.file), false
		ast.walk(visitor, n.tag); ast.walk(visitor, n.expr); ast.walk(visitor, n.body)
		return nil
	case ^ast.Case_Clause:
		r.scope, r.top_level = new_scope(r, r.scope, r.file), false
		for expr in n.list {ast.walk(visitor, expr)}
		for statement in n.body {ast.walk(visitor, statement)}
		return nil
	case ^ast.When_Stmt:
		condition, known := literal_condition(n.cond)
		ast.walk(visitor, n.cond)
		r.conditional = r.conditional || !known
		predicate := availability_expression(n.cond, r.scope)
		for body, i in ([2]^ast.Stmt{n.body, n.else_stmt}) {
			if body == nil || known && condition != (i == 0) {continue}
			r.availability = availability_and(saved_availability, predicate if i == 0 else availability_not(predicate))
			append(&r.availability_ranges, Availability_Range{r.file, body.pos.offset, body.end.offset, r.availability})
			if block, ok := body.derived.(^ast.Block_Stmt); ok {
				for statement in block.stmts {ast.walk(visitor, statement)}
			} else {ast.walk(visitor, body)}
		}
		return nil
	case ^ast.Return_Stmt:
		if r.caller >= 0 {
			results := r.procedures[r.caller].literal.type.results
			index := 0
			if results != nil {for field in results.list {
				for _ in 0..<max(1, len(field.names)) {
					if index < len(n.results) {r.contexts[unwrap_parens(n.results[index])] = Literal_Context{expr = field.type, scope = r.scope, is_type = true}}
					index += 1
				}
			}}
		}
		for result in n.results {ast.walk(visitor, result)}
		return nil
	case ^ast.Assign_Stmt:
		for expr, i in n.rhs {
			if i < len(n.lhs) {r.contexts[unwrap_parens(expr)] = Literal_Context{expr = n.lhs[i], scope = r.scope}}
			ast.walk(visitor, expr)
		}
		for expr in n.lhs {
			if n.op.kind == .Colon || n.op.kind == .In {
				if name, ok := binding_name(expr); ok {bind(r, r.scope, Symbol{name = name, scope = r.scope, file = r.file, visible_from = n.end.offset})}
			} else if _, ok := binding_name(expr); ok {
				append(&r.uses, Use{expr = expr, scope = r.scope, file = r.file, caller = r.caller, owner = r.owner, is_type = r.type_context, kind = .Write, pos = expr.pos})
			} else {ast.walk(visitor, expr)}
		}
		return nil
	case ^ast.Using_Stmt:
		for expr in n.list {append(&r.providers, Using_Provider{scope = r.scope, expr = expr, conditional = r.conditional, visible_from = n.end.offset}); ast.walk(visitor, expr)}
		return nil
	case ^ast.Call_Expr:
		if selector, ok := unwrap_parens(n.expr).derived.(^ast.Selector_Expr); ok {
			append(&r.uses, Use{expr = selector.expr, scope = r.scope, file = r.file, caller = r.caller, owner = r.owner, is_type = r.type_context, kind = .Call, member = selector.field.name, qualified = n.expr, pos = n.pos})
			ast.walk(visitor, selector.expr)
		} else if _, direct := unwrap_parens(n.expr).derived.(^ast.Ident); direct {
			append(&r.uses, Use{expr = n.expr, scope = r.scope, file = r.file, caller = r.caller, owner = r.owner, is_type = r.type_context, kind = .Call, pos = n.pos})
		} else {ast.walk(visitor, n.expr)}
		for argument in n.args {
			value := argument
			if field, ok := argument.derived.(^ast.Field_Value); ok {value = field.value}
			r.contexts[unwrap_parens(value)] = Literal_Context{call = n, scope = r.scope}
			ast.walk(visitor, value)
		}
		return nil
	case ^ast.Comp_Lit:
		ast.walk(visitor, n.type)
		for element in n.elems {
			if field, ok := element.derived.(^ast.Field_Value); ok {
				if _, named := field.field.derived.(^ast.Ident); named {
					// Named fields and identifier map keys have the same AST shape.
					// Classify only after all package declarations are registered.
					append(&r.uses, Use{expr = field.field, literal = n, scope = r.scope, file = r.file, caller = r.caller, owner = r.owner, is_type = r.type_context, kind = .Value, pos = field.field.pos})
				} else {ast.walk(visitor, field.field)}
				name, _ := binding_name(field.field)
				r.contexts[unwrap_parens(field.value)] = Literal_Context{expr = &n.node, scope = r.scope, member = name, element = name == ""}
				ast.walk(visitor, field.value)
			} else {
				r.contexts[unwrap_parens(element)] = Literal_Context{expr = &n.node, scope = r.scope, element = true}
				ast.walk(visitor, element)
			}
		}
		return nil
	case ^ast.Attribute:
		for element in n.elems {
			if field, ok := element.derived.(^ast.Field_Value); ok {ast.walk(visitor, field.value)}
		}
		return nil
	case ^ast.Field:
		r.default_scope = -1
		r.type_context = true
		ast.walk(visitor, n.type)
		r.type_context = false
		if saved_default >= 0 {r.scope = saved_default}
		ast.walk(visitor, n.default_value)
		return nil
	case ^ast.Selector_Expr:
		append(&r.uses, Use{expr = n.expr, qualified = &n.node, member = n.field.name, scope = r.scope, file = r.file, caller = r.caller, owner = r.owner, is_type = r.type_context, kind = .Value, pos = n.pos})
		ast.walk(visitor, n.expr)
		return nil
	case ^ast.Implicit_Selector_Expr, ^ast.Branch_Stmt:
		return nil
	case ^ast.Array_Type:
		r.type_scopes[cast(^ast.Expr)node] = r.scope
		// Bounds are values even inside a type expression. Keeping the outer
		// type context here would turn a #config integer into a type alias.
		r.type_context = false
		ast.walk(visitor, n.len)
		r.type_context = true
		ast.walk(visitor, n.elem)
		return nil
	case ^ast.Fixed_Capacity_Dynamic_Array_Type:
		r.type_scopes[cast(^ast.Expr)node] = r.scope
		r.type_context = false
		ast.walk(visitor, n.capacity)
		r.type_context = true
		ast.walk(visitor, n.elem)
		return nil
	case ^ast.Matrix_Type:
		r.type_scopes[cast(^ast.Expr)node] = r.scope
		r.type_context = false
		ast.walk(visitor, n.row_count); ast.walk(visitor, n.column_count)
		r.type_context = true
		ast.walk(visitor, n.elem)
		return nil
	case ^ast.Map_Type, ^ast.Dynamic_Array_Type:
		r.type_scopes[cast(^ast.Expr)node] = r.scope
	case ^ast.Struct_Type:
		if n.poly_params != nil {
			r.scope = new_scope(r, r.scope, r.file)
			bind_parameters(r, n.poly_params)
		}
		r.type_scopes[&n.node] = r.scope
		ast.walk(visitor, n.poly_params)
		ast.walk(visitor, n.align); ast.walk(visitor, n.min_field_align); ast.walk(visitor, n.max_field_align)
		for clause in n.where_clauses {ast.walk(visitor, clause)}
		ast.walk(visitor, n.fields)
		return nil
	case ^ast.Union_Type:
		if n.poly_params != nil {
			r.scope = new_scope(r, r.scope, r.file)
			bind_parameters(r, n.poly_params)
		}
		ast.walk(visitor, n.poly_params); ast.walk(visitor, n.align)
		for clause in n.where_clauses {ast.walk(visitor, clause)}
		for variant in n.variants {ast.walk(visitor, variant)}
		return nil
	case ^ast.Enum_Type:
		r.type_scopes[&n.node] = r.scope
		ast.walk(visitor, n.base_type)
		for element in n.fields {if field, ok := element.derived.(^ast.Field_Value); ok {ast.walk(visitor, field.value)}}
		return nil
	case ^ast.Ident:
		append(&r.uses, Use{expr = &n.node, scope = r.scope, file = r.file, caller = r.caller, owner = r.owner, is_type = r.type_context, kind = .Value, pos = n.pos})
	}
	return visitor
}

@(private)
promote_members :: proc(r: ^References, type: ^ast.Expr, scope, visible_from: int, conditional: bool, depth: int, namespace: ^ast.Expr = nil) -> bool {
	if namespace != nil {
		ids, certain := expression_symbols(r, namespace, scope, namespace.pos.offset)
		known, promoted := len(ids) > 0, false
		for id in ids {
			imported := r.symbols[id]
			if imported.import_path == "" {known = false; continue}
			package_scope, _, loaded := import_scope(r, imported.file, imported.import_path)
			if !loaded {known = false; continue}
			promoted = true
			for name, targets in r.scopes[package_scope].bindings {
				for target in targets {
					if r.symbols[target].visibility != 0 {continue}
					bind(r, scope, Symbol{name = name, file = r.scopes[scope].file, scope = scope, visible_from = visible_from,
						conditional = conditional || !certain, namespace_member = true, namespace_target = target})
				}
			}
		}
		if promoted {return known}
	}
	if type == nil || depth > len(r.symbols)+len(r.scopes) {return false}
	#partial switch n in type.derived {
	case ^ast.Struct_Type:
		known := true
		for field in n.fields.list {
			for expr in field.names {if name, ok := binding_name(expr); ok {bind(r, scope, Symbol{name = name, scope = scope, file = r.scopes[scope].file, visible_from = visible_from, conditional = conditional})}}
			if .Using in field.flags {
				inner := reference_type(r, field.type, r.type_scopes[type], true, 0)
				known = promote_members(r, inner, scope, visible_from, conditional, depth+1) && known
			}
		}
		return known
	case ^ast.Enum_Type:
		for expr in n.fields {
			name_expr := expr
			if field, ok := expr.derived.(^ast.Field_Value); ok {name_expr = field.field}
			if name, ok := binding_name(name_expr); ok {bind(r, scope, Symbol{name = name, scope = scope, file = r.scopes[scope].file, visible_from = visible_from, conditional = conditional})}
		}
		return true
	}
	return false
}

@(private)
resolve_expr :: proc(r: ^References, expr: ^ast.Expr, scope, offset: int, seen: ^map[int]bool = nil, available := Availability{}) -> (result: Resolution) {
	if expr == nil {return}
	available := available
	if !available.supplied {available = availability_at(r, scope, offset)}
	#partial switch n in unwrap_parens(expr).derived {
	case ^ast.Ident, ^ast.Selector_Expr:
		ids, certain := expression_symbols(r, expr, scope, offset, available)
		result.certain = certain
		for id in ids {
			target := resolve_symbol(r, id, seen, availability_and(available, binding_availability(r, id)))
			result.certain = result.certain && target.certain
			for procedure in target.targets {if !slice.contains(result.targets[:], procedure) {append(&result.targets, procedure)}}
		}
	case ^ast.Proc_Lit:
		if id, ok := r.by_literal[n]; ok {append(&result.targets, id); result.certain = true}
	}
	return
}

@(private)
resolve_symbol :: proc(r: ^References, id: int, seen: ^map[int]bool = nil, available := Availability{}) -> Resolution {
	seen := seen
	storage: map[int]bool
	if seen == nil {storage = make(map[int]bool); seen = &storage}
	if seen^[id] {return {certain = false}}
	seen^[id] = true
	defer delete_key(seen, id)
	symbol := r.symbols[id]
	available := available
	if !available.supplied {available = binding_availability(r, id)}
	offset := symbol.value.pos.offset if symbol.value != nil else 0
	result := resolve_expr(r, symbol.value, symbol.scope, offset, seen, available)
	result.certain = result.certain && !symbol.written
	return result
}

// Resolve only the type forms needed to identify using members and map keys.
// Unknown imported or computed types remain local uncertainty, never a file ban.
@(private)
reference_type :: proc(r: ^References, expr: ^ast.Expr, scope: int, is_type: bool, depth: int) -> ^ast.Expr {
	expr := expr
	if expr == nil || depth > len(r.symbols)+len(r.scopes) {return nil}
	expr = unwrap_parens(expr)
	#partial switch n in expr.derived {
	case ^ast.Ident:
		ids, certain := lookup(r, n.name, scope, n.pos.offset)
		if !certain || len(ids) != 1 {return nil}
		symbol := r.symbols[ids[0]]
		if !is_type && symbol.type != nil {return reference_type(r, symbol.type, symbol.scope, true, depth+1)}
		return reference_type(r, symbol.value, symbol.scope, is_type, depth+1)
	case ^ast.Selector_Expr:
		ids, certain := expression_symbols(r, expr, scope, expr.pos.offset)
		if certain && len(ids) == 1 {
			symbol := r.symbols[ids[0]]
			if !is_type && symbol.type != nil {return reference_type(r, symbol.type, symbol.scope, true, depth+1)}
			return reference_type(r, symbol.value, symbol.scope, is_type, depth+1)
		}
		return context_member_type(r, reference_type(r, n.expr, scope, false, depth+1), n.field.name, false, depth+1)
	case ^ast.Deref_Expr: return reference_type(r, n.expr, scope, false, depth+1)
	case ^ast.Unary_Expr: return reference_type(r, n.expr, scope, false, depth+1)
	case ^ast.Call_Expr:
		if is_type {
			shape := reference_type(r, n.expr, scope, true, depth+1)
			if shape != nil {
				#partial switch type in shape.derived {
				case ^ast.Struct_Type: if type.poly_params != nil {return shape}
				case ^ast.Union_Type: if type.poly_params != nil {return shape}
				}
			}
		}
		return nil
	case ^ast.Comp_Lit:
		if n.type != nil {return reference_type(r, n.type, scope, true, depth+1)}
		literal_context, supplied := r.contexts[unwrap_parens(expr)]
		if !supplied {return nil}
		if literal_context.call != nil {
			targets, certain := call_procedures(r, literal_context.call.expr, literal_context.scope)
			if !certain || len(targets) != 1 {return nil}
			procedure := r.procedures[targets[0]].literal
			arguments := call_arguments(procedure, literal_context.call)
			index := 0
			if procedure.type.params != nil {for field in procedure.type.params.list {
				for _ in field.names {
					if index < len(arguments) && arguments[index] != nil && unwrap_parens(arguments[index]) == expr {return reference_type(r, field.type, r.node_scopes[&procedure.type.node], true, depth+1)}
					index += 1
				}
			}}
			return nil
		}
		shape := reference_type(r, literal_context.expr, literal_context.scope, literal_context.is_type, depth+1)
		if literal_context.member != "" || literal_context.element {return context_member_type(r, shape, literal_context.member, literal_context.element, depth+1)}
		return shape
	case ^ast.Pointer_Type: return reference_type(r, n.elem, scope, true, depth+1)
	case ^ast.Helper_Type: return reference_type(r, n.type, scope, true, depth+1)
	case ^ast.Distinct_Type: return reference_type(r, n.type, scope, true, depth+1)
	case ^ast.Struct_Type, ^ast.Union_Type, ^ast.Enum_Type, ^ast.Map_Type, ^ast.Array_Type, ^ast.Dynamic_Array_Type: return expr
	}
	return nil
}


@(private)
lookup :: proc(r: ^References, name: string, scope, offset: int, available := Availability{}) -> (ids: [dynamic]int, certain: bool) {
	certain = true
	remaining := available
	if !remaining.supplied {remaining = availability_at(r, scope, offset)}
	for current := scope; current >= 0; current = r.scopes[current].parent {
		coverage := Availability{supplied = true}
		for binding_id in r.scopes[current].bindings[name] {
			symbol := r.symbols[binding_id]
			if symbol.visible_from > offset {continue}
			id := binding_id
			present := availability_and(remaining, binding_availability(r, binding_id))
			if !availability_possible(r, present) {continue}
			if symbol.conditional && !symbol.available.supplied && !symbol.namespace_member {certain = false}
			if symbol.namespace_member {
				id = symbol.namespace_target
				if r.symbols[id].visibility != 0 {continue}
			}
			if availability_possible(r, availability_and(coverage, present)) {certain = false}
			coverage = availability_or(coverage, present)
			if !slice.contains(ids[:], id) {append(&ids, id)}
		}
		// Conditional declarations may be absent. Keep outer bindings as
		// possible targets only in configurations the inner scope did not cover.
		remaining = availability_and(remaining, availability_not(coverage))
		if !availability_possible(r, remaining) {return ids, certain}
		for from in r.scopes[current].unknown_using_from {certain = certain && offset < from}
	}
	if len(ids) > 0 {certain = false}
	return
}

@(private)
binding_name :: proc(expr: ^ast.Expr) -> (string, bool) {
	expr := expr
	if expr == nil {return "", false}
	expr = unwrap_parens(expr)
	#partial switch n in expr.derived {
	case ^ast.Ident: return n.name, true
	case ^ast.Poly_Type: return binding_name(n.type)
	case ^ast.Unary_Expr: return binding_name(n.expr)
	}
	return "", false
}

@(private)
new_scope :: proc(r: ^References, parent, file: int) -> int {
	id := len(r.scopes)
	append(&r.scopes, Scope{parent = parent, file = file, bindings = make(map[string][dynamic]int)})
	return id
}

@(private)
literal_condition :: proc(expr: ^ast.Expr) -> (bool, bool) {
	if expr == nil {return false, false}
	#partial switch n in unwrap_parens(expr).derived {
	case ^ast.Ident:
		if n.name == "true" || n.name == "false" {return n.name == "true", true}
	case ^ast.Basic_Lit:
		if n.tok.text == "true" || n.tok.text == "false" {return n.tok.text == "true", true}
	case ^ast.Unary_Expr:
		if n.op.kind == .Not {value, known := literal_condition(n.expr); return !value, known}
	}
	return false, false
}

// ---------------- File ----------------

// Context is limited to compiler-established shapes; unknown factories and map
// keys remain ordinary expression uses, with uncertainty local to their targets.

context_member_type :: proc(r: ^References, shape: ^ast.Expr, member: string, element: bool, depth: int) -> ^ast.Expr {
	if shape == nil {return nil}
	scope := r.type_scopes[shape]
	#partial switch type in shape.derived {
	case ^ast.Struct_Type:
		if !element && type.fields != nil {for field in type.fields.list {
			for name in field.names {if identifier, named := binding_name(name); named && identifier == member {return reference_type(r, field.type, scope, true, depth+1)}}
		}}
	case ^ast.Map_Type: return reference_type(r, type.value, scope, true, depth+1)
	case ^ast.Array_Type: return reference_type(r, type.elem, scope, true, depth+1)
	case ^ast.Dynamic_Array_Type: return reference_type(r, type.elem, scope, true, depth+1)
	}
	return nil
}

bind_parameters :: proc(r: ^References, fields: ^ast.Field_List) {
	poly_visitor := ast.Visitor{visit = visit_poly_bindings, data = r}
	for field in fields.list {
		for name_expr in field.names {
			r.location_types[name_expr] = {field.type, r.scope, true}
			if name, ok := binding_name(name_expr); ok {bind(r, r.scope, Symbol{name = name, file = r.file, scope = r.scope, type = field.type})}
		}
		ast.walk(&poly_visitor, field.type)
	}
}

visit_poly_bindings :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {return visitor}
	r := cast(^References)visitor.data
	#partial switch n in node.derived {
	case ^ast.Poly_Type:
		// A dollar name introduces a type binding, rather than a procedure use.
		if _, exists := r.scopes[r.scope].bindings[n.type.name]; !exists {
			bind(r, r.scope, Symbol{name = n.type.name, file = r.file, scope = r.scope})
		}
		ast.walk(visitor, n.specialization)
		return nil
	case ^ast.Struct_Type, ^ast.Union_Type, ^ast.Proc_Lit:
		return nil
	case ^ast.Field:
		ast.walk(visitor, n.type)
		return nil
	}
	return visitor
}

bind :: proc(r: ^References, scope: int, symbol: Symbol) {
	if symbol.name == "" || symbol.name == "_" {return}
	id := len(r.symbols)
	append(&r.symbols, symbol)
	ids := r.scopes[scope].bindings[symbol.name]
	append(&ids, id)
	r.scopes[scope].bindings[symbol.name] = ids
}
