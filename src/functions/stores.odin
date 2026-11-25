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

// -------------------------------- Types --------------------------------

// ---------------- File ----------------

@(private = "file")
Address_Store_Key :: struct {fields: uintptr, resource: State_Location, resources_data: uintptr, resources_len: int}

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

// Field writes are relative to the actual caller. Preserve protected-state
// aliases while allowing independent private working copies.
apply_stores :: proc(check: ^State_Flow, facts: Procedure_Facts, arguments: []State_Access, pos: tokenizer.Pos, allocation: ^ast.Expr = nil, alternatives := false, result_ids: []int = nil, callbacks := true, required := true) -> (may_return: bool) {
	if len(facts.stores) == 0 && (!callbacks || len(facts.invocations) == 0) {return true}
	// A call can replay many field stores. Keep only the final bindings and
	// summary, rather than retaining every intermediate alias snapshot.
	allocator := context.allocator
	transient: mem.Dynamic_Arena
	heap := runtime.heap_allocator()
	// Callbacks also update counter history and recursion bookkeeping. Those
	// allocations belong to the body, beyond this binding-only retention pass.
	transient_work := !callbacks || len(facts.invocations) == 0
	if transient_work {
		mem.dynamic_arena_init(&transient, block_allocator = heap, array_allocator = heap, block_size = SCRATCH_BLOCK_SIZE, out_band_size = SCRATCH_BLOCK_SIZE/4)
		context.allocator = mem.dynamic_arena_allocator(&transient)
	}
	previous_cache := check.r.read_cache
	cache: Read_Cache
	if transient_work {check.r.read_cache = &cache}
	defer {check.r.read_cache = previous_cache; delete_read_cache(&cache)}
	changed_bindings := make(map[int]bool)
	changed_stores := make(map[int]bool, heap)
	defer delete(changed_stores)
	old_stores_data: rawptr
	if transient_work {
		if model := check.r.semantics; model != nil && model.infer && check.caller >= 0 {
			old_stores_data = raw_data(model.facts[check.caller].stores)
		}
	}
	retained, summary_retained: State_Clones
	defer delete_state_clones(&retained)
	defer delete_state_clones(&summary_retained)
	// Retention caches are needed only when replay owns a shorter-lived arena.
	// Callback replay already allocates into the enclosing body lifetime.
	if transient_work {
		for memo in ([2]^State_Clones{&retained, &summary_retained}) {
			memo^ = make_state_clones()
		}
		for _, binding in check.bindings {remember_state_graph(binding, &retained)}
		if model := check.r.semantics; model != nil && model.infer && check.caller >= 0 {
			previous := model.facts[check.caller]
			for stored in previous.stores {remember_state_graph(stored.value, &summary_retained)}
			for value in previous.results {remember_state_graph(value, &summary_retained)}
			for invocation in previous.invocations {remember_state_graph(invocation.callback, &summary_retained); for argument in invocation.arguments {remember_state_graph(argument, &summary_retained)}}
		}
	}
	summary_changed := false
	defer {
		context.allocator = allocator
		if transient_work {
			for id in changed_bindings {if value, exists := check.bindings[id]; exists {check.bindings[id] = clone_state_graph(value, &retained, true)}}
			if model := check.r.semantics; summary_changed {
				caller_facts := &model.facts[check.caller]
				if raw_data(caller_facts.stores) != old_stores_data {
					caller_facts.stores = slice.clone_to_dynamic(caller_facts.stores[:])
				}
				for idx in changed_stores {
					stored := &caller_facts.stores[idx]
					stored.destination.path = strings.clone(stored.destination.path)
					stored.value = clone_state_graph(stored.value, &summary_retained)
					stored.order = slice.clone_to_dynamic(stored.order[:])
					stored.available.clauses = slice.clone(stored.available.clauses)
					for &clause in stored.available.clauses {
						clause.tests = slice.clone(clause.tests)
						for &test in clause.tests {test.atom = strings.clone(test.atom)}
					}
				}
			}
			mem.dynamic_arena_destroy(&transient)
		}
	}
	event_trie := build_read_event_trie(facts)
	stores := slice.clone(facts.stores[:])
	slice.sort_by(stores, store_before)
	// Invocation order is distinct from the callback's read point: a saved
	// callback can be invoked after a write without reloading that field.
	Event :: struct {index: int, callback: bool, order: [dynamic]tokenizer.Pos, available: Availability}
	events := make([dynamic]Event)
	for stored, i in stores {append(&events, {i, false, stored.order, stored.available})}
	if callbacks {for invocation, i in facts.invocations {append(&events, {i, true, invocation.order, invocation.available})}}
	slice.sort_by(events[:], proc(left, right: Event) -> bool {return store_before(Stored_Value{order = left.order}, Stored_Value{order = right.order})})
	// Each write advances the captured referents. Historical argument snapshots
	// distinguish an earlier saved value from a later read through an alias.
	roots := make(Field_Roots)
	// A missing write preserves the incoming value only in configurations
	// where it is actually absent. Complementary stores can overwrite it fully.
	available := check.available
	defer check.available = available
	paths := make([dynamic]Availability)
	append(&paths, available if available.supplied else availability_all())
	for stored in events {
		if (stored.available.all || !stored.available.supplied) {continue}
		next := make([dynamic]Availability)
		for path in paths {
			for guard in ([2]Availability{stored.available, availability_not(stored.available)}) {
				part := availability_and(path, guard)
				if availability_possible(check.r, part) {append(&next, part)}
			}
		}
		paths = next
	}
	previous_replay := check.replay_arguments
	defer check.replay_arguments = previous_replay
	argument_ids := make([]int, len(arguments))
	for value, i in arguments {argument_ids[i] = retain_evaluated_value(check, value)}
	defer {for id in argument_ids {delete_key(&check.bindings, id)}}
	before := check.bindings
	joined: map[int]State_Access
	for path in paths {
		check.available = path
		snapshots := make([dynamic]Replay_Arguments)
		instantiated := make(Field_Transforms, heap)
		defer delete(instantiated)
		applied := make([dynamic]struct {base, value: State_Access, path: []string, weak: bool})
		check.replay_arguments = nil
		if len(paths) > 1 {check.bindings = copy_state_bindings(before)}
		returns := true
		for event in events {
			if !availability_possible(check.r, availability_and(check.available, event.available)) {continue}
			if event.callback {
				invocation := facts.invocations[event.index]
				callback := instantiate_values(check, invocation.callback, facts.parameters[:], arguments, allocation, site = pos, events = event_trie)
				values := make([]State_Access, len(invocation.arguments))
				for value, i in invocation.arguments {values[i] = instantiate_values(check, value, facts.parameters[:], arguments, allocation, site = pos, events = event_trie)}
				order := check.store_order
				sequence := slice.clone_to_dynamic(order[:])
				append(&sequence, pos)
				if !slice.contains(invocation.order[:], pos) {append(&sequence, ..invocation.order[:])}
				check.store_order = sequence
				completed := apply_callback(check, callback, values, pos, required && !invocation.optional)
				check.store_order = order
				for id in check.bindings {changed_bindings[id] = true}
				if model := check.r.semantics; model != nil && model.infer && check.caller >= 0 {summary_changed = true}
				if !completed && !invocation.optional {returns = false; break}
				current := make([]State_Access, len(arguments))
				for id, i in argument_ids {current[i] = check.bindings[id]}
				append(&snapshots, Replay_Arguments{event.order, current})
				check.replay_arguments = snapshots[:]
				continue
			}
			stored := stores[event.index]
			index, found := slice.linear_search(facts.parameters[:], stored.destination.parameter)
			if !found || index >= len(arguments) {continue}
			base := check.bindings[argument_ids[index]]
			if base.nil_value {continue}
			destination := project_access(check.r, base, stored.destination.path)
			value := instantiate_value_graph(check, stored.value, facts.parameters[:], arguments, allocation, &instantiated, events = event_trie) if transient_work else instantiate_values(check, stored.value, facts.parameters[:], arguments, allocation, events = event_trie)
			value = fit_state_value(value, destination, check)
			if value.decoded {
				value = decoded_output(check.r, destination, value.resource.root)
			}
			sequence := make([dynamic]tokenizer.Pos)
			append(&sequence, pos)
			recursive := slice.contains(stored.order[:], pos)
			if !recursive {append(&sequence, ..stored.order[:])}
			// Rebinding a field writes its slot, not the referent of the value
			// previously stored there. Whole-formal writes still name the referent.
			target := destination
			if stored.destination.path != "" {target.origins = target.slot_origins}
			stored_summary := record_store(check, target, value, stored.initializes, stored.weak || len(base.resources) > 0 || alternatives || recursive, stored.site, pos, sequence[:], &changed_stores if transient_work else nil)
			summary_changed = summary_changed || stored_summary
			store_bindings(check, base, strings.split(stored.destination.path, "."), value, stored.weak || alternatives, &roots, &changed_bindings)
			if len(result_ids) > 0 {append(&applied, {base, value, strings.split(stored.destination.path, "."), stored.weak || alternatives})}
			previous_values := snapshots[len(snapshots)-1].values if len(snapshots) > 0 else arguments
			args_changed := false
			for id, i in argument_ids {if !state_access_equal(previous_values[i], check.bindings[id]) {args_changed = true; break}}
			if args_changed {
				values := make([]State_Access, len(arguments))
				for id, i in argument_ids {values[i] = check.bindings[id]}
				append(&snapshots, Replay_Arguments{stored.order, values})
				check.replay_arguments = snapshots[:]
				clear(&instantiated)
			}
		}
		may_return = may_return || returns
		// Results use their own read points, then receive the same referent
		// writes as every other captured value. This preserves early callback
		// identities and late aliased reads without reevaluating source ASTs.
		for id, i in result_ids {
			if !returns || !facts.normal_return {continue}
			if id >= -1 {continue}
			value := copy_state_value(check.r, instantiate_value_graph(check, facts.results[i], facts.parameters[:], arguments, allocation, &instantiated, events = event_trie) if transient_work else instantiate_values(check, facts.results[i], facts.parameters[:], arguments, allocation, events = event_trie), 0)
			for write in applied {
				resources := make([dynamic]State_Location, 0, len(write.base.resources)+1, heap)
				for index in 0..=len(write.base.resources) {
					resource := write.base.resource
					if index < len(write.base.resources) {resource = write.base.resources[index]}
					if resource.root != nil {append(&resources, resource)}
				}
				if len(resources) > 0 {
					memo := make(Field_Transforms, heap)
					addr_memo := make(map[Address_Store_Key]Field_Transform, heap)
					value, _ = store_state_path(check.r, value, resources[:], write.path, write.value, write.weak || len(write.base.resources) > 0, &memo, &roots, &addr_memo)
					delete(addr_memo)
					delete(memo)
				}
				delete(resources)
			}
			check.bindings[id], changed_bindings[id] = value, true
		}
		if len(paths) > 1 {
			if joined == nil {joined = check.bindings} else {merge_state_bindings(&joined, check.bindings)}
		}
	}
	// Store replay changes existing bindings only. Keep their persistent map
	// header; the per-configuration maps belong to this call's scratch arena.
	if len(paths) > 1 {
		for id, value in joined {before[id] = value}
		check.bindings = before
	}
	return
}

// Each destination set shares one transform across all binding aliases.
// Store replay also tracks changed bindings for retention outside its scratch.
store_bindings :: proc(check: ^State_Flow, destination: State_Access, path: []string, value: State_Access, weak := false, roots: ^Field_Roots = nil, changed_bindings: ^map[int]bool = nil) {
	heap := runtime.heap_allocator()
	resources := make([dynamic]State_Location, 0, len(destination.resources)+1, heap)
	defer delete(resources)
	for index in 0..=len(destination.resources) {
		resource := destination.resource
		if index < len(destination.resources) {resource = destination.resources[index]}
		if resource.root != nil {append(&resources, resource)}
	}
	if len(resources) == 0 {return}
	memo := make(Field_Transforms, heap)
	defer delete(memo)
	addr_memo := make(map[Address_Store_Key]Field_Transform, heap)
	defer delete(addr_memo)
	for id, binding in check.bindings {
		updated, changed := store_state_path(check.r, binding, resources[:], path, value, weak || len(destination.resources) > 0, &memo, roots, &addr_memo)
		if !changed {continue}
		check.bindings[id] = updated
		if changed_bindings != nil {changed_bindings^[id] = true}
	}
}

// An address can point inside the replaced value. Update its saved referent
// while the write occurs, even if the original container handle is later rebound.
store_address_contents :: proc(r: ^References, address: State_Access, resources: []State_Location, path: []string, value: State_Access, weak: bool) -> (result: State_Access, changed: bool) {
	result = address
	if !address.addressed || len(resources) == 0 {return}
	previous, known := address.fields["^"]
	if !known {return}
	stored: State_Access
	found, missing := false, false
	first_relative := ""
	seen_relatives: map[string]bool
	defer delete(seen_relatives)
	for resource in resources {
		if resource.root == nil {continue}
		for index in 0..=len(address.resources) {
			location := address.resource
			if index < len(address.resources) {location = address.resources[index]}
			if location.root != resource.root || location.symbolic != resource.symbolic {missing = true; continue}
			relative, matches := relative_state_path(location.path, resource.path)
			for field in path {
				if !matches {break}
				if field != "" {relative, matches = relative_state_path(relative, field)}
			}
			if !matches {missing = true; continue}
			if found {
				if relative == first_relative {continue}
				if seen_relatives == nil {seen_relatives = make(map[string]bool, runtime.heap_allocator()); seen_relatives[first_relative] = true}
				if seen_relatives[relative] {continue}
				seen_relatives[relative] = true
			} else {
				first_relative = relative
			}
			projected := project_access(r, value, relative)
			if found {stored, _ = join_state_access(stored, projected)} else {stored, found = projected, true}
		}
	}
	if !found {return}
	stored = replace_state_path(r, previous^, nil, stored, weak || missing, variable = true)
	if state_access_equal(previous^, stored) {return}
	result.fields = make(map[string]^State_Access, cap(address.fields))
	for name, child in address.fields {result.fields[name] = child}
	result.fields["^"] = new_clone(stored)
	return result, true
}

record_store :: proc(check: ^State_Flow, destination, value: State_Access, initializes := false, conditional := false, site := tokenizer.Pos{}, invocation := tokenizer.Pos{}, order: []tokenizer.Pos = nil, changed_stores: ^map[int]bool = nil) -> (changed: bool) {
	model := check.r.semantics
	if model == nil || !model.infer || check.caller < 0 || len(destination.origins) == 0 {return}
	facts := &model.facts[check.caller]
	if !initializes && !reference_value(model.r, value) {return}
	sequence := slice.clone_to_dynamic(check.store_order[:])
	if len(order) == 0 {append(&sequence, site)} else {append(&sequence, ..order)}
	available := check.available
	if !available.supplied {available = availability_all()}
	protection: map[uintptr]bool
	defer delete(protection)
	for origin in destination.origins {
		weak := conditional || check.runtime_optional_stores || check.store_depth > 0
		optional := weak || check.branch_depth > 0 || availability_possible(check.r, availability_not(available))
		for guard in check.nil_guards {if guard != origin.parameter {optional, weak = true, true; break}}
		found := false
		for &stored, idx in facts.stores {
			if stored.destination != origin || stored.site != site || stored.invocation != invocation {continue}
			// Compare guards semantically: fresh snapshots must not create new
			// alternatives indefinitely during recursive fixed-point inference.
			if availability_possible(check.r, availability_and(available, availability_not(stored.available))) || availability_possible(check.r, availability_and(stored.available, availability_not(available))) {continue}
			store_changed := false
			if stored.initializes && !initializes {stored.initializes = false; store_changed = true}
			different_order := !slice.equal(stored.order[:], sequence[:])
			if (optional || different_order) && !stored.conditional {stored.conditional = true; store_changed = true}
			if (weak || different_order) && !stored.weak {stored.weak = true; store_changed = true}
			if different_order && store_before(Stored_Value{order = sequence}, stored) {stored.order = sequence; store_changed = true}
			joined, different := join_state_access(stored.value, value, protection = &protection)
			if different {stored.value = joined; store_changed = true}
			if store_changed {
				changed = true
				if changed_stores != nil {changed_stores^[idx] = true}
			}
			found = true
		}
		if !found {
			idx := len(facts.stores)
			append(&facts.stores, Stored_Value{destination = origin, value = value, initializes = initializes, conditional = optional, weak = weak, site = site, invocation = invocation, order = sequence, available = available})
			changed = true
			if changed_stores != nil {changed_stores^[idx] = true}
		}
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
				path, matches := relative_state_path(resource.path, location.path)
				if !matches {continue}
				current = project_access(check.r, binding, path)
				current.slot = resource
				found, length = true, len(location.path)
			}
		}
		if !found {
			// Globals and other untracked alternatives still have their saved
			// referent. Loading a local alternative must not discard that evidence.
			if saved, known := address.fields["^"]; known {current, found = saved^, true}
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

field_slot :: proc(r: ^References, value, base: State_Access, name: string, element := false) -> State_Access {
	result := value
	place := base
	if !base.pointer && !element {
		place.resource, place.origins = base.slot, base.slot_origins
		place.protected, place.published, place.immutable = base.slot_protected, base.slot_published, base.slot_immutable
		place.local = base.slot_local
	}
	path := access_path(r, place, name, element && finite_index_path(r, base))
	result.slot, result.slot_origins, result.slot_local = path.resource, path.origins, place.local
	result.slot_protected, result.slot_published, result.slot_immutable = place.protected, place.published, place.immutable
	return result
}

// ---------------- File ----------------


@(private = "file")
store_state_path :: proc(r: ^References, binding: State_Access, resources: []State_Location, path: []string, value: State_Access, weak: bool, memo: ^Field_Transforms, roots: ^Field_Roots, addr_memo: ^map[Address_Store_Key]Field_Transform) -> (result: State_Access, changed: bool) {
	result = binding
	if len(resources) == 0 {return}
	if roots != nil {
		any_root := false
		for resource in resources {if has_store_root(&result, resource.root, roots) {any_root = true; break}}
		if !any_root {return}
	}
	if binding.addressed {
		akey := Address_Store_Key{field_identity(binding.fields), binding.resource, uintptr(raw_data(binding.resources)), len(binding.resources)}
		if prev, ok := addr_memo^[akey]; ok {
			if prev.changed {result.fields = prev.fields; return result, true}
		} else {
			updated, different := store_address_contents(r, binding, resources, path, value, weak)
			addr_memo^[akey] = Field_Transform{updated.fields, different}
			if different {return updated, true}
		}
	}
	matched_direct := false
	for location, index in ([2]State_Location{binding.slot, binding.resource}) {
		if index == 1 && binding.addressed {continue}
		for resource in resources {
			if location.root != resource.root {continue}
			if location.path == resource.path {
				result = replace_state_path(r, result, path, value, weak, variable = index == 0)
				matched_direct = true
			} else if relative, matches := relative_state_path(resource.path, location.path); matches {
				combined := make([dynamic]string)
				append(&combined, ..strings.split(relative, "."))
				append(&combined, ..path)
				result = replace_state_path(r, result, combined[:], value, weak)
				matched_direct = true
			}
		}
		if matched_direct {return result, !state_access_equal(binding, result)}
	}
	if len(binding.fields) == 0 {return}
	key := field_identity(binding.fields)
	if previous, found := memo^[key]; found {result.fields = previous.fields; return result, previous.changed}
	for name, child in binding.fields {
		updated, different := store_state_path(r, child^, resources, path, value, weak, memo, roots, addr_memo)
		if !different {continue}
		if !changed {result.fields = make(map[string]^State_Access, len(binding.fields)); for k, previous in binding.fields {result.fields[k] = previous}}
		result.fields[name], changed = new_clone(updated), true
	}
	memo^[key] = Field_Transform{result.fields, changed}
	return
}

// Project a descendant path without allocating a concatenated prefix. A field
// boundary matters: "row" contains "row.value", never "rows.value".
@(private = "file")
relative_state_path :: proc(path, prefix: string) -> (relative: string, matches: bool) {
	if prefix == "" {return path, true}
	if path == prefix {return "", true}
	if len(path) <= len(prefix) || !strings.has_prefix(path, prefix) || path[len(prefix)] != '.' {return "", false}
	return path[len(prefix)+1:], true
}

@(private = "file")
reference_value :: proc(r: ^References, value: State_Access) -> bool {
	if value.decoded || value.pointer || value.shared || value.nil_value || len(value.callables) > 0 || value.callback_effects != {} || value.callback_modeled || value.callback_unknown || value.callback_returns {return true}
	if known_callback_type(r, value.type, value.scope) {return true}
	for _, child in value.fields {if reference_value(r, child^) {return true}}
	return false
}


// Lexical execution paths include scope-exit and reverse-registration anchors
// for deferred statements, independently of fixed-point discovery order.
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
