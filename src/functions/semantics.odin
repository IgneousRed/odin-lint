#+private
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:fmt"
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
	contracts: bool,
	transactions: [dynamic]Transaction_Fact,
}

Procedure_Facts :: struct {
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

Stored_Value :: struct {destination: Access_Origin, value: State_Access, initializes, conditional: bool, site, invocation: tokenizer.Pos, order: [dynamic]tokenizer.Pos}

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
Callback_Invocation :: struct {origin: Access_Origin, arguments: []State_Access, pos: tokenizer.Pos}

@(private = "file")
Access_Kind :: enum {Write, Destroy, Invoke, Transaction, Requires_Transaction}


// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

// The same walk computes a monotone summary and, after convergence, reports
// selected-source findings. Arguments remain explicit capabilities: writing a
// private buffer is different from writing a borrowed relation through a helper.
analyze_semantics :: proc(model: ^Semantics, diagnostics: ^[dynamic]state.Diagnostic, infer: bool) {
	model.infer = infer
	check := State_Flow{r = model.r, diagnostics = diagnostics, bindings = make(map[int]State_Access), quiet = infer, caller = -1,
		transactions = make(map[State_Location]Active_Transaction)}
	visitor := ast.Visitor{visit = visit_state_flow, data = &check}
	for file in model.r.files {
		for statement in file.file.decls {ast.walk(&visitor, statement)}
	}
}

apply_callback :: proc(check: ^State_Flow, callback: State_Access, arguments: []State_Access, pos: tokenizer.Pos) {
	model := check.r.semantics
	if model == nil || callback.nil_value || callback.zero == .Zero {return}
	for effect in callback.callback_effects {record_effect(check, effect, pos)}
	record_access(check, callback, .Invoke)
	for origin in callback.origins {
		if model.infer && check.caller >= 0 {
			facts := &model.facts[check.caller]
			found := false
			for &invocation in facts.invocations {
				if invocation.origin != origin || invocation.pos != pos {continue}
				found = true
				for argument, i in arguments {
					if i >= len(invocation.arguments) {continue}
					joined, changed := join_state_access(invocation.arguments[i], argument)
					if changed {invocation.arguments[i] = joined; model.changed = true}
				}
			}
			if !found {append(&facts.invocations, Callback_Invocation{origin, slice.clone(arguments), pos}); model.changed = true}
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
		facts := model.facts[target]
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
			if requirement.kind == .Invoke {
				if covered {continue}
				invoked := false
				for invocation in facts.invocations {
					if invocation.origin != requirement.origin {continue}
					values := make([]State_Access, len(invocation.arguments))
					for value, i in invocation.arguments {values[i] = instantiate_values(check, value, facts.parameters[:], actual_arguments)}
					apply_callback(check, access, values, pos)
					invoked = true
				}
				if !invoked {apply_callback(check, access, nil, pos)}
				continue
			}
			apply_parameter_access(check, access, requirement, pos)
		}
		apply_procedure_counters(check, facts, actual_arguments, target)
		apply_stores(check, facts, actual_arguments, pos, nil, len(callback.callables) > 1)
	}
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

contains_protected_state :: proc(access: State_Access, seen: ^map[uintptr]bool = nil) -> (protected: bool) {
	protected = access.protected && (access.pointer || access.shared || access.live)
	if len(access.fields) == 0 {return}
	seen := seen
	storage: map[uintptr]bool
	if seen == nil {storage = make(map[uintptr]bool); seen = &storage}
	key := field_identity(access.fields)
	if seen^[key] {return}
	seen^[key] = true
	for _, child in access.fields {
		protected = protected || contains_protected_state(child, seen)
	}
	return
}

instantiate_access :: proc(check: ^State_Flow, access: State_Access, parameters: []int, arguments: []^ast.Expr, scope: int, allocation: ^ast.Expr = nil) -> State_Access {
	values := make([]State_Access, len(arguments))
	for argument, i in arguments {values[i] = state_access(check, argument, scope, 0)}
	return instantiate_values(check, access, parameters, values, allocation)
}

instantiate_values :: proc(check: ^State_Flow, access: State_Access, parameters: []int, arguments: []State_Access, allocation: ^ast.Expr = nil, memo: ^Field_Transforms = nil) -> State_Access {
	result := access
	result.origins = nil
	mapped_fields: map[string]State_Access
	if len(access.origins) > 0 {
		// A symbolic callback is a value supplied by the actual caller. Carry
		// every target/effect alternative, including nil and unknown, when its
		// value is returned or stored through another formal parameter.
		callback := known_callback_type(check.r, access.type, access.scope) || access.callback_modeled || access.callback_unknown || len(access.callables) > 0 || access.callback_effects != {}
		all_nil := callback && len(access.callables) == 0 && access.callback_effects == {} && !access.callback_unknown
		all_modeled := true
		if callback {result.callables = slice.clone_to_dynamic(access.callables[:])}
		result.protected, result.published, result.resource, result.resources = false, false, {}, nil
		for origin in access.origins {
			index, found := slice.linear_search(parameters, origin.parameter)
			if !found || index >= len(arguments) {
				if callback {all_nil, all_modeled, result.callback_unknown = false, false, true}
				continue
			}
			value := arguments[index]
			value = project_access(check.r, value, origin.path)
			result.protected = result.protected || value.protected
			result.ambient = result.ambient || value.ambient
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
			if result.resource.root == nil {result.resource = value.resource} else if value.resource.root != nil && result.resource != value.resource && !slice.contains(result.resources[:], value.resource) {append(&result.resources, value.resource)}
			for resource in value.resources {if resource != result.resource && !slice.contains(result.resources[:], resource) {append(&result.resources, resource)}}
			for mapped in value.origins {if !slice.contains(result.origins[:], mapped) {append(&result.origins, mapped)}}
			if len(value.fields) > 0 {
				if mapped_fields == nil {mapped_fields = make(map[string]State_Access)}
				for name, child in value.fields {
					if previous, present := mapped_fields[name]; present {mapped_fields[name], _ = join_state_access(previous, child)} else {mapped_fields[name] = child}
				}
			}
		}
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
		for resource in access.resources {append(&result.resources, State_Location{root = allocation, path = fmt.aprintf("%p", resource.root)})}
	}
	result.fields = access.fields
	if len(access.fields) > 0 {
		memo := memo
		storage: Field_Transforms
		if memo == nil {storage = make(Field_Transforms); memo = &storage}
		key := field_identity(access.fields)
		if previous, found := memo^[key]; found {result.fields = previous.fields} else {
			result.fields = make(map[string]State_Access)
			for name, child in access.fields {result.fields[name] = instantiate_values(check, child, parameters, arguments, allocation, memo)}
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
	for component in strings.split(path, ".") {
		if component == "" {continue}
		if component == "^" {
			if referent, known := result.fields["^"]; known {result = referent} else {result = access_path(result, "^"); result.live, result.pointer = result.pointer, false}
		} else if component == "[]" {
			base := result
			result = element_access(r, base, 0)
			result.live = base.protected && (base.pointer || base.shared || base.live)

		} else {result = field_access(r, result, component, 0)}
	}
	return result
}

access_path :: proc(access: State_Access, field: string) -> State_Access {
	result := access
	repeat := false
	if field == "[]" && access.type != nil {if array, fixed := access.type.derived.(^ast.Array_Type); fixed {repeat = array.len != nil}}
	result.origins = make([dynamic]Access_Origin)
	for origin in access.origins {append(&result.origins, Access_Origin{origin.parameter, append_access_field(origin.path, field, repeat)})}
	if result.resource.root != nil {result.resource.path = append_access_field(result.resource.path, field, repeat)}
	result.resources = nil
	for resource in access.resources {
		child := resource
		child.path = append_access_field(child.path, field, repeat)
		append(&result.resources, child)
	}
	return result
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
append_access_field :: proc(path, field: string, repeat := false) -> string {
	if !repeat && slice.contains(strings.split(path, "."), field) {return ""}
	return field if path == "" else strings.concatenate({path, ".", field})
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
