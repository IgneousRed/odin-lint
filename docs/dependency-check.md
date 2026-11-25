# Read-only dependency updates

Run `./scripts/check-deps` before every commit. It evaluates the current locked
metadata and runs the checker with a declared locked Python. It needs
neither a realized development environment nor an SDK. Network errors remain
failed checks, and available updates never change source pins or locks.

Optional `GITHUB_TOKEN`/`GH_TOKEN` authentication is limited to the HTTPS GitHub API
origin. Same-origin redirects preserve it; crossing an origin drops authorization
and later redirects do not reattach it, even when returning to the API origin.

The helper uses the canonical `scripts/dev --eval` staging path with
import-from-derivation disabled. If the optional preferred Python is already
executable and registered in the Nix store, it uses that interpreter. Otherwise,
it reuses the declared public bootstrap Python, downloading only that
derivation's `out` closure from the binary cache when absent.
Local and remote source builds are disabled. An unavailable binary fails
explicitly, with no fallback to a full environment or ambient interpreter.

Each invocation holds its own temporary GC root until the checker exits. After
a successful report, Nix atomically updates `.work/nix/check-deps-python` to the
interpreter that ran the check. Failed reports preserve the previous cache root;
another invocation's lifetime root remains intact during a switch.

## Consumer API

Copy `scripts/check-deps` and `scripts/check-deps.py` unchanged. For each supported
system, export these attributes from the consuming flake:

```nix
lib.dependencyCheck.${system} =
  let interpreter = pkgs.python315;
  in {
    inherit interpreter;
    python = "${interpreter}/bin/python3";
    preferredPython = "${toolchain.python}/bin/python3"; # Optional.
    metadata = updates;
  };
```

Derive `python` from the same pinned public bootstrap `interpreter`. Choose one
with a binary substitute: the checker never builds it from source. The optional
`preferredPython` also comes from the locked Nix definitions and may select a
locally rebuilt interpreter that shares the project's compiler closure. The
checker never realizes this preferred derivation. Existing APIs without
`preferredPython` continue to use `python` and `interpreter`.

Keep the bootstrap derivation in this evaluation API, outside the development
environment's runtime manifest and package paths. An older compiler retained by
the bootstrap Python remains a dependency of its cache roots until those roots
have switched successfully; merely declaring the preferred interpreter does not
remove it.

`updates` is the same evaluated
`{ schema = 1; dependencies = [...]; }`
value already used for `share/dependency-updates.json`. Export the attribute set
directly, retaining current values derived from existing Nix definitions and
locks. No second version file, package realization or metadata-file derivation
is needed for this check.

Existing commands and flags remain valid:

```sh
./scripts/check-deps
./scripts/check-deps --json
```

The shell helper passes evaluated JSON through stdin with `--metadata-stdin`.
Direct callers of `check-deps.py` without that flag still read
`$PROJECT_NIX_ENVIRONMENT/share/dependency-updates.json`. The checker retains its
read-only behavior and exit codes: `0` for a completed report, including available
updates, and `2` for unavailable, malformed or unsupported checks.
