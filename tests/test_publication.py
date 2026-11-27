"""Publication checks include intermediate commits, not only a cleaned final tree."""

from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
GUARD = runpy.run_path(str(PROJECT / "scripts/publication-guard.py"))


class PublicationTests(unittest.TestCase):
    def test_scopes_reject_reserved_and_unknown_paths(self):
        allowed = GUARD["allowed"]
        for private, accepted in ((False, ("src/functions/main.odin", "tests/fuzz/aliases.json",
                                          "nix/llvm23/upstream/manifest.json")),
                                  (True, ("todo/proposal.md", "experiments/graphs/README.md"))):
            for path in accepted:
                self.assertTrue(allowed(path, private), path)
            for path in (".work/data.md", ".local/data.json", ".private/notes.md", ".vendor/input.md",
                         "experiments/.local/data.json", "unknown/input.md", "src/program.zip",
                         "nix/llvm23/upstream/unreviewed.json", "nix/unreviewed.json"):
                self.assertFalse(allowed(path, private), path)
        self.assertFalse(allowed("todo/proposal.md"))
        self.assertFalse(allowed("src/main.odin", True))
        for path in ("AGENTS.md", "docs/AGENTS.md", "src/functions/AGENTS.md"):
            self.assertFalse(allowed(path), path)
        self.assertTrue(allowed("instructions/AGENTS.md", True))
        self.assertTrue(allowed("instructions/src/functions/AGENTS.md", True))

    def test_outgoing_refs_are_an_explicit_allowlist_not_all_local_refs(self):
        allowed = GUARD["outgoing_allowed"]
        self.assertTrue(allowed("refs/heads/main", "refs/heads/main"))
        self.assertTrue(allowed("refs/tags/v0.7.7", "refs/tags/v0.7.7"))
        self.assertTrue(allowed("refs/heads/main", "refs/heads/main", True))
        for name in ("refs/t3/local-recovery", "refs/original/main", "refs/backup/main",
                     "refs/heads/unapproved", "refs/tags/unapproved", "refs/tags/v0.7.6"):
            self.assertFalse(allowed(name, name))
            self.assertFalse(allowed(name, "refs/heads/main"))
        self.assertFalse(allowed("refs/tags/v0.7.7", "refs/tags/v0.7.7", True))

    def test_forbidden_outgoing_ref_fails_before_reading_its_ancestry(self):
        main = GUARD["main"]
        with mock.patch("sys.argv", ["guard", "--local-ref", "refs/t3/local-recovery",
                                      "--remote-ref", "refs/heads/main"]), \
             mock.patch.dict(main.__globals__, git=mock.Mock()) as namespace:
            with self.assertRaisesRegex(ValueError, "unapproved outgoing ref"):
                main()
            namespace["git"].assert_not_called()

    def test_intermediate_blob_is_checked_even_after_removal(self):
        with tempfile.TemporaryDirectory(dir=PROJECT / ".work") as temporary:
            root = Path(temporary)
            def git(*args):
                return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.DEVNULL)
            git("init", "-q")
            git("config", "user.name", "Publication Test")
            git("config", "user.email", "publication@example.invalid")
            git("config", "commit.gpgsign", "false")
            (root / "README.md").write_text("public\n")
            git("add", ".")
            git("commit", "-qm", "Base")
            base = git("rev-parse", "HEAD").decode().strip()
            (root / ".local").mkdir()
            (root / ".local/data.md").write_text("not for upload\n")
            git("add", ".")
            git("commit", "-qm", "Intermediate")
            intermediate = git("rev-parse", "HEAD").decode().strip()
            git("rm", "-qr", ".local")
            git("commit", "-qm", "Remove")
            for old_base in (base, intermediate):
                with self.subTest(base=old_base), self.assertRaisesRegex(ValueError, "unapproved publication path"):
                    GUARD["audit"](str(root), "HEAD", old_base)


if __name__ == "__main__":
    unittest.main()
