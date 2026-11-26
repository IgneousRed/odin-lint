"""Exercise the evaluated canonical package phase with an inert compiler."""

import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
STUB = '''import json,os,sys
with open(os.environ["PACKAGE_EVENTS"], "a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1] == "version":
    print(os.environ.get("PACKAGE_VERSION", "odin version dev-2026-11a:9a6991685"))
elif sys.argv[1] == "check" and os.environ.get("PACKAGE_FAIL_CHECK"):
    raise SystemExit(12)
'''
CHECK_FLAGS = {"-vet", "-vet-tabs", "-vet-using-param", "-vet-nil-deref",
               "-vet-uninitialized", "-vet-atomic-access", "-strict-style", "-warnings-as-errors"}


class CanonicalPackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        host = (sys.platform, platform.machine().lower())
        systems = {("darwin", "arm64"): "aarch64-darwin", ("darwin", "aarch64"): "aarch64-darwin",
                   ("linux", "x86_64"): "x86_64-linux"}
        if host not in systems:
            raise unittest.SkipTest("No advertised Nix package for this host")
        cls.build_phase = subprocess.check_output(
            [str(ROOT / "scripts/dev"), "--eval", "packages." + systems[host] + ".default.buildPhase",
             "--raw", "--offline", "--option", "allow-import-from-derivation", "false"],
            cwd=ROOT, text=True)

    def phase(self, cores, version=None, fail_check=False):
        with tempfile.TemporaryDirectory(dir=ROOT / ".work") as temporary:
            root = Path(temporary)
            compiler = root / "odin"
            compiler.write_text("#!" + sys.executable + "\n" + STUB, encoding="utf-8")
            compiler.chmod(0o755)
            events = root / "events.jsonl"
            environment = {"PATH": str(root) + os.pathsep + "/usr/bin:/bin", "PACKAGE_EVENTS": str(events)}
            if cores is not None:
                environment["NIX_BUILD_CORES"] = cores
            if version:
                environment["PACKAGE_VERSION"] = version
            if fail_check:
                environment["PACKAGE_FAIL_CHECK"] = "1"
            result = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-eu", "-c",
                                     "runHook() { :; }\n" + type(self).build_phase],
                                    cwd=root, env=environment, capture_output=True, text=True)
            commands = [json.loads(line) for line in events.read_text().splitlines()] if events.exists() else []
            return result, commands

    def test_compiler_phases_use_invocation_cores_and_keep_every_required_flag(self):
        for cores in ("1", "3"):
            with self.subTest(cores=cores):
                result, commands = self.phase(cores)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual([args[0] for args in commands], ["version", "check", "check", "build"])
                for args in commands[1:3]:
                    self.assertEqual(args[:3], ["check", "src", "-thread-count:" + cores])
                    self.assertTrue(CHECK_FLAGS.issubset(args), args)
                    self.assertNotIn("-thread-count:2", args)
                self.assertIn("-vet-packages:src,effects,functions,state", commands[1])
                self.assertIn("-strict-style-packages:src,effects,functions,state", commands[1])
                self.assertIn("-vet-unused-procedures", commands[2])
                self.assertIn("-vet-packages:src,effects,state", commands[2])
                self.assertEqual(commands[3][:5], ["build", "src", "-debug", "-o:speed", "-thread-count:" + cores])
                self.assertEqual(commands[3][-1], "-out:odin-lint")

    def test_invalid_core_counts_fail_before_the_first_compiler_call(self):
        for cores in (None, "", "0", "-1", "01", "many", "1.5"):
            with self.subTest(cores=cores):
                result, commands = self.phase(cores)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(commands, [])
                self.assertIn("normalized positive integer", result.stderr)

    def test_compiler_pin_still_fails_before_checks_or_build(self):
        result, commands = self.phase("1", version="odin version other:123456789")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(commands, [["version"]])

    def test_failed_first_check_does_not_run_later_steps(self):
        result, commands = self.phase("1", fail_check=True)
        self.assertEqual(result.returncode, 12, result.stderr)
        self.assertEqual([args[0] for args in commands], ["version", "check"])


if __name__ == "__main__":
    unittest.main()
