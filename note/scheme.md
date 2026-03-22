Reaver calls itself a "Scheme", but that isn't really true.  It uses Scheme syntax, but the semantics work more like Haskell.  Functions arguments are curried, instead of taking a variable number of arguments.  Functions return one value.  There is no support for continuations, or mutation.  There aren't any ports and there's no way to implement such things in Reaver because PLAN is pure.

however, it *is* possible to implement a nearly complete Scheme in PLAN.  to do this, you would need to

- Compile scheme code to continuation passing style.
- Make every function strict by forcing each arguments and let binding.
- Have every function take a list of arguments, and invoke a continuation with a list of return values.
- Run in a virtualization context that provides effects for ports and mutable values.

This would be slow, but the optimizations needed to improve it are pretty standard and well understood.

You cannot support `set-car!` and friends, since that would be too expensive, but mutable bytearrays, mutable vectors, IORefs, and ports (buffered IO) are all possible efficiently through virtualization.

This could actually be a pretty good way to write code in plan, because the CPS style means that continuations become actual physical PLAN values that can be saved.

## Appendix: Mutation in a Pure System

### Two Complementary Mechanisms

PLAN is pure, but practical systems need mutation. Two mechanisms work together to provide it, each covering the cases where the other falls short.

**Uniqueness typing** handles the common case. A unique type statically guarantees that at most one reference to a given value exists at any point in the program. This means the runtime can safely update it in place — nobody else is holding a reference to the old state, so the mutation is unobservable from the outside. The program logic treats it as a pure transformation (consume the old value, produce a new one), but physically nothing is copied. This is the same idea as Rust's ownership system or Clean's unique types.

**Virtualization-based mutable handles** handle the cases uniqueness typing cannot. Some situations require shared, non-unique access to mutable state — buffered I/O streams being the canonical example, where multiple parts of a program may need to reference the same buffer. A unique type cannot be aliased by definition, so a different approach is needed.

The virtualization handler solves this by never surrendering the actual value into the PLAN world at all. PLAN code only ever sees an opaque ID — a capability token. The real data lives entirely inside the handler, outside the pure runtime. Because only the handler holds a reference to the value, it can safely mutate it in place whenever a request arrives. Multiple PLAN references to the same ID are fine, because none of them can access or alias the underlying data directly — they can only make requests through the handler interface.

This is structurally the same idea as Haskell's `IORef`: a reference to a mutable box maintained by the runtime, accessed only through the IO monad. The IO monad enforces that you cannot smuggle the reference into pure code; the virtualization handler enforces the same by never exposing the value at all. The PLAN approach is arguably more explicit about where the mutation actually lives.

### Why This Matters

Persistent immutable data structures cover an enormous range of problems, but there are algorithms where mutation is not incidental — it is load-bearing. Union-find, in-place sorting, hash tables with open addressing, and certain graph algorithms are cases where a purely functional encoding either carries a real performance penalty or obscures the algorithm itself.

Having a principled, well-contained mechanism for mutation in these cases is a sign of a mature design rather than a compromise. The system remains pure and deterministic where that matters, and pragmatic where it has to be. The two mechanisms — uniqueness typing for exclusive ownership, virtualization handles for shared mutable state — together cover the full range of practical mutation needs without contaminating the pure core.
