"""Compiler-backed source availability without selecting one build profile."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_cli import BINARY, PROJECT, section


class SourceAvailabilityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=PROJECT / '.work')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')
        return path

    def check(self, path, *options):
        flags = ['-no-entry-point', '-thread-count:1', '-vet', '-vet-tabs',
                 '-vet-using-param', '-vet-nil-deref', '-vet-uninitialized',
                 '-vet-atomic-access', '-strict-style', '-warnings-as-errors',
                 '-vet-packages:effects,helper,functions', '-strict-style-packages:effects,helper,functions']
        result = subprocess.run([os.environ.get('ODIN', 'odin'), 'check', str(path),
                                 *flags, *options], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def lint(self, path):
        binary = os.environ.get('ODIN_LINT_TEST_BINARY', str(BINARY))
        result = subprocess.run([binary, '--root', str(self.root), str(path)],
                                capture_output=True, text=True)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        return result.stderr

    def variants(self, first='!js', second='js', call_tags=''):
        directory = self.root / 'src/effects'
        self.write('src/effects/effects.odin', call_tags + 'package effects\n'
                   + section('Procedures', 'Public') + 'run :: proc() -> int {return selected()}\n')
        for filename, tag, value in (('native', first, 1), ('web', second, 2)):
            self.write(f'src/effects/{filename}.odin', f'#+build {tag}\n#+private\npackage effects\n'
                       + section('Procedures', 'Package')
                       + f'selected :: proc() -> int {{return {value}}}\n')
        return directory

    def test_complementary_file_tags_resolve_all_targets(self):
        directory = self.variants()
        self.check(directory)
        self.check(directory, '-target:js_wasm32')
        self.assertNotIn('LINT003:', self.lint(directory))

    def test_disjoint_target_sets_cover_only_the_callers_build_set(self):
        directory = self.variants('darwin', 'windows', '#+build darwin, windows\n')
        self.check(directory, '-target:darwin_arm64')
        self.check(directory, '-target:windows_amd64')
        self.assertNotIn('LINT003:', self.lint(directory))

    def test_incomplete_file_tag_coverage_stays_uncertain(self):
        directory = self.variants('darwin', 'windows')
        self.check(directory, '-target:darwin_arm64')
        self.assertNotIn('LINT003:', self.lint(directory))

    def test_overlapping_file_tags_stay_uncertain(self):
        directory = self.variants('darwin', 'darwin, windows')
        # This saved graph is valid for Windows, but overlaps on Darwin. No
        # configuration proof may silently certify its combined identities.
        self.check(directory, '-target:windows_amd64')
        self.assertNotIn('LINT003:', self.lint(directory))

    def test_same_when_predicate_and_alias_resolve_conditional_calls(self):
        directory = self.root / 'src/effects'
        self.write('src/effects/effects.odin', 'package effects\n'
                   'FEATURE :: #config(FEATURE, false)\nALIAS :: FEATURE\n'
                   'when FEATURE {selected :: proc() -> int {return 1}}\n'
                   'run :: proc() -> int {when ALIAS {return selected()} else {return 0}}\n')
        self.check(directory, '-define:FEATURE=true')
        self.check(directory, '-define:FEATURE=false')
        self.assertNotIn('LINT003:', self.lint(directory))

    def test_negated_stable_alias_keeps_predicate_polarity(self):
        directory = self.root / 'src/effects'
        self.write('src/effects/effects.odin', 'package effects\n'
                   'FEATURE :: #config(FEATURE, false)\nOFF :: !FEATURE\n'
                   'when OFF {selected :: proc() -> int {return 1}}\n'
                   'run :: proc() -> int {when !FEATURE {return selected()} else {return 0}}\n')
        self.check(directory, '-define:FEATURE=true')
        self.check(directory, '-define:FEATURE=false')
        self.assertNotIn('LINT003:', self.lint(directory))

    def test_negated_alias_does_not_certify_an_unrelated_guard(self):
        directory = self.root / 'src/effects'
        self.write('src/effects/effects.odin', 'package effects\n'
                   'FEATURE :: #config(FEATURE, false)\nOFF :: !FEATURE\n'
                   'OTHER :: #config(OTHER, false)\n'
                   'when OFF {selected :: proc() -> int {return 1}}\n'
                   'run :: proc() -> int {when OTHER {return selected()} else {return 0}}\n')
        self.check(directory, '-define:FEATURE=false', '-define:OTHER=true')
        self.check(directory, '-define:FEATURE=true', '-define:OTHER=false')
        self.assertNotIn('LINT003:', self.lint(directory))

    def test_exhaustive_when_alternatives_resolve_without_a_profile(self):
        directory = self.root / 'src/effects'
        self.write('src/effects/effects.odin', 'package effects\n'
                   'FEATURE :: #config(FEATURE, false)\n'
                   'when FEATURE {selected :: proc() -> int {return 1}} '
                   'else {selected :: proc() -> int {return 2}}\n'
                   'run :: proc() -> int {return selected()}\n')
        self.check(directory, '-define:FEATURE=true')
        self.check(directory, '-define:FEATURE=false')
        self.assertNotIn('LINT003:', self.lint(directory))

    def test_conditional_without_a_matching_use_guard_stays_uncertain(self):
        directory = self.root / 'src/effects'
        self.write('src/effects/effects.odin', 'package effects\n'
                   'FEATURE :: #config(FEATURE, false)\n'
                   'when FEATURE {selected :: proc() -> int {return 1}}\n'
                   'run :: proc() -> int {return selected()}\n')
        self.check(directory, '-define:FEATURE=true')
        self.assertNotIn('LINT003:', self.lint(directory))

    def test_unrelated_boolean_bindings_do_not_prove_each_other(self):
        self.write('lib/helper/helper.odin', 'package helper\n'
                   'FEATURE :: #config(HELPER_FEATURE, false)\n'
                   'when FEATURE {selected :: proc() -> int {return 1}}\n')
        directory = self.root / 'src/effects'
        self.write('src/effects/effects.odin', 'package effects\nimport "../../lib/helper"\n'
                   'FEATURE :: #config(CALLER_FEATURE, false)\n'
                   'selected_alias :: helper.selected\n'
                   'run :: proc() -> int {when FEATURE {return selected_alias()} else {return 0}}\n')
        self.check(directory, '-define:HELPER_FEATURE=true', '-define:CALLER_FEATURE=true')
        self.assertNotIn('LINT003:', self.lint(directory))

    def test_alternative_targets_keep_the_union_of_forbidden_effects(self):
        directory = self.root / 'src/functions'
        self.write('src/functions/functions.odin', 'package functions\n'
                   'run :: proc() {selected()}\n')
        self.write('src/functions/native.odin', '#+build !js\npackage functions\n'
                   'import "core:os"\n'
                   'selected :: proc() {_ = os.get_env("ODIN_LINT_TEST", context.allocator)}\n')
        self.write('src/functions/web.odin', '#+build js\npackage functions\n'
                   'selected :: proc() {}\n')
        self.check(directory)
        self.check(directory, '-target:js_wasm32')
        text = self.lint(directory)
        self.assertNotIn('LINT003:', text)
        self.assertIn('ARCH002:', text)

    def test_file_tag_proves_matching_foreign_when_guard(self):
        directory = self.root / 'src/effects'
        self.write('src/effects/effects.odin', 'package effects\n'
                   'when ODIN_OS == .JS {foreign import browser "env"\n'
                   'foreign browser {save :: proc "c" () -> i32 ---}}\n')
        self.write('src/effects/web.odin', '#+build js\npackage effects\n'
                   'run :: proc() -> i32 {return save()}\n')
        self.check(directory)
        self.check(directory, '-target:js_wasm32')
        self.assertNotIn('LINT003:', self.lint(directory))


if __name__ == '__main__':
    unittest.main()
