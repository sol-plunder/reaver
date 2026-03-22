# Bootstrapping PLAN: BPLAN and the Two Towers

## Introduction

PLAN is a small axiomatic system. Rather than directly embedding all of
the primops into this specification, implementations recognize certain
functions as intrinsics (jets) and then substitutes fast native
implementations. The result of this architecture is that it becomes
possible to introduce new intrinsics without changing the formal
semantics.

Two other major design goals are to support hyperminimal VMs, and to have
many different VMs that remain compatible. In order to make this possible,
as much logic as possible needs to live inside the system itself rather
than in the implementation of any particular runtime: the toolchain,
the optimizer, the jet matching logic, etc.

The tension is that jet matching needs to be defined inside the system,
but the system needs jets to run efficiently, and jets require jet
matching to already exist. The resolution is to split the work into two
bootstrapping towers: an implementation tower that treats jets as
primitive operations in order to bootstrap the infrastructure, and a
formal tower that then defines everything correctly from axioms using
the environment the implementation tower produced.

## The Tensions

Jet matching requires efficient noun-equality for large nouns, which is
best implemented using a cryptograph hash function. Adding an
implementation of this to a tiny (3000 lines of assembly, with no
cstdlib) implementation is quite heavy.

Similarly, we would like to be able to define the jets in a nice
language, which runs efficiently using an optimizer. Again, building
these feature directly into a runtime system would add a ton of
complexity.

However, all of these things can easily be implemented in PLAN, but
only once we have jets and jet matching. But... we need things things
in order to implement jets and jet matching. A cyclic dependency which
we resolve using a form of dependency injection.

## Two Towers

**The implementation tower** treats jets as primitive operations from
the start. This is BPLAN: PLAN extended with jets as built-ins. Using
BPLAN, the implementation tower builds canonical serialization and a hash
function, jet matching logic, the optimizer, and the language toolchain
(Reaver, etc). The sequencing is load-bearing.  This tower runs first,
and its output is precisely the environment the formal tower requires.

**The formal tower** then defines everything from raw PLAN axioms, using
the language and jet infrastructure the implementation tower produced.
It takes no shortcuts, but it does not have to.  The hard infrastructure
work is already done.

## Virtualization

Once both towers are complete, BPLAN code can still be run inside a PLAN
context via virtualization: a PLAN interpreter written in PLAN and then
jetted. The outer context injects handlers for the extended primitives,
so the interpreter is generic and the behavior is determined entirely by
what handlers are passed in.

The same primitive-extension mechanism is also how effects and
platform-specific I/O are handled at runtime via XPLAN, JPLAN, and
user-defined ABIs like RPLAN. See [effects.md](effects.md) for that
story.

## Payoff

- All implementations share the same jet matching code, optimizer, and
  toolchain, since those are written in PLAN. Only the codegen backend
  is implementation-specific.

- The runtime shrinks to something genuinely minimal.

- New platforms become cheap to support, just provide an interpreter,
  the syscall surface, the intrinsic functions, and a codegen backend,
  and everything else is inherited.

- The formal and implementation stories are both clean, because they
  were never forced to compromise each other.
