# odin-lint

Shared Odin linter for use across projects. Read `README.md` for setup and
`docs/rules.md` for implemented behavior. Read the installed coding skill before
editing when available. No skill or sibling checkout is a runtime dependency.
Keep temporary work in ignored `.work/`.

## Purpose and scope

The linter supplies FRP architectural guardrails. Check source roles and known
effects, writes to protected meaningful state, engine/local transaction scopes,
published catalog immutability, and source-proved publication preconditions.
Use alias and caller summaries only to support those checks. Private working
copies and buffers may be mutated.

Do not build a general ownership, borrowing or memory-safety checker. `OWN003`
and `OWN004` are retired along with `LINT003`/`LINT004`. Do not track allocator
resets, escaped scratch buffers, freed/consumed aliases, general returned-buffer
lifetimes, or exclusive-message handoff. Thread arguments are not implicitly
consumed. Ordinary buffer/string cleanup correctness is outside scope. Keep
actual writes/destruction of protected FRP state visible; retirement does not
permit bypassing the engine through a helper or a raw pointer.

A catalog type alone does not prove published storage. Allow private catalog
construction and cleanup; protect global catalog storage, explicit
read-only storage and catalog views
reached through published engine state. Formal mutation is a caller requirement,
not proof of an invalid actual argument. Keep concrete global/mixed-global
alternatives protected. Preserve aliases in reference-bearing children when
copying inline records or arrays into independent working storage. Whole-pointer
formal writes check the supplied referent rather than its caller's pointer slot.

Trust external implementations and apply architecture only to project-owned
code. Unknown effects, callbacks, opaque types and configuration ambiguity remain
inconclusive and nonblocking. Add precise boundary models only when useful for
FRP effects/writes; using a dependency requires no annotations, allowlists or
rule switches. Missing inputs and parse/configuration failures remain errors.

## Verification and distribution

The project owner is the sole maintainer and final reviewer. External review is
optional. Reproducible bug reports and small pull requests are welcome; responses,
acceptance and future development remain at the maintainer's discretion.

Target sources must already pass their actual Odin compiler checks. The linter
must not invoke the compiler or duplicate syntax, type, vet/style or unused-code
diagnostics. Use maximal compatible first-party vetting and strict style with
warnings as errors. Check unused procedures against closed application entries;
the pinned compiler misclassifies attributed tests, and reusable public APIs need
real consumers. Preserve every target, collection and define configuration.

After editing code, run `make lint`: compiler checks precede the freshly-built
implementation checking its own `src` and `tests`. Never use a GitHub-pinned copy
to lint this repository. Run `make verify` before committing, including the full
Odin/CLI suite and independent distribution tests. Setup/analysis failure is not
a pass. Tests assert correctness, not timing or throughput thresholds.

Consumers fetch an exact GitHub commit with the runner from the same commit,
record the full revision in the root lock, and cache only under ignored `.work/`.
Keep runner and lock synchronized during explicit upgrades. No floating branch,
automatic upgrade, sibling checkout or home-directory skill is required.
Distribute source releases with fixed version tags and full commit-SHA pins.
Compiler checks, self-lint and the full suite remain required before publishing
code changes, including changes accepted from contributors.

Keep open work/decisions in `notes/TODO.md` and out-of-scope proposals in `notes/REWORKS.md`.
Record agreed workflow policy here; implemented behavior belongs in `docs/`.
Do not commit private consumer details, machine-specific paths or local tool-pool
instructions. Remove obsolete audit narratives. New verification/audit records
must identify the linter version and source revision, configurations and outcomes.
Use Python 3's standard library without an arbitrary minor-version support floor;
keep the exact Odin pin while compiler/parser compatibility requires it.

## Active policy invariants

All 27 active rules always run, with their documented applicability. There are
no opt-in or disable switches. Support both section layouts; require kind-first
sections when none exist. Preserve public exports even with only local saved
callers. Private narrowing requires complete siblings. Zero-use code belongs to
the compiler, not this linter.

Keep single-use inlining eligibility unchanged: file/package-private procedures,
complete-package use counts, lexical resolution, stable aliases, initializers
and all expression uses. Exclude public APIs, escaping/uncertain uses and cycles;
procedure size is irrelevant. `SIMPLIFY001` instructs inlining and remains an
error. Keep uncertainty local and report each ordering dependency once.

Require a logical interface family per package: canonical `main.odin` or the
directory-name interface, with explicitly conditioned fragments when imports
cannot be combined. Preserve compiler/ABI namespace collisions, test discovery,
build conditions and generated-source ownership. Public declarations and anchored
private support stay together. Do not prescribe `shared.odin`. A representable
60% visibility majority determines the default; otherwise interfaces use Public
and helpers File. Preserve minority exports and private dependency closure.

Preserve folder responsibilities and acyclic dependency directions from
`docs/rules.md`. State/views remain definitions-only. Catalog may retain pure
lookups, with known effects and input mutation excluded. Functions may use pure
migrations; engine may call pure validators. Effects owns I/O/runtime bookkeeping;
UI renders and transacts local input while emitting meaningful-state requests.
Application composes the runtime. Do not hardcode a consumer's type names.

Compose actual writes, destructive writes and callback effects through complete
saved packages and named/positional arguments. Preserve field-store order and
conditional alternatives. Include relevant mapped collection imports as
analysis-only evidence without expanding selected diagnostics to vendor code.
Unknown nested fields keep established symbolic paths without invented shapes.

Transaction inference uses owner type/counter path, survives partial/full wrapper
inlining, and applies direct changes in statement order. Completed internal
scopes are not boundary operations. Keep returned Boolean predicates and
short-circuit outcomes correlated with their actual counters. An arbitrary false
return does not cancel a scope, and another owner's completion cannot erase it.
Keep local working-field permission separate from meaningful relations/indexes.
Addressing an embedded owner preserves its own local role as well as its slot
role. Cache write permission must not erase stores or concrete protected aliases.

Publication checks require source-established evidence. A whole-owner copy does
not imply a destructive move or mandatory success/revision guards. Straight-line
source clearing immediately after a copy identifies a transfer; leading
assertions can establish its preconditions. Report only concrete contradictions at known live destinations;
unknown or conditional protocols remain inconclusive. Calls with unmodeled scalar
effects invalidate earlier numeric publication evidence; fresh literal arguments
remain checkable. Lifecycle permission for one owner must not exempt another
owner or an unrelated relation mutation. Do not certify exclusive
aliases, general object lifetimes, race freedom, durability or atomicity.

## Implementation invariants

Parsing recovery preserves attributes, else attachment and source positions.
Resolve contextual record labels without treating them as procedure uses; keep
unknown contexts and map-key uses conservative. Conditional resolution requires
source-proved exclusive/exhaustive alternatives and joins possible effects.

The analysis itself must manage memory correctly: retained summaries own their
strings/arrays/maps across transient arenas, shared child graphs stay immutable,
transform caches live for one operation and final diagnostics belong to callers.
Release discarded inference work and retain diagnostic loop walks when stable
silent results are reused. This implementation discipline is separate from lint
policy for a target program's allocations.
