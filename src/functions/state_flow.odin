#+private file
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:slice"
import "core:strings"

// ---------------- Project ----------------

import "../state"

// -------------------------------- Types --------------------------------

// ---------------- Package ----------------

// Protected is provenance, live is a write through an existing borrow, and
// shared distinguishes map/slice backing storage from a copied record value.
@(private)
State_Flow :: struct {
	r: ^References,
	diagnostics: ^[dynamic]state.Diagnostic,
	// Nonnegative keys are lexical symbols; keys below -1 retain evaluated
	// values while later operands and cleanup mutate their referenced storage.
	bindings: map[int]State_Access,
	evaluated: map[Expression_Result]int,
	temporary: int,
	replay_arguments: []Replay_Arguments,
	// Lexical bindings that assign through storage instead of rebinding a handle.
	referents: map[int]bool,
	callback_arguments: map[int][]State_Access,
	quiet: bool,
	caller: int,
	exited: bool,
	block_stmts: []^ast.Stmt,
	statement_index: int,
	deferred: [dynamic]Deferred_Statement,
	defer_scope: tokenizer.Pos,
	store_order: [dynamic]tokenizer.Pos,
	// Unlike branch_depth, compile-time alternatives do not weaken stores
	// within their retained availability; only runtime branching does.
	store_depth: int,
	available: Availability,
	transactions: map[State_Location]Active_Transaction,
	optional_stores: bool,
	runtime_optional_stores: bool,
	publication_uncertain: bool,
	nil_guards: [dynamic]int,
	branch_depth, null_return: int,
	counter_history: [dynamic]Counter_Change,
	counter_versions: map[State_Location]^bool,
	counter_conditions: map[^ast.Expr]Counter_Condition,
}

@(private)
State_Access :: struct {
	type: ^ast.Expr,
	zero: Value_Zero,
	condition: ^ast.Expr,
	condition_version: ^bool,
	condition_negated: bool,
	scope: int,
	protected, live, pointer, shared: bool,
	local: bool,
	indirect: bool,
	uncertain, ambient: bool,
	decoded: bool,
	immutable, catalog_type: bool,
	callables: [dynamic]int,
	callback_effects: bit_set[Call_Effect],
	callback_modeled, callback_unknown: bool,
	// A modeled external alternative may return even when joined with saved
	// nonreturning targets; callback_modeled instead describes every alternative.
	callback_returns: bool,
	nil_value: bool,
	published: bool,
	origins: [dynamic]Access_Origin,
	reads: [dynamic]State_Read,
	resource, slot: State_Location,
	addressed: bool,
	slot_protected, slot_published, slot_immutable, slot_local: bool,
	slot_origins: [dynamic]Access_Origin,
	resources: [dynamic]State_Location,
	// Immutable child snapshots survive value copies. The empty key summarizes
	// collection elements; named keys describe record fields.
	fields: map[string]^State_Access,
}

@(private)
// Symbolic locations name formal referents and are replaced by actuals;
// concrete locations must survive even when joined with a formal alternative.
State_Location :: struct {root: ^ast.Expr, path: string, symbolic: bool}


@(private)
Value_Zero :: enum {Unset, Unknown, Zero, Nonzero}


@(private)
Expression_Result :: struct {expression: ^ast.Expr, index: int}

// ---------------- File ----------------

// Cleanup runs at scope exit, but its summary keeps the execution condition
// under which the deferred statement was registered.
Deferred_Statement :: struct {statement: ^ast.Stmt, conditional, weak: bool, order: [dynamic]tokenizer.Pos}

// The recursive widening path lives on the call stack; no heap-backed set is
// needed for the short ancestor chains of one join.
State_Ancestor :: struct {type: ^ast.Expr, parent: ^State_Ancestor}


// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

@(private)
visit_state_flow :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {return visitor}
	check := cast(^State_Flow)visitor.data
	// A halted path still discovers lexical procedure definitions. They may be
	// needed to establish returnability of an earlier forward-local call.
	if check.exited {if _, procedure := node.derived.(^ast.Proc_Lit); !procedure {return visitor}}
	r := check.r
	scope, scoped := r.node_scopes[node]
	// Conditional blocks share their enclosing scope in the reference pass.
	// Their statements are scoped individually and still need inference walks.
	if !scoped {if _, block := node.derived.(^ast.Block_Stmt); !block {return nil}}
	// Evaluated operands belong to one statement, including its nested calls.
	// The binding graph updates referents without replacing captured identities.
	statement := false
	#partial switch _ in node.derived {
	case ^ast.Value_Decl, ^ast.Assign_Stmt, ^ast.Return_Stmt, ^ast.Expr_Stmt,
	     ^ast.If_Stmt, ^ast.When_Stmt, ^ast.For_Stmt, ^ast.Range_Stmt,
	     ^ast.Switch_Stmt, ^ast.Type_Switch_Stmt, ^ast.Case_Clause: statement = true
	}
	previous := check.evaluated
	temporary := min(check.temporary, -1)
	if statement {check.evaluated = nil}
	defer {if statement {
		// Branch joins can retain a captured binding without its expression
		// index. None of this statement's temporaries belong in a loop head.
		for id in check.bindings {if id < temporary {delete_key(&check.bindings, id)}}
		check.evaluated = previous
		check.temporary = temporary
	}}
	#partial switch n in node.derived {
	case ^ast.Proc_Lit:
		// A body needs its working snapshots only until its summary is saved.
		// Nested procedures save into the pass allocator too, never into their
		// enclosing body's scratch arena. This bounds memory by active bodies.
		model := r.semantics
		procedure_id := r.by_literal[n]
		owner := model.owner
		if model.infer && owner < 0 && !model.pending[procedure_id] {return nil}
		if owner < 0 {model.owner = procedure_id; model.pending[procedure_id] = false}
		previous_changed := model.changed
		model.changed = false
		defer {
			if model.infer && model.changed {
				model.pending[model.owner] = true
				for dependent in model.dependents[procedure_id] {model.pending[dependent] = true}
			}
			model.changed = model.changed || previous_changed
			model.owner = owner
		}
		allocator := context.allocator
		transient: mem.Dynamic_Arena
		heap := runtime.heap_allocator()
		mem.dynamic_arena_init(&transient, block_allocator = heap, array_allocator = heap, block_size = SCRATCH_BLOCK_SIZE, out_band_size = SCRATCH_BLOCK_SIZE/4)
		context.allocator = mem.dynamic_arena_allocator(&transient)
		previous_cache := r.read_cache
		cache: Read_Cache
		r.read_cache = &cache
		defer {r.read_cache = previous_cache; delete_read_cache(&cache)}
		if model.infer {model.facts[procedure_id] = clone_semantic_facts(model.facts[procedure_id:procedure_id+1])[0]}
		first_diagnostic := len(check.diagnostics^)
		defer {
			context.allocator = model.allocator
			if model.infer {model.facts[procedure_id] = clone_semantic_facts(model.facts[procedure_id:procedure_id+1])[0]}
			for &diagnostic in check.diagnostics^[first_diagnostic:] {
				diagnostic.message = strings.clone(diagnostic.message)
				diagnostic.rule = strings.clone(diagnostic.rule)
				diagnostic.pos.file = strings.clone(diagnostic.pos.file)
			}
			context.allocator = allocator
			mem.dynamic_arena_destroy(&transient)
		}
		// Procedure declarations do not execute in source order. Keep captures
		// local to this body and resolve globals from their saved initializers.
		before := check^
		defer check^ = before
		check.caller, check.exited, check.deferred = r.by_literal[n], false, nil
		check.transactions = make(map[State_Location]Active_Transaction)
		check.optional_stores, check.nil_guards = false, nil
		check.store_order, check.store_depth = nil, 0
		check.runtime_optional_stores = false
		check.publication_uncertain = false
		check.counter_history = nil
		check.counter_versions = make(map[State_Location]^bool)
		check.counter_conditions = make(map[^ast.Expr]Counter_Condition)
		check.bindings = make(map[int]State_Access)
		check.evaluated, check.replay_arguments, check.temporary = nil, nil, 0
		check.referents = make(map[int]bool)
		check.callback_arguments = nil
		for id, binding in before.bindings {if id >= 0 && !r.symbols[id].top_level {check.bindings[id] = binding}}
		procedure_scope := r.node_scopes[&n.type.node]
		check.available = availability_at(r, procedure_scope, n.pos.offset)
		for fields in ([2]^ast.Field_List{n.type.params, n.type.results}) {
			if fields == nil {continue}
			for field in fields.list {
				for name in field.names {
					if identifier, named := binding_name(name); named {
						ids, certain := lookup(r, identifier, procedure_scope, max(int))
						if certain && len(ids) == 1 {
							access := access_type(r, field.type, procedure_scope, 0)
							if access.immutable {access.protected = false}
							if fields == n.type.params {
								append(&access.origins, Access_Origin{parameter = ids[0]})
								access.resource, access.zero = State_Location{root = name, symbolic = true}, .Unknown
							} else {
								access = fresh_zero_value(check, access, 0)
								access.slot, access.slot_local = State_Location{root = name}, access.local
								if !access.pointer && !access.shared {access.resource.root = name}
							}
							check.bindings[ids[0]] = access
						}
					}
				}
			}
		}
		for provider in r.providers {
			if !provider.is_type || provider.scope != procedure_scope {continue}
			access := access_type(r, provider.expr, provider.scope, 0)
			promote_state_access(check, access, provider.scope, provider.visible_from, 0)
		}
		ast.walk(visitor, n.type); ast.walk(visitor, n.body)
		if model.infer && !check.exited && n.body != nil && !model.facts[procedure_id].normal_return {model.facts[procedure_id].normal_return, model.changed = true, true}
		if !check.exited {for _, active in check.transactions {if active.possible > 0 {report_boundary(check, n.pos, "OWN002", "a transaction opened here has an exit without a matching finish/rollback"); break}}}
		return nil
	case ^ast.Block_Stmt:
		start := len(check.deferred)
		defer_scope := check.defer_scope
		if scoped {check.defer_scope = n.end}
		defer check.defer_scope = defer_scope
		defer {if scoped {resize(&check.deferred, start)}}
		walk_state_statements(check, visitor, n.stmts[:], start if scoped else -1)
		return nil
	case ^ast.Case_Clause:
		defer_scope := check.defer_scope
		check.defer_scope = n.end
		defer check.defer_scope = defer_scope
		start := len(check.deferred)
		defer resize(&check.deferred, start)
		for expression in n.list {ast.walk(visitor, expression)}
		walk_state_statements(check, visitor, n.body[:], start)
		return nil
	case ^ast.Branch_Stmt:
		// Unsupported transfer details do not establish a policy violation.
		return nil
	case ^ast.Defer_Stmt:
		// Scope exit follows ordinary statements; registration order reverses
		// within that exit. Keep the lexical anchor stable across early returns.
		order := slice.clone_to_dynamic(check.store_order[:])
		reversed := n.pos
		reversed.offset = -reversed.offset
		append(&order, check.defer_scope, reversed)
		append(&check.deferred, Deferred_Statement{n.stmt, check.branch_depth > 0 || check.optional_stores, check.store_depth > 0 || check.runtime_optional_stores, order})
		return nil
	case ^ast.Return_Stmt:
		if check.branch_depth > 0 && check.null_return == 0 {check.optional_stores = true}
		if check.store_depth > 0 && check.null_return == 0 {check.runtime_optional_stores = true}
		if r.semantics != nil && check.caller >= 0 && len(n.results) <= 1 {
			facts := r.semantics.facts[check.caller]
			if len(facts.result_types) == 1 {
				result := access_type(r, facts.result_types[0], r.node_scopes[&r.procedures[check.caller].literal.type.node], 0)
				if name, named := binding_name(result.type); named && name == "bool" {
					// A forwarded Boolean keeps the callee's outcome-specific scope
					// effects instead of turning a failed begin into an open scope.
					yes, no: Condition_Branch
					if len(n.results) == 1 {yes, no = walk_state_condition(check, visitor, n.results[0])} else if facts.result_bindings[0] >= 0 {yes, no = state_boolean_condition(check, check.bindings[facts.result_bindings[0]])} else {finish_state_return(check, visitor, n, scope); return nil}
					for branch, i in ([2]Condition_Branch{yes, no}) {
						if !branch.reachable {continue}
						check^ = branch.state
						finish_state_return(check, visitor, n, scope, .Nonzero if i == 0 else .Zero)
					}
					check.exited = true
					return nil
				}
			}
		}
		for result in n.results {ast.walk(visitor, result); capture_expression(check, result, scope)}
		if check.exited {return nil}
		finish_state_return(check, visitor, n, scope)
		return nil
	case ^ast.If_Stmt:
		// A nullable destination's early no-op return does not make writes to
		// its non-nil object optional. Other control flow keeps stores weak.
		null_guard := false
		if condition, compared := unwrap_parens(n.cond).derived.(^ast.Binary_Expr); compared && condition.op.text == "==" && n.else_stmt == nil {
			pointer, other := state_access(check, condition.left, scope, 0), state_access(check, condition.right, scope, 0)
			if pointer.nil_value {pointer, other = other, pointer}
			body := n.body
			if block, wrapped := body.derived.(^ast.Block_Stmt); wrapped && len(block.stmts) == 1 {body = block.stmts[0]}
			if _, exits := body.derived.(^ast.Return_Stmt); exits && other.nil_value && pointer.pointer && len(pointer.origins) == 1 && pointer.origins[0].path == "" {
				append(&check.nil_guards, pointer.origins[0].parameter)
				null_guard = true
			}
		}
		store_depth := check.store_depth
		check.store_depth += 1
		defer check.store_depth = store_depth
		depth, null_return := check.branch_depth, check.null_return
		check.branch_depth += 1
		if null_guard {check.null_return += 1}
		defer {check.branch_depth, check.null_return = depth, null_return}
		ast.walk(visitor, n.init)
		yes, no := walk_state_condition(check, visitor, n.cond)
		if yes.reachable {
			check^ = yes.state
			ast.walk(visitor, n.body)
			yes.state, yes.reachable = check^, !check.exited
		}
		if no.reachable {
			check^ = no.state
			ast.walk(visitor, n.else_stmt)
			no.state, no.reachable = check^, !check.exited
		}
		joined := join_condition_branches(yes, no)
		if joined.reachable {check^ = joined.state}
		check.optional_stores = check.optional_stores || yes.state.optional_stores || no.state.optional_stores
		check.runtime_optional_stores = check.runtime_optional_stores || yes.state.runtime_optional_stores || no.state.runtime_optional_stores
		check.exited = !joined.reachable
		return nil
	case ^ast.When_Stmt:
		statements := [1]^ast.Stmt{&n.node}
		walk_state_statements(check, visitor, statements[:], -1)
		return nil
	case ^ast.For_Stmt:
		depth := check.branch_depth
		store_depth := check.store_depth
		check.store_depth += 1
		defer check.store_depth = store_depth
		check.branch_depth += 1
		defer {check.branch_depth = depth}
		ast.walk(visitor, n.init); ast.walk(visitor, n.cond)
		if check.exited {return nil}
		walk_state_loop(check, visitor, n.body, n.post)
		return nil
	case ^ast.Range_Stmt:
		depth := check.branch_depth
		store_depth := check.store_depth
		check.store_depth += 1
		defer check.store_depth = store_depth
		check.branch_depth += 1
		defer {check.branch_depth = depth}
		ast.walk(visitor, n.init); ast.walk(visitor, n.expr)
		if check.exited {return nil}
		access := state_access(check, n.expr, scope, 0)
		value_index := 0
		if access.type != nil {if _, map_rows := access.type.derived.(^ast.Map_Type); map_rows {value_index = 1}}
		iteration := make(map[int]State_Access)
		for name, i in n.vals {
			value := State_Access{}
			if i == value_index {
				value = element_access(r, access, 0)
				_, reference := name.derived.(^ast.Unary_Expr)
				// Reference iteration aliases the element slot; it does not turn a
				// scalar/record value into a pointer when that value is copied.
				value.live = reference && access.protected
				if !reference {value = copy_state_value(r, value, 0)}
			}
			if ident, ok := binding_name(name); ok {
				body_scope := r.node_scopes[n.body]
				ids, certain := lookup(r, ident, body_scope, n.end.offset)
				if certain && len(ids) == 1 {
					check.bindings[ids[0]] = value
					iteration[ids[0]] = value
					if _, reference := name.derived.(^ast.Unary_Expr); reference {check.referents[ids[0]] = true}
				}
			}
		}
		walk_state_loop(check, visitor, n.body, nil, iteration)
		return nil
	case ^ast.Switch_Stmt, ^ast.Type_Switch_Stmt:
		depth := check.branch_depth
		store_depth := check.store_depth
		check.store_depth += 1
		defer check.store_depth = store_depth
		check.branch_depth += 1
		defer {check.branch_depth = depth}
		body: ^ast.Stmt
		#partial switch statement in node.derived {
		case ^ast.Switch_Stmt: ast.walk(visitor, statement.init); ast.walk(visitor, statement.cond); body = statement.body
		case ^ast.Type_Switch_Stmt: ast.walk(visitor, statement.tag); ast.walk(visitor, statement.expr); body = statement.body
		}
		if check.exited {return nil}
		if block, ok := body.derived.(^ast.Block_Stmt); ok {
			before := copy_state_bindings(check.bindings)
			joined := copy_state_bindings(before)
			available := check.available
			defer {check.available = available}
			transactions := copy_transactions(check.transactions)
			joined_transactions := copy_transactions(transactions)
			if len(block.stmts) >= 8 {
				sw_allocator := context.allocator
				sw_heap := runtime.heap_allocator()
				model := r.semantics
				sw_retained: [2]mem.Dynamic_Arena
				for &arena in sw_retained {mem.dynamic_arena_init(&arena, block_allocator = sw_heap, array_allocator = sw_heap, block_size = SCRATCH_BLOCK_SIZE, out_band_size = SCRATCH_BLOCK_SIZE/4)}
				sw_gen := 0
				for clause in block.stmts {
					sw_work: mem.Dynamic_Arena
					mem.dynamic_arena_init(&sw_work, block_allocator = sw_heap, array_allocator = sw_heap, block_size = SCRATCH_BLOCK_SIZE, out_band_size = SCRATCH_BLOCK_SIZE/4)
					context.allocator = mem.dynamic_arena_allocator(&sw_work)
					prev_cache := r.read_cache
					sw_cache: Read_Cache
					r.read_cache = &sw_cache
					first_diag := len(check.diagnostics^)
					check.available = available
					check.bindings, check.transactions, check.exited = copy_state_bindings(before), copy_transactions(transactions), false
					ast.walk(visitor, clause)
					merge_state_bindings(&joined, check.bindings)
					merge_transactions(&joined_transactions, check.transactions)
					check.bindings, check.transactions = joined, joined_transactions
					sw_gen = 1 - sw_gen
					mem.dynamic_arena_free_all(&sw_retained[sw_gen])
					context.allocator = mem.dynamic_arena_allocator(&sw_retained[sw_gen])
					check^ = clone_state_flow(check^)
					joined, joined_transactions = check.bindings, check.transactions
					if model != nil {
						if model.infer && check.caller >= 0 {model.facts[check.caller] = clone_semantic_facts(model.facts[check.caller:check.caller+1])[0]}
					}
					context.allocator = sw_allocator
					for &diag in check.diagnostics^[first_diag:] {
						diag.message = strings.clone(diag.message)
						diag.rule = strings.clone(diag.rule)
						diag.pos.file = strings.clone(diag.pos.file)
					}
					r.read_cache = prev_cache
					delete_read_cache(&sw_cache)
					mem.dynamic_arena_destroy(&sw_work)
				}
				check.bindings, check.transactions, check.exited = joined, joined_transactions, false
				check^ = clone_state_flow(check^)
				if model != nil {
					if model.infer && check.caller >= 0 {model.facts[check.caller] = clone_semantic_facts(model.facts[check.caller:check.caller+1])[0]}
				}
				for &arena in sw_retained {mem.dynamic_arena_destroy(&arena)}
			} else {
				for clause in block.stmts {
					check.available = available
					check.bindings, check.transactions, check.exited = copy_state_bindings(before), copy_transactions(transactions), false
					ast.walk(visitor, clause)
					merge_state_bindings(&joined, check.bindings)
					merge_transactions(&joined_transactions, check.transactions)
				}
				check.bindings, check.transactions, check.exited = joined, joined_transactions, false
			}
		}
		return nil
	case ^ast.Expr_Stmt:
		ast.walk(visitor, n.expr)
		return nil
	case ^ast.Comp_Lit:
		ast.walk(visitor, n.type)
		compound_state_access(check, n, scope, 0, visitor = visitor)
		return nil
	case ^ast.Value_Decl:
		for value in n.values {ast.walk(visitor, value); capture_expression(check, value, scope)}
		if check.exited {return nil}
		for id in r.declaration_symbols[n] {
			symbol := r.symbols[id]
			i := 0
			for name, index in n.names {if identifier, named := binding_name(name); named && identifier == symbol.name {i = index; break}}
			access := fresh_zero_value(check, access_type(r, symbol.type, symbol.scope, 0), 0)
			if i < len(n.values) {
				value := state_access(check, n.values[i], scope, 0)
				access = fit_state_value(value, access, check)
			} else if len(n.values) == 1 {
				access = fit_state_value(state_access(check, n.values[0], scope, 0, i), access, check)
			}
			access = copy_state_value(r, access, 0)
			if access.resource.root == nil && i < len(n.names) {access.resource.root = n.names[i]}
			if i < len(n.names) {access.slot = State_Location{root = n.names[i]}; access.slot_local = access.local; access.slot_protected, access.slot_published, access.slot_immutable, access.slot_origins = false, false, false, nil}
			check.bindings[id] = access
			if n.is_using {promote_state_access(check, access, scope, n.end.offset, 0)}
		}
		return nil
	case ^ast.Assign_Stmt:
		values := make([]State_Access, max(len(n.rhs), len(n.lhs)))
		for value, i in n.rhs {
			values[i] = state_access(check, value, scope, 0)
			ast.walk(visitor, value)
			if check.exited {return nil}
			// Call outcome proofs exist after evaluation; preserve the original
			// referent snapshot while attaching only this transient correlation.
			evaluated := state_access(check, value, scope, 0)
			if _, called := unwrap_parens(value).derived.(^ast.Call_Expr); called {values[i] = evaluated}
			values[i].condition, values[i].condition_version, values[i].condition_negated = evaluated.condition, evaluated.condition_version, evaluated.condition_negated
		}
		if len(n.rhs) == 1 {for i in 1..<len(values) {values[i] = state_access(check, n.rhs[0], scope, 0, i)}}
		for left in n.lhs {
			ids, certain := expression_symbols(r, left, scope, left.pos.offset)
			if certain && len(ids) == 1 && r.symbols[ids[0]].top_level && r.symbols[ids[0]].mutable && !has_attribute(r.symbols[ids[0]].decl, "rodata") {record_effect(check, .Ambient, left.pos)}
		}
		for left in n.lhs {
			if ident, plain := unwrap_parens(left).derived.(^ast.Ident); plain {
				ids, certain := lookup(r, ident.name, scope, left.pos.offset)
				if !certain || len(ids) != 1 || !check.referents[ids[0]] {
					if n.op.text != "=" {ast.walk(visitor, left)}
					continue
				}
			}
			// A projected field can have its own identity. Visit its base as well
			// so actual effects through the protected container stay visible.
			if n.op.text == "=" {
				#partial switch target in unwrap_parens(left).derived {
				case ^ast.Selector_Expr: ast.walk(visitor, target.expr)
				case ^ast.Deref_Expr: ast.walk(visitor, target.expr)
				case: ast.walk(visitor, left)
				}
			} else {ast.walk(visitor, left)}
			if check.exited {return nil}
			access := state_access(check, left, scope, 0)
			if n.op.text == "=" {access = write_slot_access(access)}
			counter := false
			if literal, ok := n.rhs[0].derived.(^ast.Basic_Lit); len(n.rhs) == 1 && ok && literal.tok.text == "1" && (n.op.text == "+=" || n.op.text == "-=") {
				delta := 1 if n.op.text == "+=" else -1
				record_counter(check, access, delta)
				if r.semantics != nil && r.semantics.contracts && check.caller >= 0 && r.files[r.procedures[check.caller].file].has_role && r.files[r.procedures[check.caller].file].role == .Engine {
					facts := r.semantics.facts[check.caller]
					counter_values := make([]State_Access, len(facts.parameters))
					for parameter, i in facts.parameters {counter_values[i] = check.bindings[parameter]}
					changes := make([dynamic]Counter_Change)
					for origin in access.origins {append(&changes, Counter_Change{origin, delta})}
					operations := counter_operations(r, changes[:], facts.parameters[:], counter_values, boundaries = false)
					counter = len(operations) > 0
					apply_counters(check, operations[:])
				}
			}
			if n.op.text == "=" && len(n.rhs) == 1 && values[0].zero == .Zero {reset_owned_counters(check, access)}
			owner_copy := false
			if r.semantics != nil && r.semantics.infer && check.caller >= 0 {
				file := r.files[r.procedures[check.caller].file]
				if file.has_role && file.role == .Engine {
					for origin in access.origins {
						parts := strings.split_n(origin.path, ".[]", 2)
						if len(parts) < 2 {continue}
						container := project_access(r, check.bindings[origin.parameter], parts[0])
						if container.type != nil && !r.relation_containers[container.type] {r.relation_containers[container.type] = true; r.semantics.changed = true}
					}
				}
			}
			if r.semantics != nil && r.semantics.infer && check.caller >= 0 && len(n.rhs) == 1 {
				facts := &r.semantics.facts[check.caller]
				for right in values[0].origins {
					for origin in access.origins {
						if right.parameter == origin.parameter && right.path != "" && right.path != origin.path && !slice.contains(facts.snapshots[:], right) {append(&facts.snapshots, right); r.semantics.changed = true}
						caller_file := r.files[r.procedures[check.caller].file]
						if caller_file.has_role && caller_file.role == .Engine && access.protected && values[0].protected && right.parameter != origin.parameter && right.path == "" && origin.path == "" {
							owner_copy = true
							// Only an adjacent clear proves transfer without replaying aliases.
							// Intervening assignments can change which source is cleared.
							clears_source := false
							if check.statement_index+1 < len(check.block_stmts) {
								statement := check.block_stmts[check.statement_index+1]
								assignment, plain := statement.derived.(^ast.Assign_Stmt)
								if plain && assignment.op.text == "=" && len(assignment.rhs) == 1 && len(assignment.lhs) == 1 {
									empty, literal := assignment.rhs[0].derived.(^ast.Comp_Lit)
									if literal && len(empty.elems) == 0 {
										cleared := state_access(check, assignment.lhs[0], scope, 0)
										clears_source = slice.contains(cleared.origins[:], right)
									}
								}
							}
							if !slice.contains(facts.copies[:], origin.parameter) {append(&facts.copies, origin.parameter); r.semantics.changed = true}
							// An explicit straight-line clear identifies a transfer. Its
							// leading assertions establish preconditions; type names and
							// unrelated Boolean/revision comparisons establish none.
							body, block := r.procedures[check.caller].literal.body.derived.(^ast.Block_Stmt)
							if clears_source && block && check.branch_depth == 0 && len(body.stmts) == len(check.block_stmts) && body.stmts[check.statement_index] == check.block_stmts[check.statement_index] {
								entry := State_Flow{r = r, caller = check.caller, bindings = make(map[int]State_Access)}
								for parameter in facts.parameters {
									symbol := r.symbols[parameter]
									value := access_type(r, symbol.type, symbol.scope, 0)
									append(&value.origins, Access_Origin{parameter = parameter})
									entry.bindings[parameter] = value
								}
								for statement in body.stmts[:check.statement_index] {
									expression, plain := statement.derived.(^ast.Expr_Stmt)
									if !plain {break}
									call, called := unwrap_parens(expression.expr).derived.(^ast.Call_Expr)
									if !called || len(call.args) != 1 {break}
									name, named := binding_name(call.expr)
									ids, certain := expression_symbols(r, call.expr, scope, call.pos.offset)
									if !named || name != "assert" || !certain || len(ids) != 0 {break}
									if !record_publication_checks(&entry, call.args[0], origin) {break}
								}
							}
						}
					}
				}

			}
			record_access(check, access, .Write, enforce_transaction = !counter && !owner_copy, slot = n.op.text == "=")
			if !check.quiet && access.protected && access.live && !working_assignment(check, access) {
				report_write(check, access, left.pos, "write targets protected FRP state; use its engine or an independent working copy", !access.immutable)
			}
		}
		for left, i in n.lhs {
			if i >= len(values) {continue}
			if n.op.text != "=" {values[i].zero = .Unknown}
			ident, plain := unwrap_parens(left).derived.(^ast.Ident)
			referent := false
			if plain {ids, certain := lookup(r, ident.name, scope, left.pos.offset); referent = certain && len(ids) == 1 && check.referents[ids[0]]}
			if !plain || referent {
				target := state_access(check, left, scope, 0)
				values[i] = fit_state_value(values[i], target, check)
				target.origins, target.published = target.slot_origins, target.slot_published
				if target.live {
					retained := copy_state_value(r, values[i], 0)
					initializes := retained.resource.root != nil && len(retained.origins) == 0 && !retained.protected
					if i < len(n.rhs) {if literal, empty := unwrap_parens(n.rhs[i]).derived.(^ast.Comp_Lit); empty && len(literal.elems) == 0 {initializes = true}}
					record_store(check, target, retained, initializes, false, n.pos)
				}
				assign_state_value(check, left, values[i], scope, 0)
				continue
			}
			ids, certain := lookup(r, ident.name, scope, left.pos.offset)
			if !certain || len(ids) != 1 {continue}
			id := ids[0]
			previous := state_access(check, left, scope, 0)
			replacement := copy_state_value(r, fit_state_value(values[i], previous, check), 0)
			replacement = fit_slot(replacement, previous)
			check.bindings[id] = replacement
		}
		return nil
	case ^ast.Using_Stmt:
		for expression in n.list {
			access := state_access(check, expression, scope, 0)
			promote_state_access(check, access, scope, n.end.offset, 0)
		}
	case ^ast.Binary_Expr:
		if n.op.text != "&&" && n.op.text != "||" {return visitor}
		yes, no := walk_state_condition(check, visitor, &n.node)
		joined := join_condition_branches(yes, no)
		if joined.reachable {check^ = joined.state}
		check.exited = !joined.reachable
		return nil
	case ^ast.Ternary_If_Expr, ^ast.Ternary_When_Expr:
		condition, left, right: ^ast.Expr
		compile_time := false
		#partial switch expression in node.derived {
		case ^ast.Ternary_If_Expr: condition, left, right = expression.cond, expression.x, expression.y
		case ^ast.Ternary_When_Expr: condition, left, right, compile_time = expression.cond, expression.x, expression.y, true
		}
		yes, no: Condition_Branch
		if compile_time {
			guard := availability_expression(condition, scope)
			available := check.available if check.available.supplied else availability_all()
			yes.state, no.state = check^, snapshot_state_flow(check)
			yes.state.available, no.state.available = availability_and(available, guard), availability_and(available, availability_not(guard))
			yes.reachable, no.reachable = availability_possible(r, yes.state.available), availability_possible(r, no.state.available)
		} else {yes, no = walk_state_condition(check, visitor, condition)}
		depth, store_depth := check.branch_depth, check.store_depth
		defer {check.branch_depth, check.store_depth = depth, store_depth}
		joined: Condition_Branch
		for branch, i in ([2]Condition_Branch{yes, no}) {
			if !branch.reachable {continue}
			check^ = branch.state
			if yes.reachable && no.reachable {
				check.branch_depth += 1
				if !compile_time {check.store_depth += 1}
			}
			ast.walk(visitor, left if i == 0 else right)
			joined = join_condition_branches(joined, Condition_Branch{check^, !check.exited})
		}
		if joined.reachable {check^ = joined.state}
		check.exited = !joined.reachable
		return nil
	case ^ast.Call_Expr:
		call := n
		effects: bit_set[Call_Effect]
		modeled, mutates, destroys, pure_builtin: bool
		// Standard-library models are explicit assumptions, not import-wide
		// permission for unknown calls and callbacks.
		operation := call_operation(r, call, scope)
		classify: {
			if operation.known {modeled, mutates, destroys = true, operation.write != "" && !operation.destroys, operation.destroys; break classify}
			expression := call.expr
			if expression == nil {break classify}
			callee := unwrap_parens(expression)
			if _, directive := callee.derived.(^ast.Basic_Directive); directive {modeled = true; break classify}
			if ident, ok := callee.derived.(^ast.Ident); ok {
				ids, certain := lookup(r, ident.name, scope, expression.pos.offset)
				if certain && len(ids) == 0 {
					if slice.contains([]string{"make", "new", "len", "cap", "size_of", "align_of", "offset_of", "type_of", "type_info_of", "typeid_of", "assert", "panic", "unreachable", "min", "max", "abs", "clamp", "complex", "real", "imag", "quaternion", "conj", "swizzle", "expand_values", "expand_to_tuple", "soa_zip", "soa_unzip", "free_all", "raw_data", "Maybe", "typeid"}, ident.name) {modeled, pure_builtin = true, ident.name != "free_all" && ident.name != "make" && ident.name != "new"; break classify}
				}
			}
			if expression_kind(r, callee, scope, 0) == "Types" {modeled = true; break classify}
			path, member := external_target(r, expression, scope)
			if path == "" {break classify}
			// Namespace membership alone is not evidence of an external effect.
			if path == "core:odin/tokenizer" && member == "default_error_handler" {effects, modeled = {.IO}, true; break classify}
			if path == "core:fmt" && slice.contains([]string{"print", "printf", "println", "eprint", "eprintf", "eprintln"}, member) {effects, modeled = {.IO}, true; break classify}
			if path == "core:time" && slice.contains([]string{"now", "sleep", "tick_now", "tick_since", "since", "until"}, member) {effects, modeled = {.Clock}, true; break classify}
			if path == "core:path/filepath" && slice.contains([]string{"abs", "abs_from_cwd", "eval_symlinks"}, member) {effects, modeled = {.Ambient}, true; break classify}
			if path == "core:time/timezone" && member == "region_load" {effects, modeled = {.IO}, true; break classify}
			if path == "vendor:raylib" {
				if strings.has_prefix(member, "Draw") || strings.has_prefix(member, "MeasureText") || strings.has_prefix(member, "GetGlyph") {effects, modeled = {.Rendering}, true; break classify}
				if slice.contains([]string{"GetMousePosition", "GetMouseX", "GetMouseY", "GetMouseDelta", "GetMouseWheelMove", "GetMouseWheelMoveV", "IsMouseButtonDown", "IsMouseButtonPressed", "IsMouseButtonReleased", "IsKeyDown", "IsKeyPressed", "IsKeyReleased", "GetKeyPressed", "GetCharPressed", "GetScreenWidth", "GetScreenHeight", "GetTime", "GetFrameTime", "WindowShouldClose", "InitWindow", "CloseWindow", "LoadTexture", "LoadFont", "LoadShader"}, member) {effects, modeled = {.IO}, true; break classify}
			}
			if path == "core:os" && slice.contains([]string{"exists", "get_env", "set_env", "unset_env", "get_environ", "get_working_directory", "set_working_directory", "open", "create", "close", "read", "write", "read_entire_file", "write_entire_file", "remove", "remove_all", "rename", "make_directory", "make_directory_all", "make_directory_temp"}, member) {effects, modeled = {.System_IO, .File_IO}, true; break classify}
			if path == "core:net" && slice.contains([]string{"dial_tcp", "dial_udp", "listen_tcp", "listen_udp", "accept_tcp", "recv_tcp", "send_tcp", "recv_udp", "send_udp", "close", "enumerate_interfaces", "lookup_ip"}, member) {effects, modeled = {.System_IO, .Network_IO}, true; break classify}
			if path == "core:thread" && slice.contains([]string{"start", "create_and_start", "join", "destroy"}, member) {effects, modeled = {.IO}, true; break classify}
			if path == "core:sys/posix" && slice.contains([]string{"pthread_create", "pthread_join", "open", "close", "read", "write", "socket", "connect", "bind", "listen", "accept", "send", "recv", "poll"}, member) {effects, modeled = {.IO}, true; break classify}
			if path == "core:math/rand" || strings.has_prefix(path, "core:math/rand/") {break classify}
			for prefix in ([]string{"core:math", "core:strings", "core:strconv", "core:unicode", "core:odin/", "core:mem", "core:reflect", "core:container/", "core:sort", "base:runtime"}) {
				if path == prefix || strings.has_prefix(path, strings.concatenate({prefix, "/"})) || strings.has_suffix(prefix, "/") && strings.has_prefix(path, prefix) {modeled = true; break classify}
			}
			break classify
		}
		targets, certain := call_procedures(r, call.expr, scope)
		namespace, member := external_target(r, call.expr, scope)
		unmodeled_external := !modeled && len(targets) == 0 &&
			(strings.has_prefix(namespace, "core:") || strings.has_prefix(namespace, "base:") || strings.has_prefix(namespace, "vendor:"))
		indirect_callee: State_Access
		indirect_callee_call := !modeled && !unmodeled_external && (len(targets) == 0 || !certain)
		if indirect_callee_call {
			indirect_callee = state_access(check, call.expr, scope, 0)
			if len(indirect_callee.callables) > 0 {targets, certain = indirect_callee.callables, true}
		}
		// Numeric facts are not mutation summaries. Once a call can change
		// storage, later publication checks cannot rely on the old scalar values.
		// Preserve call-entry evidence until this call's own checks have run.
		readonly := check.publication_uncertain || pure_builtin || operation.known && operation.write == "" && !operation.rng
		if !check.publication_uncertain && !mutates && !destroys && !operation.rng && r.semantics != nil && certain && len(targets) > 0 {
			readonly = true
			for target in targets {
				facts := callee_facts(check, target)
				if r.procedures[target].literal.body == nil || facts.effects != {} {readonly = false}
				for access in facts.accesses {if access.kind == .Write || access.kind == .Destroy || access.kind == .Invoke {readonly = false}}
			}
		}
		defer {if !readonly {check.publication_uncertain = true}}
		ast.walk(visitor, call.expr)
		capture_expression(check, call.expr, scope)
		for argument in call.args {
			value := argument
			if field, named := argument.derived.(^ast.Field_Value); named {value = field.value}
			ast.walk(visitor, value)
			capture_expression(check, value, scope)
		}
		if check.exited {return nil}
		capture_expression(check, &call.node, scope)
		if operation.rng {
			_, rng_member := external_target(r, call.expr, scope)
			parameter := "state" if rng_member == "default_random_generator" else "gen"
			argument := operation_argument(operation, call, parameter)
			value := state_access(check, argument, scope, 0)
			if argument == nil || value.ambient || value.nil_value {record_effect(check, .Ambient, call.pos)} else if parameter == "gen" {
				data := field_access(r, value, "data", 0)
				if rng_member != "query_info" {
					record_access(check, data, .Write, enforce_transaction = true)
					if data.protected && (data.pointer || data.shared || data.live) {report_write(check, data, call.pos, "random generation mutates borrowed generator state", !data.immutable)}
				}
				apply_callback(check, field_access(r, value, "procedure", 0), {data, {}, {}}, call.pos)
			}
		}
		for effect in effects {record_effect(check, effect, call.pos)}
		if unmodeled_external {record_effect(check, .Unknown, call.pos)}
		if indirect_callee_call {
			arguments := make([]State_Access, len(call.args))
			for argument, i in call.args {arguments[i] = state_access(check, argument, scope, 0)}
			// Concrete targets use the ordinary call path below. Keep symbolic,
			// modeled and unknown alternatives as well, after argument effects.
			indirect_callee.callback_modeled = indirect_callee.callback_modeled || len(indirect_callee.callables) > 0
			indirect_callee.callables = nil
			apply_callback(check, indirect_callee, arguments, call.pos, required = true)
		}
		if modeled {
			if namespace == "core:encoding/json" && slice.contains([]string{"parse_value", "parse", "parse_string", "parse_bytes"}, member) {
				allocator := state_access(check, operation_argument(operation, call, "allocator"), scope, 0)
				if member == "parse_value" {allocator = field_access(r, state_access(check, operation_argument(operation, call, "p"), scope, 0), "allocator", 0)}
				apply_callback(check, field_access(r, allocator, "procedure", 0), {field_access(r, allocator, "data", 0), {}, {}, {}, {}, {}, {}}, call.pos)
			}
			// Tokenizer initialization may call its error handler immediately;
			// later scans use the handler saved in the same lexer object.
			if namespace == "core:odin/tokenizer" {
				if member == "init" {
					destination := state_access(check, operation_argument(operation, call, "t"), scope, 0)
					handler := State_Access{callback_effects = {.IO}, callback_modeled = true}
					if argument := operation_argument(operation, call, "err"); argument != nil {handler = state_access(check, argument, scope, 0)}
					if handler.zero == .Zero {handler.nil_value, handler.callback_unknown = true, false}
					record_store(check, project_access(r, destination, "err"), handler, initializes = true, site = call.pos)
					store_bindings(check, destination, {"err"}, handler)
					apply_callback(check, handler, nil, call.pos)
				} else if operation.write == "t" {
					lexer := state_access(check, operation_argument(operation, call, "t"), scope, 0)
					apply_callback(check, field_access(r, lexer, "err", 0), nil, call.pos)
				}
			}
			if namespace == "core:odin/ast" && member == "walk" && len(call.args) > 0 {
				visitor_value := state_access(check, call.args[0], scope, 0)
				callback := field_access(r, visitor_value, "visit", 0)
				apply_callback(check, callback, {visitor_value, {}}, call.pos)
			} else if namespace == "core:odin/parser" && member == "parse_file" && len(call.args) > 0 {
				parser_value := state_access(check, call.args[0], scope, 0)
				for field in ([]string{"err", "warn"}) {apply_callback(check, field_access(r, parser_value, field, 0), nil, call.pos)}
			} else if namespace == "core:slice" && (member == "sort_by" || member == "stable_sort_by") {
				sequence := state_access(check, operation_argument(operation, call, operation.write), scope, 0)
				row := copy_state_value(r, element_access(r, sequence, 0), 0)
				callback := state_access(check, operation_argument(operation, call, "less|value"), scope, 0)
				apply_callback(check, callback, {row, row}, call.pos)
			}
		}
		if (mutates || destroys) && len(call.args) > 0 {
			argument := operation_argument(operation, call, operation.write)
			access := state_access(check, argument, scope, 0)
			// Builtin container mutators change the referenced backing storage,
			// rather than merely replacing a private descriptor slot.
			if mutates && namespace == "" && access.pointer && access.shared {
				if referent, known := access.fields["^"]; known {access = referent^} else {access = access_path(check.r, access, "^"); access.pointer = false}
			}
			record_access(check, access, .Destroy if destroys else .Write, enforce_transaction = true)
			if mutates && r.semantics != nil && r.semantics.infer && check.caller >= 0 && access.type != nil {
				file := r.files[r.procedures[check.caller].file]
				if file.has_role && file.role == .Engine && !r.relation_containers[access.type] {r.relation_containers[access.type] = true; r.semantics.changed = true}
			}
			if access.protected && (access.shared || access.live || access.pointer) {
				report_write(check, access, call.pos, "writing or destroying protected state requires its engine or a private working copy", !access.immutable)
			}
		}
		// Partial decode writes retain previous alternatives on error.
		if operation.decode {
			destination := state_access(check, operation_argument(operation, call, operation.write), scope, 0)
			value := decoded_output(check.r, destination, &call.node)
			record_store(check, destination, value, conditional = true, site = call.pos)
			store_bindings(check, destination, nil, value, true)
		}
		// Invoke known callbacks for their state writes and effects. Spawning work
		// does not create a generic ownership transfer or consume its arguments.
		if namespace == "core:thread" && member == "create_and_start" && len(call.args) > 0 {apply_callback(check, state_access(check, call.args[0], scope, 0), nil, call.pos)}
		if r.semantics == nil {return nil}
		counter_condition := Counter_Condition{}
		if len(targets) == 1 && certain && (!indirect_callee_call || len(indirect_callee.origins) == 0 && !indirect_callee.callback_unknown && indirect_callee.callback_effects == {}) {
			facts := callee_facts(check, targets[0])
			if len(facts.result_types) == 1 {
				result := access_type(r, facts.result_types[0], r.node_scopes[&r.procedures[targets[0]].literal.type.node], 0)
				if name, named := binding_name(result.type); named && name == "bool" {
					arguments := call_arguments(r.procedures[targets[0]].literal, call)
					counter_condition = Counter_Condition{target = targets[0], known = true, refine = !facts.unknown_boolean_return,
						history = slice.clone_to_dynamic(check.counter_history[:]), transactions = copy_transactions(check.transactions)}
					values := make([]State_Access, len(arguments))
					for argument, i in arguments {values[i] = state_access(check, argument, scope, 0)}
					counter_condition.effects = mapped_counter_effects(check, facts.counters[:], facts.parameters[:], values)
					counter_condition.outcomes[0] = mapped_counter_effects(check, facts.true_counters[:], facts.parameters[:], values)
					counter_condition.outcomes[1] = mapped_counter_effects(check, facts.false_counters[:], facts.parameters[:], values)
					for invocation in facts.invocations {
						index, found := slice.linear_search(facts.parameters[:], invocation.origin.parameter)
						if !found || index >= len(values) {counter_condition.refine = false; continue}
						callback := project_access(check.r, values[index], invocation.origin.path)
						actuals := make([]State_Access, len(invocation.arguments))
						for value, i in invocation.arguments {actuals[i] = instantiate_access(check, value, facts.parameters[:], arguments[:], scope)}
						returned := len(facts.returned_predicates) == 1 && !facts.unrelated_boolean_return
						predicate: Returned_Predicate
						if returned {
							predicate = facts.returned_predicates[0]
							returned = predicate.origin == invocation.origin && predicate.call.pos == invocation.pos
						}
						if len(callback.origins) == 1 && len(callback.callables) == 0 && !callback.callback_unknown {
							if returned {counter_condition.predicate = Returned_Predicate{callback.origins[0], &call.node, predicate.negated}}
							counter_condition.refine = false
							continue
						}
						if len(callback.callables) != 1 || callback.callback_unknown || len(callback.origins) > 0 || callback.callback_effects != {} {counter_condition.refine = false; continue}
						callback_facts := callee_facts(check, callback.callables[0])
						if callback_facts.unknown_boolean_return || len(callback_facts.invocations) > 0 {counter_condition.refine = false; continue}
						all := mapped_counter_effects(check, callback_facts.counters[:], callback_facts.parameters[:], actuals)
						append(&counter_condition.effects, ..all[:])
						for _, i in counter_condition.outcomes {
							changes := all
							if returned {
								observed := callback_facts.true_counters[:] if (i == 0) != predicate.negated else callback_facts.false_counters[:]
								changes = mapped_counter_effects(check, observed, callback_facts.parameters[:], actuals)
							}
							append(&counter_condition.outcomes[i], ..changes[:])
						}
					}
				}
			}
		} else if indirect_callee_call && len(indirect_callee.origins) == 1 && !indirect_callee.callback_unknown && len(targets) == 0 {
			counter_condition.known, counter_condition.target = true, -1
			counter_condition.predicate = Returned_Predicate{indirect_callee.origins[0], &call.node, false}
		}

		may_return := !certain || len(targets) == 0 || indirect_callee.callback_unknown || indirect_callee.callback_returns || len(indirect_callee.origins) > 0 || indirect_callee.callback_effects != {}
		for target in targets {
			procedure := r.procedures[target]
			facts := callee_facts(check, target)
			returns := facts.normal_return || procedure.literal.body == nil
			if procedure.literal.body == nil {record_effect(check, .Unknown, call.pos)}
			for effect in facts.effects {record_effect(check, effect, call.pos)}
			arguments := call_arguments(procedure.literal, call)
			call_values := make([]State_Access, len(arguments))
			for argument, i in arguments {call_values[i] = state_access(check, argument, scope, 0)}
			apply_procedure_counters(check, facts, call_values, target)
			for requirement in facts.accesses {
				index, found := slice.linear_search(facts.parameters[:], requirement.origin.parameter)
				if !found || index >= len(arguments) || arguments[index] == nil {continue}
				argument := arguments[index]
				access := project_access(r, state_access(check, argument, scope, 0), requirement.origin.path)
				kind := requirement.kind
				if kind == .Invoke {continue}
				apply_parameter_access(check, access, requirement, call.pos, procedure.name, index+1)
			}
			if len(targets) == 1 {
				for condition in facts.publications {
					destination := publication_argument(r, condition.destination, .Unknown, facts.parameters[:], call_values)
					left := publication_argument(r, condition.left, condition.left_zero, facts.parameters[:], call_values, arguments[:], check.publication_uncertain)
					right := publication_argument(r, condition.right, condition.right_zero, facts.parameters[:], call_values, arguments[:], check.publication_uncertain)
					if check.quiet || !destination.published || !destination.protected {continue}
					if (left.zero != .Zero && left.zero != .Nonzero) || (right.zero != .Zero && right.zero != .Nonzero) {continue}
					// Nonzero integers need not be equal; neither pointer identity nor an
					// arbitrary revision value is inferred from zero/nonzero evidence.
					if left.zero == .Nonzero && right.zero == .Nonzero {continue}
					if (left.zero == right.zero) != condition.equal {
						expression := condition.expression
						text := r.files[procedure.file].file.src[expression.pos.offset:expression.end.offset]
						message := fmt.aprintf("live-state publication via %s contradicts precondition %q must be %t at %s(%d:%d)", procedure.name, text, condition.truth, expression.pos.file, expression.pos.line, expression.pos.column)
						report_boundary(check, call.pos, "OWN005", message)
					}
				}
			}
			result_ids := make([]int, len(facts.results) if len(targets) == 1 else 0)
			for _, i in result_ids {result_ids[i] = check.evaluated[Expression_Result{&call.node, i}]}
			completed := apply_stores(check, facts, call_values, call.pos, &call.node, len(targets) > 1, result_ids)
			returns = returns && completed
			may_return = may_return || returns
		}
		if !may_return {check.exited = true; return nil}
		if counter_condition.known {
			counter_condition.version = new(bool, check.r.semantics.allocator)
			counter_condition.versions = make(map[State_Location]^bool)
			for effect in counter_condition.effects {
				if effect.access.resource.root != nil {counter_condition.versions[effect.access.resource] = check.counter_versions[effect.access.resource]}
				for resource in effect.access.resources {counter_condition.versions[resource] = check.counter_versions[resource]}
			}
			check.counter_conditions[&call.node] = counter_condition
			if id, saved := check.evaluated[Expression_Result{&call.node, 0}]; saved {
				value := check.bindings[id]
				value.condition, value.condition_version = &call.node, counter_condition.version
				check.bindings[id] = value
			}
		}
		return nil
	case ^ast.Ident, ^ast.Selector_Expr, ^ast.Deref_Expr, ^ast.Index_Expr:
		ids, certain := expression_symbols(r, cast(^ast.Expr)node, scope, node.pos.offset)
		if certain && len(ids) == 1 && r.symbols[ids[0]].top_level && r.symbols[ids[0]].mutable && !has_attribute(r.symbols[ids[0]].decl, "rodata") {record_effect(check, .Ambient, node.pos)}
		access := state_access(check, cast(^ast.Expr)node, scope, 0)
		if access.ambient {record_effect(check, .Ambient, node.pos)}
	}
	return visitor
}

@(private)
state_access :: proc(check: ^State_Flow, expression: ^ast.Expr, scope, depth: int, result_index := 0, expected := State_Access{}) -> (access: State_Access) {
	if expression == nil || depth > len(check.r.symbols)+len(check.r.scopes) {return}
	r := check.r
	scope := scope
	expression := expression
	expression = unwrap_parens(expression)
	if id, saved := check.evaluated[Expression_Result{expression, result_index}]; saved {return check.bindings[id]}
	access.zero = .Unknown
	if actual_scope, mapped := r.node_scopes[expression]; mapped {scope = actual_scope}
	#partial switch n in expression.derived {
	case ^ast.Basic_Lit:
		if text, string_value := metadata_string(n.tok.text); string_value {access.zero = .Zero if text == "" else .Nonzero} else if n.tok.text == "0" {access.zero = .Zero} else if n.tok.text == "1" {access.zero = .Nonzero}
		return
	case ^ast.Ident, ^ast.Selector_Expr:
		ids, certain := expression_symbols(r, expression, scope, expression.pos.offset)
		if field, selected := expression.derived.(^ast.Selector_Expr); selected {
			if _, implicit := field.expr.derived.(^ast.Implicit); implicit {
				if field.field.name == "random_generator" {access.ambient = true; return}
			}
		}
		if name, named := binding_name(expression); named && name == "nil" && certain && len(ids) == 0 {access.nil_value, access.zero = true, .Zero; return}
		if name, named := binding_name(expression); named && certain && len(ids) == 0 && (name == "true" || name == "false") {access.zero = .Nonzero if name == "true" else .Zero; return}
		if certain && len(ids) == 1 {
			id := ids[0]
			if binding, set := check.bindings[id]; set {return refresh_address(check, binding)}
			symbol := r.symbols[id]
			access = access_type(r, symbol.type, symbol.scope, depth+1)
			access.resource.root = symbol.type
			if symbol.value != nil && (symbol.top_level || access.type == nil) {
				value := state_access(check, symbol.value, symbol.scope, depth+1)
				access = copy_state_value(r, fit_state_value(value, access, check, depth+1), depth+1)
			}
			if symbol.top_level && symbol.mutable {access.live, access.published, access.slot_published, access.zero = true, true, true, .Unknown}
			// Global catalog storage is published data. The datatype alone
			// does not restrict private instances created inside an operation.
			if symbol.decl != nil && has_attribute(symbol.decl, "rodata") || symbol.top_level && symbol.mutable && access.catalog_type {
				access.protected, access.immutable, access.published = true, true, true
			}
			if symbol.top_level {access.slot_protected, access.slot_immutable, access.slot_local = access.protected, access.immutable, access.local}
			if symbol.top_level && r.files[symbol.file].has_role && r.files[symbol.file].role == .Engine {
				access.protected, access.live = true, true
			}
			return
		}
		if field, ok := expression.derived.(^ast.Selector_Expr); ok {
			library_path, library_member := external_target(r, expression, scope)
			if library_path == "core:odin/tokenizer" && library_member == "default_error_handler" {return State_Access{callback_effects = {.IO}, callback_modeled = true}}
			// An unresolved exported value can be a callback. Preserve that
			// unknown alternative before a join with saved procedure targets.
			if library_path != "" {return State_Access{callback_unknown = true}}
			base := state_access(check, field.expr, scope, depth+1)
			if base.addressed {
				current, loaded := load_addresses(check, base)
				if loaded {current.pointer, current.resource, current.resources, current.slot = true, base.resource, base.resources, {}; base = current}
			}
			return read_state_access(check, refresh_address(check, field_access(r, base, field.field.name, depth+1)), expression.pos)
		}
	case ^ast.Index_Expr:
		base := state_access(check, n.expr, scope, depth+1)
		access = element_access(r, base, depth+1)
		access.live = base.protected && (base.pointer || base.live || base.shared)
		access.protected = access.protected || base.protected
		access.indirect = access.indirect || base.shared || base.indirect
	case ^ast.Slice_Expr:
		access = state_access(check, n.expr, scope, depth+1)
		access.shared = true
	case ^ast.Unary_Expr:
		if n.op.text == "!" {
			access = state_access(check, n.expr, scope, depth+1)
			if access.condition != nil {access.condition_negated = !access.condition_negated}
			if access.zero == .Zero {access.zero = .Nonzero} else if access.zero == .Nonzero {access.zero = .Zero}
			return
		}
		if n.op.text == "&" {
			access = state_access(check, n.expr, scope, depth+1)
			value := access
			if access.slot.root != nil {access.resource, access.resources = access.slot, nil}
			access.protected, access.published, access.immutable = access.slot_protected, access.slot_published, access.slot_immutable
			access.origins = access.slot_origins
			access.fields = make(map[string]^State_Access)
			for name, child in value.fields {access.fields[name] = child}
			access.fields["^"] = new_clone(value)
			access.pointer, access.live, access.addressed, access.slot = true, false, true, {}
			// An embedded local owner keeps its role even in a non-local session slot.
			access.zero, access.local, access.nil_value = .Nonzero, value.local || value.slot_local, false
		}
	case ^ast.Deref_Expr:
		access = state_access(check, n.expr, scope, depth+1)
		if value, loaded := load_addresses(check, access); loaded {return value}
		access.slot, access.slot_protected, access.slot_published, access.slot_immutable = access.resource, access.protected, access.published, access.immutable
		access.slot_origins, access.slot_local = access.origins, access.local
		access.live, access.pointer = access.pointer, false
	case ^ast.Auto_Cast:
		return state_access(check, n.expr, scope, depth+1, expected = expected)
	case ^ast.Type_Cast:
		access = state_access(check, n.expr, scope, depth+1)
		if known_callback_type(r, n.type, scope) {
			if access.zero == .Zero {access.nil_value, access.callback_unknown = true, false} else if len(access.callables) == 0 && len(access.origins) == 0 && access.callback_effects == {} && !access.callback_modeled && !access.nil_value {access.callback_unknown = true}
		}
		return
	case ^ast.Ternary_If_Expr:
		access = state_access(check, n.x, scope, depth+1, expected = expected)
		other := state_access(check, n.y, scope, depth+1, expected = expected)
		access, _ = join_state_access(access, other)
		return
	case ^ast.Ternary_When_Expr:
		condition, known := literal_condition(n.cond)
		if known {return state_access(check, n.x if condition else n.y, scope, depth+1, expected = expected)}
		access = state_access(check, n.x, scope, depth+1, expected = expected)
		other := state_access(check, n.y, scope, depth+1, expected = expected)
		access, _ = join_state_access(access, other)
		return
	case ^ast.Comp_Lit: return compound_state_access(check, n, scope, depth, expected)
	case ^ast.Call_Expr:
		if r.semantics != nil {
			targets, certain := call_procedures(r, n.expr, scope)
			if !certain || len(targets) == 0 {
				callee := state_access(check, n.expr, scope, depth+1)
				if len(callee.callables) > 0 && !callee.callback_unknown && len(callee.origins) == 0 && callee.callback_effects == {} {targets, certain = callee.callables, true}
			}
			if certain && len(targets) > 0 {
				access = {}
				for target, index in targets {
					procedure := r.procedures[target]
					// Every result dependency participates in the inference worklist.
					facts := callee_facts(check, target)
					arguments := call_arguments(procedure.literal, n)
					if result_index < len(facts.results) {
						event_trie := build_read_event_trie(facts)
						value := instantiate_access(check, facts.results[result_index], facts.parameters[:], arguments[:], scope, expression, events = event_trie)
						if index == 0 {access = value} else {access, _ = join_state_access(access, value)}
					}
				}
				if len(targets) == 1 {
					if condition, saved := check.counter_conditions[expression]; saved && result_index == 0 {access.condition, access.condition_version = expression, condition.version}
				} else {access.condition, access.condition_version, access.condition_negated = nil, nil, false}
				if access.type != nil || len(access.origins) > 0 || len(access.fields) > 0 || len(access.callables) > 0 || access.callback_effects != {} {return}
			}
			if condition, saved := check.counter_conditions[expression]; saved && result_index == 0 {access.condition, access.condition_version = expression, condition.version}
		}
		if ident, ok := unwrap_parens(n.expr).derived.(^ast.Ident); ok && (ident.name == "make" || ident.name == "new") {
			ids, certain := lookup(r, ident.name, scope, expression.pos.offset)
			if certain && len(ids) == 0 && len(n.args) > 0 {
				access = access_type(r, n.args[0], scope, depth+1)
				access = fresh_zero_value(check, access, depth+1) if ident.name == "new" else copy_state_value(r, access, depth+1)
				access.protected, access.immutable, access.nil_value = false, false, false
				access.zero = .Nonzero
				if ident.name == "new" {access.pointer = true}
				access.resource.root = expression

				return
			}
		}
		if name, named := binding_name(n.expr); named && name == "raw_data" && len(n.args) > 0 {
			ids, certain := lookup(r, name, scope, n.pos.offset)
			if certain && len(ids) == 0 {access = state_access(check, n.args[0], scope, depth+1); access.pointer = true; return}
		}
		namespace, member := external_target(r, n.expr, scope)
		operation := call_operation(r, n, scope)
		if namespace == "core:encoding/json" {
			if member == "make_tokenizer" {
				data := state_access(check, operation_argument(operation, n, "data"), scope, depth+1)
				access.fields = make(map[string]^State_Access)
				access.fields["data"] = new_clone(data)
				return
			}
			if slice.contains([]string{"make_parser", "make_parser_from_string", "make_parser_from_bytes"}, member) {
				data := state_access(check, operation_argument(operation, n, "data"), scope, depth+1)
				lexer := State_Access{fields = make(map[string]^State_Access)}
				lexer.fields["data"] = new_clone(data)
				access.fields = make(map[string]^State_Access)
				access.fields["tok"] = new_clone(lexer)
				token := State_Access{fields = make(map[string]^State_Access)}
				token.fields["text"] = new_clone(data)
				access.fields["curr_token"] = new_clone(token)
				access.fields["allocator"] = new_clone(state_access(check, operation_argument(operation, n, "allocator"), scope, depth+1))
				return
			}
			if member == "get_token" {
				if result_index != 0 {return}
				data := project_access(r, state_access(check, operation_argument(operation, n, "t"), scope, depth+1), "data")
				access.fields = make(map[string]^State_Access)
				access.fields["text"] = new_clone(data)
				return
			}
			if slice.contains([]string{"parse_value", "parse", "parse_string", "parse_bytes"}, member) {
				if result_index != 0 {return}
				access.shared = true
				access.resource = State_Location{root = expression}
				return
			}
		}
		if namespace == "core:math/rand" {
			if member == "default_random_generator" {
				argument := operation_argument(operation, n, "state")
				data := state_access(check, argument, scope, depth+1)
				access.ambient = argument == nil || data.nil_value || data.ambient
				access.fields = make(map[string]^State_Access)
				access.fields["data"], access.fields["procedure"] = new_clone(data), new_clone(State_Access{callback_modeled = true, callback_returns = true})
				return
			}
			if member == "perm" {
				return State_Access{shared = true, resource = State_Location{root = expression}}
			}
			if member == "choice" {return copy_state_value(r, element_access(r, state_access(check, operation_argument(operation, n, "array|T|set"), scope, depth+1), depth+1), depth+1)}
		}
		if operation.result_alias {return state_access(check, operation_argument(operation, n, operation.write), scope, depth+1)}
		if namespace == "core:odin/parser" && member == "default_parser" {
			access.fields = make(map[string]^State_Access)
			access.fields["err"], access.fields["warn"] = new_clone(State_Access{callback_effects = {.IO}}), new_clone(State_Access{callback_effects = {.IO}})
			return
		}
		clone := (namespace == "core:slice" || namespace == "core:strings") && (member == "clone" || member == "clone_to_dynamic")
		format := namespace == "core:fmt" && slice.contains([]string{"tprintf", "tprint", "tprintln", "aprintf", "aprint", "aprintln"}, member)
		if clone || format {
			access.shared = true
			if clone && len(n.args) > 0 {
				original := state_access(check, n.args[0], scope, depth+1)
				access = original
				access.shared = true
				access.protected, access.live, access.immutable, access.published = false, false, false, false
				access.resources = nil
				access.origins = nil
				access.fields = make(map[string]^State_Access)
				if namespace == "core:slice" {access.fields[""] = new_clone(copy_state_value(r, element_access(r, original, depth+1), depth+1))}
			}

			access.resource = State_Location{root = expression}
			return
		}
		ids, certain := expression_symbols(r, n.expr, scope, expression.pos.offset)
		if certain && len(ids) == 1 {
			symbol := r.symbols[ids[0]]
			if symbol.value != nil {
				if procedure, ok := unwrap_parens(symbol.value).derived.(^ast.Proc_Lit); ok && procedure.type.results != nil && len(procedure.type.results.list) == 1 {
					return access_type(r, procedure.type.results.list[0].type, symbol.scope, depth+1)
				}
			}
		}
		// Conversions keep known protected-state provenance. Ordinary value
		// copies discard their source container identity below.
		if len(n.args) == 1 && expression_kind(r, n.expr, scope, 0) == "Types" {return state_access(check, n.args[0], scope, depth+1)}
	case ^ast.Proc_Lit:
		if id, found := r.by_literal[n]; found {append(&access.callables, id)}
	}
	return read_state_access(check, access, expression.pos)
}

// Contextual literals and nil assignments keep their compiler-established
// shape without inheriting provenance from the value they replace.
@(private)
fit_state_value :: proc(value, expected: State_Access, check: ^State_Flow = nil, depth := 0) -> State_Access {
	result := value
	if result.type == nil {
		result.type, result.scope = expected.type, expected.scope
		result.pointer, result.shared = result.pointer || expected.pointer, result.shared || expected.shared
	}
	if check == nil || result.type == nil || result.pointer || result.shared || len(value.origins) > 0 || len(value.resources) > 0 {return result}
	inline := false
	#partial switch shape in result.type.derived {
	case ^ast.Struct_Type: inline = true
	case ^ast.Array_Type: inline = shape.len != nil
	}
	if !inline {return result}
	initialize := value.zero == .Zero && len(value.fields) == 0
	if value.type == nil && value.resource.root != nil {
		if _, literal := value.resource.root.derived.(^ast.Comp_Lit); literal {initialize = true}
	}
	if initialize {
		// Context supplies the missing literal shape. Populate omitted fields
		// exactly as new(T) does, then preserve explicit fields and their borrows.
		initialized := fresh_zero_value(check, result, depth+1)
		initialized.zero, initialized.resource = result.zero, result.resource
		for name, child in value.fields {
			field_type := element_access(check.r, initialized, depth+1) if name == "" else field_access(check.r, initialized, name, depth+1)
			initialized.fields[name] = new_clone(fit_state_value(child^, field_type, check, depth+1))
		}
		result = initialized
	}
	return result
}

@(private)
retain_evaluated_value :: proc(check: ^State_Flow, value: State_Access, pos := tokenizer.Pos{}) -> int {
	check.temporary = min(check.temporary, -1)-1
	for _, present := check.bindings[check.temporary]; present; _, present = check.bindings[check.temporary] {check.temporary -= 1}
	captured := copy_state_value(check.r, value, 0)
	if pos.file != "" {captured = read_state_access(check, captured, pos)}
	check.bindings[check.temporary] = captured
	return check.temporary
}

// Copy records by value, retaining aliases only in their reference-bearing
// fields. Taking the copy's address must never borrow its source's storage.
@(private)
copy_state_value :: proc(r: ^References, access: State_Access, depth: int) -> State_Access {
	// A copied value has a new slot even when its pointer/container still
	// shares a referent. Callers attach the destination slot after copying.
	result := fit_slot(access, State_Access{})
	result.live = false
	if access.pointer || access.shared || known_callback_type(r, access.type, access.scope) || depth > len(r.symbols)+len(r.scopes) {return result}
	if access.type != nil {
		if array, fixed := access.type.derived.(^ast.Array_Type); fixed && array.len != nil {
			result.fields = make(map[string]^State_Access)
			result.fields[""] = new_clone(copy_state_value(r, element_access(r, access, depth+1), depth+1))
		}
		if record, ok := access.type.derived.(^ast.Struct_Type); ok && record.fields != nil {
			result.fields = make(map[string]^State_Access)
			for field in record.fields.list {
				for expression in field.names {
					if name, named := binding_name(expression); named {
						result.fields[name] = new_clone(copy_state_value(r, field_access(r, access, name, depth+1), depth+1))
					}
				}
			}
		}
	}
	result.protected, result.published = false, false
	result.resource, result.resources = {}, nil
	result.origins = nil
	return result
}

@(private)
field_access :: proc(r: ^References, base: State_Access, name: string, depth: int) -> (access: State_Access) {
	if depth > len(r.symbols)+len(r.scopes) {return}
	base := base
	// Addressed stores update the referent snapshot, not the address wrapper.
	if base.addressed {if value, known := base.fields["^"]; known {base.fields = value.fields}}
	if field, set := base.fields[name]; set {
		access = field^
		access = field_slot(r, access, base, name)
		access.live = base.pointer || base.live
		access.local = access.local || base.local && !access.pointer
		// An embedded value has storage within its parent even when a prior
		// record copy discarded the source's referent identity. Taking its
		// address must still let caller-relative stores reach that field.
		if access.resource.root == nil && !access.pointer && !access.shared {
			path := access_path(r, base, name)
			access.resource, access.resources = path.resource, path.resources
			if len(access.origins) == 0 && (base.pointer || base.live) {access.origins = path.origins}
		}
		access.protected = base.protected || access.protected
		if local_cache_field(r, base, access.type) {access.protected, access.slot_protected = field.protected, false}
		access.uncertain = access.uncertain || base.uncertain
		access.published = access.published || base.published
		access.immutable = access.immutable || base.immutable || access.catalog_type && access.protected && access.published
		return
	}
	record: ^ast.Struct_Type
	if base.type != nil {record, _ = base.type.derived.(^ast.Struct_Type)}
	if record != nil && record.fields != nil {
		for field in record.fields.list {
			for expression in field.names {
				if ident, named := binding_name(expression); named && ident == name {
					access = access_type(r, field.type, base.scope, depth+1)
					access = field_slot(r, access, base, name)
					// Missing child metadata (for example after a zero reset) does not
					// turn private inline storage into a borrow merely because its
					// parent is addressable. Reference fields and authoritative values
					// embedded in published storage retain their protection.
					access.protected = base.protected || access.protected && (access.pointer || access.shared || base.published)
					access.live = base.pointer || base.live
					access.local = access.local || base.local && !access.pointer
					access.indirect, access.uncertain = base.indirect, base.uncertain
					access.published = base.published
					access.immutable = access.immutable || base.immutable || access.catalog_type && access.protected && access.published
					if local_cache_field(r, base, access.type) {
						// Permission keeps actual writes/stores visible. Saved aliases
						// in the branch above retain their concrete referent protection.
						access.protected, access.slot_protected = false, false
					}
					path := access_path(r, base, name)
					access.origins, access.resource, access.resources = path.origins, path.resource, path.resources
					return
				}
			}
			if .Using in field.flags {
				inner := access_type(r, field.type, base.scope, depth+1)
				if len(field.names) > 0 {
					if embedded, named := binding_name(field.names[0]); named {inner = field_access(r, base, embedded, depth+1)}
				}
				access = field_access(r, inner, name, depth+1)
				if access.type != nil {return}
			}
		}
	}
	// Opaque nested fields still carry symbolic formal paths. Missing declared
	// shape must not erase a saved caller requirement or borrowed row identity.
	access = field_slot(r, access, base, name)
	access.protected, access.live = base.protected, base.pointer || base.live
	path := access_path(r, base, name)
	access.origins, access.resource, access.resources, access.local = path.origins, path.resource, path.resources, base.local
	access.indirect, access.uncertain = base.indirect, base.uncertain
	access.published = base.published
	return
}


@(private)
element_access :: proc(r: ^References, base: State_Access, depth: int) -> (access: State_Access) {
	if child, set := base.fields[""]; set {
		access = child^
		access = field_slot(r, access, base, "[]", true)
		// Copied inline elements live in the destination array's slots. Their
		// pointers/containers still retain the source's independent referents.
		if access.resource.root == nil && !access.pointer && !access.shared {
			path := access_path(r, base, "[]", finite_index_path(r, base))
			access.resource, access.resources = path.resource, path.resources
			if len(access.origins) == 0 && (base.pointer || base.live) {access.origins = path.origins}
		}
		access.protected = access.protected || base.protected
		access.published = access.published || base.published
		access.immutable = access.immutable || base.immutable || access.catalog_type && access.protected && access.published
		return
	}
	if base.type == nil {return}
	#partial switch n in base.type.derived {
	case ^ast.Map_Type: access = access_type(r, n.value, base.scope, depth+1)
	case ^ast.Array_Type: access = access_type(r, n.elem, base.scope, depth+1)
	case ^ast.Dynamic_Array_Type: access = access_type(r, n.elem, base.scope, depth+1)
	}
	access.protected = base.protected || access.protected && access.pointer
	path := access_path(r, base, "[]", finite_index_path(r, base))
	access = field_slot(r, access, base, "[]", true)
	access.origins, access.resource, access.resources, access.local = path.origins, path.resource, path.resources, base.local
	access.indirect, access.uncertain = base.indirect || base.shared, base.uncertain
	access.published = base.published
	access.immutable = access.immutable || base.immutable || access.catalog_type && access.protected && access.published
	return
}

@(private)
access_type :: proc(r: ^References, expression: ^ast.Expr, scope, depth: int) -> (access: State_Access) {
	if expression == nil || depth > len(r.symbols)+len(r.scopes) {return}
	expression := expression
	expression = unwrap_parens(expression)
	access.type, access.scope = expression, scope
	#partial switch n in expression.derived {
	case ^ast.Ident, ^ast.Selector_Expr:
		ids, certain := expression_symbols(r, expression, scope, expression.pos.offset)
		if certain && len(ids) == 0 {
			if name, named := binding_name(expression); named && (name == "string" || name == "cstring") {access.shared = true}
		}
		if !certain || len(ids) != 1 {return}
		symbol := r.symbols[ids[0]]
		access = access_type(r, symbol.value, symbol.scope, depth+1)
		file := r.files[symbol.file]
		if file.has_role && (file.role == .State || file.role == .Engine || r.authorities[access.type]) && type_property(r, access.type, access.scope) {access.protected = true}
		if file.has_role && file.role == .Catalog {access.catalog_type = true}
		if file.has_role && file.role == .Engine {access.local = type_property(r, symbol.value, symbol.scope, local_owner = true)}
	case ^ast.Pointer_Type:
		access = access_type(r, n.elem, scope, depth+1)
		access.pointer = true
	case ^ast.Distinct_Type:
		return access_type(r, n.type, scope, depth+1)
	case ^ast.Helper_Type:
		return access_type(r, n.type, scope, depth+1)
	case ^ast.Call_Expr:
		return access_type(r, n.expr, scope, depth+1)
	case ^ast.Map_Type, ^ast.Dynamic_Array_Type:
		access.shared = true
	case ^ast.Array_Type:
		access.shared = n.len == nil
	}
	return
}

// The saved type graph is fixed before capability inference. A worklist avoids
// depth-dependent answers for cyclic records. Cache the root's positive witness;
// only a fully exhausted reachable graph can establish negative results.
@(private)
type_property :: proc(r: ^References, expression: ^ast.Expr, scope: int, local_owner := false) -> bool {
	if expression == nil {return false}
	cache := &r.relational_types
	if local_owner {cache = &r.local_types}
	start := Type_Scope{unwrap_parens(expression), scope}
	if cached, known := cache^[start]; known {return cached}
	pending := make([dynamic]Type_Scope)
	append(&pending, start)
	seen := make(map[Type_Scope]bool)
	for len(pending) > 0 {
		current := pop(&pending)
		if current.expression == nil {continue}
		current.expression = unwrap_parens(current.expression)
		if seen[current] {continue}
		seen[current] = true
		if cached, known := cache^[current]; known {
			if cached {cache^[start] = true; return true}
			continue
		}
		#partial switch type in current.expression.derived {
		case ^ast.Ident, ^ast.Selector_Expr:
			ids, certain := expression_symbols(r, current.expression, current.scope, current.expression.pos.offset)
			if certain && len(ids) == 1 {symbol := r.symbols[ids[0]]; append(&pending, Type_Scope{symbol.value, symbol.scope})}
		case ^ast.Pointer_Type:
			if !local_owner {append(&pending, Type_Scope{type.elem, current.scope}); continue}
			ids, certain := expression_symbols(r, type.elem, current.scope, type.pos.offset)
			if certain && len(ids) == 1 {
				symbol := r.symbols[ids[0]]
				file := r.files[symbol.file]
				if file.has_role && file.role == .Engine && type_property(r, symbol.value, symbol.scope) {cache^[start] = true; return true}
			}
		case ^ast.Distinct_Type: append(&pending, Type_Scope{type.type, current.scope})
		case ^ast.Helper_Type: append(&pending, Type_Scope{type.type, current.scope})
		case ^ast.Call_Expr: append(&pending, Type_Scope{type.expr, current.scope})
		case ^ast.Map_Type, ^ast.Array_Type, ^ast.Dynamic_Array_Type:
			if local_owner {continue}
			cache^[current], cache^[start] = true, true
			return true
		case ^ast.Struct_Type:
			if type.fields != nil {for field in type.fields.list {append(&pending, Type_Scope{field.type, current.scope})}}
		}
	}
	for visited in seen {cache^[visited] = false}
	return false
}

@(private)
join_state_access :: proc(left, right: State_Access, ancestors: ^State_Ancestor = nil, from_deref := false, protection: ^map[uintptr]bool = nil) -> (result: State_Access, changed: bool) {
	storage: map[uintptr]bool
	protection := protection
	if protection == nil {protection = &storage}
	defer delete(storage)
	result = left
	if left.zero == .Unset {result.condition, result.condition_version, result.condition_negated = right.condition, right.condition_version, right.condition_negated} else if left.condition != right.condition || left.condition_version != right.condition_version || left.condition_negated != right.condition_negated {result.condition, result.condition_version, result.condition_negated = nil, nil, false}
	// Compare the meet with the previous value. A missing retained proof remains
	// missing, while a local/nested proof disagreement must update its binding.
	changed = result.condition != left.condition || result.condition_version != left.condition_version || result.condition_negated != left.condition_negated
	zero := left.zero
	if zero == .Unset {zero = right.zero} else if right.zero != .Unset && zero != right.zero {zero = .Unknown}
	if result.zero != zero {result.zero = zero; changed = true}
	callables_copied, resources_copied, origins_copied := false, false, false
	if result.type == nil && right.type != nil {result.type, result.scope = right.type, right.scope; changed = true}
	if right.protected && !result.protected {result.protected = true; changed = true}
	if right.live && !result.live {result.live = true; changed = true}
	if right.pointer && !result.pointer {result.pointer = true; changed = true}
	if right.shared && !result.shared {result.shared = true; changed = true}
	if right.published && !result.published {result.published = true; changed = true}
	if right.addressed && !result.addressed {result.addressed = true; changed = true}
	if result.nil_value && !right.nil_value {result.nil_value = false; changed = true}
	if right.local && !result.local {result.local = true; changed = true}
	if right.indirect && !result.indirect {result.indirect = true; changed = true}
	if right.uncertain && !result.uncertain {result.uncertain = true; changed = true}
	if right.ambient && !result.ambient {result.ambient = true; changed = true}
	if right.decoded && !result.decoded {result.decoded = true; changed = true}
	if right.immutable && !result.immutable {result.immutable = true; changed = true}
	if right.catalog_type && !result.catalog_type {result.catalog_type = true; changed = true}
	for target in right.callables {if !slice.contains(result.callables[:], target) {
		if !callables_copied {result.callables = slice.clone_to_dynamic(left.callables[:]); callables_copied = true}
		append(&result.callables, target); changed = true
	}}
	if right.callback_unknown && !result.callback_unknown {result.callback_unknown = true; changed = true}
	if right.callback_returns && !result.callback_returns {result.callback_returns = true; changed = true}
	if right.callback_effects &~ result.callback_effects != {} {result.callback_effects |= right.callback_effects; changed = true}
	callback_modeled := (left.callback_modeled || left.nil_value) && (right.callback_modeled || right.nil_value)
	if result.callback_modeled != callback_modeled {result.callback_modeled = callback_modeled; changed = true}
	if result.resource.root == nil && right.resource.root != nil {result.resource = right.resource; changed = true}
	resources_seen: map[State_Location]bool
	defer delete(resources_seen)
	same_resources := len(left.resources) == len(right.resources) && (raw_data(left.resources) == raw_data(right.resources) || slice.equal(left.resources[:], right.resources[:]))
	use_index := len(right.resources) >= 8
	if !same_resources {
		for resource in right.resources {if append_state_resource(&result, resource, &resources_copied, &resources_seen, use_index) {changed = true}}
	}
	if right.resource.root != nil {if append_state_resource(&result, right.resource, &resources_copied, &resources_seen, false) {changed = true}}
	retain_state_resources(&result, resources_copied)
	reads_changed: bool
	result.reads, reads_changed = join_state_reads(left.reads, right.reads[:])
	changed = changed || reads_changed
	for origin in right.origins {
		if !slice.contains(result.origins[:], origin) {
			if !origins_copied {result.origins = slice.clone_to_dynamic(left.origins[:]); origins_copied = true}
			append(&result.origins, origin); changed = true
		}
	}
	if ancestors == nil && len(right.fields) == 0 {return}
	ancestors := ancestors
	ancestor := State_Ancestor{result.type, ancestors}
	if result.type != nil {
		for parent := ancestors; parent != nil; parent = parent.parent {
			if parent.type != result.type {continue}
			borrowed_left := contains_protected_state(left, protection)
			borrowed_right := contains_protected_state(right, protection)
			result.protected = result.protected || borrowed_left || borrowed_right
			result.uncertain = true
			result.fields = nil
			return result, changed || len(left.fields) > 0 || !left.uncertain || result.protected != left.protected
		}
		ancestors = &ancestor
	}
	if len(right.fields) == 0 || field_identity(left.fields) == field_identity(right.fields) {return}
	can_deref := result.addressed && !from_deref
	fields := left.fields
	fields_copied := false
	for name, field in right.fields {
		previous, set := fields[name]
		joined, different := field^, true
		// An address's saved referent is the same value, not another record
		// nested within its type. Count real fields, not a single synthetic edge,
		// when widening recursive records.
		deref_edge := name == "^" && can_deref
		child_ancestors := ancestor.parent if deref_edge else ancestors
		if set {joined, different = join_state_access(previous^, field^, child_ancestors, deref_edge, protection)}
		if !different {continue}
		if !fields_copied {
			fields = make(map[string]^State_Access, len(left.fields)+len(right.fields))
			for k, child in left.fields {fields[k] = child}
			fields_copied = true
		}
		fields[name], changed = new_clone(joined), true
	}
	result.fields = fields
	return
}


// ---------------- File ----------------


// Local view maps not maintained by engine row mutations are frame caches.
// Their container permission does not grant writes to an aliased relation.
local_cache_field :: proc(r: ^References, base: State_Access, field_type: ^ast.Expr) -> bool {
	if !base.local || base.immutable || !r.authorities[base.type] || base.scope < 0 || field_type == nil {return false}
	file_id := r.scopes[base.scope].file
	if file_id < 0 {return false}
	file := r.files[file_id]
	_, table := field_type.derived.(^ast.Map_Type)
	return table && file.has_role && file.role == .Views && !r.relation_containers[field_type]
}

mapped_counter_effects :: proc(check: ^State_Flow, changes: []Counter_Change, parameters: []int, arguments: []State_Access) -> (result: [dynamic]Counter_Effect) {
	for change in changes {
		index, found := slice.linear_search(parameters, change.origin.parameter)
		if !found || index >= len(arguments) {continue}
		owner := arguments[index]
		effect := Counter_Effect{access = project_access(check.r, owner, change.origin.path), owner = owner, delta = change.delta, model = -1}
		for transaction, model in check.r.semantics.transactions {
			if transaction.owner_type == owner.type && transaction.counter_path == change.origin.path {effect.model = model; break}
		}
		append(&result, effect)
	}
	return
}


compound_state_access :: proc(check: ^State_Flow, n: ^ast.Comp_Lit, scope, depth: int, expected := State_Access{}, visitor: ^ast.Visitor = nil) -> (access: State_Access) {
	r := check.r
	expression := &n.node
	shape := access_type(r, n.type, scope, depth+1)
	if n.type == nil {
		shape = expected
		if shape.type == nil {
			if contextual := reference_type(r, expression, scope, false, depth+1); contextual != nil {shape = access_type(r, contextual, r.type_scopes[contextual], depth+1)}
		}
	}
	access = fresh_zero_value(check, shape, depth+1)
	access.nil_value = false
	access.zero = .Zero if len(n.elems) == 0 else .Unknown
	access.resource.root = expression
	if access.fields == nil {access.fields = make(map[string]^State_Access)}
	record: ^ast.Struct_Type
	if access.type != nil {record, _ = access.type.derived.(^ast.Struct_Type)}
	field_index, field_name := 0, 0
	for element in n.elems {
		value, name := element, ""
		if field, ok := element.derived.(^ast.Field_Value); ok {
			value = field.value
			name, _ = binding_name(field.field)
		} else if record != nil && record.fields != nil {
			// One parser field can declare several names. Positional values
			// advance through those names, not through declaration groups.
			for field_index < len(record.fields.list) && field_name >= len(record.fields.list[field_index].names) {
				field_index += 1
				field_name = 0
			}
			if field_index < len(record.fields.list) {
				name, _ = binding_name(record.fields.list[field_index].names[field_name])
				field_name += 1
			}
		}
		// Supply the field shape before consuming a nested positional literal;
		// fitting it afterwards cannot recover unnamed elements already lost.
		expected_child := field_access(r, access, name, depth+1) if record != nil && name != "" else element_access(r, access, depth+1)
		known_map := false
		if access.type != nil {_, known_map = access.type.derived.(^ast.Map_Type)}
		if visitor != nil {
			if field, keyed := element.derived.(^ast.Field_Value); keyed && (known_map || access.type == nil) {ast.walk(visitor, field.field); capture_expression(check, field.field, scope)}
			ast.walk(visitor, value)
			capture_expression(check, value, scope, expected_child)
			continue
		}
		child := state_access(check, value, scope, depth+1, expected = expected_child)
		if known_map {
			if field, keyed := element.derived.(^ast.Field_Value); keyed {
				key := copy_state_value(r, state_access(check, field.field, scope, depth+1), depth+1)
				join_state_field(&access.fields, "$key", key)
			}
		}
		if record != nil || access.type == nil || name != "" && !known_map {
			if name != "" {access.fields[name] = new_clone(copy_state_value(r, fit_state_value(child, field_access(r, access, name, depth+1), check, depth+1), depth+1))}
		} else {
			child = copy_state_value(r, fit_state_value(child, element_access(r, access, depth+1), check, depth+1), depth+1)
			join_state_field(&access.fields, "", child)
		}
	}
	return
}

capture_expression :: proc(check: ^State_Flow, expression: ^ast.Expr, scope: int, expected := State_Access{}) {
	if expression == nil || check.exited {return}
	expression := expression
	expression = unwrap_parens(expression)
	if _, saved := check.evaluated[Expression_Result{expression, 0}]; saved {return}
	// Positional nested literals can acquire their shape only from the outer
	// record. Their operands are already captured; build the value once that
	// expected shape is available instead of saving an unshaped container.
	if literal, compound := expression.derived.(^ast.Comp_Lit); compound && literal.type == nil && expected.type == nil && reference_type(check.r, expression, scope, false, 0) == nil {return}
	count := 1
	if call, called := expression.derived.(^ast.Call_Expr); called && check.r.semantics != nil {
		targets, certain := call_procedures(check.r, call.expr, scope)
		if !certain {targets = state_access(check, call.expr, scope, 0).callables}
		for target in targets {count = max(count, len(callee_facts(check, target).results))}
	}
	if check.evaluated == nil {check.evaluated = make(map[Expression_Result]int)}
	for i in 0..<count {
		value := state_access(check, expression, scope, 0, i, expected)
		check.evaluated[Expression_Result{expression, i}] = retain_evaluated_value(check, value, expression.pos)
	}
}


finish_state_return :: proc(check: ^State_Flow, visitor: ^ast.Visitor, n: ^ast.Return_Stmt, scope: int, forced := Value_Zero.Unset) {
	r := check.r
	if r.semantics != nil && check.caller >= 0 {
		facts := &r.semantics.facts[check.caller]
		values := make([]State_Access, len(facts.results))
		for _, i in values {
			if len(n.results) == 0 && facts.result_bindings[i] >= 0 {values[i] = check.bindings[facts.result_bindings[i]]} else if i < len(n.results) {values[i] = state_access(check, n.results[i], scope, 0)} else if len(n.results) == 1 {
				values[i] = state_access(check, n.results[0], scope, 0, i)
			}
		}
		returned_predicate: Returned_Predicate
		unrelated := false
		if r.semantics.infer && len(values) == 1 {
			value := values[0]
			condition, saved := check.counter_conditions[value.condition]
			if saved && condition.version == value.condition_version && condition.predicate.call != nil {
				returned_predicate = condition.predicate
				returned_predicate.negated = returned_predicate.negated != value.condition_negated
			} else {
				unrelated = value.zero == .Zero || value.zero == .Nonzero || len(value.origins) > 0
				if saved && condition.target >= 0 {unrelated = unrelated || callee_facts(check, condition.target).unrelated_boolean_return}
			}
		}
		if forced != .Unset && len(values) == 1 {values[0].zero = forced}
		// Odin assigns explicit returns into named result slots before cleanup.
		for value, i in values {if i < len(facts.result_bindings) && facts.result_bindings[i] >= 0 {check.bindings[facts.result_bindings[i]] = fit_slot(value, check.bindings[facts.result_bindings[i]])}}
		if len(check.deferred) > 0 {
			// Capture the values once, then let ordinary alias/store updates reach
			// their referents. Re-evaluating expressions could return a rebound
			// pointer; retaining only the old graph would miss cleanup mutations.
			ids := make([]int, len(values))
			for value, i in values {ids[i] = retain_evaluated_value(check, value)}
			run_deferred(check, visitor, check.deferred[:])
			for &value, i in values {value = check.bindings[ids[i]]; delete_key(&check.bindings, ids[i])}
		}
		if check.exited {return}
		if r.semantics.infer {
			if !facts.normal_return {facts.normal_return, r.semantics.changed = true, true}
			if returned_predicate.call != nil && !slice.contains(facts.returned_predicates[:], returned_predicate) {append(&facts.returned_predicates, returned_predicate); r.semantics.changed = true}
			if unrelated && !facts.unrelated_boolean_return {facts.unrelated_boolean_return = true; r.semantics.changed = true}
		}
		if r.semantics.infer && len(values) == 1 {
			if values[0].zero == .Zero {
				if !facts.has_false_return {facts.has_false_return = true; r.semantics.changed = true}
				for change in check.counter_history {if !slice.contains(facts.false_counters[:], change) {append(&facts.false_counters, change); r.semantics.changed = true}}
			} else if values[0].zero == .Nonzero {
				for change in check.counter_history {if !slice.contains(facts.true_counters[:], change) {append(&facts.true_counters, change); r.semantics.changed = true}}
			} else if !facts.unknown_boolean_return {facts.unknown_boolean_return = true; r.semantics.changed = true}
		}
		for _, i in values {
			value := fit_state_value(values[i], access_type(r, facts.result_types[i], r.node_scopes[&r.procedures[check.caller].literal.type.node], 0), check)
			if r.semantics.infer {
				joined, changed := join_state_access(facts.results[i], value)
				if changed {facts.results[i] = joined; r.semantics.changed = true}
			}
		}
	} else {run_deferred(check, visitor, check.deferred[:])}
	for _, active in check.transactions {if active.possible > 0 {report_boundary(check, n.pos, "OWN002", "return leaves a transaction opened here without a matching finish/rollback"); break}}
	check.exited = true
}


// Compile-time branches share a lexical scope. Advance their continuing states
// together so every feasible exit is known before the next statement's summaries.
walk_state_statements :: proc(check: ^State_Flow, visitor: ^ast.Visitor, statements: []^ast.Stmt, deferred_start: int, continuing: ^[dynamic]State_Flow = nil, initial: []State_Flow = nil) {
	block_stmts, statement_index, depth := check.block_stmts, check.statement_index, check.branch_depth
	defer {check.block_stmts, check.statement_index, check.branch_depth = block_stmts, statement_index, depth}
	branches, next: [dynamic]State_Flow
	append(&branches, ..initial)
	optional := check.optional_stores
	for statement, i in statements {
		conditional, is_when := statement.derived.(^ast.When_Stmt)
		if len(branches) == 0 {
			check.block_stmts, check.statement_index = statements, i
			if !is_when {
				ast.walk(visitor, statement)
				if check.exited {for pending in statements[i+1:] {ast.walk(visitor, pending)}; return}
				optional = optional || check.optional_stores
				continue
			}
			append(&branches, check^)
		}
		if nested_block, nested := statement.derived.(^ast.Block_Stmt); nested {
			// An ordinary nested block also advances all configurations together,
			// but owns only the defers added after each configuration entered it.
			for &branch in branches {branch.optional_stores = branch.optional_stores || optional}
			check.branch_depth = depth
			defer_scope := check.defer_scope
			check.defer_scope = nested_block.end
			for &branch in branches {branch.defer_scope = nested_block.end}
			walk_state_statements(check, visitor, nested_block.stmts[:], -1, &next, branches[:])
			optional = optional || check.optional_stores
			for &branch in next {
				check^ = branch
				check.optional_stores = check.optional_stores || optional
				for entry in branches {
					if !availability_possible(check.r, availability_and(entry.available, check.available)) {continue}
					start := len(entry.deferred)
					run_deferred(check, visitor, check.deferred[start:])
					resize(&check.deferred, start)
					break
				}
				check.defer_scope = defer_scope
				branch = check^
			}
		} else {
			for branch in branches {
				check^ = branch
				check.block_stmts, check.statement_index, check.branch_depth = statements, i, depth
				check.optional_stores = check.optional_stores || optional
				if is_when {
					condition, known := literal_condition(conditional.cond)
					guard := availability_expression(conditional.cond, check.r.node_scopes[&conditional.node])
					available := check.available
					if !available.supplied {available = availability_all()}
					before := snapshot_state_flow(check)
					for body, alternative in ([2]^ast.Stmt{conditional.body, conditional.else_stmt}) {
						if known && condition != (alternative == 0) {continue}
						path := availability_and(available, guard if alternative == 0 else availability_not(guard))
						if !availability_possible(check.r, path) {continue}
						check^ = snapshot_state_flow(&before)
						check.available = path
						if !known {check.branch_depth += 1}
						single := [1]^ast.Stmt{body}
						body_statements := single[:]
						if body == nil {body_statements = nil} else if block, ok := body.derived.(^ast.Block_Stmt); ok {body_statements = block.stmts[:]}
						walk_state_statements(check, visitor, body_statements, -1, &next)
						optional = optional || check.optional_stores
					}
				} else {
					ast.walk(visitor, statement)
					if !check.exited {append(&next, check^)}
					optional = optional || check.optional_stores
				}
			}
		}
		branches, next = next, branches
		clear(&next)
		if len(branches) == 0 {check.optional_stores = optional; check.exited = true; for pending in statements[i+1:] {ast.walk(visitor, pending)}; return}
	}
	if len(branches) == 0 {
		if continuing != nil {append(continuing, check^)} else if deferred_start >= 0 {run_deferred(check, visitor, check.deferred[deferred_start:])}
		return
	}
	joined: Condition_Branch
	for branch in branches {
		check^ = branch
		check.branch_depth = depth
		check.optional_stores = check.optional_stores || optional
		if continuing != nil {
			// A when body has no cleanup boundary. Its defers execute with the
			// eventual bindings and transaction state of this particular path.
			append(continuing, check^)
		} else if deferred_start >= 0 {
			run_deferred(check, visitor, check.deferred[deferred_start:])
		}
		state := check^
		if continuing != nil && len(branches) > 1 {state = snapshot_state_flow(check)}
		joined = join_condition_branches(joined, Condition_Branch{state, !check.exited})
	}
	if joined.reachable {check^ = joined.state}
	check.optional_stores = check.optional_stores || optional
	check.exited = !joined.reachable
}

run_deferred :: proc(check: ^State_Flow, visitor: ^ast.Visitor, statements: []Deferred_Statement) {
	deferred := check.deferred
	defer check.deferred = deferred
	start := len(deferred)-len(statements)
	for i := len(statements)-1; i >= 0; i -= 1 {
		// Only earlier registrations remain after this cleanup. Isolate the
		// queue so nested defers cannot overwrite the enclosing saved sequence.
		check.deferred = slice.clone_to_dynamic(deferred[:start+i])
		depth, optional := check.branch_depth, check.optional_stores
		store_depth, order := check.store_depth, check.store_order
		runtime_optional := check.runtime_optional_stores
		check.runtime_optional_stores = false
		check.store_order = statements[i].order
		check.store_depth = 1 if statements[i].weak else 0
		// Later exits cannot make previously unconditional cleanup optional.
		check.branch_depth = 1 if statements[i].conditional else 0
		check.optional_stores = false
		ast.walk(visitor, statements[i].statement)
		check.branch_depth, check.optional_stores = depth, optional
		check.store_depth, check.store_order = store_depth, order
		check.runtime_optional_stores = runtime_optional
		if check.exited {break}
	}
}
// Reach a monotone loop-head state before reporting writes. Otherwise a borrow
// assigned at the bottom of the body hides writes through it next iteration.
walk_state_loop :: proc(check: ^State_Flow, visitor: ^ast.Visitor, body, post: ^ast.Stmt, iteration: map[int]State_Access = nil) {
	available := check.available
	defer {check.available = available}
	entry := copy_state_bindings(check.bindings)
	transactions := copy_transactions(check.transactions)
	quiet := check.quiet
	check.quiet = true
	allocator := context.allocator
	heap := runtime.heap_allocator()
	retained: [2]mem.Dynamic_Arena
	for &arena in retained {mem.dynamic_arena_init(&arena, block_allocator = heap, array_allocator = heap, block_size = SCRATCH_BLOCK_SIZE, out_band_size = SCRATCH_BLOCK_SIZE/4)}
	generation := 0
	for {
		work: mem.Dynamic_Arena
		mem.dynamic_arena_init(&work, block_allocator = heap, array_allocator = heap, block_size = SCRATCH_BLOCK_SIZE, out_band_size = SCRATCH_BLOCK_SIZE/4)
		context.allocator = mem.dynamic_arena_allocator(&work)
		previous_cache := check.r.read_cache
		cache: Read_Cache
		check.r.read_cache = &cache
		// The previous checkpoint stays alive until its replacement is owned.
		// Existing mutable containers can be consumed without cloning them twice.
		model := check.r.semantics
		check.available = available
		check.exited = false
		check.bindings, check.transactions = copy_state_bindings(entry), copy_transactions(transactions)
		ast.walk(visitor, body); ast.walk(visitor, post)
		changed := merge_state_bindings(&entry, check.bindings)
		check.bindings = entry
		generation = 1-generation
		mem.dynamic_arena_free_all(&retained[generation])
		context.allocator = mem.dynamic_arena_allocator(&retained[generation])
		check^ = clone_state_flow(check^)
		if model.infer && check.caller >= 0 {model.facts[check.caller] = clone_semantic_facts(model.facts[check.caller:check.caller+1])[0]}
		entry = check.bindings
		context.allocator = allocator
		check.r.read_cache = previous_cache
		delete_read_cache(&cache)
		mem.dynamic_arena_destroy(&work)
		if !changed {break}
	}
	check^ = clone_state_flow(check^)
	model := check.r.semantics
	if model.infer && check.caller >= 0 {model.facts[check.caller] = clone_semantic_facts(model.facts[check.caller:check.caller+1])[0]}
	entry = check.bindings
	for &arena in retained {mem.dynamic_arena_destroy(&arena)}
	check.quiet = quiet
	check.exited = false
	if quiet {
		// The stable pass already computed these facts. Replaying a silent body
		// only multiplies nested-loop work and retains discarded arena snapshots.
		check.bindings = entry
		merge_transactions(&check.transactions, transactions)
		return
	}
	check.bindings, check.transactions = copy_state_bindings(entry), copy_transactions(transactions)
	check.available = available
	ast.walk(visitor, body); ast.walk(visitor, post)
	check.exited = false
	merge_state_bindings(&check.bindings, entry)
	merge_transactions(&check.transactions, transactions)
}

// Update only the copied record containing a field. A write through an existing
// borrow cannot turn that shared storage into a private local value.
assign_state_value :: proc(check: ^State_Flow, expression: ^ast.Expr, value: State_Access, scope, depth: int) {
	if expression == nil || depth > len(check.r.symbols)+len(check.r.scopes) {return}
	value := value
	value = fit_state_value(value, state_access(check, expression, scope, depth+1), check, depth+1)
	#partial switch n in unwrap_parens(expression).derived {
	case ^ast.Ident:
		ids, certain := lookup(check.r, n.name, scope, expression.pos.offset)
		if certain && len(ids) == 1 {
			id := ids[0]
			if check.referents[id] {
				previous := state_access(check, expression, scope, depth+1)
				store_bindings(check, previous, nil, value)
				check.bindings[id] = replace_state_path(check.r, previous, nil, copy_state_value(check.r, value, depth+1), false)
			} else {check.bindings[id] = fit_slot(copy_state_value(check.r, value, depth+1), check.bindings[id])}
		}
	case ^ast.Deref_Expr:
		base := state_access(check, n.expr, scope, depth+1)
		// Assigning an inline value copies it into this referent. Keep aliases
		// in reference fields without borrowing the source record's container.
		value = copy_state_value(check.r, value, depth+1)
		store_bindings(check, base, nil, value)
	case ^ast.Selector_Expr, ^ast.Index_Expr:
		base_expression: ^ast.Expr
		name := ""
		index: ^ast.Expr
		#partial switch target in unwrap_parens(expression).derived {
		case ^ast.Selector_Expr: base_expression, name = target.expr, target.field.name
		case ^ast.Index_Expr: base_expression, index = target.expr, target.index
		}
		base := state_access(check, base_expression, scope, depth+1)
		if base.protected && (base.pointer || base.live || base.shared) {return}
		fields := make(map[string]^State_Access, len(base.fields)+2)
		for field_name, field in base.fields {fields[field_name] = field}
		expected := element_access(check.r, base, depth+1) if index != nil else field_access(check.r, base, name, depth+1)
		stored := copy_state_value(check.r, fit_state_value(value, expected, check, depth+1), depth+1)
		// An unknown runtime index can refer to any element. Preserve reference
		// capabilities from other stored elements rather than replacing the bucket.
		if previous, exists := fields[name]; index != nil && exists {stored, _ = join_state_access(previous^, stored)}
		fields[name] = new_clone(stored)
		if index != nil && base.type != nil {
			if _, table := base.type.derived.(^ast.Map_Type); table {
				key := copy_state_value(check.r, state_access(check, index, scope, depth+1), depth+1)
				join_state_field(&fields, "$key", key)
			}
		}
		base.fields = fields
		assign_state_value(check, base_expression, base, scope, depth+1)
		// Explicit aliases describe the same private backing storage. Updating
		// one handle must update their snapshots without mutating another branch.
		if base.resource.root != nil {
			memo, key_memo := make(Field_Transforms, runtime.heap_allocator()), make(Field_Transforms, runtime.heap_allocator())
			defer delete(memo)
			defer delete(key_memo)
			for id, alias in check.bindings {
				check.bindings[id], _ = update_state_alias(check.r, alias, base.resource, name, stored, index != nil, &memo)
				if key, exists := fields["$key"]; index != nil && exists {check.bindings[id], _ = update_state_alias(check.r, check.bindings[id], base.resource, "$key", key^, true, &key_memo)}
			}
		}
	}
}

update_state_alias :: proc(r: ^References, access: State_Access, resource: State_Location, name: string, value: State_Access, weak: bool, memo: ^Field_Transforms) -> (result: State_Access, changed: bool) {
	result = access
	if access.addressed {
		path := [1]string{"[]" if name == "" else name}
		resources := [1]State_Location{resource}
		if updated, different := store_address_contents(r, access, resources[:], path[:], value, weak); different {return updated, true}
	}
	key := field_identity(access.fields)
	if previous, found := memo^[key]; found {result.fields, changed = previous.fields, previous.changed} else {
		for field_name, child in access.fields {
			updated, different := update_state_alias(r, child^, resource, name, value, weak, memo)
			if !different {continue}
			if !changed {
				result.fields = make(map[string]^State_Access, len(access.fields)+1)
				for key, previous in access.fields {result.fields[key] = previous}
			}
			result.fields[field_name] = new_clone(updated)
			changed = true
		}
		memo^[key] = Field_Transform{result.fields, changed}
	}

	if access.resource == resource || slice.contains(access.resources[:], resource) {
		stored := value
		if previous, exists := result.fields[name]; exists && (weak || len(access.resources) > 0) {
			joined, different := join_state_access(previous^, stored)
			if !different {return}
			stored = joined
		}
		if previous, exists := result.fields[name]; exists && state_access_equal(previous^, stored) {return}
		if !changed {
			result.fields = make(map[string]^State_Access, len(access.fields)+1)
			for key, previous in access.fields {result.fields[key] = previous}
		}
		result.fields[name] = new_clone(stored)
		changed = true
	}
	return
}

// Known-zero storage has no incoming borrows except declared defaults.
// Materialize inline children, nil reference slots and those defaults uniformly.
fresh_zero_value :: proc(check: ^State_Flow, access: State_Access, depth: int) -> State_Access {
	r := check.r
	result := access
	result.protected, result.immutable, result.published = false, false, false
	result.origins, result.resource, result.resources = nil, {}, nil
	result.zero = .Zero
	result.fields = nil
	if result.pointer || result.shared {result.nil_value = true; return result}
	if result.type == nil || depth > len(r.symbols)+len(r.scopes) {return result}
	#partial switch record in result.type.derived {
	case ^ast.Struct_Type:
		result.fields = make(map[string]^State_Access)
		if record.fields != nil {for field in record.fields.list {for expression in field.names {
			if name, named := binding_name(expression); named {
				child := field_access(r, access, name, depth+1)
				if field.default_value != nil {result.fields[name] = new_clone(copy_state_value(r, fit_state_value(state_access(check, field.default_value, access.scope, depth+1), child, check, depth+1), depth+1))} else {result.fields[name] = new_clone(fresh_zero_value(check, child, depth+1))}
			}
		}}}
	case ^ast.Array_Type:
		if record.len != nil {result.fields = make(map[string]^State_Access); result.fields[""] = new_clone(fresh_zero_value(check, element_access(r, access, depth+1), depth+1))}
	}
	return result
}

promote_state_access :: proc(check: ^State_Flow, access: State_Access, scope, offset, depth: int) {
	if access.type == nil || depth > len(check.r.symbols)+len(check.r.scopes) {return}
	if record, ok := access.type.derived.(^ast.Struct_Type); ok && record.fields != nil {
		for field in record.fields.list {
			for expression in field.names {
				name, named := binding_name(expression)
				if !named {continue}
				ids, certain := lookup(check.r, name, scope, offset)
				if certain && len(ids) == 1 {
					check.bindings[ids[0]] = field_access(check.r, access, name, depth+1)
					if check.referents == nil {check.referents = make(map[int]bool)}
					check.referents[ids[0]] = true
				}
			}
			if .Using in field.flags {
				inner := access_type(check.r, field.type, access.scope, depth+1)
				if len(field.names) > 0 {
					if name, named := binding_name(field.names[0]); named {inner = field_access(check.r, access, name, depth+1)}
				}
				promote_state_access(check, inner, scope, offset, depth+1)
			}
		}
	}
}
