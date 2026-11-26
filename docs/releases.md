# Release notes

## Unreleased

Updates the optional pinned fuzzer to odin-fuzz 0.5.0 and forwards its supported
positive target compiler thread count through `FUZZ_THREADS` or the direct
driver's `--thread-count`. Verification records retain the selected count.

The standalone runner accepts `ODIN_LINT_THREAD_COUNT` for positive per-invocation
selection. Its default remains two threads, with all other compiler flags and
checks unchanged. Cache identity includes the actual selected flag; the default
retains its existing key while other counts cannot reuse incompatible entries.
The canonical Nix recipe uses its already-validated `NIX_BUILD_CORES` for the
build as well as both compiler checks, preserving every other compiler flag.
The required Odin compiler, lint policy and native CLI are unchanged. Existing
release tags and consumer pins remain fixed until an explicit source upgrade.

## 0.7.7 — 2026-11-25

Publishes a fresh source snapshot without prior ancestry or historical release
tags. Agent instructions remain private and are excluded from public commits
and source exports; public setup and documentation are self-contained.

Updates the optional pinned fuzzer to odin-fuzz 0.4.0 using its canonical Nix
recipe without a compatibility patch. Lazy setup and dependency provenance
checks remain unchanged. Lint policy and CLI behavior are unchanged; all 27
active rules retain their documented applicability.

The required Odin compiler remains dev-2026-11a (`9a6991685`). Source revision:
the commit referenced by the fixed `v0.7.7` release tag. Consumers adopt this
release through an explicit update of their same-commit runner and full-SHA lock.

Removes the remaining GitHub Actions verification workflow and its setup
instructions. Compiler checks, self-lint, tests, distribution checks and macOS
fuzzing remain required local verification.

## 0.7.6 — 2026-11-23

Hosted CI is now optional and manually triggered. Pushes, pull requests and
schedules no longer start it, and hosted results do not gate commits or releases.
Local precommit verification remains required.

macOS CI now installs Homebrew Odin to match the locally validated compiler
distribution. Both CI jobs verify the required compiler commit before running
checks, and macOS fuzzing selects LLVM tools from the reported compiler backend.
Ubuntu retains its checksum-pinned official archive. A newer Homebrew compiler
requires an explicit compatibility upgrade rather than silently changing the pin.

Lint policy and CLI behavior are unchanged; all 27 active rules retain their
documented applicability. The required Odin compiler remains dev-2026-11a
(`9a6991685`). Source revision: the commit referenced by the fixed `v0.7.6` release
tag. Consumers adopt this release through an explicit update of their same-commit
runner and full-SHA lock.

## 0.7.5 — 2026-11-23

Fixes analysis of empty and whitespace-only Odin files. They no longer create
phantom packages or diagnostics without valid source positions. Packages with
real declarations still require their interface, and comment-only source without
a package remains an analysis error. All 27 active rules retain their documented
applicability.

Adds assertions for retained summary shapes, parser recovery offsets and final
diagnostic provenance. Checkable implementation assumptions are asserted at their
owning boundaries; invalid input and uncertain target behavior remain recoverable.

Adds pinned odin-fuzz exploration through the real CLI, isolated compiler-checked
seed projects, persistent corpus storage and a required `make precommit` gate.
macOS CI requires instrumented coverage feedback for all five launches and retains
reports and corpus artifacts. Weekly scheduled runs use a longer exploration
budget. Fuzzing found the empty-file defect fixed in this release.

The required Odin compiler remains dev-2026-11a (`9a6991685`). Source revision:
the commit referenced by the fixed `v0.7.5` release tag; `--version` reports its
full SHA when built through Make or the pinned runner. Consumers adopt this
release through an explicit update of their same-commit runner and full-SHA lock.

## 0.7.4 — 2026-11-22

Fixes inference of callbacks and protected references through contextual record
initializers, multiple known factory targets, and mixed global/formal returns.
Arguments, return operands and compound-literal elements retain their evaluated
values when later expressions mutate their source. Aliased helper calls preserve
the order of reads, writes and callback invocations.

Conditional and deferred execution retains transaction state, configuration
correlation and cleanup order. Returned references reflect completed deferred
writes. Known recursive calls no longer seed provisional returned values before
normal completion is established; unknown external alternatives remain
nonblocking. These corrections can reveal missed `ARCH007` and `OWN001` findings
and remove false callback-effect and `OWN002` transaction findings. All 27 active
rules retain their documented applicability.

Preserves finite nested-container paths and the destination slot of forwarded
pointer assignments, avoiding spurious whole-owner stores and repeated inference
growth. Path matching avoids temporary string allocations, and transient caches
and retained immutable graphs use less memory. Read histories keep source
positions directly, removing a cache back-reference that amplified self-analysis.
Protection queries reuse results within a merge, and switch checkpoints release
superseded summaries while preserving all surviving state. Condition branches
reuse incoming state instead of duplicating both continuations.

Parser recovery preserves multiline attributes, grouped expressions and array
bounds while retaining original diagnostic positions. The bootstrap runner
reports symlink-loop and excessively nested lock JSON failures as setup status
2, including on older Python runtimes.

Adds optional shared executable storage through `ODIN_LINT_CACHE`, preserving
the project-local default. Cache identity includes the compiler executable and
build flags; concurrent builds publish complete binaries without replacing an
existing entry. Each consumer retains its own reviewed runner and exact pin.

The required Odin compiler remains dev-2026-11a (`9a6991685`). Source revision:
the commit referenced by the fixed `v0.7.4` release tag; `--version` reports its
full SHA when built through Make or the pinned runner. Consumers adopt this
release through an explicit update of their same-commit runner and full-SHA lock.

## 0.7.3 — 2026-11-20

Reduces inference memory and repeated analysis by releasing procedure/store
scratch promptly, sharing immutable field records and revisiting procedures
whose input summaries changed. Store replay skips unrelated alias graphs and
retains unchanged snapshots. Builds enable speed optimization while retaining
debug information and bounds checks; the runner pays the compilation cost once
per cached revision.

Fixes positional record initializers with grouped field declarations such as
`left, right: Leaf`. Each field now retains its callbacks and protected references
through copies and helper returns. This can reveal previously missed `ARCH007`
callback effects and `OWN001` writes through protected references. All 27 active
rules retain their documented applicability; unknown callbacks remain nonblocking.

The required Odin compiler remains dev-2026-11a (`9a6991685`). Source revision:
the commit referenced by the fixed `v0.7.3` release tag; `--version` reports its
full SHA when built through Make or the pinned runner. Consumers adopt this
release through an explicit update of their same-commit runner and full-SHA lock.

## 0.7.2 — 2026-11-14

Clarifies maintainer participation, review and source release policies, and
reflows the project instructions without changing their wording. Linter rules,
diagnostics, CLI behavior and integration are unchanged.

The required Odin compiler remains dev-2026-11a (`9a6991685`). Source revision:
the commit referenced by the fixed `v0.7.2` release tag; `--version` reports its
full SHA when built through Make or the pinned runner.

## 0.7.1 — 2026-11-12

OWN005 now identifies the publication procedure, the failed assertion expression,
its required truth value and its original source location. Equivalent repeated
preconditions remain one requirement. Rule applicability and exit statuses are
unchanged.

The source is licensed under 0BSD and provided as is. Private consumer audit
narratives, machine-specific setup details and earlier release narratives have
been removed from the public source. Python tooling uses the standard library
without an unverified minor-version minimum. The required Odin compiler remains
dev-2026-11a (`9a6991685`).

Future release and verification records identify their linter version and source
revision. No earlier consumer verification result is claimed for this version.
