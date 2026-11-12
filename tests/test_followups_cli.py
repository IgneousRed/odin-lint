"""Compiler-backed fixes for confirmed consumer-review false positives."""

import unittest

import test_semantics_cli as semantic


class FollowupTests(unittest.TestCase):
    setUp = semantic.SemanticTests.setUp
    write = semantic.SemanticTests.write

    inspect = semantic.SemanticTests.inspect
    inspect_borrowed = semantic.SemanticTests.inspect_borrowed

    def test_parser_recovery_preserves_attribute_newlines_and_original_positions(self):
        for attribute in ('@(rodata)\n', '@(rodata) // retain this comment\n\n',
                          '@(private)\n@(rodata)\n'):
            with self.subTest(attribute=attribute):
                source = self.write("functions", attribute + 'values := [2]int{1,2}\n'
                                    'run :: proc(data: []int) -> int {\n'
                                    '    result := 0\n    for value in data {copy:=value\n'
                                    '        result += copy\n    }\n'
                                    '    if result > 0 {result += 1}\n    else {result = 0}\n'
                                    '    fmt.println(result)\n    return result+values[0]\n}\n',
                                    'import "core:fmt"\n')
                line = source.read_text().splitlines().index('    fmt.println(result)') + 1
                self.assertIn(f'{source}({line}:5): ARCH007', self.inspect(source))

    def test_private_helpers_discharge_writes_at_owned_and_borrowed_callers(self):
        for declaration in ('@(private="file")', '@(private)'):
            for caller, invalid in (("run :: proc() {working: state.Store; change(&working)}", False),
                                    ("run :: proc(store: ^state.Store) {change(store)}", True)):
                with self.subTest(declaration=declaration, caller=caller):
                    source = self.write("functions", caller + "\n" + declaration
                                        + " change :: proc(store: ^state.Store) {store.values[0] = 1}\n",
                                        'import "../state"\n')
                    text = self.inspect_borrowed(source) if invalid else self.inspect(source)
                    self.assertEqual('OWN001:' in text, invalid)
                    if invalid:
                        self.assertIn('run mutates protected state through parameter 1', text)

    def test_private_write_requirements_compose_through_aliases_and_helpers(self):
        source = self.write("functions", 'run :: proc() {working: state.Store; first(&working)}\n'
                            '@(private="file") first :: proc(store: ^state.Store) {Alias(store)}\n'
                            'Alias :: second\n'
                            '@(private="file") second :: proc(store: ^state.Store) {store.values[0] = 1}\n',
                            'import "../state"\n')
        self.assertNotIn('OWN001:', self.inspect(source))

    def test_public_callback_and_global_writes_check_concrete_borrowers(self):
        for body in ('run :: proc(store: ^state.Store) {change(store)}\n'
                     'change :: proc(store: ^state.Store) {store.values[0] = 1}\n',
                     'run :: proc(store: ^state.Store) {invoke(change, store)}\n'
                     'invoke :: proc(action: proc(^state.Store), store: ^state.Store) {action(store)}\n'
                     '@(private="file") change :: proc(store: ^state.Store) {store.values[0] = 1}\n',
                     'saved: state.Store\nrun :: proc(store: ^state.Store) {change(store)}\n'
                     '@(private="file") change :: proc(store: ^state.Store) {_ = store; saved.values[0] = 1}\n'):
            with self.subTest(body=body):
                source = self.write('functions', body, 'import "../state"\n')
                self.assertIn('OWN001:', self.inspect_borrowed(source))


    def test_private_helper_mixed_global_and_formal_provenance_is_rejected(self):
        source = self.write('functions', 'saved: state.Store\n'
                            'run :: proc(flag: bool) {working: state.Store; change(&working, flag)}\n'
                            '@(private="file") change :: proc(store: ^state.Store, flag: bool) {\n'
                            'target := store\nif flag {target = &saved}\ntarget.values[0] = 1\n}\n',
                            'import "../state"\n')
        self.assertIn('OWN001:', self.inspect(source))


    def test_owned_fixed_array_writes_are_discharged_through_private_helpers(self):
        self.write('state', 'Store :: struct {values: [2]int}\n')
        source = self.write('functions', 'run :: proc() {working: state.Store; change(&working)}\n'
                            '@(private="file") change :: proc(store: ^state.Store) {store.values[0] = 1}\n',
                            'import "../state"\n')
        self.assertNotIn('OWN001:', self.inspect(source))
