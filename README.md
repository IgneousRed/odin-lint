# odin-lint

Repository: [IgneousRed/odin-lint](https://github.com/IgneousRed/odin-lint).

Shared Odin linter for use across projects. It enforces the coding policies
documented in this repository. It assumes Odin compiler checks have already passed and
uses Odin's standard-library parser to analyze additional project policies. The
linter never invokes the compiler or repeats its syntax, type, vet/style, or
unused-code diagnostics. No OLS installation or third-party library is needed. Catalogs may retain
lookups without known forbidden effects; state and views remain definitions-only.

## Build and use

Requires Odin **dev-2026-11a**, compiler commit `9a6991685` (some distributions
print the shortened `9a69916`). Locally validated on macOS arm64. Verification
runs locally; this repository has no GitHub Actions workflows. Validate other
hosts with their actual compiler and project configuration.

Install **Nix once** before using this checkout or a source archive. On macOS,
install Xcode Command Line Tools as well; the locked Apple Silicon tools require
macOS 26 or later. Fuzzing requires macOS arm64 and
`/usr/bin/sandbox-exec`. The flake also exposes the local compiler/test tools on
Linux x86_64. The required macOS fuzz gate remains separate on that host.

`flake.lock` locks nixpkgs. On Apple Silicon macOS, `nix/llvm23/` supplies the exact
Odin source with LLVM 23.1.6 and rebuilt Python 3.15.2. Linux keeps the existing
`nix/toolchain.nix` recipe with LLVM 22. Nix supplies Make, Git, Python and the
matching LLVM tools. The macOS Git package uses the same rebuilt Python through
the upstream package's interpreter override, preserving its existing features.
There is no dependency on a Homebrew installation or a sibling checkout. The first
command realizes the locked environment; later commands reuse the Nix store:

```sh
./scripts/dev make build
.work/build/odin-lint --help
.work/build/odin-lint --version
./scripts/dev make check
.work/build/odin-lint --root . src
```

The ordinary environment excludes fuzzer tooling. `make fuzz` completes its
compiler/self-lint prerequisite, then selects the optional macOS environment
through `scripts/dev --profile fuzz`. Direct exploration requires that profile;
compiler-only preparation remains available in the ordinary environment. See
[fuzzing](docs/fuzzing.md) for the source pin and required gate.

For use in another project, follow [project integration](docs/integration.md).
Nix consumers package an exact source revision and run the native `odin-lint`
command after their compiler gates. The standalone runner and JSON lock remain
available for existing integrations. No installed agent skill, Python packages,
or language server is needed by the native executable.

`scripts/dev` works from a checkout or exported source archive. It stages only
the tracked setup inputs listed in `nix/source-files` and the Nix definitions,
runs in the original project directory, and holds the selected environment while
the command runs. `.work/nix/environment` retains the most recently selected
environment. Generated outputs, old results and caches are excluded from Nix
source snapshots and are left in place.

For evaluation without realizing tools, use the same declared-input stage:

```sh
./scripts/dev --eval packages.aarch64-darwin.dev-environment.drvPath --raw --option allow-import-from-derivation false
```

Use this entrypoint for project evaluation so ignored local data stays outside
the Nix source snapshot.

Every active lint rule always runs: source-role boundaries, local code policies,
visibility narrowing, alias section organization, declaration ordering,
FRP state boundaries, file organization, and single-use procedure inlining errors. Inlining
checks include package-private procedures, resolve stable aliases, and have
no procedure-size limit. Lint findings go to stderr as
`path(line:column): RULE: message`. Exit status is `0` for clean input, `1` for
lint findings, and `2` for usage, filesystem, or analysis errors. Analysis errors
take precedence over lint findings; unparseable source is an analysis error,
not a syntax lint.

Dependency checks retain the `catalog`, `state`, `views`, `functions`, `engine`,
`procedures`, `effects`, `ui`, `application`, and pure `migrations` responsibilities.
Resolved calls and aliases support FRP guardrails: known effects, protected-state
writes, engine/local transaction scopes and source-proved publication preconditions. Private
working copies remain writable, and published catalogs stay read-only. A catalog
type alone does not imply published storage; global catalog storage does.

This is an architecture linter. It does not check general use-after-free,
allocator resets, scratch-buffer escape or object lifetimes, and does not assume
thread arguments are exclusively transferred. `OWN003`/`OWN004` and the older
uncertainty-only `LINT003`/`LINT004` are retired; all 27 active rules run. Unknown
dependency behavior remains silent and nonblocking. See
[rules and limitations](docs/rules.md).

For another project, run its compiler checks first with the appropriate entry
point, collections, defines, and target. Then supply its root and scan paths.
All supplied source remains in the analysis. Explicit build tags and matching
`when` guards can resolve exclusive alternatives together; unresolved overlays
remain uncertainty rather than silently selecting one platform.
Paths other than `--source-root` are relative to the current working directory:

```sh
.work/build/odin-lint --root ../example ../example/src
.work/build/odin-lint --root ../example --source-root app/src/main/odin \
  --collection ui=../ui-library ../example/app/src/main/odin
```

With no scan paths, the command scans the source root. Explicit scan paths may
be files or directories. Traversal skips hidden entries, `vendor` entries, and
symlinks. Explicit symlinks and non-Odin files are errors. Empty directories are
clean. Accepted files are deduplicated by canonical path, retaining the lexically
first selected spelling for diagnostics when several aliases name the same file.
Reference analysis also reads saved project `.odin` sources under `--root` and
complete sibling packages for selected files outside the root. This supplies
consumer and imported-type evidence for narrowing, alias sections, and state provenance;
diagnostics remain limited to selected files. Hidden/vendor entries are excluded
from ordinary traversal; explicitly mapped imported packages and complete siblings
may supply analysis-only evidence, including beneath vendor.
Directory aliases are recorded for import identity while traversal skips them.
Unreadable or unparseable analysis sources, or symlinked Odin files, make analysis
fail rather than permitting incomplete use-count claims. Project-root scope does
not include consumers in other repositories.
Supply `--collection NAME=DIR` for active custom imports in the project graph,
including analysis-only consumers. These mappings are separate from the flags used for the preceding compiler check.

File organization requires one logical interface family per package, with
build-conditioned native/web fragments where their imports differ. Executable
and imported-namespace package names may differ from directory names when needed
for compiler/ABI compatibility. Ordinary public declarations stay in the interface
family. Helpers have no special
`shared.odin` convention. A visibility used by at least 60% of declarations takes
precedence over filename-based defaults; otherwise interfaces default to Public
and helpers to File. Private support for anchored interface declarations may
remain with its callers; helper relocation advice preserves dependency closure.
Default changes must preserve minority visibility. A private default cannot keep
public exports through an attribute, so mixed interfaces may require a
visibility-preserving reorganization with their private dependency closure.
An irreducible file-private support majority may retain the necessary Public
default so the rule does not demand an impossible directive change.

There are no rule enable/disable options. Sections are required for imports and
declarations, including in files without existing headers. The analyzer detects
kind-first or visibility-first layouts and defaults to kind-first when no layout
is present. See [rules and limitations](docs/rules.md) for applicability and
analysis limits.

## Verification

Run verification through `scripts/dev` to select the locked tools. Python tooling
uses the standard library. Generated artifacts stay in ignored `.work/`.

After editing code here, run `./scripts/dev make lint` before completing the change. It runs
applicable Odin compiler checks before freshly-built self-lint of `src` and
`tests`; setup or analysis failure is not a pass. This repository tests the
implementation being developed. GitHub-pinned copies are for consuming projects,
and the distribution runner has independent regression tests in the full suite.

```sh
./scripts/dev make check   # Type checks, vet, strict style, warnings as errors
./scripts/dev make lint    # Debug build, compiler checks, self-lint of source and Odin tests
./scripts/dev make test    # Full Odin/CLI suite, including the isolated consumer bootstrap
./scripts/dev make verify # Full compiler, self-lint and correctness suite
./scripts/dev make precommit # Dependency update check, full verification and macOS fuzzing
```

Before **every commit**, run `./scripts/check-deps` (also the first step of
`precommit`). It reports newer dependency versions without changing any lock.
Current versions come from the Nix definitions and lock. A failed network check
is a failed check. Review upgrades explicitly; an available update alone does
not change the selected toolchain.

Version queries evaluate metadata and reuse an already realized preferred
locked Python when declared. Otherwise they use the pinned public bootstrap
Python, downloading only its binary closure when absent. They do not realize
the preferred interpreter, development environment or SDKs. See the
[lean checker interface](docs/dependency-check.md) for setup and consumer wiring.

Focused tests after a debug build:

```sh
./scripts/dev odin test tests -debug -thread-count:2 -define:ODIN_TEST_THREADS=1 \
  -define:ODIN_TEST_RANDOM_SEED=1 -define:ODIN_TEST_NAMES=tests.section_policies \
  -out:.work/build/odin-lint-tests
./scripts/dev python3 -m unittest discover -s tests -p 'test_cli.py' -k compiler
```

Compiler checks use maximal compatible vetting on first-party packages:
`-vet -vet-tabs -vet-using-param -vet-nil-deref -vet-uninitialized
-vet-atomic-access -strict-style -warnings-as-errors`. The Makefile scopes vet
and strict style to this repository's packages. It additionally checks unused
procedures in the closed CLI packages `src,effects,state`; the public analysis
API in `functions` has test consumers. Do not apply unused-procedure checks to
attributed test entry points: this compiler incorrectly calls them unused even
under `odin test`. All other vet checks still cover those sources.

`SIMPLIFY001` says `inline NAME: one call within the package` and remains an
error contributing to exit `1`; its eligibility conditions are unchanged.

Compiler invocations default to two worker threads. Odin tests use one worker,
a fixed seed, and fail on memory-tracker errors. Tests assert correctness and
diagnostics, with no timings, throughput benchmarks, or performance thresholds.

See [fuzzing](docs/fuzzing.md) for LLVM setup, isolated input projects, persistent
corpus storage and the required precommit fuzz gate.

## Project documentation

- [Project integration](docs/integration.md): pinned installation, local checks, and upgrades.
- [Publishing](docs/publishing.md): source releases, verification, and participation policy.
- [Rules and limitations](docs/rules.md): implemented checks and policy choices.
- [Release notes](docs/releases.md): fixes and diagnostic changes by version.
- [Research and implementation](docs/design.md): primary sources, state guardrails,
  and analysis boundaries.

## License and maintenance

Released under the [Zero-Clause BSD license](LICENSE). You may use, copy, modify,
and distribute it for any purpose, with or without a fee. The software is provided
as is, without warranty.

This is a personal tool maintained for the author's own projects. Reproducible bug
reports and small pull requests are welcome; responses, acceptance and future
development are discretionary. Support, continued maintenance and compatibility
with future compiler releases are not promised.

Releases distribute source with fixed version tags. Consumers use full commit-SHA
pins and fixed source hashes with Nix, or the standalone runner, to build the chosen revision. See
[publishing and review policy](docs/publishing.md).

## Local storage

Generated binaries and debug bundles live under `.work/build/`; temporary package
and independent-distribution staging belongs under `.work/package/`. These are
reproducible outputs, not retained release archives. The standalone consumer
runner keeps its documented `.work/odin-lint/` cache contract.

The public checkout and source export need no private or local records. Reserved
`.private/`, `.local/`, `.vendor/` and `.work/` directories are excluded from publication.
Persistent dependency sources/Nix views belong under `.vendor/` when needed; their
pinned fetch/checksum/license/patch definitions remain public. Do not create an
empty cache or change the legacy runner cache contract just to add this folder.
Only minimal synthetic/anonymized test inputs may be retained; consumer source,
identifying paths and business data do not belong in this project. See
[publishing](docs/publishing.md) for the outgoing-history and publication audit.
