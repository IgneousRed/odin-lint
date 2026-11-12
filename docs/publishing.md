# Publishing and releases

Source repository: [IgneousRed/odin-lint](https://github.com/IgneousRed/odin-lint).
The code is released under the [Zero-Clause BSD license](../LICENSE): unrestricted
use, copying, modification and redistribution, with or without a fee, as is and
without warranty. This is a personal project with no promise of support,
continued maintenance or future compatibility.

## Publishing

Publish only the self-contained source, tests and project documentation. Exclude
machine-specific paths, private consumer details and local tool-pool instructions.
Private development history and old release/tag references must be removed before
public distribution. Review the source snapshot and Git metadata that will be
published; deleting a file alone does not remove its earlier revisions. Hosting
services may retain unreachable commits after refs are removed, so complete any
required host-side history removal before making private history public.

Run `make verify` and review the publication diff. The full suite includes an
independent consumer installation with a local Git transport fixture. It does
not prove that the GitHub URL is available.

Publish verified source on `main`. GitHub CI runs on pushes to `main` and pull
requests; a manual dispatch is also available. Confirm both matrix jobs before
distributing the revision. Then run the documented consumer bootstrap against
the real GitHub repository from a fresh project without GitHub credentials and
confirm the reported SHA. The workflow has read-only contents permission and no
publish step.

## Toolchain and CI

[verify.yml](../.github/workflows/verify.yml) pins official Odin dev-2026-11a
archives and SHA-256 digests from the
[official release](https://github.com/odin-lang/Odin/releases/tag/dev-2026-11a).
It targets Ubuntu 24.04 amd64 and macOS 15 arm64. The archive is verified before
extraction. The workflow pins its checkout and Python setup actions to full
commit SHAs. Python tooling uses the standard library; CI's interpreter is a
verification environment, not a minimum-version support promise.

Update the Odin toolchain, digests, compatibility docs and fixture checks together.
The exact compiler pin reflects parser and boundary-model compatibility. A new
runner matrix entry is a validation target, not a support claim until checks pass.

CI is project-independent. Each consuming project retains its own compiler entry
points, collections, defines and targets, then calls the pinned runner. Neither
this workflow nor the linter assumes access to local skills or another repository.

## Release identity and compatibility

`VERSION` identifies the source version. Before 1.0, increment the minor version
for added rules, policy changes or incompatible CLI/integration changes, and the
patch version for fixes that preserve documented policy. Fixes can change
findings; describe diagnostic changes in release notes. Leave updates to each
consumer's explicit commit-pin change.

For a release, update `VERSION`, document changes and the supported toolchain,
run `make verify`, commit, and confirm GitHub CI for that commit. Tag that verified
commit as `vVERSION` and publish its notes. Keep public release tags fixed.
Consumers resolve the release to a full SHA and record that immutable pin.
`--version` prints the version and embedded source revision; the runner always
stamps the fetched SHA. Direct compiler builds report `unknown` unless
`ODIN_LINT_REVISION` is supplied; Make stamps Git HEAD or accepts `REVISION` for
source archives.

New release, verification and audit records identify the linter version and
source revision, configurations and outcomes. Do not carry obsolete private
consumer audit narratives into the public repository.

No automatic release, repository creation or push occurs during verification.
