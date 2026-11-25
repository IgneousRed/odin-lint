"""Prepare and explore the current implementation through its real CLI."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import shlex
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".work" / "fuzz"
CORPUS = ROOT / ".local" / "fuzz" / "corpus"
STORE = Path("/nix/store")


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def locked_setup(require_fuzzer):
    try:
        selected = os.environ.get("PROJECT_NIX_ENVIRONMENT", "")
        if not selected or not Path(selected).is_absolute():
            raise ValueError("no selected Nix environment")
        environment = Path(selected).resolve(strict=True)
        if environment.parent != STORE:
            raise ValueError("the selected environment is outside the Nix store")
        host = (sys.platform, platform.machine().lower())
        systems = {("darwin", "arm64"): "aarch64-darwin",
                   ("darwin", "aarch64"): "aarch64-darwin",
                   ("linux", "x86_64"): "x86_64-linux"}
        if host not in systems:
            raise ValueError("no locked environment for this host")
        exported = {name: os.environ[name] for name in
                    ("HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "TZ", "TERM", "REVISION", "ODIN_FLAGS")
                    if name in os.environ}
        exported["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        profiles = ["fuzz"] if require_fuzzer else ["dev", "fuzz"]
        for profile in profiles:
            evaluation = subprocess.run(
                [str(ROOT / "scripts" / "dev"), "--eval",
                 "packages." + systems[host] + "." + profile + "-environment.outPath",
                 "--raw", "--offline", "--option", "allow-import-from-derivation", "false"],
                text=True, capture_output=True, env=exported)
            if not evaluation.returncode and evaluation.stdout.strip() == str(environment):
                break
        else:
            raise ValueError("the selected environment does not match this checkout's Nix definitions")
        manifest = json.loads((environment / "share" / "project-environment.json").read_text())
        variables, unset = manifest["variables"], manifest["unset"]
        if (type(manifest["schema"]) is not int or manifest["schema"] != 1
                or not isinstance(variables, dict) or not isinstance(unset, list)
                or any(not isinstance(value, str) for value in variables.values())):
            raise ValueError("invalid locked environment manifest")
        for name, executable in [("ODIN", "odin")] + ([("ODIN_FUZZ", "odin-fuzz")] if require_fuzzer else []):
            path = Path(variables[name])
            resolved = path.resolve(strict=True)
            if (not path.is_absolute() or STORE not in resolved.parents
                    or resolved != (environment / "bin" / executable).resolve(strict=True)
                    or not path.is_file() or not os.access(path, os.X_OK)):
                raise ValueError("the locked " + executable + " executable is unavailable")
        exported.update(variables)
        for name in unset:
            exported.pop(name, None)
        exported["PATH"] = os.pathsep.join((str(environment / "bin"), "/usr/bin", "/bin", "/usr/sbin", "/sbin"))
        exported["PROJECT_ROOT"] = str(ROOT)
        exported["PROJECT_NIX_ENVIRONMENT"] = str(environment)
        return exported
    except (OSError, ValueError, TypeError, KeyError) as error:
        raise SystemExit("Locked fuzz dependency setup unavailable: " + str(error)
                         + ". Use ./scripts/dev make fuzz for exploration or ./scripts/dev make fuzz-prepare for preparation.") from error


def source_revision(environment):
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                       text=True, stderr=subprocess.DEVNULL, env=environment).strip()
    except (OSError, subprocess.CalledProcessError):
        return environment.get("REVISION", "unknown")


def prepare(environment):
    target = WORK / "target"
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)
    shutil.copytree(ROOT / "src", target / "src")
    for name in ("VERSION", "odin-fuzz.json"):
        shutil.copy2(ROOT / name, target / name)
    for fixture in sorted((ROOT / "tests" / "fuzz").glob("*.json")):
        for relative, text in json.loads(fixture.read_text()).items():
            path = target / "inputs" / fixture.stem / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
    odin = environment["ODIN"]
    flags = ["-vet", "-vet-tabs", "-vet-using-param", "-vet-nil-deref",
             "-vet-uninitialized", "-vet-atomic-access", "-strict-style",
             "-warnings-as-errors", "-no-entry-point",
             *shlex.split(environment.get("ODIN_FLAGS", "-thread-count:2"))]
    for project in sorted((target / "inputs").iterdir()):
        collections = ["-collection:fixture=" + str(project / "vendor" / "fixture")] if project.name == "collections" else []
        for directory in sorted({p.parent for p in project.rglob("*.odin")}):
            run(odin, "check", directory, *flags, *collections, env=environment)
            if project.name == "conditions":
                run(odin, "check", directory, *flags, "-define:FUZZ_BRANCH=false", env=environment)
    return target


def summary_complete(summary, expected):
    applications = summary.get("applications", [])
    identities = [(app.get("name"), app.get("path")) for app in applications]
    required = [(app["name"], app["path"]) for app in expected]
    return (summary.get("status") == "ok" and summary.get("finding_count") == 0
            and bool(required) and len(set(identities)) == len(identities)
            and set(identities) == set(required) and all(
                app.get("status") == "explored"
                and app.get("coverage_mode") == "llvm_sancov"
                and app.get("executions", 0) > 0
                and app.get("first_party_edges_hit", 0) > 0
                and app.get("workspace_errors") == 0
                and app.get("finding_count") == 0 for app in applications))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--budget", type=float, default=60)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    if not math.isfinite(args.budget) or args.budget <= 0:
        parser.error("--budget must be finite and greater than zero")
    environment = locked_setup(not args.prepare_only)
    target = prepare(environment)
    if args.prepare_only:
        return 0
    if sys.platform != "darwin":
        raise SystemExit("The required fuzz gate runs on macOS; obtain matching local macOS verification on other hosts.")
    tool = environment["ODIN_FUZZ"]
    run(tool, "doctor", env=environment)
    source_hashes = {str(p.relative_to(target)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in sorted(target.rglob("*")) if p.is_file()}
    identity = {"version": (target / "VERSION").read_text().strip(),
                "revision": source_revision(environment),
                "odin_fuzz_executable": tool, "project_nix_environment": environment["PROJECT_NIX_ENVIRONMENT"],
                "budget": args.budget, "seed": args.seed,
                "flake_lock_sha256": hashlib.sha256((ROOT / "flake.lock").read_bytes()).hexdigest(),
                "driver_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "target_sha256": source_hashes}
    expected = json.loads((target / "odin-fuzz.json").read_text())["applications"]
    output = WORK / "runs"
    before = set(output.glob("runs/*/summary.json"))
    with tempfile.NamedTemporaryFile(mode="w", prefix="explore-", suffix=".log",
                                     dir=WORK, delete=False) as log:
        result = subprocess.run([tool, "explore", str(target),
                                 "--work-dir", str(output), "--corpus-dir", str(CORPUS),
                                 "--budget", str(args.budget), "--seed", str(args.seed)],
                                stdout=log, stderr=subprocess.STDOUT, env=environment)
    summaries = set(output.glob("runs/*/summary.json")) - before
    if len(summaries) != 1:
        raise SystemExit("Fuzz run did not produce exactly one safe summary; verification failed.")
    summary_path = summaries.pop()
    summary = json.loads(summary_path.read_text())
    complete = summary_complete(summary, expected)
    run(ROOT / "scripts" / "retain-nix-environment", summary_path.parent / "nix-environment", env=environment)
    identity.update(process_exit=result.returncode, gate_passed=result.returncode == 0 and complete)
    summary_path.with_name("verification.json").write_text(json.dumps(identity, indent=2) + "\n")
    print("Fuzz summary:", summary_path, flush=True)
    if result.returncode:
        return result.returncode
    if not complete:
        raise SystemExit("Fuzz gate failed; inspect summary.json only and request designated detailed triage.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
