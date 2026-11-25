"""Callback inference through procedure dependencies and record fields."""

import re
import unittest

import test_ownership_052_cli as fixture


class InferenceTests(unittest.TestCase):
    setUp = fixture.Ownership052Tests.setUp
    write = fixture.Ownership052Tests.write
    check = fixture.Ownership052Tests.check
    lint = fixture.Ownership052Tests.lint

    def test_when_defers_observe_the_enclosing_scopes_final_bindings(self):
        for wrapper in ("DEFER", "when true {DEFER}",
                        "when ODIN_OS == .Darwin {DEFER} else {DEFER}"):
            for callback in ("quiet", "noisy"):
                with self.subTest(wrapper=wrapper, callback=callback):
                    source = self.write("functions", "run :: proc() {\ncallback := noisy\n"
                                        + wrapper.replace("DEFER", "defer callback()")
                                        + "\ncallback = " + callback + "\n}\n"
                                        "quiet :: proc() {}\nnoisy :: proc() {fmt.println(1)}\n",
                                        'import "core:fmt"\n')
                    self.check(source.parent)
                    findings = self.lint(source)
                    for line, text in enumerate(source.read_text().splitlines(), 1):
                        if "defer callback()" in text:
                            found = re.search(re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:", findings)
                            self.assertEqual(found is not None, callback == "noisy", findings)

    def test_when_defers_finish_transactions_at_the_enclosing_scope_exit(self):
        self.write("engine", "Owner :: struct {rows: map[int]int, depth: int}\n"
                   "enter :: proc(owner: ^Owner) {owner.depth += 1}\n"
                   "leave :: proc(owner: ^Owner) {owner.depth -= 1}\n"
                   "put :: proc(owner: ^Owner) {assert(owner.depth == 1); owner.rows[1] = 42}\n")
        for wrapper in ("BODY", "when true {BODY}",
                        "when ODIN_OS == .Darwin {BODY} else {BODY}",
                        "when ODIN_OS == .Darwin {when true {BODY}} else {BODY}"):
            with self.subTest(wrapper=wrapper):
                source = self.write("procedures", "run :: proc(owner: ^engine.Owner) {\n"
                                    + wrapper.replace("BODY", "engine.enter(owner)\ndefer engine.leave(owner)")
                                    + "\nengine.put(owner)\n}\n", 'import "../engine"\n')
                caller = self.write("application", "live: engine.Owner\n"
                                    "run :: proc() {procedures.run(&live)}\n",
                                    'import "../engine"\nimport "../procedures"\n')
                main = self.root / "main/main.odin"
                main.parent.mkdir(exist_ok=True)
                main.write_text('package main\nimport "../src/application"\n'
                                'main :: proc() {\napplication.live.rows = make(map[int]int)\n'
                                'defer delete(application.live.rows)\napplication.run()\n'
                                'assert(application.live.rows[1] == 42)\nassert(application.live.depth == 0)\n}\n')
                self.check(main.parent, entry=True, run=True)
                self.assertNotIn("OWN002:", self.lint(source, caller))

    def test_conditional_defers_keep_their_branches_transaction_state(self):
        self.write("engine", "Owner :: struct {depth: int}\n"
                   "enter :: proc(owner: ^Owner) {owner.depth += 1}\n"
                   "leave :: proc(owner: ^Owner) {owner.depth -= 1}\n")
        bodies = (
            "when FLAG {engine.enter(owner); defer engine.leave(owner)}",
            "when FLAG {engine.enter(owner); defer engine.leave(owner)} else {}",
            "when FLAG {engine.enter(owner); defer engine.leave(owner)} else {engine.enter(other); defer engine.leave(other)}",
            "when FLAG {when OTHER {engine.enter(owner); defer engine.leave(owner)}}",
            "when FLAG {engine.enter(owner); defer engine.leave(owner)}\nreturn",
            "when true {engine.enter(owner); defer engine.leave(owner); return}",
            "when FLAG {defer engine.leave(owner)} else {defer engine.leave(owner)}\nengine.enter(owner)",
            "when FLAG {engine.enter(owner)}\nwhen FLAG {defer engine.leave(owner)}",
            "when FLAG {engine.enter(owner)} else {engine.enter(other)}\nwhen !FLAG {defer engine.leave(other)} else {defer engine.leave(owner)}",
            "when FLAG {engine.enter(owner)}\nwhen !INVERSE {defer engine.leave(owner)}",
            "when FLAG {engine.enter(owner)}",
        )
        for body in bodies:
            for flag in ("true", "false"):
                with self.subTest(body=body, flag=flag):
                    unclosed = body == bodies[-1]
                    source = self.write("procedures", 'FLAG :: #config(FLAG, ' + flag + ')\n'
                                        'OTHER :: #config(OTHER, true)\n'
                                        'INVERSE :: !FLAG\n'
                                        'run :: proc(owner, other: ^engine.Owner) {\n_ = other\n'
                                        + body + '\n}\n', 'import "../engine"\n')
                    caller = self.write("application", 'left, right: engine.Owner\n'
                                        'run :: proc() {procedures.run(&left, &right)}\n',
                                        'import "../engine"\nimport "../procedures"\n')
                    main = self.root / "main/main.odin"
                    main.parent.mkdir(exist_ok=True)
                    expected = int(unclosed and flag == "true")
                    main.write_text('package main\nimport "../src/application"\n'
                                    'main :: proc() {application.run(); assert(application.left.depth == '
                                    + str(expected) + ' && application.right.depth == 0)}\n')
                    self.check(main.parent, entry=True, run=True)
                    self.assertEqual("OWN002:" in self.lint(source, caller), unclosed)

    def test_returned_loop_and_switch_paths_do_not_reuse_cleanup(self):
        self.write("engine", "Owner :: struct {depth: int}\n"
                   "enter :: proc(owner: ^Owner) {owner.depth += 1}\n"
                   "leave :: proc(owner: ^Owner) {owner.depth -= 1}\n")
        for body in (
            "for choose {engine.enter(owner); defer engine.leave(owner); return}\nengine.enter(owner)",
            "switch choose {\ncase true: {engine.enter(owner); defer engine.leave(owner); return}\ncase false: engine.enter(owner)\n}",
            "switch choose {\ncase true: engine.enter(owner); defer engine.leave(owner); return\ncase false: engine.enter(owner)\n}",
        ):
            with self.subTest(body=body):
                source = self.write("procedures", "run :: proc(owner: ^engine.Owner, choose: bool) {\n"
                                    + body + "\n}\n", 'import "../engine"\n')
                caller = self.write("application", "live: engine.Owner\n"
                                    "run :: proc(choose: bool) {procedures.run(&live, choose)}\n",
                                    'import "../engine"\nimport "../procedures"\n')
                main = self.root / "main/main.odin"
                main.parent.mkdir(exist_ok=True)
                main.write_text('package main\nimport "../src/application"\n'
                                'main :: proc() {application.run(true); assert(application.live.depth == 0); '
                                'application.run(false); assert(application.live.depth == 1)}\n')
                self.check(main.parent, entry=True, run=True)
                self.assertIn("OWN002:", self.lint(source, caller))

    def test_loop_and_switch_guards_do_not_hide_other_paths_effects(self):
        for body in (
            'for choose {\nwhen FLAG {return}\nbreak\n}\nwhen FLAG {fmt.println("hit")}',
            'switch choose {\ncase true:\nwhen FLAG {return}\ncase false:\nwhen FLAG {fmt.println("hit")}\n}',
            '_ = choose\nwhen FLAG {fmt.println("hit")}',
        ):
            with self.subTest(body=body):
                source = self.write("functions", 'FLAG :: #config(FLAG, true)\n'
                                    'run :: proc(choose: bool) {\n' + body + '\n}\n',
                                    'import "core:fmt"\n')
                main = self.root / "main/main.odin"
                main.parent.mkdir(exist_ok=True)
                main.write_text('package main\nimport "../src/functions"\nmain :: proc() {functions.run(false)}\n')
                self.check(main.parent, entry=True, run=True)
                line = source.read_text().splitlines().index('when FLAG {fmt.println("hit")}') + 1
                self.assertRegex(self.lint(source), re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:")

    def test_pruned_return_paths_retain_analyzer_context(self):
        source = self.write("functions", 'FLAG :: #config(FLAG, true)\n'
                            'run :: proc(choose: bool) {\nwhen FLAG {\nfor choose {\n'
                            'when FLAG {return}\nbreak\n}\n}\n}\n')
        main = self.root / "main/main.odin"
        main.parent.mkdir(exist_ok=True)
        main.write_text('package main\nimport "../src/functions"\n'
                        'main :: proc() {functions.run(false); functions.run(true)}\n')
        self.check(main.parent, entry=True, run=True)
        self.assertNotIn("OWN002:", self.lint(source))

    def test_mixed_global_returns_preserve_concrete_storage(self):
        self.write("engine", "Owner :: struct {rows: map[int]int}\n")
        self.write("catalog", "Catalog :: struct {rows: map[int]int}\n")
        for role, type_name in (("engine", "Owner"), ("catalog", "Catalog")):
            for body, actual, protected in (
                ("return &live", "&local", True),
                ("if choose {return &live}; return local", "&local", True),
                ("if !choose {return local}; return &live", "&local", True),
                ("return local", "&local", False),
                ("return local", "&effects.live", True),
            ):
                with self.subTest(role=role, body=body, actual=actual):
                    self.write("effects", "live: " + role + "." + type_name + "\n"
                               "pick :: proc(local: ^" + role + "." + type_name + ", choose: bool) -> ^"
                               + role + "." + type_name + " {" + body + "}\n"
                               "forward :: proc(local: ^" + role + "." + type_name + ", choose: bool) -> ^"
                               + role + "." + type_name + " {return pick(local, choose)}\n",
                               'import "../' + role + '"\n')
                    source = self.write("application", "run :: proc() {\n"
                                        "local := " + role + "." + type_name + "{rows = make(map[int]int)}\n"
                                        "defer delete(local.rows)\n"
                                        "selected := effects.forward(" + actual + ", true)\n"
                                        "selected.rows[1] = 42\n}\n",
                                        'import "../effects"\nimport "../' + role + '"\n')
                    main = self.root / "main/main.odin"
                    main.parent.mkdir(exist_ok=True)
                    main.write_text('package main\nimport "../src/effects"\nimport "../src/application"\n'
                                    'main :: proc() {\neffects.live.rows = make(map[int]int)\n'
                                    'defer delete(effects.live.rows)\napplication.run()\n'
                                    + 'assert(effects.live.rows[1] == ' + ('42' if protected else '0') + ')\n}\n')
                    self.check(main.parent, entry=True, run=True)
                    findings = self.lint(source)
                    line = source.read_text().splitlines().index("selected.rows[1] = 42") + 1
                    found = re.search(re.escape(str(source)) + rf"\({line}:\d+\): OWN001:", findings)
                    self.assertEqual(found is not None, protected, findings)
                    self.assertEqual(findings.count("OWN001:"), int(protected), findings)

    def test_contextual_nested_literals_retain_callback_slots(self):
        for initializer in (
            "pair := Pair{Leaf{quiet}, Leaf{CALLBACK}}",
            "pair := Pair{{quiet}, {CALLBACK}}",
            "pair: Pair = {{quiet}, {CALLBACK}}",
            "pair := Pair{left={quiet}, right={CALLBACK}}",
            "pair := Pair{{quiet}, ({CALLBACK} if choose else {quiet})}",
            "pair := Pair{{quiet}, ({CALLBACK} when FLAG else {quiet})}",
            "pair := Pair{{quiet}, ({CALLBACK} when true else {quiet})}",
            "pair := Pair{{quiet}, (({CALLBACK} if choose else {quiet}) when FLAG else {quiet})}",
        ):
            for callback in ("noisy", "quiet", "unknown"):
                with self.subTest(initializer=initializer, callback=callback):
                    source = self.write("functions", "FLAG :: #config(FLAG, true)\n"
                                        "Pair :: struct {left, right: Leaf}\n"
                                        "Leaf :: struct {callback: proc()}\n"
                                        "run :: proc(unknown: proc(), choose: bool) {\n_ = unknown\n_ = choose\n"
                                        + initializer.replace("CALLBACK", callback) + "\n"
                                        "pair.left.callback()\npair.right.callback()\n}\n"
                                        "quiet :: proc() {}\nnoisy :: proc() {fmt.println(1)}\n",
                                        'import "core:fmt"\n')
                    self.check(source.parent)
                    findings = self.lint(source)
                    for member in ("left", "right"):
                        line = source.read_text().splitlines().index("pair." + member + ".callback()") + 1
                        found = re.search(re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:", findings)
                        self.assertEqual(found is not None, member == "right" and callback == "noisy", findings)

    def test_known_factory_alternatives_join_returned_callbacks(self):
        for factory in ("first", "first if choose else second", "conditional", "opaque", "first if choose else opaque"):
            for first_return, second_return, actual in (
                ("noisy", "quiet", "unknown"), ("quiet", "noisy", "unknown"),
                ("quiet", "quiet", "unknown"), ("unknown", "quiet", "unknown"),
                ("unknown", "noisy", "unknown"), ("unknown", "quiet", "noisy"),
            ):
                with self.subTest(factory=factory, first=first_return, second=second_return, actual=actual):
                    source = self.write("functions", "run :: proc(choose: bool, unknown: proc(), opaque: proc(proc()) -> proc()) {\n"
                                        "_ = choose\n_ = opaque\n_ = unknown\nfactory := " + factory + "\n"
                                        "callback := factory(" + actual + ")\ncallback()\n}\n"
                                        "first :: proc(unknown: proc()) -> proc() {return " + first_return + "}\n"
                                        "second :: proc(unknown: proc()) -> proc() {return " + second_return + "}\n"
                                        "when ODIN_OS == .Darwin {\n"
                                        "conditional :: proc(unknown: proc()) -> proc() {return " + first_return + "}\n"
                                        "} else {\nconditional :: proc(unknown: proc()) -> proc() {return " + second_return + "}\n}\n"
                                        "quiet :: proc() {}\nnoisy :: proc() {fmt.println(1)}\n",
                                        'import "core:fmt"\n')
                    self.check(source.parent)
                    findings = self.lint(source)
                    line = source.read_text().splitlines().index("callback()") + 1
                    found = re.search(re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:", findings)
                    effectful = first_return == "noisy" or first_return == "unknown" and actual == "noisy"
                    effectful = effectful or factory != "first" and second_return == "noisy"
                    self.assertEqual(found is not None, effectful and "opaque" not in factory, findings)

    def test_returned_callback_chain_revisits_earlier_callers(self):
        source = self.write("functions", "run :: proc() {\n"
                            "callback := first()\ncallback()\n}\n"
                            "first :: proc() -> proc() {return second()}\n"
                            "second :: proc() -> proc() {return noisy}\n"
                            "noisy :: proc() {fmt.println(1)}\n", 'import "core:fmt"\n')
        self.check(source.parent)
        findings = self.lint(source)
        line = source.read_text().splitlines().index("callback()") + 1
        self.assertRegex(findings, re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:")

    def test_nested_summary_changes_revisit_enclosing_body(self):
        source = self.write("functions", "run :: proc() {\n"
                            "nested := proc() {later()}\nnested()\n}\n"
                            "later :: proc() {noisy()}\n"
                            "noisy :: proc() {fmt.println(1)}\n", 'import "core:fmt"\n')
        self.check(source.parent)
        findings = self.lint(source)
        line = source.read_text().splitlines().index("nested()") + 1
        self.assertRegex(findings, re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:")

    def test_grouped_fields_keep_callbacks_in_their_actual_slots(self):
        names = ("head", "left", "right", "tail")
        for named in (False, True):
            for effectful in (*names, None, "unknown"):
                with self.subTest(named=named, effectful=effectful):
                    fallback = "unknown" if effectful == "unknown" else "quiet"
                    values = ["Leaf{" + ("noisy" if name == effectful else fallback) + "}"
                              for name in names]
                    elements = [name + "=" + value if named else value
                                for name, value in zip(names, values)]
                    tree = "Tree{first=pair, second=pair}" if named else "Tree{pair, pair}"
                    source = self.write("functions",
                                        "Leaf :: struct {callback: proc()}\n"
                                        "Pair :: struct {head: Leaf, left, right: Leaf, tail: Leaf}\n"
                                        "Tree :: struct {first, second: Pair}\n"
                                        "pass :: proc(value: Tree) -> Tree {return value}\n"
                                        "run :: proc(unknown: proc()) {\n_ = unknown\n"
                                        "pair := Pair{" + ", ".join(elements) + "}\n"
                                        "tree := pass(" + tree + ")\n"
                                        + "\n".join("tree.second." + name + ".callback()" for name in names)
                                        + "\n}\nquiet :: proc() {}\nnoisy :: proc() {fmt.println(1)}\n",
                                        'import "core:fmt"\n')
                    self.check(source.parent)
                    findings = self.lint(source)
                    lines = source.read_text().splitlines()
                    for name in names:
                        line = lines.index("tree.second." + name + ".callback()") + 1
                        found = re.search(re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:", findings)
                        self.assertEqual(found is not None, name == effectful, findings)


if __name__ == "__main__":
    unittest.main()
