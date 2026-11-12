"""Compiler-backed library effects and explicit import-closure regressions."""

import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

from consumer_fixture import borrowed_consumer
from test_cli import BINARY, PROJECT, section


class LibraryModelTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=PROJECT / '.work')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding='utf-8')
        return path

    def functions(self, body, imports=''):
        return self.write('src/functions/functions.odin', 'package functions\n'
                          + (section('Imports', 'Odin') + imports if imports else '')
                          + section('Procedures', 'Public') + body)

    def check(self, directory, *options):
        command = [os.environ.get('ODIN', 'odin'), 'check', str(directory), '-no-entry-point',
                   '-thread-count:2', '-vet', '-vet-tabs', '-vet-using-param', '-vet-nil-deref',
                   '-vet-uninitialized', '-vet-atomic-access', '-strict-style', '-warnings-as-errors',
                   '-vet-packages:functions,state,util,support',
                   '-strict-style-packages:functions,state,util,support', *options]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def lint(self, source, *options):
        result = subprocess.run([str(BINARY), '--root', str(self.root), *options, str(source)],
                                capture_output=True, text=True)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        return result.stderr

    def test_json_scalar_alias_conversions_are_not_callbacks(self):
        source = self.functions('convert :: proc() {\n'
                                '\ti := json.Integer(1); f := json.Float(1); b := json.Boolean(true)\n'
                                '\tassert(i == 1 && f == 1 && b)\n}\n',
                                'import "core:encoding/json"\n')
        self.check(source.parent)
        self.assertNotIn('LINT004:', self.lint(source))

    def test_scalar_conversion_alias_and_unknown_json_call_stay_distinct(self):
        source = self.functions('Integer :: json.Integer\n'
                                'convert :: proc() {\n'
                                '\tvalue := Integer(1); assert(value == 1)\n'
                                '\tencoded, error := json.marshal(value); _ = encoded; _ = error\n}\n',
                                'import "core:encoding/json"\n')
        self.check(source.parent)
        findings = self.lint(source)
        line = next(i for i, text in enumerate(source.read_text().splitlines(), 1) if 'value := Integer(1)' in text)
        self.assertNotIn(f'{source}({line}:', '\n'.join(text for text in findings.splitlines() if 'LINT004:' in text))
        self.assertNotIn('LINT004:', findings)

    def test_json_reference_and_enum_conversions_are_types(self):
        source = self.functions('convert :: proc() {\n'
                                '\ttext := json.String("a"); pointer := json.Null(nil)\n'
                                '\trows := json.Array([dynamic]json.Value{})\n'
                                '\tfields := json.Object(map[string]json.Value{})\n'
                                '\tvalue := json.Value(text); spec := json.Specification(0); error := json.Error(0)\n'
                                '\t_ = pointer; _ = value; _ = spec; _ = error\n'
                                '\tdelete(rows); delete(fields)\n}\n', 'import "core:encoding/json"\n')
        self.check(source.parent)
        self.assertNotIn('LINT004:', self.lint(source))


    def test_json_reference_conversion_preserves_borrowed_storage(self):
        self.write('src/state/state.odin', 'package state\nimport "core:encoding/json"\n'
                   'Store :: struct {rows: [dynamic]json.Value}\n')
        source = self.functions('saved: state.Store\n'
                                'convert :: proc() {rows := json.Array(saved.rows); delete(rows)}\n',
                                'import "core:encoding/json"\nimport "../state"\n')
        self.check(source.parent)
        findings = self.lint(source)
        self.assertNotIn('LINT004:', findings)
        self.assertIn('OWN001:', findings)

    def test_tokenizer_default_handler_effect_and_nil_control(self):
        for argument, external in (('', True), (', nil', False),
                                   (', tokenizer.default_error_handler', True)):
            with self.subTest(argument=argument):
                source = self.functions('scan :: proc(text: string) {\n'
                                        '\tlexer: tokenizer.Tokenizer\n'
                                        '\ttokenizer.init(&lexer, text, "input"' + argument + ')\n'
                                        '\t_ = tokenizer.scan(&lexer)\n}\n',
                                        'import "core:odin/tokenizer"\n')
                self.check(source.parent)
                text = self.lint(source)
                self.assertEqual('ARCH007:' in text, external, text)
                self.assertNotIn('LINT004:', text)

    def test_tokenizer_default_handler_direct_and_aliased_calls_keep_io(self):
        for statement in ('tokenizer.default_error_handler({}, "outside")',
                          'handler :: tokenizer.default_error_handler; handler({}, "outside")'):
            with self.subTest(statement=statement):
                source = self.functions('report :: proc() {' + statement + '}\n',
                                        'import "core:odin/tokenizer"\n')
                self.check(source.parent)
                findings = self.lint(source)
                self.assertIn('ARCH007:', findings)
                self.assertNotIn('LINT004:', findings)

    def test_tokenizer_public_scanners_carry_saved_handler_effects(self):
        calls = ('_ = tokenizer.peek_rune(t=&lexer)',
                 '_, _ = tokenizer.read_rune(t=&lexer)',
                 'tokenizer.advance_rune(t=&lexer)',
                 'tokenizer.skip_whitespace(t=&lexer)',
                 '_ = tokenizer.scan_comment(t=&lexer)',
                 '_ = tokenizer.scan_file_tag(t=&lexer)',
                 '_ = tokenizer.scan_identifier(t=&lexer)',
                 '_ = tokenizer.scan_string(quote=\'"\', t=&lexer)',
                 '_ = tokenizer.scan_raw_string(t=&lexer)',
                 '_ = tokenizer.scan_escape(t=&lexer)',
                 '_ = tokenizer.scan_rune(t=&lexer)',
                 '_, _ = tokenizer.scan_number(seen_decimal_point=false, t=&lexer)',
                 '_ = tokenizer.scan(t=&lexer)',
                 'tokenizer.error(&lexer, 0, "outside")')
        for call in calls:
            for handler, io, unknown in (('nil', False, False), ('quiet', False, False),
                                          ('tokenizer.default_error_handler', True, False),
                                          ('cast(tokenizer.Error_Handler)rawptr(uintptr(1))', False, True)):
                with self.subTest(call=call, handler=handler):
                    source = self.functions('scan :: proc(text: string) {\n'
                                            '\tlexer := tokenizer.Tokenizer{src=text, err=' + handler + '}\n'
                                            '\t' + call + '\n}\n'
                                            'quiet :: proc(pos: tokenizer.Pos, message: string, args: ..any) {_ = pos; _ = message; _ = args}\n',
                                            'import "core:odin/tokenizer"\n')
                    self.check(source.parent)
                    findings = self.lint(source)
                    self.assertEqual('ARCH007:' in findings, io, findings)
                    self.assertEqual('LINT004:' in findings, False, findings)

    def test_tokenizer_keyword_table_mutation_requires_owned_destination(self):
        source = self.functions('prepare :: proc() {\n'
                                '\ttable: tokenizer.Keyword_LUT\n'
                                '\tassert(tokenizer.keyword_lut_init(lut=&table))\n}\n',
                                'import "core:odin/tokenizer"\n')
        self.check(source.parent)
        self.assertNotIn('OWN001:', self.lint(source))
        # The saved relation establishes borrowed provenance independently of
        # Keyword_LUT's opaque external shape. The formal exports a requirement.
        self.write('src/state/state.odin', 'package state\nimport "core:odin/tokenizer"\n'
                   'Store :: struct {values: []int, table: ^tokenizer.Keyword_LUT}\n')
        source = self.functions('prepare :: proc(read: ^state.Store) '
                                '{assert(tokenizer.keyword_lut_init(lut=read.table))}\n',
                                'import "core:odin/tokenizer"\nimport "../state"\n')
        consumer = borrowed_consumer(self.root, source, call='prepare(&live)')
        self.check(consumer.parent)
        findings = self.lint(source, str(consumer))
        self.assertIn('OWN001:', findings)
        self.assertNotIn('ARCH007:', findings)

    def test_zero_initialized_handler_is_definitely_nil(self):
        source = self.functions('scan :: proc(text: string) {\n'
                                '\tlexer: tokenizer.Tokenizer\n'
                                '\thandler: tokenizer.Error_Handler\n'
                                '\ttokenizer.init(&lexer, text, "input", handler)\n'
                                '\t_ = tokenizer.scan(&lexer)\n}\n',
                                'import "core:odin/tokenizer"\n')
        self.check(source.parent)
        findings = self.lint(source)
        self.assertNotIn('ARCH007:', findings)
        self.assertNotIn('LINT004:', findings)

    def test_tokenizer_named_arguments_and_rebound_handler(self):
        source = self.functions('scan :: proc(text: string) {\n'
                                '\tlexer: tokenizer.Tokenizer\n'
                                '\ttokenizer.init(err = nil, path = "input", src = text, t = &lexer)\n'
                                '\tlexer.err = tokenizer.default_error_handler\n'
                                '\t_ = tokenizer.scan(t = &lexer)\n}\n',
                                'import "core:odin/tokenizer"\n')
        self.check(source.parent)
        self.assertIn('ARCH007:', self.lint(source))

    def test_tokenizer_helpers_preserve_explicit_nil_state(self):
        source = self.functions('scan :: proc(text: string) {\n'
                                '\tlexer: tokenizer.Tokenizer\n'
                                '\tinitialize(&lexer, text)\n\tconsume(&lexer)\n}\n'
                                'initialize :: proc(lexer: ^tokenizer.Tokenizer, text: string) {tokenizer.init(lexer, text, "input", nil)}\n'
                                'consume :: proc(lexer: ^tokenizer.Tokenizer) {_ = tokenizer.scan(lexer)}\n',
                                'import "core:odin/tokenizer"\n')
        self.check(source.parent)
        findings = self.lint(source)
        self.assertNotIn('ARCH007:', findings)
        self.assertNotIn('LINT004:', findings)

    def test_tokenizer_default_handler_store_through_helper_is_retained(self):
        source = self.functions('scan :: proc(text: string) {\n'
                                '\tlexer: tokenizer.Tokenizer\n'
                                '\ttokenizer.init(&lexer, text, "input", nil)\n'
                                '\tset_default(&lexer)\n'
                                '\t_ = tokenizer.scan(&lexer)\n}\n'
                                'set_default :: proc(lexer: ^tokenizer.Tokenizer) {lexer.err = tokenizer.default_error_handler}\n',
                                'import "core:odin/tokenizer"\n')
        self.check(source.parent)
        self.assertIn('ARCH007:', self.lint(source))

    def test_symbolic_callback_stores_keep_nil_pure_and_effectful_actuals(self):
        for handler, io in (('nil', False), ('quiet', False), ('tokenizer.default_error_handler', True)):
            with self.subTest(handler=handler):
                source = self.functions('scan :: proc(text: string) {\n'
                                        '\tlexer: tokenizer.Tokenizer\n'
                                        '\ttokenizer.init(&lexer, text, "input", nil)\n'
                                        '\tset_handler(&lexer, ' + handler + ')\n'
                                        '\t_ = tokenizer.scan(&lexer)\n}\n'
                                        'set_handler :: proc(lexer: ^tokenizer.Tokenizer, handler: tokenizer.Error_Handler) {lexer.err = handler}\n'
                                        'quiet :: proc(pos: tokenizer.Pos, message: string, args: ..any) {_ = pos; _ = message; _ = args}\n',
                                        'import "core:odin/tokenizer"\n')
                self.check(source.parent)
                findings = self.lint(source)
                self.assertEqual('ARCH007:' in findings, io, findings)
                self.assertNotIn('LINT004:', findings)

    def test_tokenizer_custom_pure_handler(self):
        source = self.functions('scan :: proc(text: string) {\n'
                                '\tlexer: tokenizer.Tokenizer\n'
                                '\ttokenizer.init(&lexer, text, "input", quiet)\n'
                                '\t_ = tokenizer.scan(&lexer)\n}\n'
                                'quiet :: proc(pos: tokenizer.Pos, message: string, args: ..any) {_ = pos; _ = message; _ = args}\n',
                                'import "core:odin/tokenizer"\n')
        self.check(source.parent)
        text = self.lint(source)
        self.assertNotIn('ARCH007:', text)
        self.assertNotIn('LINT004:', text)

    def test_tokenizer_unknown_handler_is_not_pure(self):
        source = self.functions('scan :: proc(text: string) {\n'
                                '\tlexer: tokenizer.Tokenizer\n'
                                '\thandler := cast(tokenizer.Error_Handler)rawptr(uintptr(1))\n'
                                '\ttokenizer.init(&lexer, text, "input", handler)\n'
                                '\t_ = tokenizer.scan(&lexer)\n}\n',
                                'import "core:odin/tokenizer"\n')
        self.check(source.parent)
        self.assertNotIn('LINT004:', self.lint(source))

    def test_unknown_handler_alternative_survives_known_pure_join(self):
        source = self.functions('scan :: proc(text: string, flag: bool) {\n'
                                '\thandler := quiet\n'
                                '\tif flag {handler = cast(tokenizer.Error_Handler)rawptr(uintptr(1))}\n'
                                '\tlexer: tokenizer.Tokenizer\n'
                                '\ttokenizer.init(&lexer, text, "input", handler)\n'
                                '\t_ = tokenizer.scan(&lexer)\n}\n'
                                'quiet :: proc(pos: tokenizer.Pos, message: string, args: ..any) {_ = pos; _ = message; _ = args}\n',
                                'import "core:odin/tokenizer"\n')
        self.check(source.parent)
        self.assertNotIn('LINT004:', self.lint(source))

    def test_explicit_collection_closure_loads_siblings_and_relative_imports(self):
        self.write('vendor/custom/util/util.odin', 'package util\nimport "../support"\n'
                   'twice :: proc(x: int) -> int {return multiply(x, support.FACTOR)}\n')
        self.write('vendor/custom/util/private.odin', '#+private\npackage util\n'
                   'multiply :: proc(x, y: int) -> int {return x*y}\n')
        self.write('vendor/custom/support/support.odin', 'package support\nFACTOR :: 2\n')
        self.write('vendor/custom/unreferenced/unreferenced.odin', 'invalid source')
        source = self.functions('calculate :: proc(x: int) -> int {return util.twice(x)}\n',
                                'import "custom:util"\n')
        collection = str(self.root / 'vendor/custom')
        self.check(source.parent, '-collection:custom=' + collection)
        findings = self.lint(source, '--collection', 'custom=' + collection)
        self.assertNotIn('LINT004:', findings)
        self.assertNotIn('/vendor/', findings)

    def test_collection_effects_propagate_without_vendor_findings(self):
        self.write('vendor/custom/util/util.odin', 'package util\nimport "core:fmt"\n'
                   'observe :: proc() {fmt.println("outside")}\n')
        source = self.functions('calculate :: proc() {util.observe()}\n', 'import "custom:util"\n')
        collection = str(self.root / 'vendor/custom')
        self.check(source.parent, '-collection:custom=' + collection)
        findings = self.lint(source, '--collection', 'custom=' + collection)
        self.assertIn('ARCH007:', findings)
        self.assertNotIn('/vendor/', findings)

    def test_used_missing_collection_root_is_setup_failure(self):
        source = self.functions('calculate :: proc() -> int {return util.value()}\n', 'import "custom:util"\n')
        self.write('dependency/util/util.odin', 'package util\nvalue :: proc() -> int {return 1}\n')
        mapping = 'custom=' + str(self.root / 'dependency')
        self.check(source.parent, '-collection:' + mapping)
        shutil.rmtree(self.root / 'dependency')
        result = subprocess.run([str(BINARY), '--root', str(self.root), '--collection', mapping, str(source)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('invalid collection root', result.stderr)

    def test_invalid_unused_collection_root_matches_compiler_setup_failure(self):
        source = self.functions('calculate :: proc() -> int {return 1}\n')
        self.check(source.parent)
        mapping = 'custom=' + str(self.root / 'missing')
        compiler = subprocess.run([os.environ.get('ODIN', 'odin'), 'check', str(source.parent),
                                   '-no-entry-point', '-collection:' + mapping],
                                  capture_output=True, text=True)
        self.assertNotEqual(compiler.returncode, 0)
        self.assertIn('must be a directory', compiler.stderr)
        result = subprocess.run([str(BINARY), '--root', str(self.root), '--collection', mapping, str(source)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('invalid collection root', result.stderr)

    def test_collection_symlinked_odin_sibling_is_analysis_error(self):
        self.write('vendor/custom/util/util.odin', 'package util\nvalue :: proc() -> int {return 1}\n')
        target = self.write('outside/hidden.odin', 'package util\n')
        (self.root / 'vendor/custom/util/alias.odin').symlink_to(target)
        source = self.functions('calculate :: proc() -> int {return util.value()}\n', 'import "custom:util"\n')
        result = subprocess.run([str(BINARY), '--root', str(self.root), '--collection',
                                 'custom=' + str(self.root / 'vendor/custom'), str(source)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('symlinked Odin sibling', result.stderr)

    def test_endian_reads_and_private_writes_are_modeled(self):
        source = self.functions('encode :: proc() {\n\tbuffer: [8]u8\n'
                                '\tassert(endian.put_u32(buffer[:], .Little, 42))\n'
                                '\tvalue, ok := endian.get_u32(buffer[:], .Little)\n'
                                '\tassert(ok && value == 42)\n}\n', 'import "core:encoding/endian"\n')
        self.check(source.parent)
        text = self.lint(source)
        self.assertNotIn('LINT004:', text)
        self.assertNotIn('OWN001:', text)

    def test_endian_destination_keeps_borrowed_storage_restricted(self):
        self.write('src/state/state.odin', 'package state\nStore :: struct {bytes: [8]u8}\n')
        source = self.functions('saved: state.Store\n'
                                'encode :: proc() {_ = endian.put_u32(saved.bytes[:], .Little, 42)}\n',
                                'import "core:encoding/endian"\nimport "../state"\n')
        self.check(source.parent)
        self.assertIn('OWN001:', self.lint(source))
