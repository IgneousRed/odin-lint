"""Check complete proposed Git ancestry against the publication path whitelist.

This is a local guard, not a content-anonymization proof. Review content and all
outgoing refs when material changes visibility, including historical copied blobs.
"""

import argparse
from pathlib import PurePosixPath
import subprocess
import sys


PUBLIC_ROOTS = {".gitattributes", ".gitignore", "LICENSE", "Makefile",
                "README.md", "VERSION", "flake.nix", "flake.lock", "odin-fuzz.json"}
PUBLIC_DIRECTORIES = {
    ".githooks": {""}, "docs": {".md"}, "src": {".odin"},
    ".github": {".yml", ".yaml"},
    "tests": {".odin", ".py", ".json"}, "scripts": {"", ".py"},
    "nix": {"", ".nix", ".md", ".py", ".patch"},
}
PRIVATE_ROOTS = {"README.md", ".gitignore"}
PRIVATE_DIRECTORIES = {"todo": {".md"}, "reworks": {".md"}, "experiments": {".md", ".json"},
                       "instructions": {".md"}}
RESERVED = {".private", ".local", ".work", ".vendor", ".git"}
PUBLIC_REFS = {"refs/heads/main", "refs/tags/v0.7.7"}


def outgoing_allowed(local_ref, remote_ref, private=False):
    approved = {"refs/heads/main"} if private else PUBLIC_REFS
    return local_ref == remote_ref and remote_ref in approved


def git(repository, *args):
    return subprocess.check_output(["git", "-C", repository, *args])


def allowed(path, private=False):
    parts = PurePosixPath(path).parts
    if (not parts or path.startswith("/") or any(p in RESERVED or p in (".", "..") for p in parts)):
        return False
    if not private and "AGENTS.md" in parts:
        return False
    roots = PRIVATE_ROOTS if private else PUBLIC_ROOTS
    directories = PRIVATE_DIRECTORIES if private else PUBLIC_DIRECTORIES
    return (len(parts) == 1 and path in roots or len(parts) > 1
            and PurePosixPath(path).suffix in directories.get(parts[0], set()))


def audit(repository, head, base=None, private=False):
    # A clean final tree/range must not hide reclassified material in its ancestry.
    # Accept the old base argument for existing hooks, but never exclude ancestors.
    commits = git(repository, "rev-list", head).decode().splitlines()
    seen = set()
    for commit in commits:
        for entry in git(repository, "ls-tree", "-rz", "--full-tree", commit).split(b"\0"):
            if not entry:
                continue
            metadata, raw_path = entry.split(b"\t", 1)
            mode, kind, oid = metadata.decode().split()
            path = raw_path.decode("utf-8", errors="strict")
            if (not allowed(path, private) or kind != "blob"
                    or mode not in ("100644", "100755")):
                raise ValueError("unapproved publication path/type: " + path + " at " + commit)
            if oid not in seen:
                blob = git(repository, "cat-file", "blob", oid)
                if b"\0" in blob or len(blob) > 4 * 1024 * 1024:
                    raise ValueError("unexpected binary/large publication blob: " + path)
                seen.add(oid)
    return len(commits), len(seen)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default=".")
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--private", action="store_true")
    parser.add_argument("--local-ref")
    parser.add_argument("--remote-ref")
    args = parser.parse_args()
    if args.local_ref is not None or args.remote_ref is not None:
        if not outgoing_allowed(args.local_ref, args.remote_ref, args.private):
            raise ValueError("unapproved outgoing ref: " + str(args.local_ref) + " -> " + str(args.remote_ref))
        if args.head == "0" * 40:
            print("Approved outgoing ref deletion; no source ancestry to upload.")
            return
    base = None if args.base == "0" * 40 else args.base
    commits, blobs = audit(args.repository, args.head, base, args.private)
    print(f"Publication paths passed: {commits} commits, {blobs} distinct blobs. Content review remains required.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, UnicodeError, subprocess.CalledProcessError) as error:
        print("Publication refused: " + str(error), file=sys.stderr)
        raise SystemExit(2)
