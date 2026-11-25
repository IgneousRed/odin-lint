#+private
package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:slice"

// -------------------------------- Types --------------------------------

// ---------------- Package ----------------

Availability_Range :: struct {file, start, end: int, condition: Availability}

// Source availability is a disjunction of target sets and Boolean conjunctions.
// It proves relationships between saved alternatives without picking a host or
// evaluating an unknown compiler configuration. Unrelated expressions remain
// distinct atoms; a condition and its own else branch are exact complements.
// Universal availability is inline; every nonempty clause slice is owned by
// the analysis allocator. No retained guard points at a returned stack literal.
Availability :: struct {clauses: []Availability_Clause, supplied, all: bool}

Availability_Clause :: struct {
	os: runtime.Odin_OS_Types,
	arch: runtime.Odin_Arch_Types,
	tests: []Availability_Test,
}

Availability_Test :: struct {expression: ^ast.Expr, scope: int, atom: string, value: bool}

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

availability_expression :: proc(expression: ^ast.Expr, scope: int) -> Availability {
	if value, known := literal_condition(expression); known {
		if value {return availability_all()}
		return {supplied = true}
	}
	expression := expression
	expression = unwrap_parens(expression)
	if unary, ok := expression.derived.(^ast.Unary_Expr); ok && unary.op.text == "!" {return availability_not(availability_expression(unary.expr, scope))}
	if binary, ok := expression.derived.(^ast.Binary_Expr); ok {
		if binary.op.text == "&&" {return availability_and(availability_expression(binary.left, scope), availability_expression(binary.right, scope))}
		if binary.op.text == "||" {return availability_or(availability_expression(binary.left, scope), availability_expression(binary.right, scope))}
		if binary.op.text == "==" || binary.op.text == "!=" {
			for side, i in ([2]^ast.Expr{binary.left, binary.right}) {
				other := binary.right if i == 0 else binary.left
				if value, known := literal_condition(other); known {
					result := availability_expression(side, scope)
					if value != (binary.op.text == "==") {result = availability_not(result)}
					return result
				}
				name, named := binding_name(side)
				member, selected := unwrap_parens(other).derived.(^ast.Implicit_Selector_Expr)
				if named && selected && (name == "ODIN_OS" || name == "ODIN_ARCH") {
					clause := Availability_Clause{os = runtime.ALL_ODIN_OS_TYPES, arch = runtime.ALL_ODIN_ARCH_TYPES}
					if name == "ODIN_OS" {
						os, _ := parser.get_build_os_from_string(member.field.name)
						if os == .Unknown {continue}
						clause.os = {os}
					} else {
						arch := parser.get_build_arch_from_string(member.field.name)
						if arch == .Unknown {continue}
						clause.arch = {arch}
					}
					result := Availability{clauses = slice.clone([]Availability_Clause{clause}), supplied = true}
					if binary.op.text == "!=" {result = availability_not(result)}
					return result
				}
			}
		}
	}
	tests := slice.clone([]Availability_Test{{expression = expression, scope = scope, value = true}})
	return {clauses = slice.clone([]Availability_Clause{{runtime.ALL_ODIN_OS_TYPES, runtime.ALL_ODIN_ARCH_TYPES, tests}}), supplied = true}
}

availability_at :: proc(r: ^References, scope, offset: int) -> Availability {
	if scope < 0 || r.scopes[scope].file < 0 {return availability_all()}
	file := r.scopes[scope].file
	result := r.file_availability[file]
	span := max(int)
	for guard in r.availability_ranges {
		if guard.file == file && guard.start <= offset && offset < guard.end && guard.end-guard.start < span {
			span, result = guard.end-guard.start, guard.condition
		}
	}
	return result
}

binding_availability :: proc(r: ^References, id: int, depth := 0) -> Availability {
	if depth > len(r.symbols) {return {supplied = true}}
	symbol := r.symbols[id]
	result := symbol.available
	if !result.supplied {
		result = availability_all()
		// Promoted providers without source guard evidence keep their old local
		// uncertainty. Do not upgrade them merely because their target is known.
		if symbol.conditional {
			result = Availability{clauses = slice.clone([]Availability_Clause{{os = runtime.ALL_ODIN_OS_TYPES, arch = runtime.ALL_ODIN_ARCH_TYPES, tests = slice.clone([]Availability_Test{{atom = fmt.aprintf("provider:%d", id), value = true}})}}), supplied = true}
		}
	}
	if symbol.namespace_member {result = availability_and(result, binding_availability(r, symbol.namespace_target, depth+1))}
	return result
}

availability_not :: proc(source: Availability) -> Availability {
	if availability_unconditional(source) {return {supplied = true}}
	if len(source.clauses) == 0 {return availability_all()}
	result := availability_all()
	for clause in source.clauses {
		alternatives: [dynamic]Availability_Clause
		if os := runtime.ALL_ODIN_OS_TYPES - clause.os; os != {} {append(&alternatives, Availability_Clause{os = os, arch = runtime.ALL_ODIN_ARCH_TYPES})}
		if arch := runtime.ALL_ODIN_ARCH_TYPES - clause.arch; arch != {} {append(&alternatives, Availability_Clause{os = runtime.ALL_ODIN_OS_TYPES, arch = arch})}
		for test in clause.tests {
			opposite := test
			opposite.value = !test.value
			append(&alternatives, Availability_Clause{runtime.ALL_ODIN_OS_TYPES, runtime.ALL_ODIN_ARCH_TYPES, slice.clone([]Availability_Test{opposite})})
		}
		result = availability_and(result, Availability{clauses = alternatives[:], supplied = true})
	}
	return result
}

availability_and :: proc(left, right: Availability) -> Availability {
	if availability_unconditional(left) {return right}
	if availability_unconditional(right) {return left}
	clauses: [dynamic]Availability_Clause
	for a in left.clauses {
		for b in right.clauses {
			os, arch := a.os & b.os, a.arch & b.arch
			if os == {} || arch == {} {continue}
			tests := slice.clone_to_dynamic(a.tests)
			for test in b.tests {if !slice.contains(tests[:], test) {append(&tests, test)}}
			append(&clauses, Availability_Clause{os, arch, tests[:]})
		}
	}
	return {clauses = clauses[:], supplied = true}
}

availability_or :: proc(left, right: Availability) -> Availability {
	if availability_unconditional(left) {return left}
	if availability_unconditional(right) {return right}
	if len(left.clauses) == 0 {return right}
	if len(right.clauses) == 0 {return left}
	// Branch snapshots share immutable guard clauses; joining the same proof
	// must not duplicate it at every subsequent runtime conditional.
	if raw_data(left.clauses) == raw_data(right.clauses) && len(left.clauses) == len(right.clauses) {return left}
	clauses := slice.clone_to_dynamic(left.clauses)
	append(&clauses, ..right.clauses)
	return {clauses = clauses[:], supplied = true}
}

availability_all :: proc() -> Availability {
	return {supplied = true, all = true}
}

availability_possible :: proc(r: ^References, condition: Availability) -> bool {
	if condition.all {return true}
	for clause in condition.clauses {
		if clause.os == {} || clause.arch == {} {continue}
		if len(clause.tests) == 0 {return true}
		values := make(map[string]bool)
		possible := true
		for test in clause.tests {
			key, negative := test.atom, false
			if key == "" {key, negative = availability_atom(r, test.expression, test.scope, 0)}
			value := test.value != negative
			if previous, found := values[key]; found && previous != value {possible = false; break}
			values[key] = value
		}
		if possible {return true}
	}
	return false
}

// ---------------- File ----------------

@(private="file")
availability_unconditional :: proc(condition: Availability) -> bool {
	return condition.all || len(condition.clauses) == 1 && condition.clauses[0].os == runtime.ALL_ODIN_OS_TYPES && condition.clauses[0].arch == runtime.ALL_ODIN_ARCH_TYPES && len(condition.clauses[0].tests) == 0
}

@(private="file")
availability_atom :: proc(r: ^References, expression: ^ast.Expr, scope, depth: int) -> (key: string, negative: bool) {
	if expression == nil || depth > len(r.symbols)+len(r.scopes) {return fmt.aprintf("expression:%p", expression), false}
	expression := expression
	expression = unwrap_parens(expression)
	// Negation belongs to the atom's value, including through stable aliases.
	// An alias of !FEATURE and a direct !FEATURE must share one proof identity.
	if unary, ok := expression.derived.(^ast.Unary_Expr); ok && unary.op.text == "!" {
		key, negative = availability_atom(r, unary.expr, scope, depth+1)
		return key, !negative
	}
	if ident, named := expression.derived.(^ast.Ident); named {
		// Resolve the lexical identity without consulting availability: guard
		// proofs themselves must not recursively invoke guarded name lookup.
		for current := scope; current >= 0; current = r.scopes[current].parent {
			ids: [dynamic]int
			for id in r.scopes[current].bindings[ident.name] {
				if r.symbols[id].visible_from <= expression.pos.offset {append(&ids, id)}
			}
			if len(ids) == 0 {continue}
			if len(ids) == 1 && !r.symbols[ids[0]].written {
				symbol := r.symbols[ids[0]]
				if !symbol.mutable && symbol.value != nil {return availability_atom(r, symbol.value, symbol.scope, depth+1)}
				return fmt.aprintf("symbol:%d", ids[0]), false
			}
			break
		}
	}
	return fmt.aprintf("expression:%p", expression), false
}
