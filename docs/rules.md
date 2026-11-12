# Rules and limitations

All 27 active lint rules always run. Each rule retains its syntax, dependency, or
visibility conditions; no CLI option enables or disables rules. No rule rewrites
source files.

Avoid false positives even at the cost of false negatives. External implementations
are trusted and need not follow project architecture. Missing models, foreign
bodies, unknown callbacks/allocators, opaque types and ambiguous configuration
evidence are internal unknowns, not findings. Users need no annotations, allowlists
or switches to use unmodeled code. Known effects and concrete FRP state violations remain checked. Unknown behavior is not certified safe. Compiler/input
failures remain analysis errors. `LINT003`, `LINT004`, `OWN003` and `OWN004` are retired historical
identifiers; ambiguity still prevents speculative narrowing and inlining.


Odin compiler checks are a precondition: run the appropriate syntax, type,
vet/style, and desired unused-code checks before linting. The linter never
invokes Odin or duplicates compiler-owned diagnostics. It parses source only to
analyze additional policies. If parsing/import decoding fails or a custom
collection needed for project analysis is unmapped, the CLI reports an analysis
error (exit `2`), separate from lint findings (exit `1`). A missing collection
mapping does not imply the compiler failed; supply `--collection NAME=DIR` to
give the analyzer the same path information. Recovery for compiler-valid inline
range bodies preserves multiline attributes, newline-separated `else` attachment,
and original source positions; source files are never rewritten.

## Diagnostics

| Rule | Condition and action |
| --- | --- |
| `ARCH001` | A recognized role imports a forbidden role or an unassigned path inside the source root. Follow the table below. |
| `ARCH002` | A restricted role calls a modeled OS/network operation, directly or through a resolved helper/callback. Keep the operation in effects/application and pass its results explicitly. Type-only imports are permitted. |
| `ARCH003` | Mutable package declaration in a pure role, excluding explicit `@(rodata)` storage. Pass private working data explicitly; keep surviving facts in their owner. Local mutation is allowed. |
| `ARCH004` | A state/views procedure body, or a catalog body with known external effects or input mutation. Keep state/views definitions-only; unknown effects alone do not establish catalog impurity. Procedure types and `@(test)` bodies are allowed. |
| `ARCH005` | `@(init)`/`@(fini)` in a pure role. Compose initialization/shutdown explicitly at the entry point. |
| `ARCH006` | A restricted role observes/waits for ambient time, including through resolved wrappers or callbacks. Pass clock values explicitly. Time constants and conversions are allowed. |
| `ARCH007` | A restricted role performs modeled external effects, rendering, or ambient mutable-package reads. Effects/application may perform external work; UI may render. |
| `ARCH008` | A storage worker performs modeled network I/O, or a network worker performs modeled filesystem I/O, directly or transitively. Coordinate through effects and owned messages. |
| `IMPORT001` | Top-level ordinary/foreign imports follow declarations, or ordinary imports reverse Vendor → Odin (`core:`/`base:`) → Project grouping. Reorder them. |
| `VIS001` | `private` attribute repeats the effective file default. Remove it. |
| `VIS002` | A used non-public declaration can have narrower visibility given complete sibling references. Public exports remain API boundaries; ambiguous uses and non-visibility attributes exclude narrowing. |
| `PROC001` | Nested procedure literal not passed directly as a callback. Move it to file scope or pass it directly. Named/parenthesized arguments are supported. |
| `SECTION001` | Header dash counts differ, are not powers of two, or skip levels. Use 32-dash major, 16-dash minor, then halved subsection levels. |
| `SECTION002` | Major/minor name or order is invalid, or a section repeats under the same parent. |
| `SECTION003` | Import/declaration lacks its required kind/effective-visibility group. Move it to the correct group. |
| `SECTION004` | Section contains no top-level declarations/imports, including descendants. Remove it. |
| `FILE001` | Without a 60% visibility majority, an interface needs Public default visibility and a helper needs File. |
| `FILE002` | Package name differs from its directory without an executable-main or imported-namespace compatibility reason. Preserve compiler/ABI package identities. |
| `FILE003` | Package lacks a logical interface family or has competing canonical interfaces. Canonical interfaces are `main.odin` or directory-name `.odin`; build-conditioned interface fragments preserve target-specific imports. |
| `FILE004` | An ordinary helper contains a public declaration. Narrow internal visibility where all uses permit it, or move the public declaration and private support into its interface family while preserving build conditions. |
| `FILE005` | A used interface implementation is needed only within its file and is not support for an anchored interface declaration. Move the implementation and private dependencies together. No `shared.odin` destination is prescribed. |
| `FILE006` | At least 60% of known top-level declarations have one effective visibility and the file default differs. Preserve minority visibility while changing the default or reorganizing declarations; this takes precedence over `FILE001`. |
| `FLOW001` | A declaration follows a dependency in the same kind/visibility section, outside a reference cycle. Place the user before its dependency. Applies to constants, types, globals, and procedures of every visibility. |
| `OWN001` | A direct/helper/callback write or destructive operation targets protected relational storage or published catalog data. Use engine operations or demonstrably owned unpublished data; local snapshot working fields are separately checked. |
| `OWN002` | UI invokes meaningful-state mutation, functions invokes transactions, a concrete owner mutation lacks its required transaction, or a transaction opened here has an unfinished exit. |
| `OWN005` | A known live-state transfer contradicts a precondition explicitly established by its engine implementation. The message identifies the procedure, failed expression, required truth value and declaration location. |
| `SIMPLIFY001` | File- or package-private procedure has exactly one resolved call in its package, no escaping/uncertain uses, no call-graph cycle, and only visibility attributes. Procedure size is irrelevant. Inline it; this is a lint error. |

Pure roles are `catalog`, `functions`, `migrations`, `state`, and `views`. Unused
imports/locals/declarations, shadowing, casts, semicolons, deprecated syntax,
trailing commas, and compiler `using` conventions belong to the preceding Odin
checks, not to lint rules.

## Source roles

The source root defaults to `PROJECT/src`, overridden with `--source-root DIR`.
Roles include nested packages. Same-role dependencies are permitted.

| From | Other permitted roles |
| --- | --- |
| `catalog` | None |
| `effects` | `procedures`, `engine`, `functions`, `views`, `state`, `catalog` |
| `engine` | `functions`, `views`, `state`, `catalog` |
| `functions` | `views`, `state`, `catalog`, `migrations` |
| `migrations` | `state`, `catalog` |
| `procedures` | `engine`, `functions`, `views`, `state`, `catalog` |
| `state` | `catalog` |
| `views` | `state`, `catalog` |
| `ui` | `procedures`, `engine`, `functions`, `views`, `state`, `catalog` |
| `application` | `ui`, `effects`, `procedures`, `engine`, `functions`, `views`, `state`, `catalog`, `migrations` |

Paths are normalized relative to the importing file or resolved through supplied
collections. Existing project/source/collection roots and selected files use
canonical filesystem identities, so a symlink ancestor does not change source
roles. The CLI records canonical directory-alias facts without traversing
symlink trees. Relative import targets use those facts, including nested
aliases, for both role checks and symbol resolution. The pure API performs no
filesystem I/O and resolves import aliases only when its caller supplies those
facts. Ordinary, raw, triple-quoted, and indented triple-quoted imports use one
decoded value for grouping, clock, and dependency rules. Prefix lookalikes are
unassigned paths, not roles. Multiline metadata requires whitespace-only
opening/closing delimiter lines and at least one content line. Imports outside
the source root are outside this table. Files directly at the root and in
unrecognized folders receive local policy checks without role policy; the
composition entry point can import effects. The table preserves acyclic role responsibilities while allowing direct data and
pure validation dependencies. The installed coding guidance uses the same graph.

`state` and `views` contain definitions, not runtime procedure bodies. Catalog
may also retain lookups so its qualified data APIs need no upward import or
incompatible migration. Known external effects, input mutation and publication are excluded from that exception. Missing effects or
callback/allocator evidence alone do not establish a violation.
`migrations` contains pure versioned conversions into private data; it must not import gameplay orchestration or engine/effects.
`functions` computes from explicit inputs, including writable private buffers and
explicit derived caches. `engine` owns relational mechanics and validation;
`procedures` composes transactions. `effects` owns platform/durability operations
and runtime bookkeeping. `ui` builds presentation, emits meaningful requests, and
may transact local interaction state; `application` composes the runtime.
`effects/storage/` and `effects/network/` have distinct modeled I/O responsibilities.
Source roles do not assign every allocation or runtime thread to an engine.
Workers may share immutable definitions and deterministically replay private data;
only the current application authority publishes live state. Injected callbacks
do not create import permission or erase known effects.
The root entry point remains outside the named roles. Role/effect checks cannot
infer whether arbitrary arithmetic expresses duplicated business policy or pure
runtime composition; that architectural intent still needs review.

## Resolved effects and state provenance

Saved procedures summarize known effects, writes/destructive operations,
callbacks, returned state provenance and caller-relative field stores. Summaries
converge through resolved project calls and aliases. Complete-package evidence
supports named/default arguments, multiple results, reference iteration, casts
and helpers without requiring external API annotations.

The analysis retains only enough alias information to distinguish protected FRP
state from independent working copies and to match transaction/publication
protocols. Recursive paths/records use a finite abstraction, immutable child
snapshots and operation-local transforms. Source availability joins proved
conditional alternatives; ambiguous configurations remain uncertain. Selected
files receive diagnostics while other saved sources supply evidence.

Modeled OS/network calls produce `ARCH002`; other known external effects and
ambient mutable reads produce `ARCH007`; ambient time produces `ARCH006`.
Effects/application may perform external work; UI may render. Computation,
private allocation, formatting into memory, and private-buffer mutation are
allowed. Namespace membership alone does not establish an effect. Unknown
foreign bodies, callbacks and dependencies remain silent and nonblocking.

Known higher-order models include slice comparators, AST visitors and parser
handlers. Actual arguments and effects compose through saved callback forwarders.
Recursive forwarding reuses an active invocation only when its saved argument
evidence covers the repeated arguments. Nil and unresolved callback alternatives
remain distinct. Thread creation is an external effect; it does not consume the
sender's arguments or establish an exclusive-message contract.

Operation descriptions bind named and positional destinations consistently.
Builtin/container mutation and `core:mem` zero/copy/move/set preserve protected
state provenance through raw-data conversions. JSON unmarshal checks its output
write; generic destinations are instantiated at callers. Private decoded working
data remains mutable, with conditional field stores retaining earlier possible
values. Explicit project allocator callbacks contribute known effects, but
allocator ownership, reset and output lifetime contracts are outside scope.
Known tokenizer/parser input views keep their source provenance only so a later
write through them cannot bypass protected-state rules; reads have no lifetime
preconditions. Unknown serialization registries need no model to be used.

Implicit random generators carry ambient-state effects. Explicitly seeded
private generators are allowed; supplied generator callback effects and state
writes remain checked. Additional library models improve FRP detection and are
not a prerequisite for using a dependency.

## Sections and files

Section checks always run and recognize both existing local layouts:

- **Kind first:** major Imports → Constants → Globals → Types →
  Procedures; import minors Vendor → Odin → Project; other minors Public →
  Package → File.
- **Visibility first:** imports before sections; major Public →
  Package → File, each containing Constants → Globals → Types → Procedures.

Headers are standalone `//` comments in column one, outside top-level
statements. The label has one space on each side between the dash runs, as in
`// ---------------- Public ----------------`; prose such as `// -1 is invalid-`
does not introduce a section. Strings, block comments, and procedure comments
cannot introduce headers. Files without headers must also place
imports/declarations in sections; they use kind-first layout until a
visibility-first layout is present. Files with no imports or declarations need
no sections. Section checks cannot be disabled.

Declaration kinds are resolved through local and project-imported aliases,
including alias chains, primitive types, procedure groups, generic struct/union
applications, and direct procedures returning `typeid`. Type conversions produce
values; they are not confused with generic type applications. A compiler-valid
type-position use can establish a type alias even when the imported definition
is outside the project. Literal conditional selections with the same kind on
both sides can be classified without choosing a compiler configuration.
Foreign-block attributes and member visibility are carried into section
analysis.

Dynamic overload selection, arbitrary compile-time evaluation, and external
alias bodies without type-use evidence remain unclassified. Visibility placement
still runs for these declarations. Aliases of private procedures cannot export
those procedures, but remain visible to sibling files unless explicitly
file-private. Value and type aliases keep their own declared visibility.
Enum-member aliases are constants. Unknown conditions keep uncertainty local to
their affected symbols. Foreign imports require an import group in kind-first
layouts; their group is not inferred from foreign library paths.

Each package has one logical interface family. A canonical interface is
`main.odin` or its directory name plus `.odin`; competing canonical interfaces
remain a finding. Explicitly build-conditioned `main_*` or directory-name
fragments can retain native/web imports that cannot be combined safely. Ordinary
helpers remain outside that family. Compiler checks must cover every supported
target; the analyzer does not silently select a platform.

Package names normally match directory names, with executable `main` and imported
namespace/ABI compatibility exceptions. Renaming a package is never permission to
break compiler uniqueness or its ABI prefix. Public declarations belong in their
interface family, or may become private when their complete reference boundary
permits it. Test-only declarations keep their build conditions; attributed tests
remain harness-discovered with file-private visibility. File-only implementations belong in helpers, except transitive private support
for an interface declaration that must remain there. Such support may stay with
its caller, including through uncertain conditional dependency paths; relocation advice never requires moving a file-private dependency
away from its interface caller on its own. Package-visible declarations may live in either;
there is no special `shared.odin` role and no recommendation to create or move
declarations into that filename.

The default visibility follows the declarations when one visibility accounts for
at least **60%**, including exactly 60%. Each unconditional top-level
declaration counts once, even if it declares several names. Unknown conditional
declarations and declarations with mixed effective visibilities do not establish
a majority. Mixed-visibility names must be split so each declaration can occupy
its correct section. Otherwise interfaces default to Public and helpers to File.
An empty `shared.odin` is an ordinary helper and defaults to File. The majority
rule takes precedence over filename defaults, so it never requests two
contradictory defaults for the same saved file. Redundant `private` modifiers
are checked against the current file default.

A recommended default is never permission to change another declaration's
visibility. When private defaults would hide public exports, `FILE006` (or the
filename fallback `FILE001`) asks for a visibility-preserving reorganization:
keep exports in a Public-default interface and preserve private dependency
closure. This includes conditional exports excluded from the majority vote.
Odin has no public attribute to override a private file default. Moving
package-private support into a Package-default helper can preserve its callers;
file-private support cannot be moved independently of those callers or widened
merely to satisfy the majority. For representable private minorities, preserve
visibility with explicit private attributes before changing the directive.
Recheck the same mixed package and its consumers after the transformation.

When the anchored file-private support that must remain with public exports still
meets the majority threshold in that irreducible group, keep the necessary Public
default. Reorganizing the same group cannot change that ratio, and widening its
support or hiding exports is not a valid fix. Feasible package-private or
unanchored-support reorganizations still receive majority guidance.

## Visibility and ordering

The CLI reads saved project sources under `--root` for consumer and type
evidence, as well as complete sibling packages for selected files outside that
root. Only selected files receive findings. Traversal has the same
hidden/vendor/symlink boundaries as selection for ordinary project discovery.
Referenced relative and explicitly mapped collection packages additionally supply
their complete regular Odin siblings as analysis-only evidence, including under
vendor. The import closure follows their referenced packages, without selecting
those files for diagnostics or traversing unrelated vendor packages. Every
explicit collection root must exist, even when unused, matching compiler setup.
Unreadable or unparseable
analysis sources are errors; symlinked Odin files make completeness fail.
Missing local import targets or multiple package identities at an import path
prevent speculative advice, while package-private analysis continues. Public
exports are preserved even when all saved consumers are local. The CLI
supplies canonical import-alias identities; the pure API accepts the same facts
through its optional `import_aliases` map.

`VIS002` narrows a Package-private declaration to File when complete sibling
references are confined to that file. Public exports are preserved regardless
of locally saved consumers. Resolution follows stable alias references,
initializers, signatures, callbacks and expression uses; zero-use declarations
remain the preceding compiler's responsibility. Entry points and declarations
with attributes other than visibility are excluded.

The pure `check_package` API accepts multiple complete packages and
analysis-only consumers. Its optional `complete_project` argument remains for
source compatibility;
public exports are preserved regardless of its value. Private narrowing needs
complete siblings, and interface relocation preserves public dependency closure.
Active custom collections must be
mapped even for analysis-only consumers; missing mappings are analysis errors
before findings. Complete siblings remain required for package-private claims.
`check_source` is a convenience for a complete single-file package.

`FLOW001` follows resolved declaration references within the same
kind/visibility section. It includes type dependencies, constant aliases,
procedure calls, and initializer expressions. Lexical shadowing and named-field
labels do not create edges. Compiler-established context from declarations,
assignments, returns and resolved call parameters identifies record field labels
in implicit literals, including nested record/collection values. Map keys remain
expression uses. Unresolved contextual shape keeps uncertainty local; this does
not change `SIMPLIFY001` eligibility. Reference cycles cannot have a topological
reading order, so only edges inside those cycles are exempt. These suggestions
do not move declarations or change their evaluation semantics. Each resolved declaration
pair is reported once, at its first saved use, rather than once per reference.

## FRP state guardrails

`OWN001` protects meaningful state reached through `state` definitions, engine
owners, relations and maintained indexes. Known writes and destructive operations
must use the engine or demonstrably private working data. Ordinary value copies,
fresh buffers and reconstructed caches remain mutable. Inline record/array copies
have independent containers; pointers, maps and slices retain known references to
protected state. Whole-pointer helper writes check the supplied referent, while
replacing a private handle does not mutate its old referent. Public-formal write
requirements are discharged at actual saved callers, not diagnosed merely from a
symbolic parameter. Concrete globals and mixed global alternatives stay protected.

A catalog type is data, not proof of publication. Construction and cleanup of
private catalogs are permitted. Global catalog storage, explicit
read-only storage and catalog references
reached through published engine state stay read-only, including through helpers
and callbacks. Unknown provenance does not establish publication. Plain views and
explicit local caches do not automatically become authoritative meaningful state.
Taking an embedded owner's address preserves its local role independently of the
enclosing session. Permitted cache writes still contribute field-store summaries,
so an explicit alias to protected meaningful storage does not become writable.
Propagated OWN001 messages include a representative known field; multiple fields
of the same call/parameter violation remain one finding.

`OWN002` recognizes structural transactions by owner type and counter path.
Resolved helpers/callbacks compose counter changes; partial or complete inlining
preserves the scope. Internally completed scopes are distinct from boundary
operations. Direct/deferred changes execute in statement order. Returned Boolean
predicates and short-circuit outcomes preserve the paths on which a scope opens;
a false result alone does not cancel it. Matching scopes discharge helper
preconditions. Another owner's completion or an overwritten predicate cannot
restore/erase an unrelated scope.

UI may transact its local working input while emitting requests for meaningful
state. Functions do not perform transactions. Local working-field permissions
follow the particular owner and do not permit relation/index writes through a
shared view type. Fresh/zero engine lifecycle initialization needs no pre-existing
transaction. Lifecycle permissions are per owner: a whole-owner copy cannot
exempt another owner's relation mutation, and a copy before a complete internal
transaction needs no extra transaction around the copy. Counter inference is a
guardrail, not proof of atomicity/durability.

`OWN005` checks concrete contradictions of explicit live-publication contracts.
A whole-owner copy alone is not a destructive transfer and requires neither
source clearing nor invented success/revision guards. An engine copy followed by
an immediately following source clear identifies a transfer. Leading builtin `assert`
statements can establish simple truth, negation, equality and inequality
preconditions, including conjunctive assertions. Unknown expressions establish
no requirement. A clear before the copy, a conditional clear, an intervening assignment or a
branch-local assertion does not establish this contract.

A finding requires a resolved direct call to the engine transfer, a known
protected live destination, and saved argument evidence that contradicts the
condition: for example, false approval or a zero revision compared with a
nonzero revision. Named/positional arguments are mapped to the actual parameters.
Two nonzero integers are not proof of equality. Private working destinations,
unknown values, wrappers, ambiguous targets and callback protocols remain
nonblocking. Other rules still compose known state writes and callback effects.
Mutating calls and calls without established scalar effects invalidate earlier
numeric publication proofs. A later field/local value stays inconclusive even
if it previously had a known value; fresh literal call arguments remain usable.
Read-only saved calls and known pure operations retain their evidence.

This guardrail does not infer domain meaning from field names, require every
publication protocol to look alike, certify arbitrary assertions, synchronization,
durability or atomicity, or track exclusive aliases after a handoff.

`OWN003` and `OWN004` are retired. General buffer/string allocation, release,
use-after-free, scratch retention, allocator reset and returned-storage lifetime
correctness are outside scope. No thread argument is implicitly consumed. A
program can pass these FRP guardrails and still have ordinary memory bugs.
Runtime queues, scheduling, unsafe pointer arithmetic and custom synchronization
are not certified. Parsing/setup failures still fail analysis; removing these
policies does not turn an analysis failure into a pass.

## Suggestions and coverage

Inlining analysis covers every saved, non-hidden regular `.odin` sibling in each
selected package directory, grouped by package name. Unselected siblings provide
use information but receive no lint findings. Unreadable or unparseable sibling
files and symlinked Odin siblings make analysis fail instead of permitting an
incomplete single-use claim. File symlinks are not followed.

`SIMPLIFY001` instructs the caller to inline and contributes to failure exit `1`,
like every other lint finding. It includes file-private and package-private
procedures. Public procedures and imported selectors are excluded; no cross-package consumer
analysis is attempted. There is no statement, line, or procedure-size threshold.
A single call in a package initializer, a procedure, or another expression
context can qualify. The count is syntactic, not an execution-frequency
estimate.

Stable identifier aliases, including alias chains and procedure variables with
no writes, resolve to their underlying procedure across the package. Alias
initializers do not count as additional runtime uses. Procedure aliases cannot
export private targets; public mutable aliases, reassigned aliases, returned or
stored procedure values, callbacks, and other escaping references prevent a
single-use claim. Dynamic expression/overload selection is not inferred.

Lexical scopes cover procedure parameters/results, polymorphic procedure and
aggregate parameters, local declarations, nested blocks, loops, and switch
cases. Parameter defaults use the enclosing scope, before parameter/result names
can hide outer declarations. Declaration names, struct fields, enum members,
selector names, and named argument labels are distinct from procedure uses.
Map-key expressions and struct-field labels are classified after the complete
package symbol table exists. An unresolved literal type keeps possible key uses
conservative rather than assuming an identifier is only a field label. Known
local `using` struct/enum members are expanded in their scope. Conditional
promotions retain possible outer bindings. Unresolved providers keep affected targets ineligible for speculative inlining
without producing an ambiguity diagnostic or disabling unrelated analysis. Literal `when` conditions select their known branch.
Saved source guards can establish configuration-aware identity without choosing
one compiler target or define configuration. Explicit parsed `#+build` OS and
architecture sets, their complements, and `#+project_name` groups constrain file
availability. Boolean `when` guards support literals, `!`, `&&`, `||`, Boolean
equality, `ODIN_OS`/`ODIN_ARCH` comparisons, and stable identifier aliases. A
Boolean atom is tied to its lexical binding, so unrelated same-named flags do not
prove one another. Other expressions retain their own identity; their `else`
branch is still an exact complement.

Resolution requires exactly one available binding in every configuration admitted
by the use. Disjoint exhaustive alternatives resolve together, and call summaries
retain the union of their effects. Matching guarded uses may resolve conditional
foreign declarations. Overlapping alternatives, missing coverage, unknown using
providers, and unmatched guards remain local uncertainty. A filename such as
`main_web_development.odin` does not establish a relationship to a separate
`WEB_DEVELOPMENT` define. Compiler command lines and build-system overlays are not
inferred from filenames or the host, and the linter never invokes the compiler.

The call graph follows resolved aliases and includes nested procedure
relationships. Recursive cycles suppress inlining. Non-visibility attributes
also exclude a procedure. Declaration ordering uses the broader reference graph
described above. These are review suggestions and do not rewrite source files.

Full computed/overload resolution and arbitrary foreign effect inference
are not implemented; supported resolved project effects are summarized as above.
Consumer-specific owner names and index-key conventions are not assumed globally.
SoA, stable identity, normalization,
atomic transactions, dependency approval, and tunable versus mathematical
constants require additional semantic or project evidence.

The parser reads package files regardless of target/build tags; the preceding
Odin checks follow their supplied configuration. Scan all source whose policy
diagnostics matter. A clean lint result says nothing about compiler success or
unused code; those checks remain the caller's responsibility.

The CLI reads saved files and uses host path conventions. It does not read
editor buffers, run the target application, rewrite files, or keep a
daemon/cache. macOS arm64 was validated; other hosts/compiler versions still
need coverage.

## Compiler and library modeling refinements

The tooling parser may retry compiler-checked input with lexer-inserted semicolons
spelled explicitly. This changes no compiler token boundary or source file. AST
positions, comments and diagnostic locations are mapped back to the original
input. Unsupported input remains an analysis failure.

Builtin `Maybe(T)` type construction and `raw_data` do not introduce unknown
callback effects; `raw_data` preserves known protected-state provenance.
Known `core:mem` zero/copy/move/set operations carry writes to their destination,
including through raw pointers and reordered named arguments, and retain that
destination alias in returned values. The standard `testing.expect` and `testing.expect_value` assertions are modeled
inside compiler-attributed test procedures. Other testing APIs, including deferred
cleanup registration, remain unknown until their callback effects is
modeled; ordinary production calls retain normal effect restrictions. `@(rodata)` globals are read-only definitions, not ambient
mutable inputs. Their referents are not recursively certified immutable by a
shallow storage attribute.

Single-use inlining remains an instruction contributing to failure exit `1`.
No procedure-size cutoff or automatic source rewrite is used. For generated code,
apply the change to its generating implementation.

## Outcome and library evidence

Array bounds and other value operands retain value context independently of
surrounding type positions. The pinned JSON module's declared scalar, reference,
union and enum types are recognized when used as conversions rather than unknown
callbacks. Reviewed public `core:c` type declarations are also recognized as
conversions, including stable type aliases; this grants no purity to libc
procedures. Reference conversions preserve their argument's backing storage,
protected-state provenance. This does not grant purity to a
whole module or custom serialization registry.

Named return slots receive explicit result values before deferred cleanup.
Cleanup still contributes actual state writes and counter effects. Boolean transaction outcomes and
short-circuit conditions preserve the paths on which a scope actually opens.
A false return alone never proves the helper did not increment a counter.
Proven lifecycle counter resets may complete a scope; arbitrary custom rollback
and synchronization protocols remain outside the proof.

A local pointer slot and its meaningful referent carry separate permissions.
Changing a local link does not mutate its referent, and following that link does
not grant local write permission to meaningful state.

Tokenizer handlers carry their own effects: the default handler may write to
stderr, an established nil handler is silent, and unresolved handlers retain
uncertainty. Direct calls and aliases of the default handler keep that I/O effect.
The public rune readers and scanner helpers invoke the handler saved in their
tokenizer, including error paths that update its error count. Keyword-table
initialization requires a writable destination without invoking a handler.
Custom mapped imports and complete sibling packages can supply
analysis-only bodies beneath vendor without becoming selected lint targets.
Missing/unsafe analysis inputs remain errors; no linter rule is disabled by
using a collection or by excluding third-party files from selected diagnostics.
