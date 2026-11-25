#+private
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:odin/ast"
import "core:slice"
import "core:strings"

// -------------------------------- Types --------------------------------

// ---------------- Package ----------------

Counter_Operation :: struct {owner: State_Access, delta, model: int}

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

apply_procedure_counters :: proc(check: ^State_Flow, facts: Procedure_Facts, arguments: []State_Access, target: int) {
	for change in facts.counters {
		index, found := slice.linear_search(facts.parameters[:], change.origin.parameter)
		if found && index < len(arguments) {record_counter(check, project_access(check.r, arguments[index], change.origin.path), change.delta)}
	}
	file := check.r.files[check.r.procedures[target].file]
	if check.r.semantics.contracts && file.has_role && file.role == .Engine {
		operations := counter_operations(check.r, facts.counters[:], facts.parameters[:], arguments)
		apply_counters(check, operations[:])
	}
	for origin in facts.counter_resets {
		index, found := slice.linear_search(facts.parameters[:], origin.parameter)
		if found && index < len(arguments) {reset_owned_counters(check, project_access(check.r, arguments[index], origin.path))}
	}
}

// Observations compose monotonically through calls. Keeping both signs prevents
// an internally complete scope from becoming an open boundary at its callers.
record_counter :: proc(check: ^State_Flow, access: State_Access, delta: int) {
	model := check.r.semantics
	if model == nil || check.caller < 0 {return}
	touch_counter(check, access)
	facts := &model.facts[check.caller]
	for origin in access.origins {
		change := Counter_Change{origin, delta}
		if !slice.contains(check.counter_history[:], change) {append(&check.counter_history, change)}
		if model.infer && !slice.contains(facts.counters[:], change) {append(&facts.counters, change); model.changed = true}
	}
}

counter_operations :: proc(r: ^References, changes: []Counter_Change, parameters: []int, arguments: []State_Access, boundaries := true) -> (operations: [dynamic]Counter_Operation) {
	seen := make(map[State_Location]bool)
	for change in changes {
		if boundaries && counter_direction(changes, change.origin) != change.delta {continue}
		index, found := slice.linear_search(parameters, change.origin.parameter)
		if !found || index >= len(arguments) {continue}
		owner := arguments[index]
		if owner.type == nil || owner.resource.root == nil || seen[owner.resource] {continue}
		for transaction, model in r.semantics.transactions {
			if transaction.owner_type != owner.type || transaction.counter_path != change.origin.path {continue}
			append(&operations, Counter_Operation{owner, change.delta, model})
			seen[owner.resource] = true
			break
		}
	}
	return
}

apply_counters :: proc(check: ^State_Flow, operations: []Counter_Operation) {
	for operation in operations {
		// Boundary procedures intentionally transfer a scope to/from a caller.
		// Complete scopes (including partially inlined ones) are walked locally.
		if boundary_direction(check, operation.owner, operation.model) != 0 {continue}
		active := check.transactions[operation.owner.resource]
		active.model = operation.model
		active.depth += operation.delta
		active.possible += operation.delta
		check.transactions[operation.owner.resource] = active
	}
}

boundary_direction :: proc(check: ^State_Flow, owner: State_Access, model: int) -> int {
	if check.caller < 0 {return 0}
	file := check.r.files[check.r.procedures[check.caller].file]
	if !file.has_role || file.role != .Engine {return 0}
	transaction := check.r.semantics.transactions[model]
	if owner.type != transaction.owner_type {return 0}
	for origin in owner.origins {
		path := append_access_field(check.r, origin.path, transaction.counter_path)
		if direction := counter_direction(check.r.semantics.facts[check.caller].counters[:], Access_Origin{origin.parameter, path}); direction != 0 {return direction}
	}
	return 0
}

// A literal zero or empty owner assignment is evidence of reset. Only an
// unconditional saved reset is exported as a callee postcondition.
reset_owned_counters :: proc(check: ^State_Flow, access: State_Access) {
	model := check.r.semantics
	if model == nil || check.caller < 0 {return}
	if len(access.origins) > 0 {touch_counter(check, access)}
	for resource in check.counter_versions {
		if resource.root == access.resource.root && (access.resource.path == "" || resource.path == access.resource.path || strings.has_prefix(resource.path, strings.concatenate({access.resource.path, "."}))) {
			check.counter_versions[resource] = new(bool, check.r.semantics.allocator)
		}
	}
	file := check.r.files[check.r.procedures[check.caller].file]
	body, block := check.r.procedures[check.caller].literal.body.derived.(^ast.Block_Stmt)
	terminal := block && len(body.stmts) > 0 && check.statement_index == len(body.stmts)-1 && len(check.block_stmts) == len(body.stmts) && check.block_stmts[check.statement_index] == body.stmts[check.statement_index]
	if model.infer && file.has_role && file.role == .Engine && terminal && check.branch_depth == 0 && !check.optional_stores && len(check.deferred) == 0 {
		facts := &model.facts[check.caller]
		for origin in access.origins {if !slice.contains(facts.counter_resets[:], origin) {append(&facts.counter_resets, origin); model.changed = true}}
	}
	for key, active in check.transactions {
		if key.root != access.resource.root {continue}
		counter := model.transactions[active.model].counter_path
		if key.path != "" {counter = strings.concatenate({key.path, ".", counter})}
		if access.resource.path == "" || counter == access.resource.path || strings.has_prefix(counter, strings.concatenate({access.resource.path, "."})) {
			touch_counter(check, access)
			closed := active
			closed.depth, closed.possible = 0, 0
			check.transactions[key] = closed
		}
	}
}

// ---------------- File ----------------

@(private = "file")
counter_direction :: proc(changes: []Counter_Change, origin: Access_Origin) -> int {
	directions := 0
	for change in changes {if change.origin == origin {directions |= 1 if change.delta == 1 else 2}}
	if directions == 1 {return 1}
	if directions == 2 {return -1}
	return 0
}
