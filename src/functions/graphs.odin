#+private
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "base:runtime"
import "core:mem"
import "core:odin/ast"
import "core:slice"
import "core:strings"

// -------------------------------- Constants --------------------------------

// ---------------- File ----------------

// Small alternative sets are cheaper to scan; larger unions need one lookup
// table per operation to avoid quadratic comparisons of the same locations.
@(private = "file")
RESOURCE_LOOKUP_THRESHOLD :: 16

// -------------------------------- Types --------------------------------

// ---------------- Package ----------------

// Retention preserves sharing of immutable resource arrays as well as children.
// Identity includes length because snapshots may share the same backing array.
State_Clones :: struct {
	fields: Field_Transforms,
	resources: Resource_Clones,
	reads: Read_Clones,
	orders: Read_Order_Clones,
}


// Child maps are immutable snapshots. A transform cache lives for one operation
// with fixed arguments, and caches only children: root capabilities can differ
// between values that share those same children.
Field_Transforms :: map[uintptr]Field_Transform


Field_Transform :: struct {fields: map[string]^State_Access, changed: bool}

// Immutable child maps can cache which allocation roots they contain across
// the ordered stores of one call. Root capabilities remain outside this cache.
Field_Roots :: map[struct {fields: uintptr, root: ^ast.Expr}]bool

// ---------------- File ----------------


@(private = "file")
Resource_Clones :: map[struct {data: uintptr, length: int}][dynamic]State_Location

@(private = "file")
Read_Clones :: map[struct {data: uintptr, length: int}][dynamic]State_Read

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

append_state_resource :: proc(access: ^State_Access, resource: State_Location, copied: ^bool, seen: ^map[State_Location]bool, use_index := true) -> bool {
	if resource == access.resource {return false}
	if use_index && seen^ == nil && len(access.resources) >= RESOURCE_LOOKUP_THRESHOLD {
		// This operation-local index must be freed by the caller even while
		// result allocations belong to a procedure's transient arena.
		seen^ = make(map[State_Location]bool, len(access.resources), runtime.heap_allocator())
		for existing in access.resources {seen^[existing] = true}
	}
	if seen^ != nil {
		if seen^[resource] {return false}
		seen^[resource] = true
	} else if slice.contains(access.resources[:], resource) {return false}
	if !copied^ {access.resources = slice.clone_to_dynamic(access.resources[:], runtime.heap_allocator()); copied^ = true}
	append(&access.resources, resource)
	return true
}

// Build unions on a freeing allocator; retain only the final immutable array
// in the result lifetime, not the discarded capacity-growth buffers.
retain_state_resources :: proc(access: ^State_Access, copied: bool) {
	if !copied {return}
	resources := access.resources
	access.resources = slice.clone_to_dynamic(resources[:])
	delete(resources)
}

// Loop checkpoints retain every live analysis root before releasing scratch.
// Counter revision identities live in the enclosing inference pass, so copying
// their maps preserves correlation with predicates in retained child graphs.
clone_state_flow :: proc(source: State_Flow) -> State_Flow {
	result := source
	memo := make_state_clones()
	defer delete_state_clones(&memo)
	result.bindings = make(map[int]State_Access, cap(source.bindings))
	for id, value in source.bindings {result.bindings[id] = clone_state_graph(value, &memo, true)}
	result.evaluated = make(map[Expression_Result]int, cap(source.evaluated))
	for key, value in source.evaluated {result.evaluated[key] = value}
	result.referents = make(map[int]bool, cap(source.referents))
	for key, value in source.referents {result.referents[key] = value}
	result.callback_arguments = make(map[int][]State_Access, cap(source.callback_arguments))
	for id, arguments in source.callback_arguments {
		values := slice.clone(arguments)
		for &value in values {value = clone_state_graph(value, &memo, true)}
		result.callback_arguments[id] = values
	}
	result.replay_arguments = slice.clone(source.replay_arguments)
	for &snapshot in result.replay_arguments {
		snapshot.order = slice.clone_to_dynamic(snapshot.order[:])
		snapshot.values = slice.clone(snapshot.values)
		for &value in snapshot.values {value = clone_state_graph(value, &memo, true)}
	}
	result.block_stmts = slice.clone(source.block_stmts)
	result.deferred = slice.clone_to_dynamic(source.deferred[:])
	for &statement in result.deferred {statement.order = slice.clone_to_dynamic(statement.order[:])}
	result.store_order = slice.clone_to_dynamic(source.store_order[:])
	result.available.clauses = slice.clone(source.available.clauses)
	for &clause in result.available.clauses {
		clause.tests = slice.clone(clause.tests)
		for &test in clause.tests {test.atom = strings.clone(test.atom)}
	}
	result.transactions = make(map[State_Location]Active_Transaction, cap(source.transactions))
	for key, value in source.transactions {key := key; key.path = strings.clone(key.path); result.transactions[key] = value}
	result.nil_guards = slice.clone_to_dynamic(source.nil_guards[:])
	result.counter_history = slice.clone_to_dynamic(source.counter_history[:])
	for &change in result.counter_history {change.origin.path = strings.clone(change.origin.path)}
	result.counter_versions = make(map[State_Location]^bool, cap(source.counter_versions))
	for key, value in source.counter_versions {key := key; key.path = strings.clone(key.path); result.counter_versions[key] = value}
	result.counter_conditions = make(map[^ast.Expr]Counter_Condition, cap(source.counter_conditions))
	for expression, original in source.counter_conditions {
		condition := original
		condition.history = slice.clone_to_dynamic(original.history[:])
		for &change in condition.history {change.origin.path = strings.clone(change.origin.path)}
		condition.transactions = make(map[State_Location]Active_Transaction, cap(original.transactions))
		for key, value in original.transactions {key := key; key.path = strings.clone(key.path); condition.transactions[key] = value}
		condition.versions = make(map[State_Location]^bool, cap(original.versions))
		for key, value in original.versions {key := key; key.path = strings.clone(key.path); condition.versions[key] = value}
		condition.effects = slice.clone_to_dynamic(original.effects[:])
		for &effect in condition.effects {effect.access = clone_state_graph(effect.access, &memo, true); effect.owner = clone_state_graph(effect.owner, &memo, true)}
		for &outcome, i in condition.outcomes {
			outcome = slice.clone_to_dynamic(original.outcomes[i][:])
			for &effect in outcome {effect.access = clone_state_graph(effect.access, &memo, true); effect.owner = clone_state_graph(effect.owner, &memo, true)}
		}
		condition.predicate.origin.path = strings.clone(condition.predicate.origin.path)
		result.counter_conditions[expression] = condition
	}
	return result
}

// Summaries outlive the transient inference walk. Copy every owned allocation,
// preserving shared children; AST pointers and symbol/scope indexes remain in
// the caller-owned project graph.
clone_semantic_facts :: proc(source: []Procedure_Facts, memo: ^State_Clones = nil) -> []Procedure_Facts {
	result := slice.clone(source)
	memo := memo
	storage: State_Clones
	if memo == nil {
		storage = make_state_clones()
		memo = &storage
	}
	defer delete_state_clones(&storage)
	for &facts in result {
		facts.parameters = slice.clone_to_dynamic(facts.parameters[:])
		facts.result_types = slice.clone_to_dynamic(facts.result_types[:])
		facts.result_bindings = slice.clone_to_dynamic(facts.result_bindings[:])
		facts.accesses = slice.clone_to_dynamic(facts.accesses[:])
		for &access in facts.accesses {access.origin = clone_access_origin(access.origin)}
		facts.stores = slice.clone_to_dynamic(facts.stores[:])
		for &stored in facts.stores {
			stored.destination = clone_access_origin(stored.destination)
			stored.value = clone_state_graph(stored.value, memo)
			stored.order = slice.clone_to_dynamic(stored.order[:])
			stored.available.clauses = slice.clone(stored.available.clauses)
			for &clause in stored.available.clauses {
				clause.tests = slice.clone(clause.tests)
				for &test in clause.tests {test.atom = strings.clone(test.atom)}
			}
		}
		facts.results = slice.clone_to_dynamic(facts.results[:])
		for &value in facts.results {value = clone_state_graph(value, memo)}
		facts.counters = slice.clone_to_dynamic(facts.counters[:])
		for &counter in facts.counters {counter.origin = clone_access_origin(counter.origin)}
		facts.counter_resets = slice.clone_to_dynamic(facts.counter_resets[:])
		for &origin in facts.counter_resets {origin = clone_access_origin(origin)}
		facts.true_counters = slice.clone_to_dynamic(facts.true_counters[:])
		for &counter in facts.true_counters {counter.origin = clone_access_origin(counter.origin)}
		facts.returned_predicates = slice.clone_to_dynamic(facts.returned_predicates[:])
		for &predicate in facts.returned_predicates {predicate.origin = clone_access_origin(predicate.origin)}
		facts.false_counters = slice.clone_to_dynamic(facts.false_counters[:])
		for &counter in facts.false_counters {counter.origin = clone_access_origin(counter.origin)}
		facts.snapshots = slice.clone_to_dynamic(facts.snapshots[:])
		for &origin in facts.snapshots {origin = clone_access_origin(origin)}
		facts.copies = slice.clone_to_dynamic(facts.copies[:])
		facts.lifecycle = slice.clone_to_dynamic(facts.lifecycle[:])
		facts.publications = slice.clone_to_dynamic(facts.publications[:])
		for &publication in facts.publications {
			publication.destination = clone_access_origin(publication.destination)
			publication.left, publication.right = clone_access_origin(publication.left), clone_access_origin(publication.right)
		}
		facts.invocations = slice.clone_to_dynamic(facts.invocations[:])
		for &invocation in facts.invocations {
			invocation.origin = clone_access_origin(invocation.origin)
			invocation.callback = clone_state_graph(invocation.callback, memo)
			invocation.order = slice.clone_to_dynamic(invocation.order[:])
			invocation.available.clauses = slice.clone(invocation.available.clauses)
			for &clause in invocation.available.clauses {
				clause.tests = slice.clone(clause.tests)
				for &test in clause.tests {test.atom = strings.clone(test.atom)}
			}
			invocation.arguments = slice.clone(invocation.arguments)
			for &argument in invocation.arguments {argument = clone_state_graph(argument, memo)}
		}
	}
	return result
}

join_state_field :: proc(fields: ^map[string]^State_Access, name: string, value: State_Access) {
	previous: State_Access
	saved, exists := fields^[name]
	if exists {previous = saved^}
	joined, changed := join_state_access(previous, value)
	if changed || !exists {fields^[name] = new_clone(joined)}
}

// Equality for unchanged snapshots includes slot and predicate evidence, not
// only the monotone capabilities used by join_state_access. Child maps are
// immutable; equal identities need no traversal.
state_access_equal :: proc(left, right: State_Access) -> bool {
	if len(left.reads) != len(right.reads) {return false}
	for read, i in left.reads {if read.origin != right.reads[i].origin || !read_order_equal(read.order, right.reads[i].order) {return false}}
	return left.type == right.type && left.zero == right.zero &&
	       left.condition == right.condition && left.condition_version == right.condition_version &&
	       left.condition_negated == right.condition_negated && left.scope == right.scope &&
	       left.protected == right.protected && left.live == right.live &&
	       left.pointer == right.pointer && left.shared == right.shared &&
	       left.local == right.local && left.indirect == right.indirect &&
	       left.uncertain == right.uncertain && left.ambient == right.ambient &&
	       left.decoded == right.decoded && left.immutable == right.immutable &&
	       left.catalog_type == right.catalog_type && left.callback_effects == right.callback_effects &&
	       left.callback_modeled == right.callback_modeled && left.callback_unknown == right.callback_unknown &&
	       left.callback_returns == right.callback_returns &&
	       left.nil_value == right.nil_value && left.published == right.published &&
	       left.resource == right.resource && left.slot == right.slot &&
	       left.addressed == right.addressed && left.slot_protected == right.slot_protected &&
	       left.slot_published == right.slot_published && left.slot_immutable == right.slot_immutable &&
	       left.slot_local == right.slot_local && slice.equal(left.callables[:], right.callables[:]) &&
	       slice.equal(left.origins[:], right.origins[:]) && slice.equal(left.slot_origins[:], right.slot_origins[:]) &&
	       slice.equal(left.resources[:], right.resources[:]) && (field_identity(left.fields) == field_identity(right.fields) || len(left.fields) == 0 && len(right.fields) == 0)
}

// Copy newly retained graphs while reusing any immutable children already
// owned by the destination lifetime. Working bindings preserve predicates.
clone_state_graph :: proc(source: State_Access, memo: ^State_Clones, predicates := false) -> State_Access {
	result := source
	if !predicates {result.condition, result.condition_version, result.condition_negated = nil, nil, false}
	result.fields = nil
	result.callables = slice.clone_to_dynamic(source.callables[:])
	result.reads = nil
	if len(source.reads) > 0 {
		key := struct {data: uintptr, length: int}{uintptr(raw_data(source.reads)), len(source.reads)}
		if previous, found := memo.reads[key]; found {result.reads = previous} else {
			result.reads = slice.clone_to_dynamic(source.reads[:])
			for &read in result.reads {read.origin = clone_access_origin(read.origin); read.order = clone_read_order(read.order, &memo.orders)}
			memo.reads[key] = result.reads
		}
	}
	result.origins = slice.clone_to_dynamic(source.origins[:])
	for &origin in result.origins {origin = clone_access_origin(origin)}
	result.slot_origins = slice.clone_to_dynamic(source.slot_origins[:])
	for &origin in result.slot_origins {origin = clone_access_origin(origin)}
	result.resource.path, result.slot.path = strings.clone(source.resource.path), strings.clone(source.slot.path)
	result.resources = nil
	if len(source.resources) > 0 {
		key := struct {data: uintptr, length: int}{uintptr(raw_data(source.resources)), len(source.resources)}
		if previous, found := memo.resources[key]; found {result.resources = previous} else {
			result.resources = slice.clone_to_dynamic(source.resources[:])
			for &resource in result.resources {resource.path = strings.clone(resource.path)}
			memo.resources[key] = result.resources
		}
	}
	if len(source.fields) > 0 {
		key := field_identity(source.fields)
		if previous, found := memo.fields[key]; found {result.fields = previous.fields} else {
			result.fields = make(map[string]^State_Access, cap(source.fields))
			for name, child in source.fields {result.fields[strings.clone(name)] = new_clone(clone_state_graph(child^, memo, predicates))}
			memo.fields[key] = Field_Transform{fields = result.fields}

		}
	}
	return result
}

// Seed a binding-retention cache before store replay changes any snapshots.
// These arrays and fields belong to the enclosing body and need no second copy.
remember_state_graph :: proc(value: State_Access, memo: ^State_Clones) {
	if len(value.reads) > 0 {
		key := struct {data: uintptr, length: int}{uintptr(raw_data(value.reads)), len(value.reads)}
		memo.reads[key] = value.reads
		for read in value.reads {clone_read_order(read.order, &memo.orders, true)}
	}
	if len(value.resources) > 0 {
		key := struct {data: uintptr, length: int}{uintptr(raw_data(value.resources)), len(value.resources)}
		memo.resources[key] = value.resources
	}
	if len(value.fields) == 0 {return}
	key := field_identity(value.fields)
	if _, known := memo.fields[key]; known {return}
	memo.fields[key] = Field_Transform{fields = value.fields}
	for _, child in value.fields {remember_state_graph(child^, memo)}
}

field_identity :: proc(fields: map[string]^State_Access) -> uintptr {
	return (transmute(mem.Raw_Map)fields).data
}

make_state_clones :: proc() -> State_Clones {
	heap := runtime.heap_allocator()
	return State_Clones{fields = make(Field_Transforms, heap), resources = make(Resource_Clones, heap), reads = make(Read_Clones, heap), orders = {sources = make(map[^Read_Order]^Read_Order, heap), sets = make(map[u64]^Read_Order, heap), collisions = make(map[^Read_Order]^Read_Order, heap)}}
}

delete_state_clones :: proc(memo: ^State_Clones) {
	delete(memo.fields)
	delete(memo.resources)
	delete(memo.reads)
	delete(memo.orders.sources)
	delete(memo.orders.sets)
	delete(memo.orders.collisions)
}


// ---------------- File ----------------

@(private = "file")
clone_access_origin :: proc(origin: Access_Origin) -> Access_Origin {
	result := origin
	result.path = strings.clone(origin.path)
	return result
}
