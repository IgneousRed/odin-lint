#+private
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:odin/ast"
import "core:slice"

// -------------------------------- Types --------------------------------

// ---------------- Package ----------------

Condition_Branch :: struct {state: State_Flow, reachable: bool}

// A proof names one evaluated Boolean. Counter revisions are per resource/path,
// so completed work on another owner cannot destroy that value's correlation.
Counter_Condition :: struct {
	target: int,
	known, refine: bool,
	history: [dynamic]Counter_Change,
	transactions: map[State_Location]Active_Transaction,
	version: ^bool,
	versions: map[State_Location]^bool,
	effects: [dynamic]Counter_Effect,
	outcomes: [2][dynamic]Counter_Effect,
	predicate: Returned_Predicate,
}

Counter_Effect :: struct {access, owner: State_Access, delta, model: int}

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

// Conditions execute left-to-right. Each outcome owns its mutable map headers;
// a skipped short-circuit operand cannot open a scope or write state.
walk_state_condition :: proc(check: ^State_Flow, visitor: ^ast.Visitor, expression: ^ast.Expr) -> (yes, no: Condition_Branch) {
	if expression == nil {return Condition_Branch{snapshot_state_flow(check), true}, Condition_Branch{}}
	expression := expression
	expression = unwrap_parens(expression)
	if unary, ok := expression.derived.(^ast.Unary_Expr); ok && unary.op.text == "!" {
		no, yes = walk_state_condition(check, visitor, unary.expr)
		return
	}
	if binary, ok := expression.derived.(^ast.Binary_Expr); ok && (binary.op.text == "&&" || binary.op.text == "||") {
		left_yes, left_no := walk_state_condition(check, visitor, binary.left)
		if binary.op.text == "&&" {
			if left_yes.reachable {check^ = left_yes.state; yes, no = walk_state_condition(check, visitor, binary.right)}
			no = join_condition_branches(left_no, no)
		} else {
			if left_no.reachable {check^ = left_no.state; yes, no = walk_state_condition(check, visitor, binary.right)}
			yes = join_condition_branches(left_yes, yes)
		}
		return
	}
	ast.walk(visitor, expression)
	yes, no = state_boolean_condition(check, state_access(check, expression, check.r.node_scopes[expression], 0))
	if binary, comparison := expression.derived.(^ast.Binary_Expr); comparison && (binary.op.text == "==" || binary.op.text == "!=") {
		left := state_access(check, binary.left, check.r.node_scopes[expression], 0).zero
		right := state_access(check, binary.right, check.r.node_scopes[expression], 0).zero
		if (left == .Zero || left == .Nonzero) && (right == .Zero || right == .Nonzero) && (left == .Zero || right == .Zero) {
			value := (left == right) if binary.op.text == "==" else (left != right)
			yes.reachable, no.reachable = value, !value
		}
	}
	return
}

state_boolean_condition :: proc(check: ^State_Flow, value_access: State_Access) -> (yes, no: Condition_Branch) {
	yes, no = Condition_Branch{snapshot_state_flow(check), true}, Condition_Branch{snapshot_state_flow(check), true}
	if value_access.zero == .Zero || value_access.zero == .Nonzero {yes.reachable, no.reachable = value_access.zero == .Nonzero, value_access.zero == .Zero}
	if value_access.condition == nil || check.r.semantics == nil {return}
	condition, saved := check.counter_conditions[value_access.condition]
	if !saved || condition.version != value_access.condition_version || !condition.refine {return}
	for resource, version in condition.versions {if check.counter_versions[resource] != version {return}}
	for _, i in condition.outcomes {
		branch := &yes if (i == 0) != value_access.condition_negated else &no
		// Replace only this call's counter facts. Argument effects and later
		// operations on independent owners remain on both outcomes.
		history := make([dynamic]Counter_Change)
		for change in branch.state.counter_history {if !condition_counter_origin(condition.effects[:], change.origin) {append(&history, change)}}
		for change in condition.history {if condition_counter_origin(condition.effects[:], change.origin) {append(&history, change)}}
		branch.state.counter_history = history
		for effect in condition.effects {
			if effect.model < 0 {continue}
			key := effect.owner.resource
			if previous, found := condition.transactions[key]; found {branch.state.transactions[key] = previous} else {delete_key(&branch.state.transactions, key)}
		}
		for effect in condition.outcomes[i] {record_counter(&branch.state, effect.access, effect.delta)}
		if check.r.semantics.contracts {
			operations := make([dynamic]Counter_Operation)
			seen := make(map[State_Location]bool)
			for effect in condition.outcomes[i] {
				if effect.model < 0 || effect.owner.resource.root == nil || seen[effect.owner.resource] {continue}
				directions := 0
				for candidate in condition.outcomes[i] {
					if candidate.model == effect.model && candidate.owner.resource == effect.owner.resource {directions |= 1 if candidate.delta == 1 else 2}
				}
				if directions == 3 {continue}
				append(&operations, Counter_Operation{effect.owner, effect.delta, effect.model})
				seen[effect.owner.resource] = true
			}
			apply_counters(&branch.state, operations[:])
		}
	}
	return
}

touch_counter :: proc(check: ^State_Flow, access: State_Access) {
	if check.counter_versions == nil {check.counter_versions = make(map[State_Location]^bool)}
	if access.resource.root != nil {check.counter_versions[access.resource] = new(bool)}
	for resource in access.resources {if resource.root != nil {check.counter_versions[resource] = new(bool)}}
}

snapshot_state_flow :: proc(check: ^State_Flow) -> State_Flow {
	result := check^
	result.bindings = copy_state_bindings(check.bindings)
	result.transactions = copy_transactions(check.transactions)
	result.counter_history = slice.clone_to_dynamic(check.counter_history[:])
	result.counter_versions = make(map[State_Location]^bool)
	for resource, version in check.counter_versions {result.counter_versions[resource] = version}
	result.counter_conditions = make(map[^ast.Expr]Counter_Condition)
	for expression, condition in check.counter_conditions {result.counter_conditions[expression] = condition}
	return result
}

join_condition_branches :: proc(left, right: Condition_Branch) -> Condition_Branch {
	if !left.reachable {return right}
	if !right.reachable {return left}
	result := left
	for resource, version in right.state.counter_versions {
		if result.state.counter_versions[resource] != version {result.state.counter_versions[resource] = new(bool)}
	}
	for resource, version in result.state.counter_versions {
		if version != right.state.counter_versions[resource] {result.state.counter_versions[resource] = new(bool)}
	}
	merge_state_bindings(&result.state.bindings, right.state.bindings)
	merge_transactions(&result.state.transactions, right.state.transactions)
	for change in right.state.counter_history {if !slice.contains(result.state.counter_history[:], change) {append(&result.state.counter_history, change)}}
	result.state.publication_uncertain = result.state.publication_uncertain || right.state.publication_uncertain
	result.state.optional_stores = result.state.optional_stores || right.state.optional_stores
	return result
}


copy_state_bindings :: proc(bindings: map[int]State_Access) -> map[int]State_Access {
	result := make(map[int]State_Access)
	for id, access in bindings {result[id] = access}
	return result
}

// Insert through the caller's map header so new branch bindings retain length/capacity.
merge_state_bindings :: proc(destination: ^map[int]State_Access, branch: map[int]State_Access) -> (changed: bool) {
	for id, access in branch {
		previous, set := destination^[id]
		joined, different := join_state_access(previous, access)
		if !set || different {destination^[id] = joined; changed = true}
	}
	return
}

copy_transactions :: proc(source: map[State_Location]Active_Transaction) -> map[State_Location]Active_Transaction {
	result := make(map[State_Location]Active_Transaction)
	for key, active in source {result[key] = active}
	return result
}

merge_transactions :: proc(destination: ^map[State_Location]Active_Transaction, branch: map[State_Location]Active_Transaction) {
	for key, other in branch {
		active, exists := destination^[key]
		if !exists {active.model = other.model}
		active.depth, active.possible = min(active.depth, other.depth), max(active.possible, other.possible)
		destination^[key] = active
	}
	for key, current in destination^ {
		other := branch[key]
		active := current
		active.depth, active.possible = min(active.depth, other.depth), max(active.possible, other.possible)
		destination^[key] = active
	}
}


// ---------------- File ----------------

@(private = "file")
condition_counter_origin :: proc(effects: []Counter_Effect, origin: Access_Origin) -> bool {
	for effect in effects {if slice.contains(effect.access.origins[:], origin) {return true}}
	return false
}
