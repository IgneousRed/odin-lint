# Publishing and releases

Source repository: [IgneousRed/odin-lint](https://github.com/IgneousRed/odin-lint).
The code is released under the [Zero-Clause BSD license](../LICENSE): unrestricted
use, copying, modification and redistribution, with or without a fee, as is and
without warranty. This is a personal project with no promise of support,
continued maintenance or future compatibility.

## Participation and review

IgneousRed is the sole maintainer and decides the project's direction and which
changes to accept. Reproducible bug reports and small pull requests are welcome;
responses, acceptance and future development are discretionary.

The maintainer reviews changes before publishing them. External review is optional
and does not block publication when unavailable. Compiler checks, self-lint and
the full Odin/CLI suite, including independent distribution tests, remain required
for code changes.

Releases distribute source with fixed version tags and full commit-SHA pins.
Consumers build their chosen revision with the canonical Nix package or the
standalone runner and documented Odin compiler. Prebuilt binaries, installers
and a Marketplace action are outside the current distribution scope.

## Publishing

Publish only the self-contained source, tests and project documentation. Exclude
machine-specific paths, private consumer details and local tool-pool instructions.
Audit complete outgoing ancestry, owned published refs and blob contents, not only the
final tree or newly uploaded range. Run
`./scripts/dev python3 scripts/publication-guard.py` before pushing; the tracked
pre-push hook checks complete ancestry against the approved destination and path
whitelist. Review content for consumer data manually as well: path and file-type
checks cannot establish anonymity or detect every partial copy. Unknown paths
require review before extending the whitelist. `.private/`, `.local/`, `.vendor/` and `.work/`
never belong in public commits or source packages. Private uploads are limited
to anonymized planning and experiment records; `.local/`, `.vendor/` and `.work/` never belong
there either. Agent instructions are private working material: no root or nested
`AGENTS.md` belongs in public history or source exports. Active instructions may
remain ignored locally, with maintained copies in the private companion.

When material is reclassified to lower visibility, first preserve required content
at its approved destination, then purge it from the old more-visible repository
history. Cover old rename paths, copied blobs, all affected owned branches/tags,
and release/source archives; moving or deleting files only at HEAD is insufficient.
Audit dirty work and the exact outgoing owned refs so old ancestry cannot simply
return to a public push. The pre-push guard allows only public `main` and the
reviewed release tags, or private `main`. Extend this explicit list only for an
authorized publication. Never mirror-push or send `refs/t3/*`, backup/original
refs or other machine-only recovery. Local T3 undo/checkpoint refs, app metadata
and retained thread/worktree bindings are not public refs and remain untouched.
No T3 maintenance or shutdown is a publication prerequisite.
Identify pinned-consumer impact and coordinate authorized
replacement SHAs, fixed hashes and matching runners before remote replacement.
Reverify invalidated source/package/pin identities. Necessary history rewrites
and force-updates of affected owned refs are authorized; otherwise preserve
unaffected history and assets. The normal fixed-tag rule below does not require
retaining reclassified content in old tags.

Owned-ref sanitation is not proof of host-wide erasure. Cached/unreachable objects,
PR refs, forks and other clones can remain outside verified control. Report what
was checked and any residual exposure. Prepare a support request if needed, but
send none without user approval.

Run `./scripts/dev make precommit` and review the publication diff. Before every
commit, run the read-only `./scripts/check-deps` update report; `precommit` runs
this first. Report available updates without silently changing the locks. Network
or unsupported-source errors leave that check incomplete. The full suite includes an
independent consumer installation with a local Git transport fixture. It does
not prove that the GitHub URL is available.

Publish locally verified source on `main`. Run the documented consumer bootstrap
against the real GitHub repository from a fresh project without GitHub credentials
and confirm the reported SHA before distributing the revision. Verification is
local; there is no GitHub Actions workflow or hosted-check release prerequisite.

## Local toolchain and verification

Use the Odin dev-2026-11a compiler commit `9a6991685`/`9a69916` documented in
README. Use the locked environment through `scripts/dev`, which supplies the
compiler with LLVM 23.1.6 on Apple Silicon macOS and the existing LLVM 22 recipe
on Linux. Confirm it with `./scripts/dev odin version` and
`./scripts/dev odin report`; see
[fuzzing setup](fuzzing.md). Python tooling uses the standard library without an
arbitrary minor-version support floor.

Update the compiler pin, compatibility docs and fixture checks together. The exact
pin reflects parser and boundary-model compatibility. Validate a new host or
compiler with its actual targets, collections and defines before claiming support.
Compiler checks, freshly built self-lint, the Odin/CLI/distribution suite and
macOS fuzzing remain local verification requirements through `./scripts/dev make precommit`.

Each consuming project retains its own compiler entry points, collections,
defines and targets, then calls its pinned native package or standalone runner.
Neither local verification nor the linter assumes access to local skills or
another repository.

## Release identity and compatibility

`VERSION` identifies the source version. Before 1.0, increment the minor version
for added rules, policy changes or incompatible CLI/integration changes, and the
patch version for fixes that preserve documented policy. Fixes can change
findings; describe diagnostic changes in release notes. Leave updates to each
consumer's explicit commit-pin change.

For a release, update `VERSION`, document changes and the supported toolchain,
run `./scripts/dev make precommit`, commit, and validate the public consumer bootstrap for that
commit. Tag that locally verified commit as `vVERSION` and publish its notes.
Keep public release tags fixed.
Consumers resolve the release to a full SHA and record that immutable pin.
`--version` prints the version and embedded source revision; the runner always
stamps the fetched SHA. The Nix package requires and embeds the exact payload SHA;
its local development output uses `unknown` when a clean source revision is not
available. Direct compiler builds report `unknown` unless
`ODIN_LINT_REVISION` is supplied; Make stamps Git HEAD or accepts `REVISION` for
source archives.

New release, verification and audit records identify the linter version and
source revision, configurations and outcomes. Do not carry obsolete private
consumer audit narratives into the public repository.

No automatic release, repository creation or push occurs during verification.
