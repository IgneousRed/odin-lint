#+private
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

Semantics :: struct {
	r: ^References,
	facts: []Procedure_Facts,
	infer, changed: bool,
	allocator: mem.Allocator,
	pending: []bool,
	dependents: []map[int]bool,
	owner: int,
	contracts: bool,
	transactions: [dynamic]Transaction_Fact,
}

Procedure_Facts :: struct {
	// Bottom for a saved body: a missing summary cannot yet continue a caller.
	normal_return: bool,
	parameters: [dynamic]int,
	accesses: [dynamic]Parameter_Access,
	stores: [dynamic]Stored_Value,
	results: [dynamic]State_Access,
	result_types: [dynamic]^ast.Expr,
	result_bindings: [dynamic]int,
	effects: bit_set[Call_Effect],
	lifecycle: [dynamic]int,
	counters: [dynamic]Counter_Change,
	false_counters, true_counters: [dynamic]Counter_Change,
	returned_predicates: [dynamic]Returned_Predicate,
	unrelated_boolean_return: bool,
	counter_resets: [dynamic]Access_Origin,
	has_false_return, unknown_boolean_return: bool,
	snapshots: [dynamic]Access_Origin,
	copies: [dynamic]int,
	publications: [dynamic]Publication_Check,
	invocations: [dynamic]Callback_Invocation,
}

// Availability selects compile-time paths; weak retains runtime unwritten
// alternatives. Conditional also includes configuration-only writes for lifecycle
// consumers, which must never infer unconditional initialization from one path.
Stored_Value :: struct {destination: Access_Origin, value: State_Access, initializes, conditional, weak: bool, site, invocation: tokenizer.Pos, order: [dynamic]tokenizer.Pos, available: Availability}

Counter_Change :: struct {origin: Access_Origin, delta: int}

Returned_Predicate :: struct {origin: Access_Origin, call: ^ast.Expr, negated: bool}

Publication_Check :: struct {
	destination, left, right: Access_Origin,
	left_zero, right_zero: Value_Zero,
	equal: bool,
	// ASTs live for the invocation, including across summary generations.
	expression: ^ast.Expr,
	truth: bool,
}


Field_Path_Key :: struct {path, field: string, repeat: bool}


// Read timing belongs to the value, so assigning a saved callback later does
// not reload its source after an aliased formal write.
State_Read :: struct {origin: Access_Origin, order: ^Read_Order}
Replay_Arguments :: struct {order: [dynamic]tokenizer.Pos, values: []State_Access}

Access_Origin :: struct {parameter: int, path: string}

Transaction_Fact :: struct {
	owner_type: ^ast.Expr,
	counter_path: string,
	working: [dynamic]string,
}

Active_Transaction :: struct {depth, possible, model: int}

Call_Effect :: enum {IO, System_IO, File_IO, Network_IO, Clock, Ambient, Rendering, Unknown}


// ---------------- File ----------------

@(private = "file")
Parameter_Access :: struct {origin: Access_Origin, kind: Access_Kind, owner, slot: bool}

@(private = "file")
Callback_Invocation :: struct {origin: Access_Origin, callback: State_Access, arguments: []State_Access, pos: tokenizer.Pos, optional: bool, order: [dynamic]tokenizer.Pos, available: Availability}

@(private = "file")
Access_Kind :: enum {Write, Destroy, Invoke, Transaction, Requires_Transaction}


// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

// New field reads acquire the current execution order. Values loaded from a
// saved binding already have their read point and must retain it.
read_state_access :: proc(check: ^State_Flow, access: State_Access, pos: tokenizer.Pos) -> State_Access {
	result := access
	for origin in access.origins {
		if origin.path == "" {continue}
		found := false
		for read in access.reads {if read.origin == origin {found = true; break}}
		if found {continue}
		order := prefix_read_order(check.r.read_cache, nil, check.store_order[:], pos)
		if len(result.reads) == len(access.reads) {result.reads = slice.clone_to_dynamic(access.reads[:])}
		append(&result.reads, State_Read{origin, order})
	}
	if !access.pointer && !access.shared {
		copied := false
		for name, child in access.fields {
			value := read_state_access(check, child^, pos)
			if state_access_equal(child^, value) {continue}
			if !copied {
				result.fields = make(map[string]^State_Access, len(access.fields))
				for key, field in access.fields {result.fields[key] = field}
				copied = true
			}
			result.fields[name] = new_clone(value)
		}
	}
	return result
}

// The same walk computes a monotone summary and, after convergence, reports
// selected-source findings. Arguments remain explicit capabilities: writing a
// private buffer is different from writing a borrowed relation through a helper.
analyze_semantics :: proc(model: ^Semantics, diagnostics: ^[dynamic]state.Diagnostic, infer: bool) {
	model.infer = infer
	model.allocator = context.allocator
	model.owner = -1
	check := State_Flow{r = model.r, diagnostics = diagnostics, bindings = make(map[int]State_Access), quiet = infer, caller = -1,
		transactions = make(map[State_Location]Active_Transaction)}
	visitor := ast.Visitor{visit = visit_state_flow, data = &check}
	for file in model.r.files {
		for statement in file.file.decls {ast.walk(&visitor, statement)}
	}

}

apply_callback :: proc(check: ^State_Flow, callback: State_Access, arguments: []State_Access, pos: tokenizer.Pos, required := false) -> (may_return: bool) {
	model := check.r.semantics
	if model == nil || callback.nil_value || callback.zero == .Zero {return true}
	may_return = callback.callback_unknown || callback.callback_returns || callback.callback_effects != {} || len(callback.origins) > 0 || len(callback.callables) == 0
	for effect in callback.callback_effects {record_effect(check, effect, pos)}
	record_access(check, callback, .Invoke)
	for origin in callback.origins {
		if model.infer && check.caller >= 0 {
			facts := &model.facts[check.caller]
			optional := !required || check.branch_depth > 0 || check.optional_stores || availability_possible(check.r, availability_not(check.available))
			found := false
			value := State_Access{callback_modeled = true}
			append(&value.origins, origin)
			for read in callback.reads {if read.origin == origin {append(&value.reads, read)}}
			order := slice.clone_to_dynamic(check.store_order[:])
			append(&order, pos)
			for &invocation in facts.invocations {
				if invocation.origin != origin || invocation.pos != pos || !slice.equal(invocation.order[:], order[:]) {continue}
				if availability_possible(check.r, availability_and(check.available, availability_not(invocation.available))) || availability_possible(check.r, availability_and(invocation.available, availability_not(check.available))) {continue}
				joined_callback, callback_changed := join_state_access(invocation.callback, value)
				if callback_changed {invocation.callback = joined_callback; model.changed = true}
				if optional && !invocation.optional {invocation.optional = true; model.changed = true}
				found = true
				for argument, i in arguments {
					if i >= len(invocation.arguments) {continue}
					joined, changed := join_state_access(invocation.arguments[i], argument)
					if changed {invocation.arguments[i] = joined; model.changed = true}
				}
			}
			if !found {append(&facts.invocations, Callback_Invocation{origin, value, slice.clone(arguments), pos, optional, order, check.available}); model.changed = true}
		}
	}
	if callback.callback_unknown || len(callback.callables) == 0 && len(callback.origins) == 0 && callback.callback_effects == {} && !callback.callback_modeled {record_effect(check, .Unknown, pos)}
	for target in callback.callables {
		// Join forwarding arguments monotonically, using the same bounded paths
		// and recursive-record joins as retained summaries. A covered back edge
		// stops nested forwarding but still checks direct state writes.
		if check.callback_arguments == nil {check.callback_arguments = make(map[int][]State_Access)}
		previous, recursive := check.callback_arguments[target]
		actual_arguments := arguments
		covered := recursive
		if recursive {
			if len(previous) != len(arguments) {record_effect(check, .Unknown, pos); continue}
			joined := slice.clone(previous)
			for argument, i in arguments {
				value, changed := join_state_access(previous[i], argument)
				joined[i], covered = value, covered && !changed
			}
			if !covered {check.callback_arguments[target] = joined}
			actual_arguments = joined
		} else {check.callback_arguments[target] = slice.clone(arguments)}
		defer {if !recursive {delete_key(&check.callback_arguments, target)}}
		if check.r.procedures[target].literal.body == nil {record_effect(check, .Unknown, pos)}
		facts := callee_facts(check, target)
		returns := facts.normal_return || check.r.procedures[target].literal.body == nil
		for effect in facts.effects {record_effect(check, effect, pos)}
		for requirement in facts.accesses {
			index, parameter := slice.linear_search(facts.parameters[:], requirement.origin.parameter)
			access: State_Access
			if parameter {
				if index >= len(actual_arguments) {record_effect(check, .Unknown, pos); continue}
				access = project_access(check.r, actual_arguments[index], requirement.origin.path)
			} else {
				captured, available := check.bindings[requirement.origin.parameter]
				if !available {record_effect(check, .Unknown, pos); continue}
				access = project_access(check.r, captured, requirement.origin.path)
			}
			if requirement.kind == .Invoke {continue}
			apply_parameter_access(check, access, requirement, pos)
		}
		apply_procedure_counters(check, facts, actual_arguments, target)
		completed := apply_stores(check, facts, actual_arguments, pos, nil, len(callback.callables) > 1, callbacks = !covered, required = required)
		returns = returns && completed
		may_return = may_return || returns
	}
	return
}

apply_parameter_access :: proc(check: ^State_Flow, access: State_Access, requirement: Parameter_Access, pos: tokenizer.Pos, procedure := "", parameter := -1) {
	kind := requirement.kind
	access := access
	if kind == .Write && requirement.slot {access = write_slot_access(access, referent = requirement.origin.path == "" && access.pointer)}
	if kind == .Requires_Transaction {
		if !access.protected || transaction_active(check, access) {return}
		record_access(check, access, kind)
		if len(access.origins) == 0 {report_boundary(check, pos, "OWN002", "engine relation mutation requires a matching transaction on this owner")}
		return
	}
	// A callee-authorized effect has separate unsatisfied preconditions. An
	// ordinary helper's write acquires owner permission here, so this engine
	// caller must establish the scope rather than silently laundering the write.
	record_access(check, access, kind, requirement.owner, enforce_transaction = !requirement.owner, slot = requirement.slot)
	if kind == .Write || kind == .Destroy {
		working := kind == .Write && working_assignment(check, access)
		if access.protected && (access.pointer || access.live || access.shared) && ((!requirement.owner && !working) || access.immutable) {
			message := "this call writes or destroys protected state"
			if parameter > 0 {message = fmt.aprintf("%s %s protected state through parameter %d", procedure, "destroys" if kind == .Destroy else "mutates", parameter)}
			report_write(check, access, pos, message, !access.immutable, requirement.origin.path)
		}
	}
	if kind == .Transaction && check.caller >= 0 {
		file := check.r.files[check.r.procedures[check.caller].file]
		if file.has_role && file.role == .Functions {report_boundary(check, pos, "OWN002", "functions may compute on owned data but must not invoke engine transactions")}
		if file.has_role && file.role == .UI && !(access.slot_local if requirement.slot else access.local) {report_boundary(check, pos, "OWN002", "UI may transact local interaction state; emit a typed request for meaningful-state changes")}
	}
}

// A permission never erases an actual write or release. Transaction scope is a
// separate caller precondition, discharged at the point of the operation.
record_access :: proc(check: ^State_Flow, access: State_Access, kind: Access_Kind, owner := false, enforce_transaction := false, slot := false) {
	model := check.r.semantics
	if model == nil || !model.infer || check.caller < 0 {return}
	facts := &model.facts[check.caller]
	file := check.r.files[check.r.procedures[check.caller].file]
	mutation := kind == .Write || kind == .Destroy
	owned := owner || mutation && !access.immutable && (file.has_role && file.role == .Engine || kind == .Write && working_assignment(check, access))
	for origin in access.origins {
		item := Parameter_Access{origin = origin, kind = kind, owner = owned, slot = slot}
		if !slice.contains(facts.accesses[:], item) {append(&facts.accesses, item); model.changed = true}
	}
	if !mutation || !owned {return}
	record_access(check, access, .Transaction, slot = slot)
	if !enforce_transaction || !model.contracts || !file.has_role || file.role != .Engine {return}
	for origin in access.origins {
		if slice.contains(facts.lifecycle[:], origin.parameter) {continue}
		base := check.bindings[origin.parameter]
		boundary := false
		for _, model_id in model.transactions {if boundary_direction(check, base, model_id) != 0 {boundary = true; break}}
		if !boundary && !transaction_active(check, base) {record_access(check, base, .Requires_Transaction)}
	}
}


record_effect :: proc(check: ^State_Flow, effect: Call_Effect, pos: tokenizer.Pos) {
	model := check.r.semantics
	if model == nil {return}
	if model.infer {
		if check.caller >= 0 && effect not_in model.facts[check.caller].effects {
			model.facts[check.caller].effects += {effect}
			model.changed = true
		}
		return
	}
	if check.quiet || effect == .Unknown {return}
	file := -1
	if check.caller >= 0 {file = check.r.procedures[check.caller].file} else {
		for source, i in check.r.files {if source.file.fullpath == pos.file {file = i; break}}
	}
	if file < 0 || !check.r.files[file].selected {return}
	source := check.r.files[file]
	if !source.has_role || source.role == .Application {return}
	if source.role == .Effects {
		if effect == .File_IO && strings.has_prefix(source.role_path, "effects/network/") ||
		effect == .Network_IO && strings.has_prefix(source.role_path, "effects/storage/") {
			append(check.diagnostics, state.Diagnostic{pos, "ARCH008", "worker I/O crosses the storage/network owner boundary; coordinate through effects and owned messages"})
		}
		return
	}
	if effect == .File_IO || effect == .Network_IO {return}
	if effect == .Rendering && source.role == .UI {return}
	if effect == .Ambient && source.role not_in PURE_ROLES && source.role != .UI {return}
	rule, message := "ARCH007", "external effects belong in effects or application; pass their results as explicit inputs"
	if effect == .System_IO {rule, message = "ARCH002", "OS/network effects belong in effects or application; use explicit data in lower roles"}
	if effect == .Ambient {message = "read mutable runtime state through explicit inputs, not an ambient package variable"}
	if effect == .Clock {rule, message = "ARCH006", "pass clock values explicitly; do not observe or wait for ambient time through this call"}
	append(check.diagnostics, state.Diagnostic{pos, rule, message})
}

call_arguments :: proc(literal: ^ast.Proc_Lit, call: ^ast.Call_Expr) -> [dynamic]^ast.Expr {
	parameters := make([dynamic]string)
	defaults := make([dynamic]^ast.Expr)
	if literal.type.params != nil {for field in literal.type.params.list {
		for expression in field.names {
			name, _ := binding_name(expression)
			append(&parameters, name)
			append(&defaults, field.default_value)
		}
	}}
	return slice.clone_to_dynamic(bind_arguments(parameters[:], defaults[:], call.args[:]))
}

call_procedures :: proc(r: ^References, expression: ^ast.Expr, scope: int) -> (targets: [dynamic]int, certain: bool) {
	if expression == nil {return}
	resolved := resolve_expr(r, expression, scope, expression.pos.offset)
	return resolved.targets, resolved.certain && len(resolved.targets) > 0
}

mark_authority :: proc(r: ^References, expression: ^ast.Expr, scope: int) {
	if expression == nil {return}
	expression := expression
	expression = unwrap_parens(expression)
	if r.authorities[expression] {return}
	r.authorities[expression] = true
	#partial switch n in expression.derived {
	case ^ast.Ident, ^ast.Selector_Expr:
		ids, certain := expression_symbols(r, expression, scope, expression.pos.offset)
		if certain && len(ids) == 1 {mark_authority(r, r.symbols[ids[0]].value, r.symbols[ids[0]].scope)}
	case ^ast.Struct_Type:
		if n.fields != nil {for field in n.fields.list {mark_authority(r, field.type, scope)}}
	case ^ast.Distinct_Type: mark_authority(r, n.type, scope)
	case ^ast.Helper_Type: mark_authority(r, n.type, scope)
		// Pointer fields may reference another owner or an immutable catalog. They
		// are not embedded ownership; access_type resolves their independent type.
	}
}

// Immutable child graphs share the same descendant result across one join.
// Root permissions are independent of the shared fields and stay outside the cache.
contains_protected_state :: proc(access: State_Access, memo: ^map[uintptr]bool) -> (protected: bool) {
	protected = access.protected && (access.pointer || access.shared || access.live)
	if protected || len(access.fields) == 0 {return}
	key := field_identity(access.fields)
	if cached, found := memo^[key]; found {return cached}
	for _, child in access.fields {
		if contains_protected_state(child^, memo) {protected = true; break}
	}
	if memo^ == nil {memo^ = make(map[uintptr]bool, runtime.heap_allocator())}
	memo^[key] = protected
	return
}

instantiate_access :: proc(check: ^State_Flow, access: State_Access, parameters: []int, arguments: []^ast.Expr, scope: int, allocation: ^ast.Expr = nil, events: ^Read_Event_Trie = nil) -> State_Access {
	values := make([]State_Access, len(arguments))
	for argument, i in arguments {values[i] = state_access(check, argument, scope, 0)}
	return instantiate_values(check, access, parameters, values, allocation, events = events)
}

instantiate_values :: proc(check: ^State_Flow, access: State_Access, parameters: []int, arguments: []State_Access, allocation: ^ast.Expr = nil, site := tokenizer.Pos{}, events: ^Read_Event_Trie = nil) -> State_Access {
	allocator := context.allocator
	heap := runtime.heap_allocator()
	retained := make_state_clones()
	defer delete_state_clones(&retained)
	remember_state_graph(access, &retained)
	for value in arguments {remember_state_graph(value, &retained)}
	for snapshot in check.replay_arguments {for value in snapshot.values {remember_state_graph(value, &retained)}}
	work: mem.Dynamic_Arena
	mem.dynamic_arena_init(&work, block_allocator = heap, array_allocator = heap, block_size = SCRATCH_BLOCK_SIZE, out_band_size = SCRATCH_BLOCK_SIZE/4)
	defer mem.dynamic_arena_destroy(&work)
	context.allocator = mem.dynamic_arena_allocator(&work)
	previous_cache := check.r.read_cache
	cache: Read_Cache
	check.r.read_cache = &cache
	defer {check.r.read_cache = previous_cache; delete_read_cache(&cache)}
	result := instantiate_value_graph(check, access, parameters, arguments, allocation, nil, site, events)
	context.allocator = allocator
	return clone_state_graph(result, &retained, true)
}

instantiate_value_graph :: proc(check: ^State_Flow, access: State_Access, parameters: []int, arguments: []State_Access, allocation: ^ast.Expr = nil, memo: ^Field_Transforms = nil, site := tokenizer.Pos{}, events: ^Read_Event_Trie = nil) -> State_Access {
	result := access
	result.origins = nil
	result.reads = nil
	mapped_fields: map[string]^State_Access
	if len(access.origins) > 0 {
		// A symbolic callback is a value supplied by the actual caller. Carry
		// every target/effect alternative, including nil and unknown, when its
		// value is returned or stored through another formal parameter.
		callback := known_callback_type(check.r, access.type, access.scope) || access.callback_modeled || access.callback_unknown || access.callback_returns || len(access.callables) > 0 || access.callback_effects != {}
		all_nil := callback && len(access.callables) == 0 && access.callback_effects == {} && !access.callback_unknown && !access.callback_returns
		all_modeled := true
		if callback {result.callables = slice.clone_to_dynamic(access.callables[:])}
		// Published evidence comes from concrete storage, never a formal's type.
		// Substitute symbolic identities, retaining the concrete alternatives in
		// either return order without applying formal restrictions to private data.
		result.protected = access.protected && access.published
		result.resource, result.resources = {}, nil
		resources_copied := false
		resources_seen: map[State_Location]bool
		defer delete(resources_seen)
		for index in 0..=len(access.resources) {
			resource := access.resource
			if index < len(access.resources) {resource = access.resources[index]}
			if resource.root == nil || resource.symbolic {continue}
			if result.resource.root == nil {result.resource = resource} else {append_state_resource(&result, resource, &resources_copied, &resources_seen)}
		}
		for origin in access.origins {
			index, found := slice.linear_search(parameters, origin.parameter)
			if !found || index >= len(arguments) {
				if callback {all_nil, all_modeled, result.callback_unknown = false, false, true}
				continue
			}
			value: State_Access
			found_read := false
			for read in access.reads {
				if read.origin != origin {continue}
				// Replay snapshots are in event order. Each interval selects one
				// historical value, however many read paths lie within it.
				for snapshot_index in -1..<len(check.replay_arguments) {
					lower, upper: []tokenizer.Pos
					values := arguments
					if snapshot_index >= 0 {lower = check.replay_arguments[snapshot_index].order[:]; values = check.replay_arguments[snapshot_index].values}
					has_upper := snapshot_index+1 < len(check.replay_arguments)
					if has_upper {upper = check.replay_arguments[snapshot_index+1].order[:]}
					if !read_order_between(read.order, lower, upper, snapshot_index >= 0, has_upper) {continue}
					observed := project_access(check.r, values[index], origin.path)
					if !found_read {value = observed} else {value, _ = join_state_access(value, observed)}
					found_read = true
				}
			}
			if !found_read {value = project_access(check.r, arguments[index], origin.path)}
			result.reads, _ = join_state_reads(result.reads, value.reads[:])
			if (allocation != nil || site.file != "") && len(value.reads) == 0 {
				for read in access.reads {
					if read.origin != origin {continue}
					position := allocation.pos if allocation != nil else site
					pruned := prune_read_order(read.order, events)
					order := prefix_read_order(check.r.read_cache, pruned, check.store_order[:], position)
					for mapped in value.origins {
						addition := []State_Read{{mapped, order}}
						result.reads, _ = join_state_reads(result.reads, addition)
					}
				}
			}
			result.protected = result.protected || value.protected
			result.ambient = result.ambient || value.ambient
			result.callback_returns = result.callback_returns || value.callback_returns
			if callback {
				if value.zero == .Zero {value.nil_value, value.callback_unknown = true, false}
				result.callback_effects |= value.callback_effects
				result.callback_unknown = result.callback_unknown || value.callback_unknown ||
					!value.nil_value && len(value.callables) == 0 && len(value.origins) == 0 && value.callback_effects == {} && !value.callback_modeled
				all_nil = all_nil && value.nil_value
				all_modeled = all_modeled && (value.callback_modeled || value.nil_value)
				for target in value.callables {if !slice.contains(result.callables[:], target) {append(&result.callables, target)}}
			} else {result.callback_modeled = result.callback_modeled || value.callback_modeled}
			result.published = result.published || value.published
			if result.resource.root == nil {result.resource = value.resource} else if value.resource.root != nil {append_state_resource(&result, value.resource, &resources_copied, &resources_seen)}
			for resource in value.resources {append_state_resource(&result, resource, &resources_copied, &resources_seen)}
			for mapped in value.origins {if !slice.contains(result.origins[:], mapped) {append(&result.origins, mapped)}}
			if len(value.fields) > 0 {
				if mapped_fields == nil {mapped_fields = make(map[string]^State_Access, len(value.fields)+len(access.fields))}
				for name, child in value.fields {
					if _, present := mapped_fields[name]; present {join_state_field(&mapped_fields, name, child^)} else {mapped_fields[name] = child}
				}
			}
		}
		retain_state_resources(&result, resources_copied)
		if callback {
			result.nil_value = all_nil
			result.callback_modeled = all_modeled
		}
	}
	// Allocation sites form a finite identity domain, including recursive factories.
	// Do not embed an unbounded chain of prior call paths in a fresh result key.
	if len(access.origins) == 0 && access.resource.root != nil && allocation != nil {
		result.resource = State_Location{root = allocation, path = fmt.aprintf("%p", access.resource.root)}
		result.resources = nil
		resources_copied := false
		resources_seen: map[State_Location]bool
		defer delete(resources_seen)
		for resource in access.resources {append_state_resource(&result, State_Location{root = allocation, path = fmt.aprintf("%p", resource.root)}, &resources_copied, &resources_seen)}
		retain_state_resources(&result, resources_copied)
	}
	result.fields = access.fields
	if len(access.fields) > 0 {
		memo := memo
		storage: Field_Transforms
		if memo == nil {storage = make(Field_Transforms, runtime.heap_allocator()); memo = &storage}
		defer delete(storage)
		key := field_identity(access.fields)
		if previous, found := memo^[key]; found {result.fields = previous.fields} else {
			result.fields = make(map[string]^State_Access, len(access.fields))
			for name, child in access.fields {result.fields[name] = new_clone(instantiate_value_graph(check, child^, parameters, arguments, allocation, memo, site, events))}
			memo^[key] = Field_Transform{fields = result.fields}
		}
	}
	if len(mapped_fields) > 0 {
		for name, child in result.fields {mapped_fields[name] = child}
		result.fields = mapped_fields
	}
	return result
}

// A formal mutation is a capability requirement, not evidence of a borrowed
// actual argument. Keep the requirement in summaries and enforce concrete saved
// callers; global, immutable, published and unknown alternatives remain checked.
report_write :: proc(check: ^State_Flow, access: State_Access, pos: tokenizer.Pos, message: string, allow_engine := true, field := "") {
	if check.quiet {return}
	deferred := false
	if check.caller >= 0 && !access.published && len(access.origins) > 0 {
		procedure := check.r.procedures[check.caller]
		if procedure.literal.body != nil {
			facts := check.r.semantics.facts[check.caller]
			deferred = true
			// Every resource alternative must be a formal requirement or established
			// private storage. A global/unknown alternative remains a concrete concern.
			for index in 0..=len(access.resources) {
				resource := access.resource
				if index < len(access.resources) {resource = access.resources[index]}
				formal := false
				if resource.root != nil && procedure.literal.type.params != nil {
					for field in procedure.literal.type.params.list {
						for name in field.names {if resource.root == name {formal = true; break}}
					}
				}
				if !formal && resource.root != nil {
					value := state_access(check, resource.root, check.r.node_scopes[resource.root], 0)
					formal = !value.protected && !value.published && !value.immutable && !value.uncertain && len(value.origins) == 0
				}
				if !formal {deferred = false; break}
			}
			for origin in access.origins {
				accounted := false
				if slice.contains(facts.parameters[:], origin.parameter) {
					for requirement in facts.accesses {if requirement.origin == origin && (requirement.kind == .Write || requirement.kind == .Destroy) {accounted = true; break}}
				}
				if !accounted {deferred = false; break}
			}
		}
	}
	if deferred {return}
	message := message
	// One call/parameter violation stays one finding. Include a deterministic
	// example field instead of multiplying diagnostics for every summary path.
	prefix := strings.concatenate({message, " (including field "})
	for &diagnostic in check.diagnostics^ {
		if diagnostic.rule != "OWN001" || diagnostic.pos != pos {continue}
		if diagnostic.message == message {return}
		if strings.has_prefix(diagnostic.message, prefix) {
			previous := diagnostic.message[len(prefix):len(diagnostic.message)-1]
			if field == "" {diagnostic.message = message} else if field < previous {diagnostic.message = fmt.aprintf("%s%s)", prefix, field)}
			return
		}
	}
	if field != "" {message = fmt.aprintf("%s%s)", prefix, field)}
	report_boundary(check, pos, "OWN001", message, allow_engine)
}

report_boundary :: proc(check: ^State_Flow, pos: tokenizer.Pos, rule, message: string, allow_engine := true) {
	if check.quiet {return}
	for file in check.r.files {
		if file.file.fullpath != pos.file || !file.selected {continue}
		if allow_engine && rule == "OWN001" && file.has_role && file.role == .Engine {return}
		append(check.diagnostics, state.Diagnostic{pos, rule, message})
		return
	}
}

working_assignment :: proc(check: ^State_Flow, access: State_Access) -> bool {
	if !access.local || access.shared || access.indirect || len(access.resources) > 0 || check.r.semantics == nil {return false}
	for resource, active in check.transactions {
		if active.depth <= 0 || resource.root != access.resource.root {continue}
		for field in check.r.semantics.transactions[active.model].working {
			path := field if resource.path == "" else strings.concatenate({resource.path, ".", field})
			if access.resource.path == path || strings.has_prefix(access.resource.path, strings.concatenate({path, "."})) {return true}
		}
	}
	return false
}

project_access :: proc(r: ^References, access: State_Access, path: string) -> State_Access {
	result := access
	rest := path
	for component in strings.split_iterator(&rest, ".") {
		if component == "" {continue}
		if component == "^" {
			if referent, known := result.fields["^"]; known {result = referent^} else {result = access_path(r, result, "^"); result.live, result.pointer = result.pointer, false}
		} else if component == "[]" {
			base := result
			result = element_access(r, base, 0)
			result.live = base.protected && (base.pointer || base.shared || base.live)

		} else {result = field_access(r, result, component, 0)}
	}
	return result
}

access_path :: proc(r: ^References, access: State_Access, field: string, repeat := false) -> State_Access {
	result := access
	repeat := repeat
	if field == "[]" && access.type != nil {if array, fixed := access.type.derived.(^ast.Array_Type); fixed {repeat = repeat || array.len != nil}}
	result.origins = make([dynamic]Access_Origin, len(access.origins))
	for origin, i in access.origins {result.origins[i] = Access_Origin{origin.parameter, append_access_field(r, origin.path, field, repeat && finite_location_index(r, State_Location{root = r.symbols[origin.parameter].type, path = origin.path, symbolic = true}))}}
	if result.resource.root != nil {
		allowed := repeat
		if allowed {allowed = finite_location_index(r, result.resource)}
		result.resource.path = append_access_field(r, result.resource.path, field, allowed)
	}
	result.resources = nil
	resources_copied := false
	resources_seen: map[State_Location]bool
	defer delete(resources_seen)
	for resource in access.resources {
		child := resource
		allowed := repeat
		if allowed {allowed = finite_location_index(r, child)}
		child.path = append_access_field(r, child.path, field, allowed)
		append_state_resource(&result, child, &resources_copied, &resources_seen)
	}
	retain_state_resources(&result, resources_copied)
	return result
}

finite_index_path :: proc(r: ^References, access: State_Access) -> (finite: bool) {
	current := Type_Scope{access.type, access.scope}
	start := current
	container := false
	if known, found := r.finite_index_types[current]; found {return known}
	seen := make(map[Type_Scope]bool, runtime.heap_allocator())
	defer delete(seen)
	for current.expression != nil && !seen[current] {
		seen[current] = true
		#partial switch type in current.expression.derived {
		case ^ast.Ident, ^ast.Selector_Expr:
			ids, certain := expression_symbols(r, current.expression, current.scope, current.expression.pos.offset)
			if !certain || len(ids) != 1 {finite = certain && len(ids) == 0 && container; break}
			symbol := r.symbols[ids[0]]
			current = Type_Scope{symbol.value, symbol.scope}
			continue
		case ^ast.Array_Type: container = true; current.expression = type.elem; continue
		case ^ast.Dynamic_Array_Type: container = true; current.expression = type.elem; continue
		case ^ast.Multi_Pointer_Type: container = true; current.expression = type.elem; continue
		case ^ast.Map_Type: container = true; current.expression = type.value; continue
		case ^ast.Pointer_Type: current.expression = type.elem; continue
		case ^ast.Distinct_Type: current.expression = type.type; continue
		case ^ast.Helper_Type: current.expression = type.type; continue
		case: finite = container
		}
		break
	}
	r.finite_index_types[start] = finite
	return
}


external_target :: proc(r: ^References, expression: ^ast.Expr, scope: int) -> (path, member: string) {
	if expression == nil {return}
	scope := scope
	callee := unwrap_parens(expression)
	for _ in 0..=len(r.symbols) {
		if selector, ok := callee.derived.(^ast.Selector_Expr); ok {
			ids, certain := expression_symbols(r, selector.expr, scope, selector.pos.offset)
			if certain && len(ids) == 1 && r.symbols[ids[0]].import_path != "" {
				path, member = r.symbols[ids[0]].import_path, selector.field.name
				break
			}
		}
		ids, certain := expression_symbols(r, callee, scope, callee.pos.offset)
		if !certain || len(ids) != 1 {break}
		symbol := r.symbols[ids[0]]
		if symbol.value == nil || symbol.written {break}
		callee, scope = unwrap_parens(symbol.value), symbol.scope
	}
	return
}

// Origins and allocation identities use the same finite path abstraction.
// Re-entering a field through a recursive shape widens to the whole resource,
// retaining conservative aliasing instead of creating next.next... forever.
// Fixed inline array dimensions are finite and must not collapse at the second [].
append_access_field :: proc(r: ^References, path, field: string, repeat := false) -> string {
	if path == "" {return field}
	key := Field_Path_Key{path, field, repeat}
	if value, found := r.field_paths[key]; found {return value}
	widened := false
	if !repeat {
		widened = field == "" && strings.has_suffix(path, ".")
		rest := path
		for component in strings.split_iterator(&rest, ".") {if component == field {widened = true; break}}
	}
	// Cache the complete pure transform, including recursive widening. Keys
	// and nonempty results belong to the invocation, not a temporary body.
	context.allocator = r.path_allocator
	key.path, key.field = strings.clone(path), strings.clone(field)
	value := ""
	if !widened {value = strings.concatenate({path, ".", field})}
	r.field_paths[key] = value
	return value
}


// Record actual summary reads, including callbacks and global initializers.
// Nested bodies invalidate their enclosing traversal, which supplies captures.
callee_facts :: proc(check: ^State_Flow, target: int) -> Procedure_Facts {
	model := check.r.semantics
	if model.infer && model.owner >= 0 {model.dependents[target][model.owner] = true}
	return model.facts[target]
}


// ---------------- File ----------------

@(private = "file")
transaction_active :: proc(check: ^State_Flow, access: State_Access) -> bool {
	for index in 0..=len(access.resources) {
		resource := access.resource
		if index < len(access.resources) {resource = access.resources[index]}
		active := false
		for owner, transaction in check.transactions {
			if transaction.depth <= 0 || owner.root != resource.root {continue}
			if owner == resource {active = true; break}
			// Scalar/value rows can belong to an enclosing owner. A distinct
			// relation owner still needs its own matching scope.
			if access.type == nil || access.uncertain || type_property(check.r, access.type, access.scope) {continue}
			if owner.path == "" || strings.has_prefix(resource.path, strings.concatenate({owner.path, "."})) {active = true; break}
		}
		if !active {return false}
	}
	return true
}

// A merged value may keep a container type after its path has consumed it.
// Consume the saved source shape independently of working field snapshots.
// Unknown shapes preserve existing conservative paths; a proved exhausted
// container disables repeated-index expansion and uses ordinary widening.
@(private = "file")
finite_location_index :: proc(r: ^References, location: State_Location) -> bool {
	if location.root == nil || !strings.contains(location.path, "[]") {return true}
	if value, known := r.index_paths[location]; known {return value}
	finite := true
	scope, scoped := r.node_scopes[location.root]
	if !scoped {scope, scoped = r.type_scopes[location.root]}
	source, is_type := location.root, false
	if declared, known := r.location_types[location.root]; known {
		source, scope, is_type, scoped = declared.source, declared.scope, declared.is_type, true
	}
	if scoped {
		shape := reference_type(r, source, scope, is_type, 0)
		rest := location.path
		for component in strings.split_iterator(&rest, ".") {
			if shape == nil {break}
			if actual, known := r.type_scopes[shape]; known {scope = actual}
			if component == "" || component == "^" {continue}
			next: ^ast.Expr
			#partial switch type in shape.derived {
			case ^ast.Map_Type:
				if component == "[]" {next = type.value}
			case ^ast.Array_Type:
				if component == "[]" {next = type.elem}
			case ^ast.Dynamic_Array_Type:
				if component == "[]" {next = type.elem}
			case ^ast.Struct_Type:
				if component == "[]" {finite = false; break}
				if type.fields != nil {for field in type.fields.list {for name in field.names {
					if ident, named := binding_name(name); named && ident == component {next = field.type}
				}}}
			}
			if !finite {break}
			shape = reference_type(r, next, scope, true, 0)
		}
		if shape != nil {
			#partial switch _ in shape.derived {
			case ^ast.Struct_Type, ^ast.Proc_Type: finite = false
			}
		}
	}
	context.allocator = r.path_allocator
	key := location
	key.path = strings.clone(location.path)
	r.index_paths[key] = finite
	return finite
}
