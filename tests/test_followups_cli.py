"""Compiler-backed fixes for confirmed consumer-review false positives."""

import unittest

import test_semantics_cli as semantic
import test_cli as cli


class ParserRecoveryTests(unittest.TestCase):
    setUp = cli.CliTests.setUp
    write = cli.CliTests.write
    check = cli.CliTests.check
    lint = cli.CliTests.lint

    def test_expression_newlines_survive_inline_range_recovery(self):
        declarations = (
            ("Globals", '@(\n\trodata\n) // attribute stays attached\nvalues := [2]int{1, 2}\n', 'values[0]'),
            ("Constants", 'VALUE :: (\n\t1 // grouped expression\n)\n', 'VALUE'),
            ("Types", 'Value :: [\n\t2 // array bound\n]int\n', 'len(Value{})'),
            ("Types", 'Value :: [\n\t(\n\t\t2\n\t)\n]int\n', 'len(Value{})'),
        )
        for kind, declaration, value in declarations:
            for inline in (False, True):
                for effect in (False, True):
                    with self.subTest(kind=kind, declaration=declaration, inline=inline, effect=effect):
                        text = 'package functions\n'
                        if effect:
                            text += cli.section('Imports', 'Odin') + 'import "core:fmt"\n'
                        text += cli.section(kind, 'Public') + declaration + cli.section('Procedures', 'Public')
                        text += ('run :: proc(data: []int) -> int {\n\tresult := 0\n'
                                 '\tfor value in data {' + ('' if inline else '\n\t\t') + 'item := value\n'
                                 '\t\tresult += item\n\t}\n'
                                 '\tif result > 0 {result += 1}\n\telse {result = 0}\n')
                        if effect:
                            text += '\tfmt.println(result)\n'
                        text += '\treturn result + ' + value + '\n}\n'
                        source = self.write('src/functions/functions.odin', text)
                        self.check(source.parent, '-vet-tabs', '-vet-using-param', '-vet-nil-deref',
                                   '-vet-uninitialized', '-vet-atomic-access', library=True)
                        result = self.lint(source)
                        self.assertEqual(result.returncode, int(effect), result.stderr)
                        if effect:
                            line = text.splitlines().index('\tfmt.println(result)') + 1
                            self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)
                            self.assertIn(f'{source}({line}:2): ARCH007:', result.stderr)
                        else:
                            self.assertEqual(result.stderr, '')

    def test_nested_callback_bodies_still_recover_inside_expressions(self):
        for inline in (False, True):
            for grouped in (False, True):
                with self.subTest(inline=inline, grouped=grouped):
                    text = ('package functions\n' + cli.section('Procedures', 'Public')
                            + 'run :: proc(data: []int) -> int {\n\treturn invoke(\n\t\t'
                            + ('(' if grouped else '') + 'proc(data: []int) -> int {\n'
                            '\t\t\tresult := (\n\t\t\t\t0\n\t\t\t)\n'
                            '\t\t\tfor value in data {' + ('' if inline else '\n\t\t\t\t') + 'item := value\n'
                            '\t\t\t\tresult += item\n\t\t\t}\n'
                            '\t\t\tif result > 0 {result += 1}\n\t\t\telse {result = 0}\n'
                            '\t\t\treturn result\n\t\t}' + (')' if grouped else '') + ',\n'
                            '\t\tdata,\n\t)\n}\n'
                            'invoke :: proc(action: proc([]int) -> int, data: []int) -> int {return action(data)}\n')
                    source = self.write('src/functions/functions.odin', text)
                    self.check(source.parent, '-vet-tabs', '-vet-using-param', '-vet-nil-deref',
                               '-vet-uninitialized', '-vet-atomic-access', library=True)
                    result = self.lint(source)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stderr, '')


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
