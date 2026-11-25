#+private
package tests

// -------------------------------- Imports --------------------------------

// ---------------- Project ----------------

import "../src/state"

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

// Tests of one policy count its findings while all other rules still run.
count_rule :: proc(diagnostics: []state.Diagnostic, rule: string) -> (count: int) {
	for diagnostic in diagnostics {
		count += int(diagnostic.rule == rule)
	}
	return
}
