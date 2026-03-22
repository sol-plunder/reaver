# BPLAN Architecture

## Background

PLAN is a minimal combinator runtime. The goal is a system where everything meaningful — the language toolchain, optimizer, and jet matching logic — is defined in PLAN itself, built up from axioms, with as little complexity as possible baked into the runtime.

In the old world, Sire (the language/toolchain) was either compiled into the runtime or loaded from a pill (a binary serialization of a noun). This pushes complexity into external binaries and makes the runtime heavy and hard to port. In the new world, implementations bundle an assembler and build everything from source, with PLAN as the medium for defining the toolchain and all higher-level machinery.

## The Bootstrapping Problem

The ideal is to write the optimizer, jet matching logic, and toolchain in PLAN. Writing them in raw assembly would be unreasonable in practice, and having them in PLAN means all implementations can share the same code.

However, jet matching is not trivial. Jets are intrinsic functions: the runtime recognizes a known PLAN expression by hashing its canonical serialization and, on a match, dispatches to a fast native implementation instead. This requires both a canonical noun serialization format and a hash function — neither of which comes for free. PLAN itself can be implemented in roughly 3,000 lines of assembly with no dependencies, so these primitives are actually quite heavy in proportion.

This creates a circularity: you want to define jet matching in PLAN, but you need jets to run PLAN efficiently, and jet matching has to exist before jets work.

## Two Towers

The resolution is to recognize that there are actually two separate bootstrapping goals with conflicting needs, and to stop trying to satisfy them simultaneously.

**The implementation tower** starts from a small runtime and needs to make practical progress. It does not care about formal purity — it just needs jets available immediately in order to build the rest of the system. This is BPLAN: PLAN extended with jets as primitive operations. Using BPLAN, the implementation tower builds:

- Canonical noun serialization and a hash function
- Jet matching logic
- The optimizer (lazy evaluation untangling, analogous to GHC's simplifier/STG pipeline)
- The language toolchain (Reaver, Sire)

The output is a working system with a comfortable language and live jet optimization machinery.

**The formal tower** then uses that environment to define everything from raw PLAN axioms. It needs a nice language to work with, and it needs jets to be optimized as they are defined. Both of those things are only available because the implementation tower already ran. The formal tower does not take shortcuts — it derives everything correctly — but it can do so comfortably because the hard infrastructure work is already done.

The sequencing is load-bearing: the impl tower must run first, and its output is precisely the environment the formal tower requires.

## Virtualization

Once both towers are complete, BPLAN code can still be run inside a PLAN context via virtualization: a PLAN interpreter written in PLAN and then jetted. The outer context injects handlers for the extended primitives (syscalls, etc.), so the interpreter is generic and the behavior is determined entirely by what handlers are passed in.

This same pattern extends to:

- **XPLAN**: PLAN extended with amd64/Linux syscalls
- **JPLAN**: PLAN extended with JavaScript browser APIs

Both are just instances of the same evaluator with different handler sets. This means device drivers and platform-specific logic — things that previously lived in the runtime (timers, networking, etc.) — can be implemented in PLAN instead, with the runtime only providing the syscall surface. Virtualization also serves as the portability and isolation story: XPLAN or JPLAN code can run sandboxed inside any PLAN context by swapping handlers.

## Payoff

- All implementations share the same jet matching code, optimizer, and toolchain, since those are written in PLAN. Only the codegen backend is implementation-specific.
- Device drivers move out of the runtime and into PLAN, radically reducing what a production runtime needs to provide.
- The runtime shrinks to something genuinely minimal.
- New platforms become cheap to support — provide the syscall surface and a codegen backend, and everything else is inherited.
- The formal and implementation stories are both clean, because they were never forced to compromise each other.