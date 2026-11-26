# Project integration

## Locked Nix integration

Install Nix once and use the consuming project's `scripts/dev` entrypoint. Keep
the project's existing compiler checks, entry points, collections, defines and
targets. After those gates pass, invoke the packaged native command:

```sh
./scripts/dev odin-lint --root . src
```

The canonical recipe is [nix/package.nix](../nix/package.nix). Copy it unchanged
into the consuming project's Nix definitions as `odin-lint-package.nix`, then
call it with an explicit locked payload and the shared compiler. The recipe may
be newer than the payload: an older published source pin need not contain Nix
files. For example, use this declaration for 0.7.7, replacing the revision and
hash placeholders with the full commit and source NAR hash from its release:

```nix
# nix/odin-lint-source.nix
{ fetchFromGitHub }:
let
  owner = "IgneousRed";
  repo = "odin-lint";
  version = "0.7.7";
  rev = "FULL_40_CHARACTER_COMMIT_SHA";
  hash = "sha256-BASE64_SOURCE_NAR_HASH";
in {
  inherit owner repo version rev hash;
  src = fetchFromGitHub { inherit owner repo rev hash; };
}
```

Wire the source and recipe into the consuming flake:

```nix
lintSource = pkgs.callPackage ./nix/odin-lint-source.nix { };
odinLint = pkgs.callPackage ./nix/odin-lint-package.nix {
  inherit (toolchain) odin;
  inherit (lintSource) src version;
  revision = lintSource.rev;
};
```

Add `odinLint` to the locked development environment's tools. The recipe checks
the compiler identity, runs compiler checks for the linter itself and embeds the
full payload revision. `odin-lint --version` identifies that payload. The native
command runs from any project directory without Python, Git, a source checkout,
or a cache resolver at runtime. Its compiler checks during packaging do not
replace the consuming project's compiler gates.

Package compiler checks and builds use Nix's normalized `NIX_BUILD_CORES` concurrency. Set
the Nix cores option per invocation before the outer environment launcher when
a check-thread limit is required; the setting must cover the initial package
realization, not only a later command. All vet/style/unused checks remain active.
All other compiler and build flags remain unchanged.

Keep the existing payload pin during a setup migration. An explicit upgrade
changes the source revision, fixed hash and version together after review and
affected verification. Derive update metadata directly from `lintSource.rev`
with `kind = "github-release"` and `repository = "IgneousRed/odin-lint"`; do not
maintain a second version list. Run the read-only `scripts/check-deps` before
every commit and report updates without changing locks automatically.

Within odin-lint itself, `./scripts/dev make lint` builds and checks the working
checkout. A released package is never substituted for self-lint.

## Standalone runner compatibility

The checked-in runner and JSON lock remain supported for existing integrations
and independent distribution testing. The runner
fetches an exact GitHub commit, builds a standalone executable, and forwards all
linter arguments and its exit status. It requires Python 3, Git, and Odin
dev-2026-11a (compiler `9a6991685`, sometimes printed as `9a69916`). It uses only
Python's standard library. Select Odin with the `ODIN` environment variable when
it is not on `PATH`. The runner validates the documented compiler identity before
using a cache or fetching source. A different compiler fails setup even if it
could build the code.

No linter checkout elsewhere on the machine, local agent skill, or consuming
project modification outside the integration files is required. The published
GitHub repository is [IgneousRed/odin-lint](https://github.com/IgneousRed/odin-lint).
Public copies require no GitHub credentials. Private forks require authenticated
Git access.

### Install into a project

Run from the consuming project's root. Replace
the revision below with a full, lowercase 40-character published commit SHA. Branches,
tags, short SHAs, and `latest` are deliberately rejected by the runner.

```sh
LINT_REVISION=FULL_40_CHARACTER_COMMIT_SHA
python3 - IgneousRed/odin-lint "$LINT_REVISION" <<'PY'
import json
from pathlib import Path
import re
import sys
import tempfile
from urllib.request import urlopen

repository, revision = sys.argv[1:]
if not re.fullmatch(r'[0-9a-f]{40}', revision):
    raise SystemExit('replace the revision with a full lowercase commit SHA')
Path('.work/package').mkdir(parents=True, exist_ok=True)
staging = Path(tempfile.mkdtemp(prefix='odin-lint-upgrade-', dir='.work/package'))
for name in ('README.md', 'docs/integration.md', 'docs/rules.md', 'scripts/run-odin-lint.py'):
    destination = staging / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    url = f'https://raw.githubusercontent.com/{repository}/{revision}/{name}'
    with urlopen(url) as response:
        destination.write_bytes(response.read())
runner = staging / 'scripts/run-odin-lint.py'
compile(runner.read_text(encoding='utf-8'), str(runner), 'exec')
(staging / 'odin-lint.lock.json').write_text(
    json.dumps({'repository': repository, 'revision': revision}, indent=2) + '\n', encoding='utf-8')
print(staging)
PY
```

Read the staged README, integration guide and rules before adopting or upgrading.
The printed staging directory remains under ignored `.work/`; downloads do not
change the installed runner or lock. After reviewing, substitute that directory
below and install the staged pair:

```sh
python3 - .work/package/odin-lint-upgrade-PRINTED_SUFFIX <<'PY'
import os
from pathlib import Path
import sys

staging = Path(sys.argv[1])
runner, lock = staging / 'scripts/run-odin-lint.py', staging / 'odin-lint.lock.json'
compile(runner.read_text(encoding='utf-8'), str(runner), 'exec')
lock.read_text(encoding='utf-8')  # Both staged files must exist before replacing either.
Path('tools').mkdir(exist_ok=True)
os.replace(runner, 'tools/run-odin-lint.py')
os.replace(lock, 'odin-lint.lock.json')
PY
```

A failed download leaves the installed pair intact. Do not run lint between the
two replacements; review and commit the pair together. The staged documentation
remains available after installation.

Review and commit `tools/run-odin-lint.py` and `odin-lint.lock.json`. Add `.work/`
to the project's `.gitignore`. Keep the lock file in the project root: cache
files default to `.work/odin-lint/` next to it, outside the linter's source graph.

For a private fork, obtain the same pinned files with an authenticated GitHub
client before the staged installation. The runner's subsequent HTTPS Git fetch
uses your configured Git credentials. Never put credentials in the lock file.

## Run compiler checks, then lint

Use the project's actual entry point, collections, defines, and target for Odin
checks. Use maximal compatible compiler vetting on first-party packages. This example
assumes a single-package application named `src` in `src/`:

```sh
odin check src -vet -vet-tabs -vet-using-param -vet-nil-deref \
  -vet-uninitialized -vet-atomic-access -strict-style -warnings-as-errors \
  -vet-unused-procedures -vet-packages:src -strict-style-packages:src
python3 tools/run-odin-lint.py odin-lint.lock.json --root . src
```

A Make target makes the ordering explicit:

```make
.PHONY: check lint
ODIN_VET_FLAGS = -vet -vet-tabs -vet-using-param -vet-nil-deref -vet-uninitialized -vet-atomic-access -strict-style -warnings-as-errors
check:
	odin check src $(ODIN_VET_FLAGS) -vet-unused-procedures -vet-packages:src -strict-style-packages:src

lint: check
	python3 tools/run-odin-lint.py odin-lint.lock.json --root . src
```

For multiple packages, list the actual first-party package names with
`-vet-packages` and `-strict-style-packages`, preserving all target/define
configurations. Run a separate unused-procedure pass scoped to closed application
entry points so another executable's uses or external library APIs are not
misclassified. The pinned compiler reports attributed tests as unused even under
`odin test`; keep those packages under every other vet check. Existing compiler
failures block shared lint and must be reported rather than hidden or weakened.
The analyzer still reads all supplied source. Its configuration-aware lookup proves
explicit source build tags and matching `when` guards; it does not select a host
profile, infer filename/define correlations, or replace any target compiler gate.
Keep unmatched development overlays as analysis uncertainty until their source
conditions or a future explicit integration contract establish the relationship.

Run these commands in the consuming project with its actual toolchain and
dependencies installed. The linter does not install project dependencies or
run compiler checks. For a library, use the appropriate `-no-entry-point` compiler
check. Pass custom mappings separately to the analyzer:

```sh
python3 tools/run-odin-lint.py odin-lint.lock.json \
  --root . --source-root app/src/main/odin \
  --collection ui=vendor/ui-library app/src/main/odin
```

Use a root containing all saved project consumers and complete package siblings.
Public exports remain API boundaries; the linter does not infer that outside
consumers are absent. Private narrowing and declaration-order checks use the saved
reference graph. Missing required inputs remain analysis errors.

Exit statuses are preserved: `0` clean, `1` lint findings, `2` setup, usage,
filesystem, or analysis errors. A network or build failure cannot become a clean
result. The executable itself never fetches tools or invokes Odin.

## Cache and upgrades

The first run fetches the locked source and compiles it in a private temporary
directory, using speed optimization with debug information and bounds checks
retained. The extra compilation cost is paid once per cache entry. Only a
successful binary is atomically installed. The cache key
includes repository, commit, compiler version and executable digest, OS, CPU
architecture, and the runner's build flags.

The runner defaults to two compiler threads. Select a different positive integer
for one invocation with `ODIN_LINT_THREAD_COUNT`; empty values, signs, leading
zeros and non-integers fail setup before compiler/cache access. All other build
flags and compiler identity checks remain fixed:

```sh
ODIN_LINT_THREAD_COUNT=1 python3 tools/run-odin-lint.py odin-lint.lock.json --version
```

The effective thread flag is included in the cache key. Unset and explicit `2`
retain the original cache identity; a different count cannot reuse that binary.
Later runs need no network while that cache exists, but still need Odin to identify
the compiler. Downloaded source is removed after building. Deleting
the selected cache forces a rebuild. Do not cache an executable across different
compiler/host identities under a manually chosen key.

To share compatible binaries across projects and worktrees, set `ODIN_LINT_CACHE`
to an absolute directory in your existing user-owned tool store. For example:

```sh
export ODIN_LINT_CACHE="$HOME/.cache/odin-lint"
python3 tools/run-odin-lint.py odin-lint.lock.json --version
```

The directory is created when absent. With the variable unset or empty, the
runner retains the project-local `.work/odin-lint/` default. Locks and analysis
inputs remain in each project; no cache is required beforehand. Concurrent cold
requests may build separately, but publish only complete binaries without
replacing a winner. The cache filesystem must support hard links within one
directory. Use a directory writable only by trusted users: cached binaries are
executed. A cache error is a setup failure, with no silent fallback or pin change.

```sh
python3 tools/run-odin-lint.py odin-lint.lock.json --version
```

Upgrade deliberately: choose and review a new commit, obtain the runner from
that same commit using the staged installation above, update the lock, and run
the project's full compiler/lint checks. Commit both changes together. Moving
`main` or creating a new release
does not alter a project's pinned behavior. Remove superseded project-local Odin
linters and their exclusive support files during adoption; preserve independent
OLS/editor support and unrelated compiler/runtime/schema/non-Odin checks.

This repository develops the shared linter itself: `./scripts/dev make lint` checks the freshly
built implementation after compiler checks. It does not install a GitHub copy of
itself. The distribution runner is exercised independently by regression tests.

The runner preserves normal clean/finding/analysis statuses (`0`, `1`, `2`). A
child analyzer killed by a signal, or returning another unexpected status, is
reported explicitly as an analysis failure and normalized to `2`. Missing output
from a terminated analyzer is never a clean run. Consumer pins remain unchanged
until an explicit runner-and-lock upgrade.

Compiler gates must match the real build's entry semantics as well as target,
collection and define settings. A check using `-no-entry-point` does not prove an
executable/object build that omits that flag will pass. Keep native/C entry
bridges aligned with the pinned compiler; resolve actual compiler failures before
running policy analysis. Never treat a skipped linter as clean.

The 0.4 consumer upgrade retains all rules while relaxing proved compatibility
conflicts. Preserve platform interface fragments, package ABI names and pure
catalog lookup APIs instead of forcing incompatible application changes. Formal
mutation summaries express caller requirements; review concrete borrowed-call
findings and retain suspected false positives with exact source and compiler
commands for the next review.

## Trusted dependency boundaries

Missing external models and unresolved semantic/configuration evidence do not
produce lint findings or change the exit status. Boundary models add detection;
consumers need no per-library annotations or allowlists. Known violations remain
errors. Missing required collections, unreadable sources and parsing failures
still fail analysis with exit 2; best-effort policy inference never turns a setup
failure into a pass. The retired LINT003/LINT004 and OWN003/OWN004 IDs may remain as zero-count
historical entries in consumer reports. All 27 active rules run. The linter checks
FRP boundaries; it does not check general memory or allocator lifetimes.
