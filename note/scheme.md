Reaver calls itself a "Scheme", but that isn't really true.  It uses Scheme syntax, but the semantics work more like Haskell.  Functions arguments are curried, instead of taking a variable number of arguments.  Functions return one value.  There is no support for continuations, or mutation.  There aren't any ports and there's no way to implement such things in Reaver because PLAN is pure.

however, it *is* possible to implement a nearly complete Scheme in PLAN.  to do this, you would need to

- Compile scheme code to continuation passing style.
- Make every function strict by forcing each arguments and let binding.
- Have every function take a list of arguments, and invoke a continuation with a list of return values.
- Run in a virtualization context that provides effects for ports and mutable values.

This would be slow, but the optimizations needed to improve it are pretty standard and well understood.

You cannot support `set-car!` and friends, since that would be too expensive, but mutable bytearrays, mutable vectors, IORefs, and ports (buffered IO) are all possible efficiently through virtualization.

This could actually be a pretty good way to write code in plan, because the CPS style means that continuations become actual physical PLAN values that can be saved.