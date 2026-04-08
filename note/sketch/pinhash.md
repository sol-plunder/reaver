# remaining pinhash design issues

This is an ongoing unresolved design issue.  It is easy enough to add a jet for this but it is hard to come up with one that is worthy of freezing or that can be implemented without a lot of code.

One problem is that serialization and hashing are both pretty mechanically complicated, and there are a lot of different ways to do both with no obviously correct choice.

I put a ton of work into trying to avoid jetting this and just have a generic Memorization mechanism instead, but I conclude that this either requires the management of a significant hidden data structure (map pins to hashes) with no good solutions (need weak refs? How to prune? How to persist?) or mutation (which breaks our persistence model and GC scalability solutions).

Current best guess at an approach is to just jet it, but have the jet impl be written in XPLAN to avoid needing many deps in the runtime.

- Write serialization and hashing in XPLAN, explicitly mutating hash slots on pins to implement memoization.
- Register this plan fn with the runtime as the jet impl.
- Separate formal jet imp in PLAN.
- runtime system always hashes before moving data into an immutable heaps (shared heap or persisted heap).

----

https://github.com/sol-plunder/reaver/blob/master/note%2Fsketch%2Fserialize.md

^ I think something like this format should be used for external storage and for hashing.

And I think we should use sha256 for pin hashing.  It is a lot less code than BLAKE, simpler, and has hardware support.

- https://github.com/ml3m/SHA256-ASM-X86-64

- https://www.nayuki.io/res/fast-sha2-hashes-in-x86-assembly/sha256-x8664.S

Probably this should actually be how pinhash is implemented: sha256 + this format.

In particular, serialization should be made to support streaming into a buffer and then that should be combined with an sha256 hash function to support hashing without any allocations.