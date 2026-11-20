#+private
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:mem"
import "core:odin/ast"
import "core:slice"
import "core:strings"

// -------------------------------- Types --------------------------------

// ---------------- Package ----------------

// Child maps are immutable snapshots. A transform cache lives for one operation
// with fixed arguments, and caches only children: root capabilities can differ
// between values that share those same children.
Field_Transforms :: map[uintptr]Field_Transform

Field_Transform :: struct {fields: map[string]^State_Access, changed: bool}

// Immutable child maps can cache which allocation roots they contain across
// the ordered stores of one call. Root capabilities remain outside this cache.
Field_Roots :: map[struct {fields: uintptr, root: ^ast.Expr}]bool

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

// Summaries outlive the transient inference walk. Copy every owned allocation,
// preserving shared children; AST pointers and symbol/scope indexes remain in
// the caller-owned project graph.
clone_semantic_facts :: proc(source: []Procedure_Facts) -> []Procedure_Facts {
	result := slice.clone(source)
	memo := make(Field_Transforms)
	for &facts in result {
		facts.parameters = slice.clone_to_dynamic(facts.parameters[:])
		facts.result_types = slice.clone_to_dynamic(facts.result_types[:])
		facts.result_bindings = slice.clone_to_dynamic(facts.result_bindings[:])
		facts.accesses = slice.clone_to_dynamic(facts.accesses[:])
		for &access in facts.accesses {access.origin = clone_access_origin(access.origin)}
		facts.stores = slice.clone_to_dynamic(facts.stores[:])
		for &stored in facts.stores {
			stored.destination = clone_access_origin(stored.destination)
			stored.value = clone_state_graph(stored.value, &memo)
			stored.order = slice.clone_to_dynamic(stored.order[:])
		}
		facts.results = slice.clone_to_dynamic(facts.results[:])
		for &value in facts.results {value = clone_state_graph(value, &memo)}
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
			invocation.arguments = slice.clone(invocation.arguments)
			for &argument in invocation.arguments {argument = clone_state_graph(argument, &memo)}
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
clone_state_graph :: proc(source: State_Access, memo: ^Field_Transforms, predicates := false) -> State_Access {
	result := source
	if !predicates {result.condition, result.condition_version, result.condition_negated = nil, nil, false}
	result.fields = nil
	result.callables = slice.clone_to_dynamic(source.callables[:])
	result.origins = slice.clone_to_dynamic(source.origins[:])
	for &origin in result.origins {origin = clone_access_origin(origin)}
	result.slot_origins = slice.clone_to_dynamic(source.slot_origins[:])
	for &origin in result.slot_origins {origin = clone_access_origin(origin)}
	result.resource.path, result.slot.path = strings.clone(source.resource.path), strings.clone(source.slot.path)
	result.resources = slice.clone_to_dynamic(source.resources[:])
	for &resource in result.resources {resource.path = strings.clone(resource.path)}
	if len(source.fields) > 0 {
		key := field_identity(source.fields)
		if previous, found := memo^[key]; found {result.fields = previous.fields} else {
			result.fields = make(map[string]^State_Access, len(source.fields))
			for name, child in source.fields {result.fields[strings.clone(name)] = new_clone(clone_state_graph(child^, memo, predicates))}
			memo^[key] = Field_Transform{fields = result.fields}
		}
	}
	return result
}

// Seed a binding-retention cache before store replay changes any snapshots.
// These fields already belong to the enclosing body and need no second copy.
remember_state_fields :: proc(fields: map[string]^State_Access, memo: ^Field_Transforms) {
	if len(fields) == 0 {return}
	key := field_identity(fields)
	if _, known := memo^[key]; known {return}
	memo^[key] = Field_Transform{fields = fields}
	for _, child in fields {remember_state_fields(child.fields, memo)}
}

field_identity :: proc(fields: map[string]^State_Access) -> uintptr {
	return (transmute(mem.Raw_Map)fields).data
}

// ---------------- File ----------------

@(private = "file")
clone_access_origin :: proc(origin: Access_Origin) -> Access_Origin {
	result := origin
	result.path = strings.clone(origin.path)
	return result
}
