# Encoding Effects in PLAN

## Two Models for Effects

There are two baseline models for effects in a functional system: the
inside-out state machine (as in Urbit/Nock) and direct impure effects
(as in Lisp).

In the state machine model, a program never performs effects directly.
Instead it produces a request value describing what it wants done, and
the runtime calls it back with a response, yielding a new request and a
new callback. The entire program state at any point is a serializable
data structure which can be saved to disk, inspected, replayed, and
resumed.

The cost is overhead: every effectful operation requires constructing a
request, returning through the runtime, and invoking a continuation.
This makes the model unsuitable for low-latency IO like raw socket
operations.

In the impure model, effects are performed directly. This is fast and
simple, but determinism, replayability, and sandboxability are gone
entirely.

## PLAN's Approach

PLAN is deterministic like Nock, and supports the state machine model
for persistent machines that need replayability. But we also need fast
IO, which the state machine model cannot provide.

The resolution is to introduce impure extended variants of PLAN that
directly support effects via handler injection. The main instances are:

- **XPLAN**: PLAN extended with amd64/Linux syscalls

- **JPLAN**: PLAN extended with JavaScript browser APIs

PLAN itself remains pure. Impurity is confined entirely to the injected
handlers. The purity boundary runs along the handler set, not along any
other architectural line.

## Portable ABIs

XPLAN and JPLAN are intentionally thin and non-portable. They provide
only the raw syscall surface of their host platform and do not pretend
to be anything else. Most code is portable PLAN written against abstract
ABIs that sit on top of them.

Portable imperative ABIs (like RPLAN, a PLAN ABI for REPL interaction)
are defined in terms of PLAN virtualization, with a thin
platform-specific driver implemented in XPLAN or JPLAN. The program
logic is written against the abstract ABI and is therefore portable;
only the driver is platform-specific.

Code that needs fully serializable program state uses the explicit
request/continuation model instead, as described above. The choice
between the two is explicit: virtualization for performance,
request/continuation for persistence and inspectability.

## Appendix: The IO Monad

Haskell's IO monad appears to be a middle path: It looks like the state
machine approach at the type level, organizing pure and impure code into
distinct layers.

But Haskell supports impurity through `unsafePerformIO`, and after the
optimizer processes Haskell code, it no longer resembles callbacks; it
looks like direct effects. Operationally, the IO monad is just the Lisp
model: the type system is a useful organizational tool for the
programmer, but it does not change what the runtime actually does.

The IO monad is genuinely valuable for what it is designed to do,
helping programmers organize code and reason about composability.
However, determinism and operational purity are not its goals, and it
does attempt to enforce them.
