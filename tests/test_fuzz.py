"""Checks for the project-owned fuzz gate; odin-fuzz remains a CLI dependency."""

import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
DRIVER = runpy.run_path(str(PROJECT / "scripts" / "fuzz.py"))


def application(name):
    return {"name": name, "path": "src", "status": "explored",
            "coverage_mode": "llvm_sancov", "executions": 2,
            "first_party_edges_hit": 3, "workspace_errors": 0, "finding_count": 0}


class FuzzGateTests(unittest.TestCase):
    def test_preparation_preserves_checks_with_per_invocation_compiler_flags(self):
        prepare = DRIVER["prepare"]
        with tempfile.TemporaryDirectory(dir=PROJECT / ".work") as temporary:
            root = Path(temporary)
            (root / "src").mkdir()
            (root / "src/main.odin").write_text("package src\n")
            (root / "tests/fuzz").mkdir(parents=True)
            (root / "tests/fuzz/example.json").write_text(json.dumps({"src/main.odin": "package src\n"}))
            for name in ("VERSION", "odin-fuzz.json"):
                (root / name).write_text("{}\n")
            with mock.patch.dict(prepare.__globals__, ROOT=root, WORK=root / "work", run=mock.Mock()) as namespace:
                prepare({"ODIN": "/locked/odin", "ODIN_FLAGS": "-thread-count:1"})
                command = namespace["run"].call_args.args
                self.assertEqual(command[:2], ("/locked/odin", "check"))
                self.assertIn("-thread-count:1", command)
                self.assertIn("-vet-uninitialized", command)
                self.assertIn("-strict-style", command)
                self.assertIn("-warnings-as-errors", command)

    def test_make_activates_fuzz_profile_after_lint(self):
        result = subprocess.run(
            [shutil.which("make"), "--no-print-directory", "-n", "fuzz",
             "ODIN=inert-odin", "PYTHON=inert-python", "REVISION=" + "a" * 40],
            cwd=PROJECT, env=os.environ | {"PROJECT_NIX_ENVIRONMENT": str(PROJECT)},
            text=True, capture_output=True, check=True)
        flags = os.environ.get("ODIN_FLAGS", "-thread-count:2")
        activation = f'./scripts/dev --profile fuzz env ODIN_FLAGS="{flags}" inert-python scripts/fuzz.py'
        self.assertIn(activation, result.stdout)
        self.assertLess(result.stdout.index(".work/build/odin-lint --root . src tests"),
                        result.stdout.index(activation))

    def test_every_configured_launch_must_be_present_once(self):
        expected = [{"name": name, "path": "src"} for name in ("cli", "aliases")]
        summary = {"status": "ok", "finding_count": 0, "applications": [application("aliases"), application("cli")]}
        self.assertTrue(DRIVER["summary_complete"](summary, expected))
        for names in (("cli",), ("cli", "cli"), ("cli", "other"), ("cli", "aliases", "other")):
            with self.subTest(names=names):
                self.assertFalse(DRIVER["summary_complete"](
                    {"status": "ok", "finding_count": 0, "applications": [application(name) for name in names]}, expected))
        summary["applications"][0]["path"] = "other"
        self.assertFalse(DRIVER["summary_complete"](summary, expected))
        self.assertFalse(DRIVER["summary_complete"]({"status": "ok", "finding_count": 0, "applications": []}, []))

    def test_findings_or_incomplete_feedback_fail_the_gate(self):
        expected = [{"name": "cli", "path": "src"}]
        for field, value in (("status", "findings"), ("finding_count", 1)):
            summary = {"status": "ok", "finding_count": 0, "applications": [application("cli")]}
            summary[field] = value
            self.assertFalse(DRIVER["summary_complete"](summary, expected))
        for field, value in (("status", "build_failed"), ("coverage_mode", "asan"),
                             ("executions", 0), ("first_party_edges_hit", 0),
                             ("workspace_errors", 1), ("finding_count", 1)):
            with self.subTest(field=field, value=value):
                app = application("cli")
                app[field] = value
                self.assertFalse(DRIVER["summary_complete"]({"status": "ok", "finding_count": 0, "applications": [app]}, expected))
                del app[field]
                self.assertFalse(DRIVER["summary_complete"]({"status": "ok", "finding_count": 0, "applications": [app]}, expected))

    def test_invalid_budgets_fail_before_preparation(self):
        main = DRIVER["main"]
        for budget in ("0", "-1", "nan", "inf"):
            with self.subTest(budget=budget), \
                 mock.patch.object(sys, "argv", ["fuzz.py", "--budget", budget]), \
                 mock.patch.dict(main.__globals__, prepare=mock.Mock()) as namespace, \
                 mock.patch("sys.stderr"):
                with self.assertRaises(SystemExit) as caught:
                    main()
                self.assertEqual(caught.exception.code, 2)
                namespace["prepare"].assert_not_called()

    def test_verification_records_snapshot_and_process_outcome(self):
        main = DRIVER["main"]
        with tempfile.TemporaryDirectory(dir=PROJECT / ".work") as temporary:
            root = Path(temporary)
            target = root / "target"
            target.mkdir()
            (target / "VERSION").write_text("0.7.4\n", encoding="utf-8")
            (root / "VERSION").write_text("different live version\n", encoding="utf-8")
            expected = [{"name": "cli", "path": "src"}]
            (target / "odin-fuzz.json").write_text(json.dumps({"applications": expected}), encoding="utf-8")
            (root / "tool").mkdir()
            (root / "flake.lock").write_text("{}\n", encoding="utf-8")
            summary_path = root / "runs" / "runs" / "test" / "summary.json"
            app = application("cli")

            def execute(command, **kwargs):
                if "explore" in command:
                    self.assertEqual(kwargs["env"]["ODIN_FUZZ"], command[0])
                    self.assertEqual(command[command.index("--corpus-dir") + 1], str(root / ".local/fuzz/corpus"))
                    summary_path.parent.mkdir(parents=True, exist_ok=True)
                    summary_path.write_text(json.dumps({"status": "ok", "finding_count": 0, "applications": [app]}), encoding="utf-8")
                    return subprocess.CompletedProcess(command, process_exit)
                return subprocess.CompletedProcess(command, 0)

            for process_exit, finding in ((0, False), (1, False), (0, True)):
                with self.subTest(process_exit=process_exit, finding=finding):
                    if summary_path.exists():
                        summary_path.unlink()
                    app = application("cli")
                    if finding:
                        app["finding_count"] = 1
                    with mock.patch.object(sys, "argv", ["fuzz.py"]), \
                         mock.patch.object(sys, "platform", "darwin"), \
                         mock.patch.dict(main.__globals__, ROOT=root, WORK=root, CORPUS=root / ".local/fuzz/corpus",
                                         prepare=lambda _environment: target, run=mock.Mock(),
                                         locked_setup=lambda _required: {
                                             "PROJECT_NIX_ENVIRONMENT": str(root),
                                             "ODIN_FUZZ": str(root / "tool" / "odin-fuzz")}), \
                         mock.patch("subprocess.run", side_effect=execute), \
                         mock.patch("subprocess.check_output", return_value="a" * 40 + "\n"), \
                         mock.patch("builtins.print"):
                        if finding:
                            with self.assertRaisesRegex(SystemExit, "Fuzz gate failed"):
                                main()
                        else:
                            self.assertEqual(main(), process_exit)
                    identity = json.loads(summary_path.with_name("verification.json").read_text())
                    self.assertEqual(identity["gate_passed"], process_exit == 0 and not finding)
                    self.assertEqual(identity["process_exit"], process_exit)
                    self.assertEqual(identity["version"], "0.7.4")
                    self.assertEqual(identity["revision"], "a" * 40)
                    self.assertEqual(identity["target_sha256"]["VERSION"],
                                     hashlib.sha256((target / "VERSION").read_bytes()).hexdigest())


class LockedDependencyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=PROJECT / ".work")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "source archive with spaces"
        (self.root / "scripts").mkdir(parents=True)
        self.store = self.root / "fixture-store"
        self.environment = self.store / "locked-environment"
        (self.environment / "bin").mkdir(parents=True)
        (self.environment / "share").mkdir()
        self.variables = {}
        for name, executable in (("ODIN", "odin"), ("ODIN_FUZZ", "odin-fuzz")):
            path = self.store / executable / "bin" / executable
            path.parent.mkdir(parents=True)
            path.write_text('#!/bin/sh\nprintf "%s\\n" "$ODIN" "${ODIN_FUZZ_SCANNER-unset}" '
                            '"${ODIN_FUZZ_EXTRA-unset}" "$PATH" "$@" > "$0.observed"\n')
            path.chmod(0o755)
            (self.environment / "bin" / executable).symlink_to(path)
            self.variables[name] = str(path)
        self.variables["ODIN_ROOT"] = str(self.store / "odin" / "share")
        (self.store / "odin" / "share").mkdir()
        self.write_manifest()
        self.development = self.store / "development-environment"
        (self.development / "bin").mkdir(parents=True)
        (self.development / "share").mkdir()
        (self.development / "bin/odin").symlink_to(self.variables["ODIN"])
        self.write_manifest(self.development,
                            {key: value for key, value in self.variables.items() if key != "ODIN_FUZZ"})
        (self.root / "selected-environment").write_text(str(self.environment) + "\n")
        (self.root / "selected-dev-environment").write_text(str(self.development) + "\n")
        launcher = self.root / "scripts" / "dev"
        launcher.write_text('''#!/bin/sh
set -eu
project=${0%/scripts/dev}
printf '%s\\n' "$@" > "$project/eval-arguments"
printf '%s' "$PATH" > "$project/eval-path"
case "$2" in
    *.dev-environment.outPath) selection=selected-dev-environment ;;
    *.fuzz-environment.outPath) selection=selected-environment ;;
    *) exit 8 ;;
esac
IFS= read -r selected < "$project/$selection"
printf '%s' "$selected"
''')
        launcher.chmod(0o755)
        legacy = self.root / ".work" / "fuzz" / "tool" / "odin-fuzz"
        legacy.parent.mkdir(parents=True)
        legacy.write_text('#!/bin/sh\nexit 99\n')
        legacy.chmod(0o755)
        self.setup = DRIVER["locked_setup"]
        patches = [mock.patch.dict(self.setup.__globals__, ROOT=self.root, STORE=self.store),
                   mock.patch.object(sys, "platform", "darwin"),
                   mock.patch("platform.machine", return_value="arm64"),
                   mock.patch.dict(os.environ, {
            "PROJECT_NIX_ENVIRONMENT": str(self.environment),
            "PATH": str(legacy.parent), "ODIN": str(legacy), "ODIN_ROOT": str(legacy.parent),
            "ODIN_FUZZ": str(legacy), "ODIN_FUZZ_SCANNER": str(legacy),
            "ODIN_FUZZ_SCANNER_CACHE": str(legacy.parent), "ODIN_FUZZ_EXTRA": str(legacy),
            "CC": str(legacy), "LLVM_SYMBOLIZER_PATH": str(legacy),
                   }, clear=True)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def write_manifest(self, environment=None, variables=None):
        environment = self.environment if environment is None else environment
        variables = self.variables if variables is None else variables
        (environment / "share" / "project-environment.json").write_text(json.dumps({
            "schema": 1, "variables": variables, "unset": []}))

    def test_archive_selects_only_manifest_tool_and_ignores_ambient_overrides(self):
        environment = self.setup(True)
        self.assertEqual(environment["ODIN_FUZZ"], self.variables["ODIN_FUZZ"])
        self.assertEqual(environment["ODIN"], self.variables["ODIN"])
        self.assertEqual(environment["ODIN_ROOT"], self.variables["ODIN_ROOT"])
        self.assertEqual(environment["PATH"].split(os.pathsep),
                         [str(self.environment / "bin"), "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        for name in ("ODIN_FUZZ_SCANNER", "ODIN_FUZZ_SCANNER_CACHE", "ODIN_FUZZ_EXTRA", "CC", "LLVM_SYMBOLIZER_PATH"):
            self.assertNotIn(name, environment)
        subprocess.run([environment["ODIN_FUZZ"], "doctor"], env=environment, check=True)
        observed = Path(environment["ODIN_FUZZ"] + ".observed").read_text().splitlines()
        self.assertEqual(observed[:3], [self.variables["ODIN"], "unset", "unset"])
        self.assertEqual(observed[-1], "doctor")
        arguments = (self.root / "eval-arguments").read_text().splitlines()
        self.assertEqual(arguments[:2], ["--eval", "packages.aarch64-darwin.fuzz-environment.outPath"])
        self.assertIn("--offline", arguments)
        self.assertEqual(arguments[-3:], ["--option", "allow-import-from-derivation", "false"])
        self.assertEqual((self.root / "eval-path").read_text(), "/usr/bin:/bin:/usr/sbin:/sbin")
        self.assertFalse((self.root / ".git").exists())

    def test_missing_or_spoofed_environment_refuses_before_preparation(self):
        for selected in ("", "relative", str(self.root)):
            with self.subTest(selected=selected), \
                 mock.patch.dict(os.environ, PROJECT_NIX_ENVIRONMENT=selected), \
                 mock.patch.object(sys, "argv", ["fuzz.py"]), \
                 mock.patch.dict(DRIVER["main"].__globals__, prepare=mock.Mock()) as namespace:
                with self.assertRaisesRegex(SystemExit, "Locked fuzz dependency setup unavailable"):
                    DRIVER["main"]()
                namespace["prepare"].assert_not_called()
        self.assertFalse((self.root / "eval-arguments").exists())

    def test_changed_dependency_selection_refuses_stale_environment(self):
        self.setup(True)
        (self.root / "selected-environment").write_text(str(self.store / "upgraded-environment") + "\n")
        with self.assertRaisesRegex(SystemExit, "does not match this checkout"):
            self.setup(True)

    def test_unavailable_nix_evaluation_fails_closed(self):
        (self.root / "scripts" / "dev").write_text('#!/bin/sh\nexit 7\n')
        with self.assertRaisesRegex(SystemExit, "does not match this checkout"):
            self.setup(True)

    def test_missing_or_substituted_locked_tools_never_fall_back(self):
        for name in ("ODIN", "ODIN_FUZZ"):
            with self.subTest(name=name):
                original = self.variables[name]
                self.variables[name] = self.variables["ODIN" if name == "ODIN_FUZZ" else "ODIN_FUZZ"]
                self.write_manifest()
                with self.assertRaisesRegex(SystemExit, "executable is unavailable"):
                    self.setup(True)
                self.variables[name] = original
        self.write_manifest()
        Path(self.variables["ODIN_FUZZ"]).unlink()
        with self.assertRaisesRegex(SystemExit, "Locked fuzz dependency setup unavailable"):
            self.setup(True)

    def test_prepare_only_requires_locked_compiler_without_fuzzer(self):
        del self.variables["ODIN_FUZZ"]
        self.write_manifest()
        environment = self.setup(False)
        self.assertEqual(environment["ODIN"], self.variables["ODIN"])
        self.assertNotIn("ODIN_FUZZ", environment)
        with self.assertRaisesRegex(SystemExit, "Locked fuzz dependency setup unavailable"):
            self.setup(True)

    def test_normal_profile_allows_preparation_and_refuses_ambient_fuzzer(self):
        with mock.patch.dict(os.environ, PROJECT_NIX_ENVIRONMENT=str(self.development)):
            environment = self.setup(False)
            self.assertEqual(environment["ODIN"], self.variables["ODIN"])
            self.assertNotIn("ODIN_FUZZ", environment)
            with self.assertRaisesRegex(SystemExit, "does not match this checkout"):
                self.setup(True)
        self.assertFalse(Path(self.variables["ODIN_FUZZ"] + ".observed").exists())

    def test_direct_archive_driver_refuses_without_locked_setup(self):
        driver = self.root / "scripts" / "fuzz.py"
        driver.write_bytes((PROJECT / "scripts" / "fuzz.py").read_bytes())
        result = subprocess.run([sys.executable, "-I", str(driver), "--prepare-only"],
                                env={}, cwd=self.root, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Locked fuzz dependency setup unavailable", result.stderr)
        self.assertFalse((self.root / ".work" / "fuzz" / "target").exists())


if __name__ == "__main__":
    unittest.main()
