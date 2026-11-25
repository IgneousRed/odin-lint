"""Compiler-backed store and counter-reset summaries across compile-time exits."""

import os
import shlex
import re
import subprocess
import unittest

import test_ownership_052_cli as fixture


class ConditionalStoreTests(unittest.TestCase):
    setUp = fixture.Ownership052Tests.setUp
    write = fixture.Ownership052Tests.write
    lint = fixture.Ownership052Tests.lint

    def run_checked(self, main, flag, expected_output=""):
        odin = os.environ.get("ODIN", "odin")
        packages = "main,application,engine,functions,procedures"
        flags = [*shlex.split(os.environ.get("ODIN_FLAGS", "-thread-count:2")), "-vet", "-vet-tabs", "-vet-using-param",
                 "-vet-nil-deref", "-vet-uninitialized", "-vet-atomic-access",
                 "-strict-style", "-warnings-as-errors", "-vet-packages:" + packages,
                 "-strict-style-packages:" + packages, "-define:FLAG=" + str(flag).lower()]
        for command in (
            [odin, "check", str(main.parent), *flags, "-vet-unused-procedures"],
            [odin, "run", str(main.parent), *flags, "-debug", "-o:none",
             "-out:" + str(self.root / "probe")],
        ):
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            if command[1] == "run":
                self.assertEqual(result.stdout, expected_output)

    def main(self, source):
        path = self.root / "main/main.odin"
        path.parent.mkdir(exist_ok=True)
        path.write_text("package main\n" + source)
        return path

    def test_callback_stores_retain_only_reachable_early_return_alternatives(self):
        # The pair records whether FLAG=false / FLAG=true returns before STORE.
        cases = (
            ("when FLAG {return}", (False, True)),
            ("when FLAG {} else {return}", (True, False)),
            ("when !FLAG {return}", (True, False)),
            ("when INVERSE {return}", (True, False)),
            ("when FLAG {when !INVERSE {return}}", (False, True)),
            ("when FLAG {} else {when INVERSE {return}}", (True, False)),
            ("when FLAG {} else {}\nwhen FLAG {return}", (False, True)),
            ("when FLAG {} else {}\nwhen INVERSE {return}", (True, False)),
            ("when FLAG {if choose {return}}", (False, True)),
            ("if choose {return}", (True, True)),
            ("when true {return}", (True, True)),
            ("when false {return}", (False, False)),
            ("when FLAG {when INVERSE {return}}", (False, False)),
            ("when FLAG {} else {}\nwhen FLAG {when INVERSE {return}}", (False, False)),
            ("when FLAG {if false {return}} else {if false {return}}", (False, False)),
            ("when FLAG {} else {}", (False, False)),
            ("when FLAG {when INVERSE {}} else {when !INVERSE {}}", (False, False)),
            ("when FLAG {} else {}\n{when INVERSE {return}\nSTORE}", (True, False)),
            ("when FLAG {} else {}\n{when FLAG {return}\nSTORE}", (False, True)),
            ("when FLAG {} else {}\n{when FLAG {when INVERSE {return}}\nSTORE}", (False, False)),
            ("", (False, False)),
        )
        self.check_callback_cases([
            (guard.replace("STORE", store) if "STORE" in guard else guard + "\n" + store, outcomes)
            for guard, outcomes in cases
            for store in ("box.callback = quiet", "store_quiet(box)")
        ])

    def test_conditional_deferred_stores_keep_the_unwritten_alternative(self):
        cases = (
            ("when FLAG {defer box.callback = quiet}", (True, False)),
            ("when FLAG {defer store_quiet(box)}", (True, False)),
            ("{when FLAG {defer box.callback = quiet}}", (True, False)),
            ("when FLAG {box.callback = quiet}", (True, False)),
            ("defer box.callback = quiet", (False, False)),
            ("when FLAG {} else {}\ndefer box.callback = quiet", (False, False)),
            ("defer box.callback = quiet\nwhen FLAG {} else {}", (False, False)),
            ("defer box.callback = quiet\nwhen FLAG {return}", (False, False)),
            ("defer store_quiet(box)\nwhen FLAG {return}", (False, False)),
            ("when FLAG {return}\ndefer box.callback = quiet", (False, True)),
        )
        self.check_callback_cases(cases)

    def test_deferred_store_execution_order_and_configuration_coverage(self):
        cases = (
            ("defer box.callback = noisy\nbox.callback = quiet", (True, True)),
            ("defer box.callback = quiet\nbox.callback = noisy", (False, False)),
            ("defer box.callback = noisy\ndefer box.callback = quiet", (True, True)),
            ("defer box.callback = quiet\ndefer box.callback = noisy", (False, False)),
            ("{defer box.callback = noisy\nbox.callback = quiet}", (True, True)),
            ("{defer box.callback = noisy}\nbox.callback = quiet", (False, False)),
            ("defer box.callback = quiet\n{defer box.callback = noisy}", (False, False)),
            ("defer {defer box.callback = noisy; box.callback = quiet}", (True, True)),
            ("defer {defer box.callback = quiet; box.callback = noisy}", (False, False)),
            ("when FLAG {defer box.callback = quiet} else {defer box.callback = quiet}", (False, False)),
            ("when FLAG {defer box.callback = quiet}\nwhen INVERSE {defer box.callback = quiet}", (False, False)),
            ("when FLAG {defer box.callback = noisy} else {defer box.callback = noisy}\nbox.callback = quiet", (True, True)),
            ("when FLAG {defer box.callback = noisy} else {defer box.callback = quiet}", (False, True)),
            ("when FLAG {defer box.callback = quiet}", (True, False)),
            ("when FLAG {when INVERSE {defer box.callback = quiet}}", (True, True)),
            ("when FLAG {defer box.callback = quiet; return}\nwhen INVERSE {defer box.callback = quiet}", (False, False)),
            ("defer box.callback = noisy\nwhen FLAG {box.callback = quiet; return}\nbox.callback = quiet", (True, True)),
            ("when FLAG {return}\ndefer box.callback = quiet", (False, True)),
            ("when FLAG {} else {}\n{defer box.callback = noisy\nbox.callback = quiet}\nbox.callback = quiet", (False, False)),
            ("when FLAG {defer box.callback = quiet} else {defer box.callback = quiet}\n{defer box.callback = noisy}", (False, False)),
            ("if choose {defer box.callback = noisy}\nbox.callback = quiet", (False, False)),
            ("defer box.callback = noisy\nif choose {box.callback = quiet; return}\nbox.callback = quiet", (True, True)),
            ("when FLAG {if choose {return}; defer box.callback = quiet}", (True, True)),
        )
        # Both replayed helper stores and direct stores must agree with actual
        # scope exit. Named arguments exercise substitution through another layer.
        self.check_callback_cases([
            (body.replace("box.callback = quiet", quiet).replace("box.callback = noisy", noisy), outcomes)
            for body, outcomes in cases
            for quiet, noisy in (
                ("box.callback = quiet", "box.callback = noisy"),
                ("store_callback(box, quiet)", "store_callback(box, noisy)"),
                ("store_callback(callback = quiet, box = box)", "store_callback(callback = noisy, box = box)"),
            )
        ], direct=True)

    def test_recursive_deferred_stores_keep_finite_guarded_summaries(self):
        source = self.write("functions", "FLAG :: #config(FLAG, true)\nBox :: struct {callback: proc()}\n"
                            "run :: proc() -> bool {\nbox := Box{noisy}\nreset(&box, 3)\n"
                            "box.callback() // recursive\nreturn box.callback == noisy\n}\n"
                            "reset :: proc(box: ^Box, count: int) {\n"
                            "when FLAG {defer box.callback = quiet} else {defer box.callback = quiet}\n"
                            "if count > 0 {reset(count = count - 1, box = box)}\nbox.callback = noisy\n}\n"
                            "quiet :: proc() {}\n")
        source.with_name("callbacks.odin").write_text('package functions\nimport "core:fmt"\n'
                                                    'noisy :: proc() {fmt.println("hit")}\n')
        main = self.main('import "../src/functions"\nmain :: proc() {assert(!functions.run())}\n')
        for flag in (False, True):
            self.run_checked(main, flag)
        findings = self.lint(source)
        line = source.read_text().splitlines().index("box.callback() // recursive") + 1
        self.assertNotRegex(findings, re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:")

    def test_returned_values_keep_identity_and_observe_deferred_referent_writes(self):
        cases = (
            ("^Box", "box := new(Box)\nbox.callback = quiet\ndefer box.callback = noisy\nreturn box", "value.callback", "free(value)", True),
            ("^Box", "box := new(Box)\nbox.callback = noisy\ndefer box.callback = quiet\nreturn box", "value.callback", "free(value)", False),
            ("Box", "box := Box{quiet}\ndefer box.callback = noisy\nreturn box", "value.callback", "", False),
            ("Link", "box := new(Box)\nbox.callback = quiet\nlink := Link{box}\ndefer box.callback = noisy\nreturn link", "value.box.callback", "free(value.box)", True),
            ("^Box", "box := new(Box)\nbox.callback = quiet\nother := new(Box)\nother.callback = noisy\ndefer free(other)\ndefer box = other\nreturn box", "value.callback", "free(value)", False),
            ("^Box", "box := new(Box)\nbox.callback = quiet\nother := new(Box)\nother.callback = quiet\ndefer free(other)\ndefer box = other\ndefer box.callback = noisy\nreturn box", "value.callback", "free(value)", True),
            ("[1]Box", "boxes := [1]Box{{quiet}}\ndefer boxes[0].callback = noisy\nreturn boxes", "value[0].callback", "", False),
            ("[]Box", "boxes := make([]Box, 1)\nboxes[0].callback = quiet\ndefer boxes[0].callback = noisy\nreturn boxes", "value[0].callback", "delete(value)", True),
            ("Box", "box := Box{quiet}\ndefer set(&box, noisy)\nreturn box", "value.callback", "", False),
            ("^Box", "box := new(Box)\nbox.callback = quiet\ndefer set(box, noisy)\nreturn box", "value.callback", "free(value)", True),
            ("proc()", "callback := quiet\ndefer callback = noisy\nreturn callback", "value", "", False),
            ("^Box", "box := new(Box)\nbox.callback = quiet\ndefer replace(box, Box{noisy})\nreturn box", "value.callback", "free(value)", True),
            ("^Box", "box := new(Box)\nbox.callback = noisy\ndefer replace(box, Box{quiet})\nreturn box", "value.callback", "free(value)", False),
            ("^Box", "box := new(Box)\nbox.callback = quiet\nreplace(box, Box{noisy})\nreturn box", "value.callback", "free(value)", True),
            ("Box", "box := Box{quiet}\ndefer replace(&box, Box{noisy})\nreturn box", "value.callback", "", False),
            ("^proc()", "box := new(Box)\nbox.callback = quiet\ndefer box.callback = noisy\nreturn &box.callback", "value^", "free(value)", True),
            ("^proc()", "box := new(Box)\nbox.callback = noisy\ndefer box.callback = quiet\nreturn &box.callback", "value^", "free(value)", False),
            ("^Box", "box := new(Pair)\nbox.box.callback = quiet\ndefer box.box.callback = noisy\nreturn &box.box", "value.callback", "free(value)", True),
            ("^proc()", "box := new(Pair)\nbox.box.callback = quiet\ndefer box.box = Box{noisy}\nreturn &box.box.callback", "value^", "free(value)", True),
            ("^proc()", "box := new(Box)\nbox.callback = quiet\nother := new(Box)\nother.callback = quiet\ndefer free(other)\ndefer box = other\ndefer box.callback = noisy\nreturn &box.callback", "value^", "free(value)", True),
            ("CallbackLink", "box := new(Box)\nbox.callback = quiet\nlink := CallbackLink{&box.callback}\ndefer box.callback = noisy\nreturn link", "value.callback^", "free(value.callback)", True),
            ("^Box", "box := new(Box)\nbox.callback = noisy\nreplace(box, Box{quiet})\nreturn box", "value.callback", "free(value)", False),
            ("^Box", "box := new(Pair)\nbox.box.callback = noisy\ndefer box.box.callback = quiet\nreturn &box.box", "value.callback", "free(value)", False),
        )
        # Addressed fields are at offset zero in these one-field records, so
        # callers can free the original allocation through the returned address.
        bodies = ["FLAG :: #config(FLAG, true)\nBox :: struct {callback: proc()}\nLink :: struct {box: ^Box}\n"
                  "Pair :: struct {box: Box}\nCallbackLink :: struct {callback: ^proc()}\n"]
        for index, (result, body, callback, cleanup, _) in enumerate(cases):
            bodies.append(f"run_{index} :: proc() -> bool {{\nvalue := factory_{index}()\n"
                          + (f"defer {cleanup}\n" if cleanup else "")
                          + f"{callback}() // returned {index}\nreturn {callback} == noisy\n}}\n"
                          + f"factory_{index} :: proc() -> {result} {{\n{body}\n}}\n")
        bodies.append("set :: proc(box: ^Box, callback: proc()) {box.callback = callback}\n"
                      "replace :: proc(box: ^Box, value: Box) {box^ = value}\nquiet :: proc() {}\n")
        source = self.write("functions", "".join(bodies))
        source.with_name("callbacks.odin").write_text('package functions\nimport "core:fmt"\n'
                                                    'noisy :: proc() {fmt.println("hit")}\n')
        main = self.main('import "../src/functions"\nmain :: proc() {\n_ = functions.FLAG\n'
                         + "\n".join(f"assert(functions.run_{i}() == {str(case[-1]).lower()})" for i, case in enumerate(cases))
                         + "\n}\n")
        for flag in (False, True):
            self.run_checked(main, flag, "hit\n" * sum(case[-1] for case in cases))
        findings = self.lint(source)
        lines = source.read_text().splitlines()
        for index, (_, _, callback, _, expected) in enumerate(cases):
            with self.subTest(case=index):
                line = lines.index(f"{callback}() // returned {index}") + 1
                self.assertEqual(bool(re.search(re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:", findings)), expected, findings)

    def test_changed_helper_summaries_rebuild_transitive_callers(self):
        allocate = "box := new(Box)\nbox.callback = noisy\n"
        cases = (
            (allocate + "replace(box, Box{quiet})\nreturn box", (False, False)),
            (allocate + "defer replace(box, Box{quiet})\nreturn box", (False, False)),
            (allocate + "reset_with(box, replace)\nreturn box", (False, False)),
            ("if depth > 0 {return second_INDEX(choose, depth-1)}\n" + allocate
             + "replace(box, Box{quiet})\nreturn box", (False, False)),
            ("if depth > 0 {return second_INDEX(choose, depth-1)}\n" + allocate
             + "replace(box, Box{quiet})\nif choose {box.callback = noisy}\nreturn box", (False, True)),
            ("build := proc() -> ^Box {\n" + allocate
             + "replace(box, Box{quiet})\nreturn box\n}\nreturn build()", (False, False)),
            (allocate + "when FLAG {replace(box, Box{quiet})} else {reset_with(box, replace)}\nreturn box", (False, False)),
            (allocate + "reset_INDEX(box, choose, depth)\nreturn box", (False, False)),
            (allocate + "reset_INDEX(box, choose, depth)\nreturn box", (False, True)),
            (allocate + "reset_INDEX(box, choose, depth)\nbox.callback()\nreturn box", (False, False)),
        )
        helpers = ("replace :: proc(box: ^Box, value: Box) {box^ = value}\n"
                   "reset_with :: proc(box: ^Box, apply: proc(^Box, Box)) {apply(box, Box{quiet})}\n"
                   "quiet :: proc() {}\n")
        bodies = []
        for index, (body, outcomes) in enumerate(cases):
            bodies.append(f"observe_{index} :: proc(choose: bool) -> bool {{\n"
                          f"return run_{index}(choose) // observer {index}\n}}\n"
                          f"run_{index} :: proc(choose: bool) -> bool {{\n"
                          f"value := forward_{index}(choose)\ndefer free(value)\n"
                          f"value.callback() // callback {index}\nreturn value.callback == noisy\n}}\n"
                          f"forward_{index} :: proc(choose: bool) -> ^Box {{return factory_{index}(choose, 2)}}\n"
                          f"factory_{index} :: proc(choose: bool, depth: int) -> ^Box {{\n"
                          "_ = choose\n_ = depth\n" + body.replace("INDEX", str(index)) + "\n}\n")
            if "second_INDEX" in body:
                helpers += (f"second_{index} :: proc(choose: bool, depth: int) -> ^Box {{\n"
                            f"return factory_{index}(choose, depth)\n}}\n")
            if "reset_INDEX" in body:
                helpers += (f"reset_{index} :: proc(box: ^Box, choose: bool, depth: int) {{\n"
                            f"if depth > 0 {{other := factory_{index}(choose, depth-1); free(other)}}\n"
                            "box.callback = quiet\n"
                            + ("if choose {box.callback = noisy}\n" if any(outcomes) else "") + "}\n")
        main = self.main('import "../src/functions"\nmain :: proc() {\n'
                         + "\n".join(f"assert(functions.observe_{i}({str(choose).lower()}) == {str(outcomes[int(choose)]).lower()})"
                                     for i, (_, outcomes) in enumerate(cases) for choose in (False, True))
                         + "\n}\n")
        for helpers_first in (False, True):
            with self.subTest(helpers_first=helpers_first):
                source = self.write("functions", "FLAG :: #config(FLAG, true)\nBox :: struct {callback: proc()}\n"
                                    + (helpers if helpers_first else "") + "".join(bodies)
                                    + ("" if helpers_first else helpers))
                source.with_name("callbacks.odin").write_text('package functions\nimport "core:fmt"\n'
                                                            'noisy :: proc() {fmt.println("hit")}\n')
                for flag in (False, True):
                    self.run_checked(main, flag, "hit\n" * sum(sum(outcomes) for _, outcomes in cases))
                findings = self.lint(source)
                lines = source.read_text().splitlines()
                for index, (_, outcomes) in enumerate(cases):
                    for marker in (f"// callback {index}", f"// observer {index}"):
                        with self.subTest(case=index, marker=marker):
                            line = next(i for i, text in enumerate(lines, 1) if text.endswith(marker))
                            self.assertEqual(bool(re.search(re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:", findings)), any(outcomes), findings)

    def test_call_completion_preserves_optional_callbacks_and_forward_definitions(self):
        source = self.write("functions", """
FLAG :: #config(FLAG, true)
normal :: proc() {
    forward()
    noisy() // normal
}
optional :: proc() {
    maybe(hang, false)
    noisy() // optional
}
mandatory :: proc() {
    invoke(empty)
    noisy() // mandatory
}
sorted :: proc() {
    values: [0]int
    slice.sort_by(values[:], compare)
    noisy() // sorted
}
mixed :: proc(choose: bool) {
    callback := handler_hang if choose else tokenizer.default_error_handler
    handler_invoke(callback)
    noisy() // mixed
}
mixed_reverse :: proc(choose: bool) {
    callback := tokenizer.default_error_handler if choose else handler_hang
    handler_forward(callback)
    noisy() // mixed_reverse
}
mixed_pure :: proc(choose: bool) {
    state := rand.create_u64(1)
    generator := rand.default_random_generator(&state)
    callback: runtime.Random_Generator_Proc = random_hang
    if !choose {callback = generator.procedure}
    random_invoke(callback, generator.data)
    noisy() // mixed_pure
}
short :: proc() {
    _ = false && halt_bool()
    noisy() // short
}
choice :: proc(choose: bool) {
    _ = halt_bool() if choose else true
    noisy() // choice
}
compile_choice :: proc() {
    _ = halt_bool() when FLAG else true
    noisy() // compile_choice
}
halted :: proc() {
    hang()
    noisy() // halted
}
halted_cleanup :: proc() {
    defer noisy() // cleanup
    defer hang()
}
halted_return :: proc() -> proc() {
    defer hang()
    return noisy
}
return_consumer :: proc() {
    callback := halted_return()
    callback() // returned
}
prefix :: proc() {
    noisy() // prefix
    hang()
}
forward :: proc() {inner(); inner :: proc() {}}
maybe :: proc(callback: proc(), choose: bool) {if choose {callback()}}
invoke :: proc(callback: proc()) {callback()}
empty :: proc() {}
hang :: proc() {hang()}
halt_bool :: proc() -> bool {hang(); return false}
compare :: proc(left, right: int) -> bool {_ = left; _ = right; hang(); return false}
keep :: proc(callback: proc()) {_ = callback}
handler_forward :: proc(callback: tokenizer.Error_Handler) {handler_invoke(callback)}
handler_invoke :: proc(callback: tokenizer.Error_Handler) {callback({}, "callback")}
handler_hang :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {handler_hang(pos, msg, ..args)}
random_invoke :: proc(callback: runtime.Random_Generator_Proc, data: rawptr) {buffer: [1]byte; callback(data, .Read, buffer[:])}
random_hang :: proc(data: rawptr, mode: runtime.Random_Generator_Mode, p: []byte) {random_hang(data, mode, p)}
""".replace("    ", "\t"), 'import "base:runtime"\nimport "core:slice"\nimport "core:odin/tokenizer"\nimport "core:math/rand"\n')
        source.with_name("callbacks.odin").write_text('package functions\nimport "core:fmt"\n'
                                                    'noisy :: proc() {fmt.println("hit")}\n')
        main = self.main('import "../src/functions"\nmain :: proc() {\n'
                         '_ = functions.FLAG\nfunctions.normal()\nfunctions.optional()\n'
                         'functions.mandatory()\nfunctions.sorted()\nfunctions.short()\n'
                         'functions.choice(false)\nfunctions.compile_choice()\n'
                         'functions.mixed(false)\nfunctions.mixed_reverse(true)\n'
                         'functions.mixed_pure(false)\n'
                         + "\n".join(f"functions.keep(functions.{name})" for name in
                                     ("halted", "halted_cleanup", "return_consumer", "prefix")) + "\n}\n")
        self.run_checked(main, False, "hit\n" * 10)
        findings = self.lint(source)
        lines = source.read_text().splitlines()
        for marker, expected in (("normal", True), ("optional", True), ("mandatory", True),
                                 ("sorted", True), ("short", True), ("choice", True),
                                 ("mixed", True), ("mixed_reverse", True),
                                 ("mixed_pure", True),
                                 ("compile_choice", True), ("halted", False), ("cleanup", False),
                                 ("returned", False), ("prefix", True)):
            with self.subTest(marker=marker):
                line = next(i for i, text in enumerate(lines, 1) if text.endswith("// " + marker))
                self.assertEqual(bool(re.search(re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:", findings)), expected, findings)

    def test_unknown_external_callbacks_preserve_reachable_continuations(self):
        bodies = (
            'callback := hang if choose else strings.trim_space; _ = callback(" hello ")',
            'callback := strings.trim_space if !choose else hang; _ = callback(" hello ")',
            'callback := hang; if !choose {callback = strings.trim_space}; _ = callback(" hello ")',
            'callback := hang if choose else TRIM; _ = callback(" hello ")',
            'box := Box{hang if choose else strings.trim_space}; _ = box.callback(" hello ")',
            'callback := pick(choose); _ = callback(" hello ")',
            'callback := hang if choose else strings.trim_space; _ = invoke(callback)',
            'box := Box{hang}; if !choose {box.callback = strings.trim_space}; _ = box.callback(" hello ")',
            'callback := strings.trim_space; _ = callback(" hello ")',
        )
        declarations = ['FLAG :: #config(FLAG, true)\nTRIM :: strings.trim_space\n'
                        'Box :: struct {callback: proc(string) -> string}\n'
                        'hang :: proc(text: string) -> string {return hang(text)}\n'
                        'pick :: proc(choose: bool) -> proc(string) -> string {return hang if choose else strings.trim_space}\n'
                        'invoke :: proc(callback: proc(string) -> string) -> string {return callback(" hello ")}\n']
        declarations.extend(f'run_{index} :: proc(choose: bool) {{\n_ = choose\n{body}\n'
                            f'noisy() // external {index}\n}}\n' for index, body in enumerate(bodies))
        source = self.write("functions", "".join(declarations), 'import "core:strings"\n')
        source.with_name("callbacks.odin").write_text('package functions\nimport "core:fmt"\n'
                                                    'noisy :: proc() {fmt.println("hit")}\n')
        main = self.main('import "../src/functions"\nmain :: proc() {\n_ = functions.FLAG\n'
                         + "\n".join(f"functions.run_{index}(false)" for index in range(len(bodies))) + "\n}\n")
        self.run_checked(main, False, "hit\n" * len(bodies))
        findings = self.lint(source)
        lines = source.read_text().splitlines()
        for index in range(len(bodies)):
            with self.subTest(case=index):
                line = lines.index(f"noisy() // external {index}") + 1
                self.assertRegex(findings, re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:")

    def check_callback_cases(self, cases, direct=False):
        # Compile all variants together for each FLAG value. Every reset still
        # has its own formal/store sites, runtime assertion and diagnostic line.
        bodies = ["FLAG :: #config(FLAG, true)\nINVERSE :: !FLAG\nBox :: struct {callback: proc()}\n"]
        direct_indexes = []
        for index, (body, _) in enumerate(cases):
            bodies.append(f"run_{index} :: proc(choose: bool) -> bool {{\nbox := Box{{noisy}}\n"
                          f"reset_{index}(&box, choose)\nbox.callback() // case {index}\n"
                          "return box.callback == noisy\n}\n"
                          f"reset_{index} :: proc(box: ^Box, choose: bool) {{\n_ = choose\n" + body + "\n}\n")
            if direct and "return" not in body:
                direct_indexes.append(index)
                bodies.append(f"direct_{index} :: proc(choose: bool) -> bool {{\n_ = choose\n"
                              "storage := Box{noisy}\nbox := &storage\n{\n" + body + "\n}\n"
                              f"box.callback() // direct {index}\nreturn box.callback == noisy\n}}\n")
        if direct:
            bodies.append("store_callback :: proc(box: ^Box, callback: proc()) {box.callback = callback}\n")
        bodies.append("store_quiet :: proc(box: ^Box) {box.callback = quiet}\nquiet :: proc() {}\n")
        source = self.write("functions", "".join(bodies))
        source.with_name("callbacks.odin").write_text('package functions\nimport "core:fmt"\n'
                                                    'noisy :: proc() {fmt.println("hit")}\n')
        for flag in (False, True):
            assertions = [f"assert(functions.run_{index}(true) == {str(outcomes[int(flag)]).lower()})"
                          for index, (_, outcomes) in enumerate(cases)]
            assertions.extend(f"assert(functions.direct_{index}(true) == {str(cases[index][1][int(flag)]).lower()})"
                              for index in direct_indexes)
            main = self.main('import "../src/functions"\nmain :: proc() {\n'
                             + "\n".join(assertions)
                             + "\nbox: functions.Box\nfunctions.store_quiet(&box)\nbox.callback()\n}\n")
            self.run_checked(main, flag, "hit\n" * (sum(outcomes[int(flag)] for _, outcomes in cases)
                                                  + sum(cases[index][1][int(flag)] for index in direct_indexes)))
        findings = self.lint(source)
        lines = source.read_text().splitlines()
        for index, (_, outcomes) in enumerate(cases):
            with self.subTest(case=index, body=cases[index][0]):
                line = lines.index(f"box.callback() // case {index}") + 1
                found = re.search(re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:", findings)
                self.assertEqual(found is not None, any(outcomes), findings)
                if index in direct_indexes:
                    line = lines.index(f"box.callback() // direct {index}") + 1
                    found = re.search(re.escape(str(source)) + rf"\({line}:\d+\): ARCH007:", findings)
                    self.assertEqual(found is not None, any(outcomes), findings)

    def test_conditional_counter_reset_is_not_an_unconditional_postcondition(self):
        for guard, outcomes in (
            ("when FLAG {return}", (0, 1)),
            ("when FLAG {} else {return}", (1, 0)),
            ("when FLAG {} else {}\nwhen INVERSE {return}", (1, 0)),
            ("when FLAG {when !INVERSE {return}}", (0, 1)),
            ("when FLAG {when INVERSE {return}}", (0, 0)),
            ("when FLAG {} else {}", (0, 0)),
            ("", (0, 0)),
            ("when FLAG {defer RESET}", (1, 0)),
            ("defer RESET", (0, 0)),
            ("defer RESET\nreturn", (0, 0)),
            ("defer RESET\ndefer enter(owner)", (0, 0)),
            ("defer enter(owner)\ndefer RESET", (1, 1)),
        ):
            with self.subTest(guard=guard):
                engine = self.write("engine", "FLAG :: #config(FLAG, true)\nINVERSE :: !FLAG\n"
                                    "Owner :: struct {depth: int}\n"
                                    "enter :: proc(owner: ^Owner) {owner.depth += 1}\n"
                                    "leave :: proc(owner: ^Owner) {owner.depth -= 1}\n"
                                    "reset :: proc(owner: ^Owner) {\n"
                                    + (guard.replace("RESET", "owner^ = {}") if "RESET" in guard else guard + "\nowner^ = {}")
                                    + "\n}\n")
                source = self.write("procedures", "run :: proc(owner: ^engine.Owner) {\n"
                                    "engine.enter(owner)\nengine.reset(owner)\n}\n", 'import "../engine"\n')
                caller = self.write("application", "live: engine.Owner\n"
                                    "run :: proc() {procedures.run(&live)}\n",
                                    'import "../engine"\nimport "../procedures"\n')
                for flag, depth in zip((False, True), outcomes):
                    main = self.main('import "../src/application"\nimport "../src/engine"\n'
                                     'main :: proc() {application.run(); assert(application.live.depth == '
                                     + str(depth) + '); if application.live.depth > 0 {engine.leave(&application.live)}}\n')
                    self.run_checked(main, flag)
                findings = self.lint(source, caller, engine)
                self.assertEqual("OWN002:" in findings, any(outcomes), findings)

    def test_nested_scope_cleanup_keeps_each_paths_enclosing_defers(self):
        self.write("engine", "Owner :: struct {depth: int}\n"
                   "enter :: proc(owner: ^Owner) {owner.depth += 1}\n"
                   "leave :: proc(owner: ^Owner) {owner.depth -= 1}\n")
        source = self.write("procedures", "FLAG :: #config(FLAG, true)\n"
                            "run :: proc(owner, other: ^engine.Owner) {\n"
                            "when FLAG {engine.enter(owner); defer engine.leave(owner)}\n"
                            "{engine.enter(other); defer engine.leave(other); when FLAG {return}}\n"
                            "}\n", 'import "../engine"\n')
        caller = self.write("application", "left, right: engine.Owner\n"
                            "run :: proc() {procedures.run(&left, &right)}\n",
                            'import "../engine"\nimport "../procedures"\n')
        main = self.main('import "../src/application"\nmain :: proc() {application.run(); '
                         'assert(application.left.depth == 0 && application.right.depth == 0)}\n')
        for flag in (False, True):
            self.run_checked(main, flag)
        self.assertNotIn("OWN002:", self.lint(source, caller))
