# remaining pinhash design issues

This is an ongoing unresolved design issue.  It is easy enough to add a jet for this but it is hard to come up with one that is worthy of freezing or that can be implemented without a lot of code.

One problem is that serialization and hashing are both pretty mechanically complicated, and there are a lot of different ways to do both with no obviously correct choice.

I put a ton of work into trying to avoid jetting this and just have a generic Memorization mechanism instead, but I conclude that this either requires the management of a significant hidden data structure (map pins to hashes) with no good solutions (need weak refs? How to prune? How to persist?) or mutation (which breaks our persistence model and GC scalability solutions).

Current best guess at an approach is to just jet it, but have the jet impl be written in XPLAN to avoid needing many deps in the runtime.

- Write serialization and hashing in XPLAN, explicitly mutating hash slots on pins to implement memoization.
- Register this plan fn with the runtime as the jet impl.
- Separate formal jet imp in PLAN.
- runtime system always hashes before moving data into an immutable heaps (shared heap or persisted heap).