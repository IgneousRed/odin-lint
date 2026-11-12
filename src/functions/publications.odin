#+private
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:odin/ast"
import "core:slice"

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

// Leading assertions on a proven transfer are source-established contracts.
// Unknown expressions are not requirements inferred from a name or datatype.
record_publication_checks :: proc(entry: ^State_Flow, expression: ^ast.Expr, destination: Access_Origin, truth := true) -> bool {
	expression := expression
	expression = unwrap_parens(expression)
	if expression == nil {return false}
	if unary, ok := expression.derived.(^ast.Unary_Expr); ok && unary.op.text == "!" {
		return record_publication_checks(entry, unary.expr, destination, !truth)
	}
	left := expression
	right: ^ast.Expr
	equal := !truth
	if binary, ok := expression.derived.(^ast.Binary_Expr); ok {
		if binary.op.text == "&&" && truth || binary.op.text == "||" && !truth {
			if !record_publication_checks(entry, binary.left, destination, truth) {return false}
			return record_publication_checks(entry, binary.right, destination, truth)
		}
		if binary.op.text != "==" && binary.op.text != "!=" {return false}
		left, right, equal = binary.left, binary.right, (binary.op.text == "==") == truth
	}
	// Do not interpret computations or calls as entry-value contracts, or scan
	// past an assertion whose effects on later operands are not established.
	for raw_operand in ([2]^ast.Expr{left, right}) {
		if raw_operand == nil {continue}
		operand := unwrap_parens(raw_operand)
		resolve_operand: for {
			#partial switch node in operand.derived {
			case ^ast.Selector_Expr: operand = unwrap_parens(node.expr)
			case ^ast.Deref_Expr: operand = unwrap_parens(node.expr)
			case ^ast.Ident, ^ast.Basic_Lit: break resolve_operand
			case: return false
			}
		}
	}
	facts := &entry.r.semantics.facts[entry.caller]
	condition := Publication_Check{destination = destination, equal = equal, expression = expression, truth = truth}
	left_value := state_access(entry, left, entry.r.node_scopes[left], 0)
	right_value := State_Access{zero = .Zero}
	if right != nil {right_value = state_access(entry, right, entry.r.node_scopes[right], 0)}
	left_known, right_known: bool
	condition.left, condition.left_zero, left_known = publication_value(left_value, facts.parameters[:])
	condition.right, condition.right_zero, right_known = publication_value(right_value, facts.parameters[:])
	if !left_known || !right_known {return false}
	for saved in facts.publications {
		// Presentation evidence does not create another equivalent requirement.
		previous := saved
		previous.expression, previous.truth = condition.expression, condition.truth
		if previous == condition {return true}
	}
	append(&facts.publications, condition)
	entry.r.semantics.changed = true
	return true
}

publication_argument :: proc(r: ^References, origin: Access_Origin, zero: Value_Zero, parameters: []int, arguments: []State_Access, expressions: []^ast.Expr = nil, uncertain := false) -> State_Access {
	if origin.parameter < 0 {return State_Access{zero = zero}}
	index, found := slice.linear_search(parameters, origin.parameter)
	if !found || index >= len(arguments) {return State_Access{zero = .Unknown}}
	value := project_access(r, arguments[index], origin.path)
	if uncertain {
		literal := false
		if origin.path == "" && index < len(expressions) && expressions[index] != nil {
			expression := unwrap_parens(expressions[index])
			_, literal = expression.derived.(^ast.Basic_Lit)
			name, named := binding_name(expression)
			literal = literal || named && (name == "true" || name == "false" || name == "nil")
		}
		if !literal {value.zero = .Unknown}
	}
	return value
}

// ---------------- File ----------------

@(private = "file")
publication_value :: proc(access: State_Access, parameters: []int) -> (origin: Access_Origin, zero: Value_Zero, known: bool) {
	origin.parameter, zero = -1, access.zero
	if len(access.origins) == 1 && slice.contains(parameters, access.origins[0].parameter) {
		return access.origins[0], .Unknown, true
	}
	return origin, zero, len(access.origins) == 0 && !access.published && !access.uncertain && (zero == .Zero || zero == .Nonzero)
}
