# Rework proposals

Proposals do not authorize implementation. Implemented behavior and analysis
limits remain in `docs/`.

1. **Plan organization changes as visibility/dependency groups. Confidence: 9/10.**
   `FILE004`, `FILE005`, `FILE006` and `VIS002` describe related constraints through
   separate findings. Mixed interfaces and generated packages can receive many
   local recommendations without one safe ordering of edits. Represent proposed
   declaration groups with visibility, consumer and private dependency constraints
   before describing moves/defaults. This would replace isolated relocation text
   with coherent plans and make unsatisfied constraints explicit. Pros: fewer
   incompatible edits, clearer treatment of private support and test/platform
   declarations. Cons: a larger planning model and proof obligations around
   conditional declarations and shared private dependencies. Public exports remain
   anchored regardless of saved local consumers.
   Version 0.4 already preserves conditioned interface families, irreducible private
   closure and valid namespace collisions. Reconsider a larger planner if the new
   consumer pass still has individually valid but collectively incompatible advice;
   preserve the agreed representable 60% policy and folder roles.

2. **Group concrete diagnostics by their originating operation. Confidence: 9/10.**
   FRP write/effect summaries repeat one originating operation at many callers.
   Uncertainty-only diagnostics were retired in 0.5; keep them silent. Version 0.4 discharges public-formal requirements at saved
   callers. Preserve full
   per-location records while adding complete originating requirements, propagation
   edges and evidence of a concrete invalid state-boundary caller. Pros: easier review without a
   bulk application refactor and clearer distinction between uncertainty and a counterexample. Cons: more
   provenance data and presentation design; no external caller may be certified
   merely because saved callers are private copies. Reconsider if the new consumer
   results still require repetitive manual tracing; keep all rules and their
   enforcement active.
