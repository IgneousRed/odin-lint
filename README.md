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
print the shortened `9a69916`). Locally validated on macOS arm64; GitHub CI is
configured for macOS arm64 and Linux amd64. Other hosts are not yet validated.

From a checkout, with Odin and Make installed:

```sh
make build
# Equivalent: mkdir -p .work && odin build src -debug -thread-count:2 -out:.work/odin-lint
.work/odin-lint --help
.work/odin-lint --version
make check
.work/odin-lint --root . src
```

For use in another project, follow [project integration](docs/integration.md).
Its checked-in runner and lock file fetch and build a pinned GitHub revision,
then cache it in the consuming project's `.work/`. No local linter checkout,
installed agent skill, Python packages, or language server is needed. The runner
requires Python 3, Git, and the documented Odin version.

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
.work/odin-lint --root ../example ../example/src
.work/odin-lint --root ../example --source-root app/src/main/odin \
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

Requires Make, Git, Odin, and Python 3's standard library. No Python packages are
installed. Generated artifacts stay in ignored `.work/`.

After editing code here, run `make lint` before completing the change. It runs
applicable Odin compiler checks before freshly-built self-lint of `src` and
`tests`; setup or analysis failure is not a pass. This repository tests the
implementation being developed. GitHub-pinned copies are for consuming projects,
and the distribution runner has independent regression tests in the full suite.

```sh
make check   # Type checks, vet, strict style, warnings as errors
make lint    # Debug build, compiler checks, self-lint of source and Odin tests
make test    # Full Odin/CLI suite, including the isolated consumer bootstrap
make verify  # Required full check before committing
```

Focused tests after a debug build:

```sh
odin test tests -debug -thread-count:2 -define:ODIN_TEST_THREADS=1 \
  -define:ODIN_TEST_RANDOM_SEED=1 -define:ODIN_TEST_NAMES=tests.section_policies \
  -out:.work/odin-lint-tests
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_cli.py' -k compiler
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

## Project documentation

- [Agent instructions](AGENTS.md): project invariants.
- [Project integration](docs/integration.md): pinned installation, CI use, and upgrades.
- [Publishing](docs/publishing.md): first push, release process, and pending decisions.
- [Rules and limitations](docs/rules.md): implemented checks and policy choices.
- [Release notes](docs/releases.md): fixes and diagnostic changes by version.
- [Research and implementation](docs/design.md): primary sources, state guardrails,
  and analysis boundaries.
- [Open work and decisions](notes/TODO.md): remaining coverage and workflow decisions.
- [Rework proposals](notes/REWORKS.md): future simplifications outside active work.

## License and maintenance

Released under the [Zero-Clause BSD license](LICENSE). You may use, copy, modify,
and distribute it for any purpose, with or without a fee. The software is provided
as is, without warranty.

This is a personal tool maintained for the author's own projects. Reproducible bug
reports and small pull requests are welcome; responses, acceptance and future
development are discretionary. Support, continued maintenance and compatibility
with future compiler releases are not promised.

Releases distribute source with fixed version tags. Consumers use the existing
runner and full commit-SHA pins to build the chosen revision. See
[publishing and review policy](docs/publishing.md).
