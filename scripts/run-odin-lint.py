#!/usr/bin/env python3
"""Fetch/build a locked GitHub revision, then forward arguments and exit status."""

import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

BUILD_FLAGS = ("-debug", "-o:speed", "-thread-count:2")


def main():
    if len(sys.argv) < 2:
        print("usage: run-odin-lint.py LOCK_FILE [LINTER_ARGUMENT ...]", file=sys.stderr)
        return 2
    try:
        lock_path = Path(sys.argv[1]).resolve()
    except RuntimeError as error:  # Older pathlib versions use this for symlink loops.
        raise ValueError(f"cannot resolve lock file: {error}") from error
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
    except RecursionError as error:
        raise ValueError("lock file JSON nesting is too deep") from error
    repository, revision = lock["repository"], lock["revision"]
    if not isinstance(repository, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*", repository):
        raise ValueError("repository must be a GitHub OWNER/REPO")
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("revision must be a full lowercase 40-character commit SHA")
    build_flags = BUILD_FLAGS
    thread_count = os.environ.get("ODIN_LINT_THREAD_COUNT")
    if thread_count is not None:
        if not re.fullmatch(r"[1-9][0-9]*", thread_count):
            raise ValueError("ODIN_LINT_THREAD_COUNT must be a positive integer without leading zeros")
        build_flags = (*(flag for flag in BUILD_FLAGS if not flag.startswith("-thread-count:")),
                       "-thread-count:" + thread_count)
    odin = shutil.which(os.environ.get("ODIN", "odin"))
    if odin is None:
        raise ValueError("Odin is required; install the documented version or set ODIN to its executable")
    odin = str(Path(odin).resolve())
    compiler = subprocess.check_output([odin, "version"], text=True).strip()
    if not re.search(r"(?:^|\s)version\s+[^\s:]+:9a69916(?:85)?$", compiler):
        raise ValueError("Odin dev-2026-11a compiler 9a6991685 (or 9a69916) is required; found " + compiler)
    compiler_hash = hashlib.sha256()
    with open(odin, "rb") as executable:
        for chunk in iter(lambda: executable.read(1024 * 1024), b""):
            compiler_hash.update(chunk)
    identity = "\n".join((repository, revision, compiler, compiler_hash.hexdigest(),
                          sys.platform, platform.machine(), *build_flags))
    key = hashlib.sha256(identity.encode()).hexdigest()
    cache_root = os.environ.get("ODIN_LINT_CACHE")
    cache = Path(cache_root) if cache_root else lock_path.parent / ".work" / "odin-lint"
    if cache_root and not cache.is_absolute():
        raise ValueError("ODIN_LINT_CACHE must be an absolute directory path")
    cache.mkdir(parents=True, exist_ok=True)
    binary = cache / (key + (".exe" if os.name == "nt" else ""))
    if not binary.is_file():
        print(f"Building odin-lint from {repository}@{revision}", file=sys.stderr)
        # Private temporary sources never enter the consumer's project graph.
        # Only a successful build is atomically published into the cache.
        with tempfile.TemporaryDirectory(prefix="build-", dir=cache) as temporary:
            source = Path(temporary) / "source"
            subprocess.run(["git", "init", "--quiet", str(source)], check=True, stdout=sys.stderr)
            subprocess.run(["git", "-C", str(source), "fetch", "--quiet", "--depth=1", "--no-tags",
                            "--", f"https://github.com/{repository}.git", revision], check=True, stdout=sys.stderr)
            subprocess.run(["git", "-C", str(source), "checkout", "--quiet", "--detach", "FETCH_HEAD"],
                           check=True, stdout=sys.stderr)
            actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
            if actual != revision:
                raise ValueError(f"fetched revision {actual} does not match {revision}")
            built = Path(temporary) / binary.name
            subprocess.run([odin, "build", "src", *build_flags,
                            f"-define:ODIN_LINT_REVISION={revision}", f"-out:{built}"],
                           cwd=source, check=True, stdout=sys.stderr)
            try:
                # Same-filesystem linking publishes the complete binary without
                # replacing a concurrent winner or an executable already in use.
                os.link(built, binary)
            except FileExistsError:
                pass
    status = subprocess.run([str(binary), *sys.argv[2:]]).returncode
    if status < 0:
        print(f"odin-lint analysis failed: analyzer terminated by signal {-status}", file=sys.stderr)
        return 2
    if status not in (0, 1, 2):
        print(f"odin-lint analysis failed: analyzer exited with unexpected status {status}", file=sys.stderr)
        return 2
    return status


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"odin-lint setup failed: {error}", file=sys.stderr)
        sys.exit(2)
