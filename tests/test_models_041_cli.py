"""Compiler-backed C conversions and JSON input/allocator model regressions."""

import os
import subprocess
import unittest

from consumer_fixture import borrowed_consumer
from test_cli import BINARY
import test_models_040_cli as models


class Model041Tests(unittest.TestCase):
    setUp = models.LibraryModelTests.setUp
    write = models.LibraryModelTests.write
    functions = models.LibraryModelTests.functions

    def check(self, directory):
        result = subprocess.run([os.environ.get('ODIN', 'odin'), 'check', str(directory),
                                 '-no-entry-point', '-thread-count:1', '-vet', '-vet-tabs',
                                 '-vet-using-param', '-vet-nil-deref', '-vet-uninitialized',
                                 '-vet-atomic-access', '-strict-style', '-warnings-as-errors',
                                 '-vet-packages:functions,state,support,consumer,catalog',
                                 '-strict-style-packages:functions,state,support,consumer,catalog'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def lint(self, source, *selected):
        result = subprocess.run([str(BINARY), '--root', str(self.root), str(source),
                                 *map(str, selected)], capture_output=True, text=True)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        return result.stderr

    def test_c_scalar_conversions_and_stable_type_aliases(self):
        source = self.functions('C_Int :: c.int\n'
                                'convert :: proc(value: int) -> c.int {\n'
                                '\t_ = c.char(value); _ = c.short(value); _ = c.long(value)\n'
                                '\t_ = c.uint(value); _ = c.size_t(value); _ = c.ptrdiff_t(value)\n'
                                '\t_ = c.int_fast64_t(value); _ = c.uint_least32_t(value)\n'
                                '\t_ = c.float(value); _ = c.double(value); _ = c.bool(value != 0)\n'
                                '\treturn C_Int(value)\n}\n', 'import "core:c"\n')
        self.check(source.parent)
        self.assertNotIn('LINT004:', self.lint(source))

    def test_unmodeled_external_procedure_is_nonblocking(self):
        source = self.functions('encode :: proc(value: int) {data, error := json.marshal(value); '
                                '_ = data; _ = error}\n', 'import "core:encoding/json"\n')
        self.check(source.parent)
        findings = self.lint(source)
        self.assertNotIn('LINT004:', findings)
        self.assertNotIn('ARCH007:', findings)
        self.assertNotIn('callback target is unavailable', findings)

    def test_json_tokenizer_and_parser_constructors_have_no_callback(self):
        source = self.functions('scan :: proc(text: string, bytes: []u8) {\n'
                                '\tmake := json.make_tokenizer\n'
                                '\tlexer := make(data=text, parse_integers=true)\n'
                                '\ttoken, token_error := json.get_token(t=&lexer)\n'
                                '\t_ = token; _ = token_error\n'
                                '\tp := json.make_parser(bytes, allocator=context.temp_allocator)\n'
                                '\t_ = p\n}\n', 'import "core:encoding/json"\n')
        self.check(source.parent)
        findings = self.lint(source)
        self.assertNotIn('LINT004:', findings)
        self.assertNotIn('ARCH007:', findings)
        self.assertNotIn('OWN001:', findings)


    def test_json_token_text_retains_a_concrete_borrowed_relation(self):
        self.write('src/state/state.odin', 'package state\nStore :: struct {bytes: []u8}\n')
        source = self.functions('change :: proc(input: ^state.Store) {\n'
                                '\tlexer := json.make_tokenizer(string(input.bytes))\n'
                                '\ttoken, error := json.get_token(&lexer); _ = error\n'
                                '\t_ = copy(transmute([]u8)token.text, []u8{1})\n}\n',
                                'import "core:encoding/json"\n// ---------------- Project ----------------\n'
                                + 'import "../state"\n')
        consumer = borrowed_consumer(self.root, source, call='change(&live)')
        self.check(consumer.parent)
        findings = self.lint(source, consumer)
        self.assertIn('OWN001:', findings)
        self.assertNotIn('LINT004:', findings)


    def test_parser_construction_defers_custom_allocator_effects(self):
        self.write('support/support.odin', 'package support\nimport "base:runtime"\n'
                   'import "core:fmt"\nimport "core:mem"\n'
                   'noisy :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, '
                   'old: rawptr, old_size: int, loc: runtime.Source_Code_Location) -> ([]u8, mem.Allocator_Error) '
                   '{_ = data; _ = mode; _ = size; _ = alignment; _ = old; _ = old_size; _ = loc; '
                   'fmt.println("allocate"); return nil, .Out_Of_Memory}\n')
        for parse, external in (('', False), ('value, error := json.parse_value(&parser); _ = value; _ = error', True)):
            with self.subTest(parse=parse):
                source = self.functions('parse :: proc(text: string) {\n'
                                        '\tallocator := mem.Allocator{procedure=support.noisy}\n'
                                        '\tparser := json.make_parser(text, allocator=allocator); _ = parser\n'
                                        '\t' + parse + '\n}\n',
                                        'import "core:encoding/json"\nimport "core:mem"\n'
                                        + '// ---------------- Project ----------------\nimport "../../support"\n')
                self.check(source.parent)
                findings = self.lint(source)
                self.assertEqual('ARCH007:' in findings, external, findings)
                self.assertEqual('LINT004:' in findings, False, findings)

    def test_unknown_allocator_callback_remains_uncertain(self):
        source = self.functions('parse :: proc(text: string) {\n'
                                '\tallocator := mem.Allocator{procedure=cast(mem.Allocator_Proc)rawptr(uintptr(1))}\n'
                                '\tparser := json.make_parser(text, allocator=allocator)\n'
                                '\tvalue, error := json.parse_value(&parser); _ = value; _ = error\n}\n',
                                'import "core:encoding/json"\nimport "core:mem"\n')
        self.check(source.parent)
        self.assertNotIn('LINT004:', self.lint(source))


    def test_saved_json_parser_helpers_keep_allocator_effects_and_unknown_outputs(self):
        self.write('support/support.odin', 'package support\nimport "base:runtime"\n'
                   'import "core:fmt"\nimport "core:mem"\n'
                   'noisy :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, '
                   'old: rawptr, old_size: int, loc: runtime.Source_Code_Location) -> ([]u8, mem.Allocator_Error) '
                   '{_ = data; _ = mode; _ = size; _ = alignment; _ = old; _ = old_size; _ = loc; '
                   'fmt.println("allocate"); return nil, .Out_Of_Memory}\n')
        for procedure, external in (('support.noisy', True),
                                     ('cast(mem.Allocator_Proc)rawptr(uintptr(1))', False)):
            for callback in (False, True):
                with self.subTest(procedure=procedure, callback=callback):
                    invoke = 'read(&parser)'
                    helper = ''
                    if callback:
                        invoke = 'invoke(read, &parser)'
                        helper = ('invoke :: proc(read: proc(^json.Parser), value: ^json.Parser) '
                                  '{read(value)}\n')
                    source = self.functions('run :: proc(text: string) {\n'
                                            '\t_ = support.noisy\n'
                                            '\tallocator := mem.Allocator{procedure=' + procedure + '}\n'
                                            '\tparser := json.make_parser(text, allocator=allocator)\n'
                                            '\t' + invoke + '\n}\n'
                                            'read :: proc(value: ^json.Parser) {'
                                            'result, error := json.parse_value(value); _ = result; _ = error}\n'
                                            + helper, 'import "core:encoding/json"\nimport "core:mem"\n'
                                            '// ---------------- Project ----------------\nimport "../../support"\n')
                    self.check(source.parent)
                    findings = self.lint(source)
                    self.assertNotIn('LINT004:', findings)
                    self.assertEqual('ARCH007:' in findings, external, findings)

    def test_catalog_lookup_can_read_modeled_input(self):
        source = self.write('src/catalog/catalog.odin', 'package catalog\n'
                            'import "core:encoding/json"\n'
                            'lookup :: proc(text: string) -> bool {\n'
                            '\tlexer := json.make_tokenizer(text)\n'
                            '\ttoken, error := json.get_token(&lexer); _ = error\n'
                            '\treturn token.text == "{"\n}\n')
        self.check(source.parent)
        findings = self.lint(source)
        self.assertNotIn('ARCH004:', findings)
        self.assertNotIn('LINT004:', findings)

    def test_recursive_callback_forwarding_joins_known_capabilities(self):
        for callback, effect, unknown, io in (
                ('cycle', '', False, False),
                ('cycle', 'fmt.println("tick"); ', False, True),
                ('cast(proc(^Link))rawptr(uintptr(1))', '', True, False)):
            with self.subTest(callback=callback, effect=effect):
                source = self.functions('Link :: struct {stopped: bool, run: proc(^Link)}\n'
                                        'run :: proc() {link := Link{run=' + callback + '}; cycle(&link)}\n'
                                        'cycle :: proc(link: ^Link) {if link.stopped {return}; '
                                        + effect + 'link.run(link)}\n',
                                        'import "core:fmt"\n' if io else '')
                self.check(source.parent)
                findings = self.lint(source)
                self.assertEqual('LINT004:' in findings, False, findings)
                self.assertEqual('ARCH007:' in findings, io, findings)


if __name__ == '__main__':
    unittest.main()
