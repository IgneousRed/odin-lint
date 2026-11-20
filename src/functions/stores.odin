#+private
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "base:runtime"
import "core:mem"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:slice"
import "core:strings"

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

// Field writes are relative to the actual caller. Preserve protected-state
// aliases while allowing independent private working copies.
apply_stores :: proc(check: ^State_Flow, facts: Procedure_Facts, arguments: []State_Access, pos: tokenizer.Pos, allocation: ^ast.Expr = nil, alternatives := false) {
	if len(facts.stores) == 0 {return}
	// A call can replay many field stores. Keep only the final bindings and
	// summary, rather than retaining every intermediate alias snapshot.
	allocator := context.allocator
	transient: mem.Dynamic_Arena
	heap := runtime.heap_allocator()
	mem.dynamic_arena_init(&transient, block_allocator = heap, array_allocator = heap, block_size = INFERENCE_BLOCK_SIZE, out_band_size = INFERENCE_BLOCK_SIZE/8)
	context.allocator = mem.dynamic_arena_allocator(&transient)
	changed_bindings := make(map[int]bool)
	retained := make(Field_Transforms)
	for _, binding in check.bindings {remember_state_fields(binding.fields, &retained)}
	summary_changed := false
	defer {
		context.allocator = allocator
		for id in changed_bindings {check.bindings[id] = clone_state_graph(check.bindings[id], &retained, true)}
		if model := check.r.semantics; summary_changed {
			model.facts[check.caller] = clone_semantic_facts(model.facts[check.caller:check.caller+1])[0]
		}
		mem.dynamic_arena_destroy(&transient)
	}
	stores := slice.clone(facts.stores[:])
	slice.sort_by(stores, store_before)
	// Arguments are immutable snapshots for this call; all transfers share the
	// same substitution even when a value occurs in several destination stores.
	instantiated := make(Field_Transforms)
	roots := make(Field_Roots)
	for stored in stores {
		index, found := slice.linear_search(facts.parameters[:], stored.destination.parameter)
		if !found || index >= len(arguments) {continue}
		base := arguments[index]
		if base.nil_value {continue}
		destination := project_access(check.r, base, stored.destination.path)
		value := instantiate_values(check, stored.value, facts.parameters[:], arguments, allocation, &instantiated)
		value = fit_state_value(value, destination, check)
		if value.decoded {
			value = decoded_output(check.r, destination, value.resource.root)
		}
		sequence := make([dynamic]tokenizer.Pos)
		append(&sequence, pos)
		recursive := slice.contains(stored.order[:], pos)
		if !recursive {append(&sequence, ..stored.order[:])}
		stored_summary := record_store(check, destination, value, stored.initializes, stored.conditional || len(base.resources) > 0 || alternatives || recursive, stored.site, pos, sequence[:])
		summary_changed = summary_changed || stored_summary
		store_bindings(check, base, strings.split(stored.destination.path, "."), value, stored.conditional || alternatives, &roots, &changed_bindings)
	}
}

// Each possible destination shares one transform across all binding aliases.
// Store replay also tracks changed bindings for retention outside its scratch.
store_bindings :: proc(check: ^State_Flow, destination: State_Access, path: []string, value: State_Access, weak := false, roots: ^Field_Roots = nil, changed_bindings: ^map[int]bool = nil) {
	for index in 0..=len(destination.resources) {
		resource := destination.resource
		if index < len(destination.resources) {resource = destination.resources[index]}
		memo := make(Field_Transforms)
		for id, binding in check.bindings {
			updated, changed := store_state_path(check.r, binding, resource, path, value, weak || len(destination.resources) > 0, &memo, roots)
			if !changed {continue}
			check.bindings[id] = updated
			if changed_bindings != nil {changed_bindings^[id] = true}
		}
	}
}

record_store :: proc(check: ^State_Flow, destination, value: State_Access, initializes := false, conditional := false, site := tokenizer.Pos{}, invocation := tokenizer.Pos{}, order: []tokenizer.Pos = nil) -> (changed: bool) {
	model := check.r.semantics
	if model == nil || !model.infer || check.caller < 0 {return}
	facts := &model.facts[check.caller]
	if !initializes && !reference_value(value) && !known_callback_type(model.r, value.type, value.scope) {return}
	order := slice.clone_to_dynamic(order)
	if len(order) == 0 {append(&order, site)}
	for origin in destination.origins {
		optional := conditional || check.optional_stores || check.branch_depth > 0
		for guard in check.nil_guards {if guard != origin.parameter {optional = true}}
		found := false
		for &stored in facts.stores {
			if stored.destination != origin || stored.site != site || stored.invocation != invocation {continue}
			if stored.initializes && !initializes {stored.initializes = false; changed = true}
			different_order := len(stored.order) != len(order)
			if !different_order {for position, i in order {if position != stored.order[i] {different_order = true; break}}}
			if (optional || different_order) && !stored.conditional {stored.conditional = true; changed = true}
			if different_order && store_before(Stored_Value{order = order}, stored) {stored.order = order; changed = true}
			joined, different := join_state_access(stored.value, value)
			if different {stored.value = joined; changed = true}
			found = true
		}
		if !found {append(&facts.stores, Stored_Value{destination = origin, value = value, initializes = initializes, conditional = optional, site = site, invocation = invocation, order = order}); changed = true}
	}
	model.changed = model.changed || changed
	return
}

refresh_address :: proc(check: ^State_Flow, address: State_Access) -> State_Access {
	if !address.addressed {return address}
	if value, loaded := load_addresses(check, address); loaded {
		result := address
		result.fields = make(map[string]^State_Access, len(address.fields)+1)
		for name, child in address.fields {if name != "^" {result.fields[name] = child}}
		result.fields["^"] = new_clone(value)
		return result
	}
	return address
}

// Loading all alternatives keeps branch-selected field addresses conservative.
load_addresses :: proc(check: ^State_Flow, address: State_Access) -> (value: State_Access, loaded: bool) {
	for index in 0..=len(address.resources) {
		resource := address.resource
		if index < len(address.resources) {resource = address.resources[index]}
		if resource.root == nil {continue}
		current := State_Access{}
		found, length := false, -1
		for _, binding in check.bindings {
			for location in ([2]State_Location{binding.slot, binding.resource}) {
				if location.root != resource.root || len(location.path) < length {continue}
				if location == binding.resource && (binding.addressed || binding.pointer && location == resource) {continue}
				prefix := location.path
				if prefix != "" {prefix = strings.concatenate({prefix, "."})}
				if location.path != resource.path && !strings.has_prefix(resource.path, prefix) {continue}
				path := "" if location.path == resource.path else resource.path[len(prefix):]
				current = project_access(check.r, binding, path)
				current.slot = resource
				found, length = true, len(location.path)
			}
		}
		if found {
			if !loaded {value = current} else {value, _ = join_state_access(value, current)}
			loaded = true
		}
	}
	return
}

replace_state_path :: proc(r: ^References, base: State_Access, path: []string, value: State_Access, weak: bool, root := true, variable := false) -> State_Access {
	if len(path) == 0 || len(path) == 1 && path[0] == "" {
		result := fit_state_value(value, base)
		if weak {result, _ = join_state_access(base, result)}
		if root {
			if !variable || !result.pointer && !result.shared {result.pointer, result.resource, result.resources = base.pointer, base.resource, base.resources}
			result = fit_slot(result, base)
			result.protected = result.protected || (base.slot_protected if variable else base.protected)
			result.live, result.local = base.live, result.local || base.local
			result.published = result.published || (base.slot_published if variable else base.published)
			result.immutable = result.immutable || (base.slot_immutable if variable else base.immutable)
			origins := base.slot_origins if variable else base.origins
			result.origins = slice.clone_to_dynamic(result.origins[:])
			for origin in origins {if !slice.contains(result.origins[:], origin) {append(&result.origins, origin)}}
		}
		return result
	}
	name := path[0]
	if name == "[]" {name = ""}
	child := element_access(r, base, 0) if name == "" else field_access(r, base, name, 0)
	stored := replace_state_path(r, child, path[1:], value, weak, false)
	if name == "" {stored, _ = join_state_access(child, stored)}
	if previous, exists := base.fields[name]; exists && state_access_equal(previous^, stored) {return base}
	result := base
	result.fields = make(map[string]^State_Access, len(base.fields)+1)
	for key, previous in base.fields {result.fields[key] = previous}
	result.fields[name] = new_clone(stored)
	return result
}

// Slot capabilities describe where a value lives; referent capabilities describe
// what its pointers and containers can access. A private handle may be rebound.
write_slot_access :: proc(access: State_Access, referent := false) -> State_Access {
	result := access
	// A whole-pointer formal writes the supplied referent, not the caller's
	// private pointer variable. Its current capabilities already name that slot.
	if referent {result.shared = false; return result}
	result.protected, result.immutable, result.origins, result.local = access.slot_protected, access.slot_immutable, access.slot_origins, access.slot_local
	result.published, result.shared = access.slot_published, false
	if access.slot.root != nil {result.resource = access.slot}
	// Keep alternate-resource evidence so selecting an ambiguous owner cannot
	// acquire a transaction permission from only its first possible target.
	return result
}

fit_slot :: proc(value, slot: State_Access) -> State_Access {
	result := value
	result.slot, result.slot_origins, result.slot_local = slot.slot, slot.slot_origins, slot.slot_local
	result.slot_protected, result.slot_published, result.slot_immutable = slot.slot_protected, slot.slot_published, slot.slot_immutable
	return result
}

field_slot :: proc(value, base: State_Access, name: string, element := false) -> State_Access {
	result := value
	place := base
	if !base.pointer && !element {
		place.resource, place.origins = base.slot, base.slot_origins
		place.protected, place.published, place.immutable = base.slot_protected, base.slot_published, base.slot_immutable
		place.local = base.slot_local
	}
	path := access_path(place, name)
	result.slot, result.slot_origins, result.slot_local = path.resource, path.origins, place.local
	result.slot_protected, result.slot_published, result.slot_immutable = place.protected, place.published, place.immutable
	return result
}

// ---------------- File ----------------

@(private = "file")
store_state_path :: proc(r: ^References, binding: State_Access, resource: State_Location, path: []string, value: State_Access, weak: bool, memo: ^Field_Transforms, roots: ^Field_Roots) -> (result: State_Access, changed: bool) {
	result = binding
	if resource.root == nil {return}
	if roots != nil && !has_store_root(&result, resource.root, roots) {return}
	for location, index in ([2]State_Location{binding.slot, binding.resource}) {
		if location.root != resource.root || index == 1 && binding.addressed {continue}
		if location.path == resource.path {
			result = replace_state_path(r, binding, path, value, weak, variable = index == 0)
			return result, !state_access_equal(binding, result)
		}
		prefix := location.path
		if prefix != "" {prefix = strings.concatenate({prefix, "."})}
		if strings.has_prefix(resource.path, prefix) {
			combined := make([dynamic]string)
			append(&combined, ..strings.split(resource.path[len(prefix):], "."))
			append(&combined, ..path)
			result = replace_state_path(r, binding, combined[:], value, weak)
			return result, !state_access_equal(binding, result)
		}
	}
	if len(binding.fields) == 0 {return}
	key := field_identity(binding.fields)
	if previous, found := memo^[key]; found {result.fields = previous.fields; return result, previous.changed}
	for name, child in binding.fields {
		updated, different := store_state_path(r, child^, resource, path, value, weak, memo, roots)
		if !different {continue}
		if !changed {result.fields = make(map[string]^State_Access, len(binding.fields)); for key, previous in binding.fields {result.fields[key] = previous}}
		result.fields[name], changed = new_clone(updated), true
	}
	memo^[key] = Field_Transform{result.fields, changed}
	return
}

@(private = "file")
reference_value :: proc(value: State_Access) -> bool {
	if value.decoded || value.pointer || value.shared || value.nil_value || len(value.callables) > 0 || value.callback_effects != {} || value.callback_modeled || value.callback_unknown {return true}
	for _, child in value.fields {if reference_value(child^) {return true}}
	return false
}


// Source execution paths, not fixed-point discovery order, determine overwrite order.
@(private = "file")
store_before :: proc(left, right: Stored_Value) -> bool {
	for position, i in left.order {
		if i >= len(right.order) {return false}
		other := right.order[i]
		if position.file != other.file {return position.file < other.file}
		if position.offset != other.offset {return position.offset < other.offset}
	}
	return len(left.order) < len(right.order)
}

// Child snapshots are immutable throughout a call. A negative result skips
// only graphs with no possible matching slot or backing-storage allocation.
@(private = "file")
has_store_root :: proc(value: ^State_Access, root: ^ast.Expr, cache: ^Field_Roots) -> bool {
	if value.slot.root == root || value.resource.root == root {return true}
	if len(value.fields) == 0 {return false}
	key := struct {fields: uintptr, root: ^ast.Expr}{field_identity(value.fields), root}
	if found, known := cache^[key]; known {return found}
	for _, child in value.fields {
		if has_store_root(child, root, cache) {cache^[key] = true; return true}
	}
	cache^[key] = false
	return false
}
