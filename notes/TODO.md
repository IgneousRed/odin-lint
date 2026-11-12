# Open work and decisions

Ordered roughly by expected return on effort. Confidence expresses usefulness,
not permission for out-of-scope implementation.

## FRP guardrails

1. **Review concrete state-boundary reports when reproduced. Confidence: 9/10.**
   Use unfiltered compiler-gated output with exact source and configuration.
   Distinguish protected meaningful-state writes from private construction/cleanup,
   and published catalog storage from a catalog datatype. Unknown storage and
   custom protocols remain inconclusive. New audit records identify the linter
   version and source revision; obsolete consumer histories are not retained.
2. **Keep external models optional. Confidence: 9/10.**
   Model an operation only when it establishes useful FRP writes/effects. Unknown
   callbacks, opaque types and configurations remain silent. No allocator or
   lifetime contract is required to use a library.

General allocation/free, scratch escape, dangling returns, queue element liveness
and exclusive-message proofs are outside the agreed scope. OWN003/OWN004 and
their unfinished lifetime-analysis backlogs are retired, not deferred work.

## Workflow and distribution

1. **Finish public distribution of 0.7.1. Confidence: 10/10.**
   Publish the sanitized source with fresh history. Keep the hosted repository
   private until old private development commits are no longer retrievable;
   rewriting refs alone does not purge hosted cached views. Confirm both hosted
   verification jobs and a fresh unauthenticated installation before release.
2. **Choose an external review policy. Confidence: 10/10.**
   No reviewer or mandatory external review policy has been selected. Resolve
   who reviews which changes and what happens when unavailable.
3. **Validate future hosts/compiler upgrades deliberately. Confidence: 9/10.**
   Odin dev-2026-11a `9a6991685` is pinned. Preserve compiler checks before lint and
   existing targets/collections/defines. Reproduced compiler crashes need compiler
   evidence; do not weaken vet/style checks or treat skipped lint as clean.
4. **Decide preservation before a stateful mode. Confidence: 8/10.**
   The current CLI persists no analysis state. A future daemon/incremental/editor
   mode needs an explicit preservation decision and separate scope approval.
