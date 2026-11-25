"""Compiler-backed reference writes, copied output slots and reset lifetimes."""

import os
import subprocess
import unittest

from test_cli import BINARY
import test_semantics_cli as semantic


class Ownership041Tests(unittest.TestCase):
    setUp = semantic.SemanticTests.setUp
    write = semantic.SemanticTests.write

    def inspect(self, entry, *selected):
        checked = subprocess.run([
            os.environ.get('ODIN', 'odin'), 'check', str(entry.parent), '-no-entry-point',
            '-thread-count:1', '-vet', '-vet-tabs', '-vet-using-param', '-vet-nil-deref',
            '-vet-uninitialized', '-vet-atomic-access', '-strict-style', '-warnings-as-errors',
            '-vet-packages:application,state,engine,functions,procedures,effects',
            '-strict-style-packages:application,state,engine,functions,procedures,effects',
        ], capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        binary = os.environ.get('ODIN_LINT_BINARY', str(BINARY))
        result = subprocess.run([binary, '--root', str(self.root), str(entry), *map(str, selected)],
                                capture_output=True, text=True)
        self.assertIn(result.returncode, (0, 1), result.stdout + result.stderr)
        return result.stderr

    def test_reference_iterator_writes_are_checked_at_actual_callers(self):
        self.write('state', 'Row :: struct {value: int}\nFacts :: struct {rows: [2]Row}\n')
        source = self.write('functions', 'edit :: proc(facts: ^state.Facts) '
                            '{for &row in facts.rows {row = {value=1}}}\n', 'import "../state"\n')
        for borrowed in (False, True):
            for callee_selected in (False, True):
                with self.subTest(borrowed=borrowed, callee_selected=callee_selected):
                    setup = 'working := saved; functions.edit(&working)' if not borrowed else 'functions.edit(&saved)'
                    caller = self.write('application', 'saved: state.Facts\n'
                                        'run :: proc() {' + setup + '}\n',
                                        'import "../state"\nimport "../functions"\n')
                    findings = self.inspect(caller, *([source] if callee_selected else []))
                    self.assertEqual('OWN001:' in findings, borrowed, findings)
                    if borrowed:
                        self.assertTrue(any(str(caller) in line and 'OWN001:' in line
                                            for line in findings.splitlines()), findings)

    def test_reference_iterator_keeps_borrowed_referent_after_whole_assignment(self):
        self.write('state', 'Row :: struct {values: []int}\nFacts :: struct {rows: [2]Row}\n')
        source = self.write('functions', 'edit :: proc(facts: ^state.Facts, values: []int) '
                            '{for &row in facts.rows {row = {values=values}; row.values[0]=1}}\n',
                            'import "../state"\n')
        caller = self.write('application', 'saved: state.Facts\n'
                            'run :: proc() {working: state.Facts; functions.edit(&working, saved.rows[0].values)}\n',
                            'import "../state"\nimport "../functions"\n')
        self.assertIn('OWN001:', self.inspect(caller, source))


    def test_value_iteration_preserves_pointer_element_borrows(self):
        self.write('state', 'Row :: struct {value:int}\nFacts :: struct {rows:[2]^Row}\n')
        self.write('functions', 'edit :: proc(facts:^state.Facts) '
                   '{for row in facts.rows {row.value=1}}\n', 'import "../state"\n')
        caller = self.write('application', 'saved:state.Facts\n'
                            'run :: proc() {functions.edit(&saved)}\n',
                            'import "../state"\nimport "../functions"\n')
        self.assertIn('OWN001:', self.inspect(caller))

    def test_negated_record_field_without_predicate_reaches_stable_summary(self):
        source = self.write('functions', 'Pointer :: struct {pressed, down:bool, position:int}\n'
                            'pointer :: proc(previous, mouse:Pointer, active:bool)->Pointer {'
                            'if active {return {pressed=!previous.down, down=true, position=mouse.position}}; '
                            'result:=mouse; result.position=previous.position; return result}\n')
        caller = self.write('application', 'run :: proc(active:bool)->bool {'
                            'previous, mouse:functions.Pointer; '
                            'return functions.pointer(previous,mouse,active).pressed}\n',
                            'import "../functions"\n')
        findings = self.inspect(caller, source)
        self.assertNotIn('LINT004:', findings)
        self.assertNotIn('OWN', findings)

    def test_private_migration_field_aliases_keep_destination_provenance(self):
        self.write('state', 'Bag :: struct {remaining:[4]int, eligible:u8}\n'
                   'Luck :: struct {bags:[2]Bag}\nFacts :: struct {luck:Luck}\n')
        source = self.write('functions', 'copy :: proc(old, next:^state.Facts) {'
                            'next^={luck=old.luck}; bag:=&next.luck.bags[0]; '
                            'bag.remaining[3]=0; bag.eligible &= ~u8(8)}\n', 'import "../state"\n')
        for borrowed_input, borrowed_output in ((False, False), (True, False), (False, True)):
            with self.subTest(borrowed_input=borrowed_input, borrowed_output=borrowed_output):
                old = '&saved' if borrowed_input else '&private'
                next_value = '&saved' if borrowed_output else '&next'
                caller = self.write('application', 'saved: state.Facts\n'
                                    'run :: proc() {private, next: state.Facts; '
                                    '_ = private; _ = next; functions.copy(' + old + ', ' + next_value + ')}\n',
                                    'import "../state"\nimport "../functions"\n')
                findings = self.inspect(caller, source)
                self.assertEqual('OWN001:' in findings, borrowed_output, findings)

    def test_migration_copy_keeps_borrowed_reference_fields(self):
        self.write('state', 'Facts :: struct {rows:[2]int, values:[]int}\n')
        source = self.write('functions', 'copy :: proc(old, next:^state.Facts) '
                            '{next^=old^; next.values[0]=1}\n', 'import "../state"\n')
        caller = self.write('application', 'saved: state.Facts\n'
                            'run :: proc() {next: state.Facts; functions.copy(&saved, &next)}\n',
                            'import "../state"\nimport "../functions"\n')
        self.assertIn('OWN001:', self.inspect(caller, source))
