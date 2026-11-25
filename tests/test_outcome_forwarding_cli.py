"""Compiler-backed outcome correlation across generic callback boundaries."""

import unittest

import test_ownership_040_cli as ownership


class OutcomeForwardingTests(unittest.TestCase):
    setUp = ownership.Ownership040Tests.setUp
    write = ownership.Ownership040Tests.write
    inspect = ownership.Ownership040Tests.inspect

    def program(self, body, *, condition='!engine.invoke(engine.begin, owner, other)',
                false_after_open=False, tail='engine.update(owner); engine.finish(owner)',
                extra=''):
        result = 'false' if false_after_open else 'true'
        self.write('engine',
                   'Owner :: struct {rows: map[int]int, depth: int, failed: bool}\n'
                   'begin :: proc(owner: ^Owner) -> bool {if owner.failed {return false}; '
                   'owner.depth += 1; return ' + result + '}\n'
                   'finish :: proc(owner: ^Owner) {owner.depth -= 1}\n'
                   'update :: proc(owner: ^Owner) {owner.rows[1] = 2}\n'
                   'invoke :: proc(action: proc(^Owner)->bool, owner, other: ^Owner) -> bool '
                   '{_ = other; ' + body + '}\n' + extra)
        return self.write('procedures',
                          'run :: proc(owner, other: ^engine.Owner) {'
                          'if ' + condition + ' {return}; ' + tail + '}\n',
                          'import "../engine"\n')

    def inspect_saved(self, source):
        caller = self.write('application',
                            'owner, other: engine.Owner\n'
                            'run :: proc() {procedures.run(&owner, &other)}\n',
                            'import "../engine"\nimport "../procedures"\n')
        return self.inspect(caller, source)

    def test_generic_result_shapes_preserve_both_outcomes(self):
        shapes = (
            ('return action(owner)', '!engine.invoke(engine.begin, owner, other)'),
            ('out := action(owner); return out', '!engine.invoke(engine.begin, owner, other)'),
            ('out := action(owner); alias := out; return alias', '!engine.invoke(engine.begin, owner, other)'),
            ('return !action(owner)', 'engine.invoke(engine.begin, owner, other)'),
            ('return action(owner)', '!engine.invoke(other=other, owner=owner, action=engine.begin)'),
        )
        for body, condition in shapes:
            for invalid in (False, True):
                with self.subTest(body=body, condition=condition, false_after_open=invalid):
                    source = self.program(body, condition=condition, false_after_open=invalid)
                    self.assertEqual('OWN002:' in self.inspect(source), invalid)

    def test_nested_generic_forwarder_preserves_predicate_identity(self):
        for invalid in (False, True):
            with self.subTest(false_after_open=invalid):
                source = self.program('return pass(action, owner)', false_after_open=invalid,
                                      extra='pass :: proc(action: proc(^Owner)->bool, owner: ^Owner) '
                                            '-> bool {return action(owner)}\n')
                self.assertEqual('OWN002:' in self.inspect(source), invalid)

    def test_independent_completed_scopes_do_not_erase_the_predicate(self):
        for body in ('begin(other); finish(other); return action(owner)',
                     'out := action(owner); begin(other); finish(other); return out'):
            for invalid in (False, True):
                with self.subTest(body=body, false_after_open=invalid):
                    source = self.program(body, false_after_open=invalid)
                    self.assertEqual('OWN002:' in self.inspect(source), invalid)

    def test_unfinished_other_scope_is_not_erased_by_a_false_predicate(self):
        source = self.program('begin(other); return action(owner)')
        self.assertIn('OWN002:', self.inspect(source))

    def test_finished_same_owner_does_not_reopen_from_the_old_predicate(self):
        source = self.program('out := action(owner); if out {finish(owner)}; return out')
        self.assertIn('OWN002:', self.inspect_saved(source))

    def test_callback_guard_does_not_authorize_another_owner(self):
        source = self.program('return action(owner)',
                              condition='!engine.invoke(engine.begin, other, owner)',
                              tail='engine.update(owner); engine.finish(other)')
        self.assertIn('OWN002:', self.inspect_saved(source))

    def test_nonreturned_callback_cannot_be_treated_as_the_false_predicate(self):
        for body in ('action(owner); return false', 'out := action(owner); _ = out; return false'):
            with self.subTest(body=body):
                source = self.program(body)
                self.assertIn('OWN002:', self.inspect(source))

    def test_conditionally_inverted_alias_does_not_keep_one_branch_proof(self):
        self.program('return action(owner)')
        source = self.write('procedures',
                            'run :: proc(owner, other: ^engine.Owner, invert: bool) {'
                            'entered := engine.begin(owner); guard := entered; '
                            'if invert {guard = !entered}; '
                            'if !guard {return}; engine.update(owner); engine.finish(owner); _ = other}\n',
                            'import "../engine"\n')
        self.assertIn('OWN002:', self.inspect(source))


if __name__ == '__main__':
    unittest.main()
