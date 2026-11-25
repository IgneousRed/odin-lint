"""Compiler-gated low-noise boundaries with concrete violation controls."""

import os
import subprocess
import unittest

import test_cli as cli

BINARY = cli.BINARY
section = cli.section


class TrustedBoundaryTests(unittest.TestCase):
    setUp = cli.CliTests.setUp
    write = cli.CliTests.write

    def source(self, role, body, imports=''):
        prefix = 'package ' + role + '\n'
        if imports:
            prefix += section('Imports', 'Odin') + imports
        return self.write(f'src/{role}/{role}.odin', prefix + section('Procedures', 'Public') + body)

    def inspect(self, source):
        flags = ['-no-entry-point', '-thread-count:1', '-vet', '-vet-tabs',
                 '-vet-using-param', '-vet-nil-deref', '-vet-uninitialized',
                 '-vet-atomic-access', '-strict-style', '-warnings-as-errors',
                 '-vet-packages:functions,catalog', '-strict-style-packages:functions,catalog']
        checked = subprocess.run([os.environ.get('ODIN', 'odin'), 'check', str(source.parent), *flags],
                                 capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        result = subprocess.run([str(BINARY), '--root', str(self.root), str(source)],
                                capture_output=True, text=True)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        return result

    def test_unmodeled_serializer_is_clean_without_annotations(self):
        source = self.source('functions',
                             'encode :: proc(value: int) -> ([]u8, bool) {\n'
                             '\tdata, error := json.marshal(value, allocator=context.temp_allocator)\n'
                             '\treturn data, error == nil\n}\n', 'import "core:encoding/json"\n')
        result = self.inspect(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')

    def test_public_exports_stay_anchored_with_only_local_saved_callers(self):
        source = self.source('functions',
                             'entry :: proc() -> int {return lookup()}\n'
                             'lookup :: proc() -> int {return 42}\n')
        result = self.inspect(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')

    def test_unknown_callback_is_clean(self):
        source = self.source('functions', 'invoke :: proc(action: proc()) {action()}\n')
        result = self.inspect(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')

    def test_network_namespace_does_not_imply_network_io(self):
        source = self.source('functions',
                             'valid :: proc(text: string) -> bool {_, ok := net.parse_ip4_address(text); return ok}\n',
                             'import "core:net"\n')
        result = self.inspect(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')

    def test_unknown_effects_do_not_establish_catalog_impurity(self):
        source = self.source('catalog',
                             'encode :: proc(value: int) -> []u8 {data, error := json.marshal(value); _ = error; return data}\n',
                             'import "core:encoding/json"\n')
        result = self.inspect(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')

    def test_unknown_call_does_not_hide_known_io(self):
        for role in ('functions', 'catalog'):
            with self.subTest(role=role):
                source = self.source(role,
                                     'encode :: proc(value: int) {data, error := json.marshal(value); _ = error; fmt.println(len(data))}\n',
                                     'import "core:encoding/json"\nimport "core:fmt"\n')
                result = self.inspect(source)
                self.assertIn('ARCH007:', result.stderr)
                if role == 'catalog':
                    self.assertIn('ARCH004:', result.stderr)
                self.assertNotIn('LINT004:', result.stderr)


if __name__ == '__main__':
    unittest.main()
