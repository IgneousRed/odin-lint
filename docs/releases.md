# Release notes

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
