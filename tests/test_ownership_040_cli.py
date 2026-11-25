"""Compiler-backed caller capabilities, result guards and transaction outcomes."""

import os
import subprocess
import unittest

from test_cli import BINARY
import test_semantics_cli as semantic


class Ownership040Tests(unittest.TestCase):
    setUp = semantic.SemanticTests.setUp
    write = semantic.SemanticTests.write

    def inspect(self, source, *selected):
        checked = subprocess.run([os.environ.get('ODIN', 'odin'), 'check', str(source.parent),
                                  '-no-entry-point', '-thread-count:2', '-vet', '-vet-tabs',
                                  '-vet-using-param', '-vet-nil-deref', '-vet-uninitialized',
                                  '-vet-atomic-access', '-strict-style', '-warnings-as-errors',
                                  '-vet-packages:state,engine,procedures,functions,effects,ui,catalog'],
                                 capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        result = subprocess.run([str(BINARY), '--root', str(self.root), str(source), *map(str, selected)],
                                capture_output=True, text=True)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        return result.stderr

    def transaction(self, condition='!engine.begin(owner)', begin_return='true', tail='assert(engine.finish(owner))'):
        self.write('engine', 'Owner :: struct {rows: map[int]int, transaction: Transaction}\n'
                   'Transaction :: struct {depth: int, failed: bool}\n'
                   'begin :: proc(owner: ^Owner) -> bool {tx := &owner.transaction; '
                   'if tx.failed {return false}; tx.depth += 1; return ' + begin_return + '}\n'
                   'finish :: proc(owner: ^Owner) -> bool {owner.transaction.depth -= 1; return true}\n'
                   'update :: proc(owner: ^Owner) {owner.rows[1] = 2}\n'
                   'destroy :: proc(owner: ^Owner) {delete(owner.rows); owner^ = {}}\n')
        return self.write('procedures', 'run :: proc(owner: ^engine.Owner, valid: bool) {_ = valid; '
                          'if ' + condition + ' {return}; engine.update(owner)\n' + tail + '}\n',
                          'import "../engine"\n')

    def test_short_circuit_scope_guards_preserve_actual_outcomes(self):
        for condition in ('!engine.begin(owner)', '!valid || !engine.begin(owner)',
                          '!(valid && engine.begin(owner))'):
            with self.subTest(condition=condition):
                self.assertNotIn('OWN002:', self.inspect(self.transaction(condition)))

    def test_false_after_open_and_missing_finish_remain_findings(self):
        self.assertIn('OWN002:', self.inspect(self.transaction(begin_return='false')))
        self.assertIn('OWN002:', self.inspect(self.transaction(tail='')))

    def test_callback_scopes_keep_missing_finish_and_wrong_owner_controls(self):
        for body, invalid in (
                ('invoke(enter, owner); owner.rows[1] = 2; invoke(leave, owner)', False),
                ('invoke(enter, owner); owner.rows[1] = 2', True),
                ('invoke(enter, owner); other.rows[1] = 2; invoke(leave, owner)', True)):
            with self.subTest(body=body):
                source = self.write('engine', 'Owner :: struct {rows: map[int]int, depth: int}\n'
                                    'closed :: proc(owner, other: ^Owner) {_ = other; ' + body + '}\n'
                                    '@(private="file") enter :: proc(owner: ^Owner) {owner.depth += 1}\n'
                                    '@(private="file") leave :: proc(owner: ^Owner) {owner.depth -= 1}\n'
                                    '@(private="file") invoke :: proc(action: proc(^Owner), owner: ^Owner) {action(owner)}\n')
                caller = self.write('application', 'owner, other: engine.Owner\n'
                                    'run :: proc() {engine.closed(&owner, &other)}\n', 'import "../engine"\n')
                self.assertEqual('OWN002:' in self.inspect(caller, source), invalid)

    def test_boolean_forwarders_and_stable_aliases_preserve_scope_outcomes(self):
        for body, named in (
                ('return begin(owner)', False),
                ('result := begin(owner); return result', False),
                ('result := begin(owner); alias := result; return alias', False),
                ('result := begin(owner); value := 1; value = 0; _ = value; return result', False),
                ('result := !begin(owner); return !result', False),
                ('action := begin; result := action(owner); return result', False),
                ('result = begin(owner); return', True)):
            with self.subTest(body=body):
                source = self.transaction(condition='!engine.open(owner)')
                engine = self.root / 'src/engine/engine.odin'
                result = '(result: bool)' if named else 'bool'
                engine.write_text(engine.read_text() + 'open :: proc(owner: ^Owner) -> ' + result +
                                  ' {' + body + '}\n')
                self.assertNotIn('OWN002:', self.inspect(source))

    def test_forwarded_false_outcomes_keep_real_counter_effects(self):
        for body in ('result := begin(owner); result = false; return result',
                     'result := begin(owner); defer owner.transaction.depth += 1; return result',
                     'return begin(owner)'):
            with self.subTest(body=body):
                source = self.transaction(condition='!engine.open(owner)')
                engine = self.root / 'src/engine/engine.odin'
                text = engine.read_text()
                if body == 'return begin(owner)':
                    text = text.replace('tx.depth += 1; return true', 'tx.depth += 1; return false')
                engine.write_text(text + 'open :: proc(owner: ^Owner) -> bool {' + body + '}\n')
                self.assertIn('OWN002:', self.inspect(source))

    def test_saved_boolean_conditions_keep_scope_guards(self):
        for guard in ('!entered', 'failed'):
            with self.subTest(guard=guard):
                source = self.transaction()
                source.write_text(source.read_text().replace(
                    'if !engine.begin(owner)',
                    'entered := engine.begin(owner); failed := !entered; _ = failed; if ' + guard))
                self.assertNotIn('OWN002:', self.inspect(source))

    def test_saved_boolean_guards_do_not_hide_changed_scopes_or_wrong_owner(self):
        for body in ('entered := engine.begin(owner); engine.finish(owner); '
                     'if !entered {return}; engine.update(owner)',
                     'entered := engine.begin(owner); entered = false; '
                     'if !entered {return}; engine.finish(owner)',
                     'entered := engine.begin(owner); if !entered {return}; '
                     'engine.update(other); engine.finish(owner)'):
            with self.subTest(body=body):
                self.transaction()
                source = self.write('procedures', 'run :: proc(owner, other: ^engine.Owner) {_ = other; ' + body + '}\n',
                                    'import "../engine"\n')
                caller = self.write('application', 'owner, other: engine.Owner\n'
                                    'run :: proc() {procedures.run(&owner, &other)}\n',
                                    'import "../engine"\nimport "../procedures"\n')
                self.assertIn('OWN002:', self.inspect(caller, source))

    def test_saved_guard_survives_independent_completed_owner_scope(self):
        for finish, invalid in (('engine.finish(other); ', False), ('', True)):
            with self.subTest(finish=finish):
                self.transaction()
                source = self.write('procedures',
                                    'run :: proc(owner, other: ^engine.Owner) {'
                                    'entered := engine.begin(owner); engine.begin(other); ' + finish +
                                    'if !entered {return}; engine.update(owner); engine.finish(owner)}\n',
                                    'import "../engine"\n')
                self.assertEqual('OWN002:' in self.inspect(source), invalid)

    def test_nested_boolean_join_discards_disagreeing_branch_proofs(self):
        self.transaction()
        source = self.write('procedures', 'Guard :: struct {entered: bool}\n'
                            'run :: proc(owner: ^engine.Owner, invert: bool) {'
                            'entered := engine.begin(owner); box := Guard{entered = !entered}; '
                            'if invert {box.entered = entered}; '
                            'if !box.entered {return}; engine.finish(owner)}\n',
                            'import "../engine"\n')
        self.assertIn('OWN002:', self.inspect(source))

    def test_boolean_outcomes_keep_counter_effects_in_call_arguments(self):
        source = self.transaction(condition='!engine.begin(engine.select(owner, other))')
        source.write_text(source.read_text().replace('valid: bool)', 'valid: bool, other: ^engine.Owner)'))
        engine = self.root / 'src/engine/engine.odin'
        engine.write_text(engine.read_text() + 'select :: proc(owner, other: ^Owner) -> ^Owner '
                          '{other.transaction.depth += 1; return owner}\n')
        self.assertIn('OWN002:', self.inspect(source))

    def test_direct_callback_joins_preserve_known_and_unknown_effects(self):
        for alternative, expected in (('known', None),
                                      ('cast(proc())rawptr(uintptr(1))', None),
                                      ('noisy', 'ARCH007:')):
            with self.subTest(alternative=alternative):
                source = self.write('functions', 'known :: proc() {}\n'
                                    'noisy :: proc() {fmt.println(1)}\n'
                                    'run :: proc(flag: bool) {chosen := known; if flag {chosen = ' +
                                    alternative + '}; chosen()}\n', 'import "core:fmt"\n')
                text = self.inspect(source)
                if expected:
                    self.assertIn(expected, text)
                else:
                    self.assertNotIn('LINT004:', text)
                    # The unused noisy declaration is effectful but the pure call is not.
                    self.assertFalse(any('ARCH007:' in line and '(5:' in line for line in text.splitlines()))

    def test_direct_callback_join_keeps_symbolic_actual_effects(self):
        source = self.write('functions', 'known :: proc() {}\n'
                            'run :: proc(action: proc(), flag: bool) {chosen := known; '
                            'if flag {chosen = action}; chosen()}\n')
        caller = self.write('functions/consumer', 'noisy :: proc() {fmt.println(1)}\n'
                            'run :: proc() {functions.run(noisy, true)}\n',
                            'import functions ".."\nimport "core:fmt"\n')
        self.assertIn('ARCH007:', self.inspect(caller, source))

    def test_symbolic_callback_outcomes_do_not_erase_actual_open_scopes(self):
        source = self.transaction(condition='!engine.invoke(engine.begin, owner)', begin_return='false')
        engine = self.root / 'src/engine/engine.odin'
        engine.write_text(engine.read_text() + 'invoke :: proc(action: proc(^Owner) -> bool, '
                          'owner: ^Owner) -> bool {return action(owner)}\n')
        self.assertIn('OWN002:', self.inspect(source))

    def test_terminal_owner_reset_closes_scope(self):
        self.assertNotIn('OWN002:', self.inspect(self.transaction(tail='engine.destroy(owner)')))

    def test_reset_before_begin_does_not_hide_new_scope(self):
        source = self.transaction(tail='')
        engine = self.root / 'src/engine/engine.odin'
        text = engine.read_text().replace('tx.depth += 1', 'tx.depth = 0; tx.depth += 1')
        engine.write_text(text)
        self.assertIn('OWN002:', self.inspect(source))


    def test_nested_private_heap_and_stack_work_do_not_gain_borrowed_requirements(self):
        self.write('state', 'Store :: struct {values: [2]int}\n')
        self.write('engine', 'Work :: struct {facts: state.Store}\n', 'import "../state"\n')
        for allocated in ('working: engine.Work; change(&working)',
                          'working := new(engine.Work); defer free(working); change(working)'):
            with self.subTest(allocated=allocated):
                source = self.write('procedures', 'run :: proc() {' + allocated + '}\n'
                                    'change :: proc(work: ^engine.Work) {work.facts.values[0] = 1}\n',
                                    'import "../engine"\n')
                self.assertNotIn('OWN001:', self.inspect(source))
        source = self.write('procedures', 'published: engine.Work\n'
                            'run :: proc() {change(&published)}\n'
                            'change :: proc(work: ^engine.Work) {work.facts.values[0] = 1}\n',
                            'import "../engine"\n')
        self.assertIn('OWN001:', self.inspect(source))

    def test_local_link_slot_is_distinct_from_meaningful_referent(self):
        self.write('engine', 'Owner :: struct {rows: map[int]int}\n'
                   'Local :: struct {rows: map[int]int, meaningful: ^Owner, depth: int}\n'
                   'enter :: proc(local: ^Local, owner: ^Owner = nil) {local.meaningful = owner; local.depth += 1}\n'
                   'leave :: proc(local: ^Local) {local.depth -= 1}\n'
                   'update :: proc(owner: ^Owner) {owner.rows[1] = 2}\n')
        source = self.write('ui', 'run :: proc(local: ^engine.Local) {engine.enter(local); engine.leave(local)}\n',
                            'import "../engine"\n')
        caller = self.write('application', 'local: engine.Local\nrun :: proc() {ui.run(&local)}\n',
                            'import "../ui"\nimport "../engine"\n')
        self.assertNotIn('OWN002:', self.inspect(caller, source))
        source = self.write('ui', 'run :: proc(local: ^engine.Local) {engine.update(local.meaningful)}\n',
                            'import "../engine"\n')
        self.assertIn('OWN002:', self.inspect(caller, source))


    def test_fresh_catalog_work_is_writable_but_published_catalog_is_not(self):
        self.write('catalog', 'Catalog :: struct {values: [2]int}\n')
        source = self.write('functions', 'prepare :: proc(data: ^catalog.Catalog) {data.values[0] = 1}\n'
                            'run :: proc() {data := new(catalog.Catalog); defer free(data); prepare(data)}\n',
                            'import "../catalog"\n')
        self.assertNotIn('OWN001:', self.inspect(source))
        source = self.write('functions', 'published: catalog.Catalog\n'
                            'prepare :: proc(data: ^catalog.Catalog) {data.values[0] = 1}\n'
                            'run :: proc() {prepare(&published)}\n', 'import "../catalog"\n')
        self.assertIn('OWN001:', self.inspect(source))


    def test_by_value_slots_are_private_while_reference_children_keep_borrows(self):
        self.write('state', 'Row :: struct {value: int}\n'
                   'Store :: struct {value: int, values: [2]int, rows: map[int]Row, refs: [2]^Row}\n')
        for body, invalid in (('value.value = 1; value.values[0] = 2', False),
                              ('value.rows[1] = {}', True), ('value.refs[0].value = 2', True)):
            with self.subTest(body=body):
                source = self.write('functions', 'change :: proc(data: state.Store) {value := data; ' + body + '}\n',
                                    'import "../state"\n')
                caller = self.write('application', 'live: state.Store\nrun :: proc() {functions.change(live)}\n',
                                    'import "../functions"\nimport "../state"\n')
                self.assertEqual('OWN001:' in self.inspect(caller, source), invalid)
