# Research and implementation

## Primary sources

No external source is vendored.

- [Odin compiler flags](https://github.com/odin-lang/Odin/wiki/Compiler-Flags)
  and installed `odin help check` describe compiler vet/style checks. These checks
  belong to the preceding compiler step; the linter assumes they passed.
- [OLS documentation](https://github.com/DanielGavin/ols/blob/master/README.md)
  covers compiler-backed workspace checking, checker arguments, and
  `core:odin/parser` diagnostics. Its
  [maintainer explanation](https://github.com/DanielGavin/ols/issues/1206)
  distinguishes filesystem compiler checks from immediate parser diagnostics.
- The [Micro Odin linter](https://gist.github.com/Tekkitslime/cb71fc40b06d30eb9515927fe670d342)
  invokes `odin check` and recognizes file/line/column diagnostics. This CLI uses
  the same practical positional convention.
- [Odin IntelliJ](https://github.com/obiwan87/odin-intellij) exposes checker
  arguments and explicit source/collection roots. Those ideas inform the CLI's
  explicit source/collection root configuration.
- [Odin dev-2026-10 string decoding](https://github.com/odin-lang/Odin/blob/dev-2026-10/src/string.cpp)
  defines triple-quoted literal indentation, CRLF normalization, and escapes.
  Import metadata is decoded once using those rules; the ordinary standard
  library unquote helper alone does not cover triple delimiters.

The installed dev-2026-10 `strconv.unquote_char` octal branch examines all
remaining input, so a valid escape followed by text can fail. The shared decoder
bounds octal calls to one four-byte source escape before continuing. Ordinary
and triple-quoted strings use the same escape-processing loop.

These sources informed positional diagnostics and explicit project configuration.
The current boundary assumes compiler checks have already passed. Reusing Odin's
parser for policy analysis avoids a new grammar, language-server lifecycle, and
extra dependency. That design conclusion is an inference from the sources, not a
claim that they implement our policies.

## Policy origins

The author's earlier project linters informed the section, visibility and FRP
policies. Their ideas are implemented here as one standard-library-only CLI;
those projects and their source trees are not dependencies.

| Policy | Implementation |
| --- | --- |
| Section hierarchy/order, empty sections, import groups, declaration placement | `SECTION001`–`SECTION004`, `IMPORT001`, both layouts |
| File organization, 60% defaults, visibility narrowing | `FILE001`–`FILE006`, `VIS001`/`VIS002` |
| Nested procedures with direct callback exception | `PROC001`, named/parenthesized arguments supported |
| Single-use procedures, top-down reading | Conservative `SIMPLIFY001`/`FLOW001` |
| Dead/unused code, including recursion | Owned by the preceding Odin checks; no lint rule |
| Source-role boundaries and call effects | `ARCH001`–`ARCH008`, configurable source root, ten-role dependency table |
| OLS cross-package visibility/alias resolution | Project-source reference graph for narrowing, static aliases, and type-use evidence; arbitrary compiler evaluation remains outside scope |
| Protected facts, local UI transactions, publication guards | Generic source-role/provenance models and structural protocols; no consumer-specific type names |

The ten-role table, immutable definition roles, explicit initialization and
private working-data ownership are defined by this repository's documentation.
See [rules and limitations](rules.md) for exact scope and the qualitative
guidance left to review.

All policy checks run on every invocation. The CLI configures only scan/root
paths and collection mappings; it contains no rule switches. Section layout is
detected from existing headers, with kind-first requirements for unsectioned
files. Each package has one logical interface family, with a canonical `main.odin` or
directory-name interface and explicit build-conditioned fragments as needed.
Package names preserve executable and namespace/ABI compatibility. Public
declarations live in the interface family;
package declarations need no dedicated shared file. Defaults follow a visibility
majority of at least 60%, with interface-Public/helper-File fallbacks.

## Analysis data and FRP scope

`src/main.odin` composes the command. `src/effects` owns CLI parsing, filesystem
reads and output. `src/functions` parses supplied strings and computes diagnostics
without filesystem access. `src/state` defines source inputs and diagnostics.
A stateless invocation needs no extra engine layer.

Paths, saved sources, ASTs, scopes, symbols, alias relationships and uses belong
to the caller's invocation arena. Semantic inference uses a separate working arena
per pass and two compact summary generations. Retained summaries copy their owned
strings, arrays and shared child maps before the working arena is released;
AST references and symbol indexes continue to refer to the invocation graph.
Final diagnostics are copied into the caller's allocator before releasing the
final working arena. Discarded convergence work does not accumulate until CLI
exit. Working and summary arenas batch state-provenance maps into blocks rather
than allocating and freeing each map through the heap. No daemon or persistent
analysis cache is introduced.
Symbols and procedures have stable array indexes within that analysis.
File scopes inherit a shared package scope; local scopes track declaration order
and shadowing. Namespace promotions forward to actual declaration identities.
State-access copies retain immutable field provenance. Shared child snapshots form
a DAG, not independently owned trees. Alias updates, caller-relative stores and instantiation cache transformed child maps for
one operation with fixed arguments. The key is the pinned runtime map allocation
identity; caches never cross analyses or argument environments. Root capabilities
remain separate because values can share children while having different roots.
Queries visit shared children once while preserving declared-type checks on each
relevant shape. This preserves sharing without a depth/iteration cutoff or loss
of protected-state evidence. Recursive summary widening remains conservative. Joins reuse
unchanged child snapshots and copy collections only when a new fact is added.
Silent nested-loop walks reuse their stable result; the diagnostic walk still visits every body.
Procedures analyze independent binding snapshots and loops converge to a monotone
provenance state. Stable procedure aliases share one lexical resolver across call
effects and inlining. Immutable source availability facts contain disjunctions of
OS/architecture sets and conjunctions of lexical Boolean atoms. Guarded lookup
subtracts each scope's proven coverage before considering outer bindings; overlap
or uncovered configurations prevent certainty. Exhaustive alternatives contribute
all possible callees, preserving the union of effects. Universal guards are inline
values and allocated guard facts live with the analysis, never a temporary call
summary arena.
Only relevant unresolved lookups suppress possible inline targets. Effects and
capability summaries are per-procedure facts; structural transaction/publication
models are policy evidence, with the limits documented in `rules.md`. Publication
preconditions come from leading assertions on an explicit engine transfer and
are instantiated at resolved direct calls. Conditions retain owned origin paths
across inference arenas. Assertion AST references retain the failed expression
and its original source position for OWN005 messages without owning transient
strings or creating duplicate equivalent requirements. Wrapper, callback and unknown protocol requirements are
not generalized from potentially joined origins. Adjacent clearing avoids stale
lookahead aliases; calls with unmodeled scalar changes invalidate earlier numeric
publication proofs without erasing state-write or transaction requirements.
Diagnostic positions borrow package data until emission. The source-role table
is enum-indexed; all 100 pairs across its ten roles are tested against independent
expected edges.

Source, path configuration, and tool version determine all results; nothing
persists between runs. No database, live-store transactions, reload snapshots, or
migrations are introduced. A future stateful mode requires a preservation decision
first.

Selected files form one map from canonical identity to diagnostic spelling;
root and collection coordinates are normalized before pure analysis. Sorted keys
provide processing order, and path aliases cannot cause repeated analysis.
The effects boundary records directory aliases for pure import-target resolution,
including aliases exposed by a prior rewrite. Role and symbol checks share that
resolved target identity.
Project files and outside-root sibling packages are loaded once per invocation
to establish consumer information and complete internal use counts, even for an
explicit single-file selection. Analysis-only files never receive diagnostics.
Parsing is an implementation detail of policy analysis, not an independent syntax check.
Parse/import-decoding failures and missing collection mappings return analysis
errors separately from policy diagnostics. The linter never launches a compiler
or the target application. Compiler checks run first in the surrounding workflow.

Verification includes representative source cases, memory-tracked Odin tests,
CLI/filesystem cases, and small examples checked by Odin before linting. No test
uses wall-clock thresholds or throughput benchmarks.

Formal mutation summaries are capability requirements checked at actual calls;
symbolic formals are not themselves demonstrated borrowed mutations. Outcome,
slot/referent and transaction facts retain the distinction between missing evidence
and a concrete violation. Explicit collection import closures contribute
analysis-only source facts while selection remains limited to requested files.

## Precision and trusted boundaries

The chosen policy favors avoiding false positives over finding every defect.
Dependency internals need not follow the project's architecture. Unknown effects,
callbacks and configuration identities remain inference facts
that limit positive advice, without user-facing uncertainty diagnostics. Specific
reviewed operation models still establish real effects and FRP state-write requirements. Namespace membership alone cannot establish an external effect.
LINT003/LINT004 and OWN003/OWN004 are retired historical identifiers; all 27
active rules run. General allocator, release and object lifetime checks are outside
scope. No consumed-alias state, allocator generation or exclusive-message model
is retained.
Genuine input and setup failures remain analysis errors rather than clean results.
