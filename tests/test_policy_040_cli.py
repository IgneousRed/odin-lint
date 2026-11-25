"""Compiler-backed value contexts and satisfiable interface/catalog policies."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_cli import PROJECT, section
import test_policies_cli as policy_cases


class Policy040Tests(unittest.TestCase):
    lint = policy_cases.ProjectPolicyTests.lint

    def setUp(self):
        temp = tempfile.TemporaryDirectory(dir=PROJECT / '.work')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def write(self, relative, source):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding='utf-8')
        return path

    def compile(self, directory, *extra, mode='check'):
        packages = {line.split()[1] for path in self.root.rglob('*.odin')
                    for line in path.read_text().splitlines() if line.startswith('package ')}
        flags = ['-thread-count:2', '-vet', '-vet-tabs', '-vet-using-param', '-vet-nil-deref',
                 '-vet-uninitialized', '-vet-atomic-access', '-strict-style', '-warnings-as-errors',
                 '-vet-packages:' + ','.join(sorted(packages)),
                 '-strict-style-packages:' + ','.join(sorted(packages))]
        if mode == 'check':
            flags.append('-no-entry-point')
        else:
            flags.extend(['-debug', '-define:ODIN_TEST_THREADS=1', '-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true',
                          '-out:' + str(self.root / 'test-binary')])
        result = subprocess.run([os.environ.get('ODIN', 'odin'), mode, str(directory), *flags, *extra],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_array_bounds_remain_values_while_element_aliases_remain_types(self):
        source = self.write('src/sample/sample.odin', 'package sample\n' + section('Constants', 'Public')
                            + 'LENGTH :: #config(LENGTH, 32)\n' + section('Types', 'Public')
                            + 'Number :: int\nFrame :: struct {values: [LENGTH]Number}\n')
        self.compile(source.parent)
        self.assertNotIn('SECTION003', self.lint(source))
        source.write_text('package sample\n' + section('Types', 'Public') + 'LENGTH :: #config(LENGTH, 32)\nNumber :: int\nFrame :: struct {values: [LENGTH]Number}\n')
        self.compile(source.parent)
        self.assertIn('SECTION003', self.lint(source))

    def test_matrix_dimensions_are_values_and_enum_indexed_arrays_stay_types(self):
        source = self.write('src/sample/sample.odin', 'package sample\n' + section('Constants', 'Public')
                            + 'ROWS :: #config(ROWS, 2)\nCOLS :: 2\n' + section('Types', 'Public')
                            + 'Direction :: enum {Left, Right}\n'
                            + 'Frame :: struct {basis: matrix[ROWS, COLS]f32, indexed: [Direction]int}\n')
        self.compile(source.parent)
        self.assertNotIn('SECTION003', self.lint(source))

    def test_main_package_keeps_its_compiler_identity_in_any_directory(self):
        source = self.write('src/entry/main.odin', 'package main\n' + section('Procedures', 'Public')
                            + 'main :: proc() {}\n')
        self.compile(source.parent)
        self.assertNotIn('FILE002', self.lint(source))
        source.write_text('package unrelated\n')
        self.compile(source.parent)
        self.assertIn('FILE002', self.lint(source))

    def test_imported_abi_namespace_can_require_a_distinct_package_name(self):
        source = self.write('src/raylib/raylib.odin', 'package graphics_adapter\n'
                            + section('Imports', 'Vendor') + 'import rl "vendor:raylib"\n'
                            + section('Procedures', 'Public')
                            + 'x :: proc() -> f32 {vector: rl.Vector2; return vector.x}\n')
        self.compile(source.parent)
        self.assertNotIn('FILE002', self.lint(source))
        self.write('src/data/data.odin', 'package adapter\n' + section('Constants', 'Public') + 'VALUE :: 1\n')
        loaded = self.write('src/adapter/adapter.odin', 'package adapter_api\n'
                            + section('Imports', 'Project') + 'import data "../data"\n'
                            + section('Constants', 'Public') + 'VALUE :: data.VALUE\n')
        self.compile(loaded.parent)
        self.assertNotIn('FILE002', self.lint(loaded))

    def test_transitive_imported_namespace_preserves_compiler_required_package_name(self):
        self.write('src/support/support.odin', 'package support\n'
                   + section('Imports', 'Vendor') + 'import rl "vendor:raylib"\n'
                   + section('Procedures', 'Public')
                   + 'x :: proc() -> f32 {vector: rl.Vector2; return vector.x}\n')
        source = self.write('src/raylib/raylib.odin', 'package graphics_adapter\n'
                            + section('Imports', 'Project') + 'import bridge "../support"\n'
                            + section('Procedures', 'Public')
                            + 'x :: proc() -> f32 {return bridge.x()}\n')
        self.compile(source.parent)
        original = source.read_text()
        try:
            source.write_text(original.replace('package graphics_adapter', 'package raylib'))
            rejected = subprocess.run([os.environ.get('ODIN', 'odin'), 'check', str(source.parent),
                                       '-no-entry-point', '-thread-count:2'], capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('A package name must be unique', rejected.stderr)
        finally:
            source.write_text(original)
        self.compile(source.parent)
        self.assertNotIn('FILE002', self.lint(source))
        # A saved but unreachable consumer must not grant a namespace exception.
        support = self.root / 'src/support/support.odin'
        self.write('src/unrelated/unrelated.odin', support.read_text().replace('package support', 'package unrelated'))
        support.write_text('package support\n' + section('Procedures', 'Public')
                           + 'x :: proc() -> f32 {return 1}\n')
        self.compile(source.parent)
        self.assertIn('FILE002', self.lint(source))

    def test_conditional_import_cycle_does_not_grant_a_namespace_exception(self):
        self.write('lib/a/a_windows.odin', 'package a\nimport "../b"\nVALUE :: b.VALUE\n')
        self.write('lib/a/a_darwin.odin', 'package a\nVALUE :: 1\n')
        self.write('lib/b/b_darwin.odin', 'package b\nimport "../a"\nVALUE :: a.VALUE\n')
        self.write('lib/b/b_windows.odin', 'package b\nVALUE :: 2\n')
        source = self.write('src/raylib/raylib.odin', 'package graphics_adapter\n'
                            + section('Imports', 'Project') + 'import bridge "../../lib/a"\n'
                            + section('Procedures', 'Public')
                            + 'x :: proc() -> int {return bridge.VALUE}\n')
        # Each target has an acyclic compiler graph; saved evidence has both edges.
        self.compile(source.parent, '-target:darwin_arm64')
        self.compile(source.parent, '-target:windows_amd64')
        self.assertIn('FILE002', self.lint(source))

    def test_build_conditioned_fragments_form_one_interface_family(self):
        common = self.write('src/showcase/showcase.odin', 'package showcase\n'
                            + section('Procedures', 'Public') + 'read :: proc() -> int {return target()}\n')
        native = self.write('src/showcase/main_native.odin', '#+build !js\npackage showcase\n'
                            + section('Imports', 'Odin') + 'import "core:math"\n'
                            + section('Procedures', 'Public') + 'target :: proc() -> int {\n\ttotal := int(math.abs(f32(-1)))\n\tdata := [2]int{1, 2}\n\tfor value in data {copy := value\n\t\ttotal += copy\n\t}\n\treturn total\n}\n')
        web = self.write('src/showcase/main_web.odin', '#+build js\npackage showcase\n'
                         + section('Imports', 'Odin') + 'import "base:runtime"\n'
                         + section('Procedures', 'Public') + 'target :: proc() -> int {return size_of(runtime.Context)}\n')
        self.compile(common.parent)
        self.compile(common.parent, '-target:js_wasm32')
        findings = self.lint(common, native, web)
        self.assertNotIn('FILE003', findings)
        self.assertNotIn('FILE004', findings)
        common.unlink()
        self.compile(native.parent)
        self.compile(native.parent, '-target:js_wasm32')
        self.assertNotIn('FILE003', self.lint(native, web))

    def test_fragment_prefix_without_build_condition_stays_a_helper(self):
        common = self.write('src/sample/sample.odin', 'package sample\n')
        helper = self.write('src/sample/main_extra.odin', 'package sample\n'
                            + section('Constants', 'Public') + 'VALUE :: 1\n')
        self.compile(common.parent)
        text = self.lint(helper)
        self.assertIn('FILE004', text)
        self.assertIn('private', text)
        self.assertIn('configuration-preserving interface', text)
        helper.unlink()
        extra = self.write('src/sample/main.odin', 'package sample\n')
        self.compile(common.parent)
        self.assertIn('FILE003', self.lint(common, extra))

    def test_file_private_attributed_tests_stay_in_the_test_only_file(self):
        source = self.write('src/sample/sample.odin', 'package sample\n'
                            + section('Procedures', 'Public') + 'work :: proc() -> int {return 1}\n')
        test = self.write('src/sample/sample_test.odin', '#+test\npackage sample\n'
                          + section('Imports', 'Odin') + 'import "core:testing"\n'
                          + section('Procedures', 'Public')
                          + '@(test) check_value :: proc(t: ^testing.T) {testing.expect_value(t, work(), 1)}\n')
        self.compile(source.parent)
        self.compile(source.parent, mode='test')
        before = self.lint(source, test)
        self.assertIn('FILE004', before)
        self.assertIn('preserve test-only', before)
        test.write_text('#+private file\n' + test.read_text().replace(section('Procedures', 'Public'), section('Procedures', 'File')))
        self.compile(source.parent)
        self.compile(source.parent, mode='test')
        self.assertNotIn('FILE004', self.lint(source, test))

    def test_catalog_lookups_may_use_private_scalar_work_without_effects(self):
        source = self.write('src/catalog/catalog.odin', 'package catalog\n' + section('Constants', 'Public')
                            + 'VALUES :: [3]int{3, 0, 1}\n' + section('Procedures', 'Public')
                            + 'lookup :: proc(index: int) -> int {\n\tif index < 0 || index >= len(VALUES) {return 0}\n'
                            + '\tvalues := VALUES\n\tvalue := values[index]\n\tvalue += 1\n\treturn value-1\n}\n'
                            + 'label :: proc(index: int) -> string {if index == 1 {return "one"}; return ""}\n')
        self.compile(source.parent)
        self.assertNotIn('ARCH004', self.lint(source))

    def test_unexecuted_global_write_does_not_taint_a_pure_catalog_lookup(self):
        source = self.write('src/catalog/catalog.odin', 'package catalog\ncounter := 0\n'
                            'lookup :: proc() -> int {if false {counter = 1}; return 2}\n')
        self.compile(source.parent)
        findings = self.lint(source)
        self.assertIn('ARCH003', findings)
        self.assertNotIn('ARCH004', findings)

    def test_known_unsafe_catalog_bodies_remain_findings(self):
        cases = (
            ('', 'lookup :: proc(value: ^int) -> int {value^ += 1; return value^}\n'),
            ('import "core:fmt"\n', 'lookup :: proc() {fmt.println("outside")}\n'),
            ('', 'lookup :: proc(action: proc() -> int) -> int {return action()}\n'),
            ('', 'counter := 0\nlookup :: proc() -> int {counter += 1; return counter}\n'),
            ('', 'saved: ^int\nlookup :: proc(value: ^int) {saved = value}\n'),
            ('', 'counter := 0\nlookup :: proc() {helper()}\nhelper :: proc() {counter = 1}\n'),
        )
        for imports, body in cases:
            with self.subTest(body=body):
                source = self.write('src/catalog/catalog.odin', 'package catalog\n' + imports + body)
                self.compile(source.parent)
                findings = self.lint(source)
                self.assertEqual('ARCH004' in findings, 'return action()' not in body, findings)
        for role in ('state', 'views'):
            source = self.write(f'src/{role}/{role}.odin', f'package {role}\nlookup :: proc() -> int {{return 1}}\n')
            self.compile(source.parent)
            self.assertIn('ARCH004', self.lint(source))
