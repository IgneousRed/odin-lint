# Fuzzing the CLI

Run `./scripts/dev make precommit` before deciding to commit. It checks dependency
updates, then runs `make verify` and the macOS fuzz gate (`make fuzz`). On other
hosts, run `./scripts/dev make verify` locally and
obtain matching local macOS fuzz verification for the same sources. Verification
runs locally. A missing toolchain, failed build/discovery or absent coverage
feedback is incomplete verification.

## Setup and execution

Install Nix once and Xcode Command Line Tools. The gate requires macOS arm64 and
`/usr/bin/sandbox-exec`. The locked Nix environment supplies Python, Git, the
exact Odin source, rebuilt Python 3.15.2 and matching LLVM 23.1.6 tools on
macOS 26 or later. The ordinary development environment excludes fuzzer tooling;
the optional `fuzz` profile adds the pinned package when requested.
Check the selected tools:

```sh
./scripts/dev odin report
./scripts/dev --profile fuzz odin-fuzz doctor
```

No Python packages or sibling checkout are required.

```sh
./scripts/dev make fuzz-prepare # Materialize and compiler-check seed projects
./scripts/dev make fuzz         # 60-second exploration budget, split between launches
./scripts/dev make fuzz FUZZ_BUDGET=300 FUZZ_SEED=2
./scripts/dev --profile fuzz python3 scripts/fuzz.py --budget 60 # Direct driver
```

`FUZZ_THREADS` selects the target compiler's positive thread count (default `2`).
The direct driver accepts `--thread-count`; the selected value is forwarded to
both LLVM-IR and fallback ASan builds and retained in `verification.json`.
Seed compiler checks retain their separate per-invocation `ODIN_FLAGS`. To run
every compiler path with one thread, including the standalone distribution tests:

```sh
NIX_CONFIG='cores = 1' ODIN_LINT_THREAD_COUNT=1 ./scripts/dev make precommit \
  ODIN_FLAGS=-thread-count:1 FUZZ_THREADS=1
```

These selections do not change the default compiler settings or substitute the
locked compiler/scanner. `NIX_CONFIG` applies before initial package realization.

`make fuzz` completes its compiler/self-lint prerequisite in the active environment
and then enters the optional profile. `make verify` and ordinary setup do not
realize the fuzzer. `make fuzz-prepare` needs only the declared compiler and may
run without the fuzzer installed. Linux retains compiler-only preparation and
obtains its required fuzz evidence from macOS.

Nix packages odin-fuzz 0.5.0 at full commit
`ed06f23bea76601e44efc9c5c13e42e54b1b9f14` from
[IgneousRed/odin-fuzz](https://github.com/IgneousRed/odin-fuzz), using the fixed
source hash in `nix/odin-fuzz-source.nix` and its canonical Nix recipe, without
patches. The canonical package owns the immutable scanner and tool paths;
`scripts/fuzz.py` invokes the packaged CLI without cloning or managing a scanner
cache. Upgrades are explicit changes to the Nix declarations. Each run copies the
current `src`, `VERSION` and root `odin-fuzz.json` into `.work/fuzz/target`.
`tests/fuzz/*.json` stores seed projects as path-to-source mappings, materialized
under that target's `inputs/`. Each seed package passes compiler checks before
exploration. Fixture source remains data in the repository so ordinary self-lint
does not analyze deliberate violations as part of its own saved project graph.

Both Make targets and direct `scripts/fuzz.py` calls require a matching locked
dependency setup before preparing inputs or invoking tools. The driver evaluates
this checkout's declared Nix profile offline, without realizing packages,
using system tools and the standard Nix bootstrap location rather than ambient
executable directories. It compares the output path with the active environment,
selects compiler and fuzzer executables from its immutable manifest, and checks
their resolved store paths against its `bin` entries. Missing tools, unavailable
evaluation and a stale environment fail the gate. Exploration accepts only the
current `fuzz-environment`; preparation accepts the current `dev-environment` or
`fuzz-environment`. An ambient fuzzer cannot make the ordinary environment pass
the exploration gate.

Child commands receive the locked tool paths and a restricted environment;
ambient `PATH`, `ODIN`, `ODIN_FUZZ*`, scanner caches and compiler/tool overrides
cannot substitute another tool. The canonical fuzzer package also fixes its
compiler, scanner and LLVM paths, and refuses unpackaged
execution or a local scanner build fallback. Working-tree edits remain eligible;
this gate checks dependency provenance and adds no test-suite prerequisite.

The configuration declares a free-argument CLI launch and fixed-root launches
for aliases/callers, transaction/publication state, conditional declarations and
parser recovery, and mapped analysis-only collection imports. Explicit file
lists expose mutable source inputs. Fixed roots keep the CLI's whole-project
analysis small. Fixed argument launches preserve those roots; the free-argument
launch explores option handling separately. No alternate analysis API is used. Make propagates per-invocation `ODIN_FLAGS`
to seed checks and compiler-backed fixtures without changing the required check
flags; direct driver callers may set the same environment variable.

Persistent coverage-winning cases live in `.local/fuzz/corpus`. Unique reports,
diagnostics and self-contained reproducer bundles live under
`.work/fuzz/runs/runs/`. `verification.json` beside each safe `summary.json` records the
linter version, Git revision, hashes of the actual staged sources/configuration,
fuzzer executable, Nix environment, lock hash, budget, seed and process outcome.
Each new run also registers `nix-environment` as a GC root retaining its tool
closure while needed. Retire reproducible run roots after their last consumer;
preserve necessary evidence and source/configuration hashes outside `.work/`.
Git HEAD alone does not identify uncommitted changes. Resolved historical runs
are not permanent archives.

The gate requires `coverage_mode=llvm_sancov`, nonzero first-party edge feedback
and successful executions for every configured launch, matched by name and path
exactly once. Confirmed findings and workspace errors fail the gate even if the
tool exits successfully. An ASan-only fallback fails this gate. The budget must
be finite and positive. Budgets bound exploration, not compilation and confirmation;
tests make no timing or throughput assertions. A clean run is bounded evidence,
not proof of semantic correctness. Source mutations may be invalid and reject
normally with exit 2; lint findings exit 1 and are also normal target behavior.

## Findings and assertions

Use internal assertions for checkable implementation assumptions, especially
summary retention, graph transformations and source-position restoration. Keep
uncertain target behavior conservative and normal invalid inputs recoverable.
Assertions must never manufacture stronger FRP policy or memory-safety claims
about analyzed programs.

The project gate reads only the safe `summary.json`. The upstream `GUIDE.md`
documents the `doctor`, `scan` and `explore` commands. Findings or setup failures
stop the gate; a summary is not a substitute for detailed triage by the
designated maintainer.

For a confirmed finding, retain the identity and inputs, reduce it into a
deterministic Odin/CLI regression, and compiler-check a semantic reproducer in
its actual configuration. The designated owner performs detailed reproduction
and fixes. Parser or input robustness failures remain distinct from wrong-policy
diagnostics. Rerun affected checks and the precommit gate after fixes. Timeouts
and unconfirmed signals require triage; they are not confirmed bugs.

Confirm the required Odin compiler commit (`9a6991685`/`9a69916`) with
`./scripts/dev odin version` before verification. Compiler upgrades require an
explicit compatibility update to the shared toolchain. Keep reports and
persistent corpus in the machine-local area.

## Retention

Temporary targets, discovery and generated runs remain under `.work/fuzz/`.
Before finishing a task, retain only necessary, minimal anonymized corpus and
reproducible finding evidence under `.local/fuzz/`; discard regenerable snapshots
and resolved reports. Never retain consumer source, identifying paths or business
data, including in machine-local evidence. Retained summaries
must state their source/configuration identity and actual validation limits.
