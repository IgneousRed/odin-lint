"""Consumer bootstrap checks using an isolated Git remote and real compiler."""

import json
import os
import shlex
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from test_cli import BINARY, PROJECT, section


PACKAGE_WORK = PROJECT / ".work" / "package"


class DistributionTests(unittest.TestCase):
    def setUp(self):
        PACKAGE_WORK.mkdir(parents=True, exist_ok=True)
        environment = mock.patch.dict(os.environ, {"ODIN_LINT_CACHE": ""})
        environment.start()
        self.addCleanup(environment.stop)

    def test_version_does_not_require_project_sources(self):
        result = subprocess.run([str(BINARY), "--root", "/missing-project", "--version"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"odin-lint {PROJECT.joinpath('VERSION').read_text().strip()} (", result.stdout)
        self.assertEqual(result.stderr, "")

    @unittest.skipUnless(os.name == "posix", "deleting a working directory requires POSIX")
    def test_help_and_version_do_not_require_a_live_working_directory(self):
        with tempfile.TemporaryDirectory(dir=PACKAGE_WORK) as temporary:
            root = Path(temporary)
            for option in ("--version", "--help"):
                with self.subTest(option=option):
                    working = root / "working"
                    working.mkdir()

                    def remove_working_directory():
                        os.chdir(working)
                        working.rmdir()

                    result = subprocess.run([str(BINARY), option], capture_output=True, text=True,
                                            preexec_fn=remove_working_directory)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue(result.stdout)
                    self.assertEqual(result.stderr, "")

    def test_bootstrap_fetches_a_pin_and_reuses_it_without_the_remote(self):
        with tempfile.TemporaryDirectory(dir=PACKAGE_WORK) as temporary:
            root = Path(temporary)
            source = root / "source snapshot"
            source.mkdir()
            shutil.copytree(PROJECT / "src", source / "src")
            shutil.copyfile(PROJECT / "VERSION", source / "VERSION")
            subprocess.run(["git", "init", "--quiet", str(source)], check=True)
            subprocess.run(["git", "-C", str(source), "add", "."], check=True)
            subprocess.run(["git", "-C", str(source), "-c", "user.name=Distribution Test",
                            "-c", "user.email=distribution@example.invalid", "-c", "commit.gpgsign=false",
                            "commit", "--quiet", "-m", "Snapshot"], check=True)
            revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
            remote = root / "remote.git"
            subprocess.run(["git", "clone", "--quiet", "--bare", str(source), str(remote)], check=True)
            shutil.rmtree(source)
            consumer = root / "independent project"
            (consumer / "src").mkdir(parents=True)
            runner = consumer / "tools" / "run-odin-lint.py"
            runner.parent.mkdir()
            shutil.copyfile(PROJECT / "scripts" / "run-odin-lint.py", runner)
            lock = consumer / "odin-lint.lock.json"
            lock.write_text(json.dumps({"repository": "odin-lint-test/odin-lint", "revision": revision}), encoding="utf-8")
            program = consumer / "src" / "main.odin"
            program.write_text("package src\n" + section("Procedures", "Public") + "main :: proc() {}\n", encoding="utf-8")
            # Keep the production HTTPS interface; Git redirects only this test
            # repository to an isolated bare remote, with no live network access.
            cache = root / "shared cache"
            environment = {**os.environ, "ODIN_LINT_CACHE": str(cache), "GIT_CONFIG_COUNT": "1",
                           "GIT_CONFIG_KEY_0": f"url.{remote.as_uri()}.insteadOf",
                           "GIT_CONFIG_VALUE_0": "https://github.com/odin-lint-test/odin-lint.git",
                           "GIT_TERMINAL_PROMPT": "0", "PYTHONDONTWRITEBYTECODE": "1",
                           "ODIN_LINT_THREAD_COUNT": "1"}
            command = [sys.executable, str(runner), str(lock)]
            built = subprocess.run([*command, "--version"], cwd=consumer, env=environment, capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            self.assertIn(f"({revision})", built.stdout)
            self.assertIn("Building odin-lint", built.stderr)
            binaries = list(cache.iterdir())
            self.assertEqual(len(binaries), 1)
            original = (binaries[0].read_bytes(), binaries[0].stat().st_mtime_ns)
            self.assertFalse((consumer / ".work").exists())
            shutil.rmtree(remote)
            second = root / "second consumer"
            second.mkdir()
            second_lock = second / lock.name
            shutil.copyfile(lock, second_lock)
            reused = subprocess.run([sys.executable, str(runner), str(second_lock), "--version"],
                                    cwd=second, env=environment, capture_output=True, text=True)
            self.assertEqual(reused.returncode, 0, reused.stderr)
            self.assertEqual(reused.stdout, built.stdout)
            self.assertNotIn("Building odin-lint", reused.stderr)
            self.assertFalse((second / ".work").exists())
            self.assertEqual((binaries[0].read_bytes(), binaries[0].stat().st_mtime_ns), original)
            subprocess.run([os.environ.get("ODIN", "odin"), "check", "src", *shlex.split(os.environ.get("ODIN_FLAGS", "-thread-count:2")),
                            "-vet", "-vet-tabs", "-vet-using-param", "-vet-nil-deref",
                            "-vet-uninitialized", "-vet-atomic-access", "-strict-style",
                            "-warnings-as-errors", "-vet-unused-procedures", "-vet-packages:src"],
                           cwd=consumer, check=True)
            for text, expected in ((program.read_text(), 0),
                                   ("package src\nmain :: proc() {}\n", 1),
                                   ("package src\nmain :: proc( {", 2)):
                with self.subTest(expected=expected):
                    program.write_text(text, encoding="utf-8")
                    result = subprocess.run([*command, "--root", ".", "src"], cwd=consumer,
                                            env=environment, capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertNotIn("Building odin-lint", result.stderr)
            # A missing newly pinned revision must fail, never fall back to the
            # previous cached binary or publish a partial installation.
            lock.write_text(json.dumps({"repository": "odin-lint-test/odin-lint", "revision": "0" * 40}), encoding="utf-8")
            failed = subprocess.run([*command, "--version"], cwd=consumer, env=environment,
                                    capture_output=True, text=True)
            self.assertEqual(failed.returncode, 2, failed.stderr)
            self.assertIn("odin-lint setup failed", failed.stderr)
            self.assertEqual(failed.stdout, "")
            self.assertEqual(len(list(cache.iterdir())), 1)

    @unittest.skipUnless(os.name == "posix", "fixture tools use executable scripts")
    def test_concurrent_cold_requests_publish_one_complete_binary(self):
        with tempfile.TemporaryDirectory(dir=PACKAGE_WORK) as temporary:
            root = Path(temporary).resolve()
            tools, cache, ready = root / "tools", root / "cache", root / "ready"
            tools.mkdir()
            ready.mkdir()
            compiler = tools / "odin"
            compiler.write_text("#!/usr/bin/env python3\n" + '''import json,os,sys,time
from pathlib import Path
if sys.argv[1] == "version":
    print("odin version dev-2026-11:9a6991685")
else:
    ready = Path(os.environ["TEST_READY"])
    (ready / str(os.getpid())).write_text(json.dumps(sys.argv[1:]))
    deadline = time.monotonic() + 10
    while len(list(ready.iterdir())) < 2:
        if time.monotonic() > deadline: raise SystemExit("second build did not arrive")
        time.sleep(.01)
    out = Path(next(a[5:] for a in sys.argv if a.startswith("-out:")))
    out.write_text("#!/usr/bin/env python3\\nprint('complete')\\n")
    out.chmod(0o755)
''', encoding="utf-8")
            git = tools / "git"
            git.write_text("#!/usr/bin/env python3\n" + '''import sys
from pathlib import Path
if sys.argv[1] == "init": Path(sys.argv[-1]).mkdir()
elif "rev-parse" in sys.argv: print("0" * 40)
''', encoding="utf-8")
            compiler.chmod(0o755)
            git.chmod(0o755)
            lock = root / "lock.json"
            lock.write_text(json.dumps({"repository": "owner/repo", "revision": "0" * 40}), encoding="utf-8")
            environment = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                           "ODIN": str(compiler), "ODIN_LINT_CACHE": str(cache), "TEST_READY": str(ready),
                           "ODIN_LINT_THREAD_COUNT": "1"}
            command = [sys.executable, str(PROJECT / "scripts/run-odin-lint.py"), str(lock)]
            children = [subprocess.Popen(command, env=environment, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, text=True) for _ in range(2)]
            try:
                for child in children:
                    stdout, stderr = child.communicate(timeout=20)
                    self.assertEqual(child.returncode, 0, stderr)
                    self.assertEqual(stdout, "complete\n")
                self.assertEqual(len(list(ready.iterdir())), 2)
                for observed in ready.iterdir():
                    arguments = json.loads(observed.read_text())
                    self.assertEqual(arguments[:5], ["build", "src", "-debug", "-o:speed", "-thread-count:1"])
                    self.assertEqual(sum(arg.startswith("-thread-count:") for arg in arguments), 1)
                self.assertEqual(len(list(cache.iterdir())), 1)
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                    child.wait()

    def test_cache_identity_separates_incompatible_builds(self):
        environment = mock.patch.dict(os.environ)
        environment.start()
        self.addCleanup(environment.stop)
        os.environ.pop("ODIN_LINT_THREAD_COUNT", None)
        runner = runpy.run_path(str(PROJECT / "scripts/run-odin-lint.py"))
        with tempfile.TemporaryDirectory(dir=PACKAGE_WORK) as temporary:
            root = Path(temporary).resolve()
            compiler, lock = root / "compiler", root / "lock.json"
            compiler.write_bytes(b"compiler A")
            lock.write_text(json.dumps({"repository": "owner/repo", "revision": "0" * 40}), encoding="utf-8")
            with mock.patch.object(sys, "argv", ["runner", str(lock)]), \
                 mock.patch("shutil.which", return_value=str(compiler)), \
                 mock.patch("subprocess.check_output", return_value="odin version dev-2026-11:9a6991685"), \
                 mock.patch.object(Path, "is_file", return_value=True), \
                 mock.patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0)) as execute:
                def selected():
                    self.assertEqual(runner["main"](), 0)
                    return Path(execute.call_args[0][0][0])

                first = selected()
                self.assertEqual(first.parent, root / ".work/odin-lint")
                with mock.patch.dict(os.environ, ODIN_LINT_THREAD_COUNT="2"):
                    self.assertEqual(selected().name, first.name)
                with mock.patch.dict(os.environ, ODIN_LINT_THREAD_COUNT="1"):
                    single_thread = selected().name
                    self.assertNotEqual(single_thread, first.name)
                    self.assertEqual(selected().name, single_thread)
                with mock.patch.dict(os.environ, ODIN_LINT_THREAD_COUNT="4"):
                    self.assertNotIn(selected().name, (first.name, single_thread))
                relocated = root / "same-compiler"
                shutil.copyfile(compiler, relocated)
                with mock.patch("shutil.which", return_value=str(relocated)):
                    self.assertEqual(selected().name, first.name)
                with mock.patch.dict(os.environ, {"ODIN_LINT_CACHE": str(root / "shared")}):
                    self.assertEqual(selected().name, first.name)
                keys = {first.name}
                for data in (b"compiler B", b"compiler C"):
                    compiler.write_bytes(data)
                    keys.add(selected().name)
                for repository, revision in (("other/repo", "0" * 40), ("owner/repo", "1" * 40)):
                    lock.write_text(json.dumps({"repository": repository, "revision": revision}), encoding="utf-8")
                    keys.add(selected().name)
                with mock.patch("platform.machine", return_value="other-cpu"):
                    keys.add(selected().name)
                with mock.patch.object(sys, "platform", "other-os"):
                    keys.add(selected().name)
                with mock.patch.dict(runner["main"].__globals__, {"BUILD_FLAGS": ("-debug", "-o:none")}):
                    keys.add(selected().name)
                self.assertEqual(len(keys), 8)
                with mock.patch.dict(os.environ, {"ODIN_LINT_CACHE": "relative-cache"}):
                    with self.assertRaisesRegex(ValueError, "absolute directory"):
                        selected()

    def test_invalid_thread_selection_fails_before_compiler_or_cache_use(self):
        runner = runpy.run_path(str(PROJECT / "scripts/run-odin-lint.py"))
        with tempfile.TemporaryDirectory(dir=PACKAGE_WORK) as temporary:
            root = Path(temporary)
            lock = root / "lock.json"
            lock.write_text(json.dumps({"repository": "owner/repo", "revision": "0" * 40}))
            for value in ("", "0", "-1", "+1", "01", "1.5", "nan", " 1", "1 "):
                with self.subTest(value=value), \
                     mock.patch.object(sys, "argv", ["runner", str(lock)]), \
                     mock.patch.dict(os.environ, ODIN_LINT_THREAD_COUNT=value), \
                     mock.patch("shutil.which") as compiler:
                    with self.assertRaisesRegex(ValueError, "positive integer"):
                        runner["main"]()
                    compiler.assert_not_called()
                    self.assertFalse((root / ".work").exists())

    def test_compiler_pin_is_enforced_before_cache_or_git_use(self):
        runner = runpy.run_path(str(PROJECT / "scripts" / "run-odin-lint.py"))
        with tempfile.TemporaryDirectory(dir=PACKAGE_WORK) as temporary:
            root = Path(temporary)
            lock = root / "odin-lint.lock.json"
            lock.write_text(json.dumps({"repository": "owner/repo", "revision": "0" * 40}), encoding="utf-8")
            for version in ("odin version dev-2026-10:123456789", "odin version dev-2026-11:9a69916850",
                            "/tools/9a6991685/odin version dev-2026-10:123456789",
                            "/tools/9a69916/odin version dev-2026-10:123456789",
                            "odin version dev-2026-11:a9a69916", "odin version dev-2026-11:9a69916f"):
                with self.subTest(version=version), \
                     mock.patch.object(sys, "argv", ["run-odin-lint.py", str(lock)]), \
                     mock.patch("shutil.which", return_value=sys.executable), \
                     mock.patch("subprocess.check_output", return_value=version), \
                     mock.patch("subprocess.run") as execute:
                    with self.assertRaisesRegex(ValueError, "compiler 9a6991685"):
                        runner["main"]()
                    execute.assert_not_called()
                    self.assertFalse((root / ".work").exists())

    def test_documented_compiler_identity_forms_reuse_a_cached_binary(self):
        runner = runpy.run_path(str(PROJECT / "scripts" / "run-odin-lint.py"))
        with tempfile.TemporaryDirectory(dir=PACKAGE_WORK) as temporary:
            root = Path(temporary)
            lock = root / "odin-lint.lock.json"
            lock.write_text(json.dumps({"repository": "owner/repo", "revision": "0" * 40}), encoding="utf-8")
            for revision in ("9a6991685", "9a69916"):
                with self.subTest(revision=revision), \
                     mock.patch.object(sys, "argv", ["run-odin-lint.py", str(lock), "--version"]), \
                     mock.patch("shutil.which", return_value=sys.executable), \
                     mock.patch("subprocess.check_output", return_value="odin version dev-2026-11:" + revision), \
                     mock.patch.object(Path, "is_file", return_value=True), \
                     mock.patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0)) as execute:
                    self.assertEqual(runner["main"](), 0)
                    execute.assert_called_once()
                    self.assertEqual(execute.call_args[0][0][-1], "--version")

    def test_abnormal_analyzer_exit_is_reported_as_analysis_failure(self):
        runner = runpy.run_path(str(PROJECT / "scripts" / "run-odin-lint.py"))
        with tempfile.TemporaryDirectory(dir=PACKAGE_WORK) as temporary:
            lock = Path(temporary) / "odin-lint.lock.json"
            lock.write_text(json.dumps({"repository": "owner/repo", "revision": "0" * 40}), encoding="utf-8")
            for status, expected in ((0, 0), (1, 1), (2, 2), (-9, 2), (247, 2)):
                with self.subTest(status=status), \
                     mock.patch.object(sys, "argv", ["run-odin-lint.py", str(lock)]), \
                     mock.patch("shutil.which", return_value=sys.executable), \
                     mock.patch("subprocess.check_output", return_value="odin version dev-2026-11:9a69916"), \
                     mock.patch.object(Path, "is_file", return_value=True), \
                     mock.patch("subprocess.run", return_value=subprocess.CompletedProcess([], status)), \
                     mock.patch("sys.stderr") as error:
                    self.assertEqual(runner["main"](), expected)
                    output = "".join(call.args[0] for call in error.write.call_args_list)
                    if status == -9:
                        self.assertIn("signal 9", output)
                    elif status == 247:
                        self.assertIn("unexpected status 247", output)
                    else:
                        self.assertEqual(output, "")

    def test_mutable_revision_is_rejected_before_fetching(self):
        with tempfile.TemporaryDirectory(dir=PACKAGE_WORK) as temporary:
            lock = Path(temporary) / "odin-lint.lock.json"
            lock.write_text(json.dumps({"repository": "owner/repo", "revision": "main"}), encoding="utf-8")
            result = subprocess.run([sys.executable, str(PROJECT / "scripts" / "run-odin-lint.py"), str(lock)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("full lowercase 40-character commit SHA", result.stderr)

    @unittest.skipUnless(os.name == "posix", "requires unprivileged symlink creation")
    def test_lock_symlink_loop_is_a_setup_failure(self):
        with tempfile.TemporaryDirectory(dir=PACKAGE_WORK) as temporary:
            lock = Path(temporary) / "loop.json"
            lock.symlink_to(lock.name)
            result = subprocess.run([sys.executable, str(PROJECT / "scripts/run-odin-lint.py"), str(lock)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertIn("odin-lint setup failed:", result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertFalse((lock.parent / ".work").exists())

    def test_excessively_nested_lock_is_a_setup_failure(self):
        with tempfile.TemporaryDirectory(dir=PACKAGE_WORK) as temporary:
            lock = Path(temporary) / "nested.json"
            lock.write_text("[" * 2000 + "0" + "]" * 2000, encoding="utf-8")
            result = subprocess.run([sys.executable, str(PROJECT / "scripts/run-odin-lint.py"), str(lock)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertIn("odin-lint setup failed:", result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertFalse((lock.parent / ".work").exists())


if __name__ == "__main__":
    unittest.main()
