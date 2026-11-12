#+private
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:mem"
import "core:slice"
import "core:strings"

// -------------------------------- Types --------------------------------

// ---------------- Package ----------------

// Child maps are immutable snapshots. A transform cache lives for one operation
// with fixed arguments, and caches only children: root capabilities can differ
// between values that share those same children.
Field_Transforms :: map[uintptr]Field_Transform

Field_Transform :: struct {fields: map[string]State_Access, changed: bool}

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

field_identity :: proc(fields: map[string]State_Access) -> uintptr {
	return (transmute(mem.Raw_Map)fields).data
}

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

// ---------------- File ----------------

@(private = "file")
clone_state_graph :: proc(source: State_Access, memo: ^Field_Transforms) -> State_Access {
	result := source
	result.condition, result.condition_version, result.condition_negated = nil, nil, false
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
			result.fields = make(map[string]State_Access)
			for name, child in source.fields {result.fields[strings.clone(name)] = clone_state_graph(child, memo)}
			memo^[key] = Field_Transform{fields = result.fields}
		}
	}
	return result
}

@(private = "file")
clone_access_origin :: proc(origin: Access_Origin) -> Access_Origin {
	result := origin
	result.path = strings.clone(origin.path)
	return result
}
