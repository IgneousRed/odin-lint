"""Consumer bootstrap checks using an isolated Git remote and real compiler."""

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

from test_cli import BINARY, PROJECT, section


class DistributionTests(unittest.TestCase):
    def test_version_does_not_require_project_sources(self):
        result = subprocess.run([str(BINARY), "--root", "/missing-project", "--version"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"odin-lint {PROJECT.joinpath('VERSION').read_text().strip()} (", result.stdout)
        self.assertEqual(result.stderr, "")

    @unittest.skipUnless(os.name == "posix", "deleting a working directory requires POSIX")
    def test_help_and_version_do_not_require_a_live_working_directory(self):
        with tempfile.TemporaryDirectory(dir=PROJECT / ".work") as temporary:
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
        with tempfile.TemporaryDirectory(dir=PROJECT / ".work") as temporary:
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
            environment = {**os.environ, "GIT_CONFIG_COUNT": "1",
                           "GIT_CONFIG_KEY_0": f"url.{remote.as_uri()}.insteadOf",
                           "GIT_CONFIG_VALUE_0": "https://github.com/odin-lint-test/odin-lint.git",
                           "GIT_TERMINAL_PROMPT": "0", "PYTHONDONTWRITEBYTECODE": "1"}
            command = [sys.executable, str(runner), str(lock)]
            built = subprocess.run([*command, "--version"], cwd=consumer, env=environment, capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            self.assertIn(f"({revision})", built.stdout)
            self.assertIn("Building odin-lint", built.stderr)
            self.assertEqual(len(list((consumer / ".work" / "odin-lint").iterdir())), 1)
            shutil.rmtree(remote)
            subprocess.run([os.environ.get("ODIN", "odin"), "check", "src", "-thread-count:2",
                            "-vet", "-strict-style", "-warnings-as-errors"], cwd=consumer, check=True)
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
            self.assertEqual(len(list((consumer / ".work" / "odin-lint").iterdir())), 1)

    def test_compiler_pin_is_enforced_before_cache_or_git_use(self):
        runner = runpy.run_path(str(PROJECT / "scripts" / "run-odin-lint.py"))
        with tempfile.TemporaryDirectory(dir=PROJECT / ".work") as temporary:
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
        with tempfile.TemporaryDirectory(dir=PROJECT / ".work") as temporary:
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
        with tempfile.TemporaryDirectory(dir=PROJECT / ".work") as temporary:
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
        with tempfile.TemporaryDirectory(dir=PROJECT / ".work") as temporary:
            lock = Path(temporary) / "odin-lint.lock.json"
            lock.write_text(json.dumps({"repository": "owner/repo", "revision": "main"}), encoding="utf-8")
            result = subprocess.run([sys.executable, str(PROJECT / "scripts" / "run-odin-lint.py"), str(lock)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("full lowercase 40-character commit SHA", result.stderr)


if __name__ == "__main__":
    unittest.main()
