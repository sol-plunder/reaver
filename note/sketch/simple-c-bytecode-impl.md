# TODO: This is incorrect

This is an LLM generated document created from notes and it contains some hallucinations which seem reasonable but which are very misleading and wrong.  This needs human attention before any implementation attempt.

# PLAN: A Portable C Runtime

## Overview

PLAN is a minimal functional programming system named after its four
value types: **Pins**, **Laws**, **Apps**, and **Nats**. This document
proposes a design for a simple, portable C implementation of the PLAN
runtime. The goal is correctness and minimality. The implementation
should be small enough to audit completely and port to new platforms
with modest effort.

The runtime is the price of admission, paid once. Everything above it —
the optimizer, jet matching, the module system, the toolchain — is PLAN
written in PLAN and runs on any conforming implementation.

---

## Value Model

Every PLAN value is one of four types.

**Nat** — A natural number of arbitrary size. Small nats fitting in 61
bits are immediate (stored in the pointer word). Large nats are heap
objects.

**Pin** — A content-addressed immutable wrapper around another value.
A pin's identity is determined entirely by its hash. Pins are eternal:
once created they never change and never move.

**Law** — A supercombinator function. Has an arity, a name (a Nat),
and a body (a PLAN value). Laws have no free variables.

**App** — A function application. Has a head and a flat array of
arguments. The head of an App is never another App. Apps are always
flat: `((f x) y)` is stored as `App(f, [x, y])`, not as nested Apps.
This eliminates spine-unwinding during evaluation.

**Thunk** — A suspended computation: a code pointer (law + bytecode
offset) and a captured environment (array of Vals). Thunks are updated
in place when evaluated, enabling sharing.

---

## Tagged Pointer Representation

All values are represented as a single `uintptr_t`. The low 3 bits
encode the type tag. Heap pointers have these bits cleared (objects are
word-aligned). Small nats are stored directly in the upper 61 bits with
a tag distinguishing them from pointers.

```c
typedef uintptr_t Val;

#define TAG_APP   0x0   // pointer to App object  (most common; no tag cost)
#define TAG_LAW   0x1   // pointer to Law object
#define TAG_PIN   0x2   // pointer to Pin object
#define TAG_THUNK 0x3   // pointer to Thunk object
#define TAG_SMALL 0x4   // immediate nat: value in bits 3..63
#define TAG_BIG   0x5   // pointer to large Nat object

#define TAG_OF(v)      ((v) & 0x7)
#define PTR_OF(v)      ((ObjHdr*)((v) & ~0x7ULL))
#define SMALL_NAT(n)   (((Val)(n) << 3) | TAG_SMALL)
#define IS_SMALL(v)    (TAG_OF(v) == TAG_SMALL)
#define SMALL_VAL(v)   ((v) >> 3)
```

---

## Heap Object Layout

Every heap object begins with a header word encoding the tag, a GC
mark bit, the number of pointer fields, and the object size in words.

```c
// header: [tag:3][gc_mark:1][n_ptrs:28][size_words:32]
typedef uintptr_t ObjHdr;
```

The `n_ptrs` field tells the GC how many word-sized Val fields follow
the header (after any scalar prefix). This means the GC never needs a
type switch to trace objects — it reads `n_ptrs` and scans that many
words.

Object layouts:

```
App:   [hdr: n_ptrs=1+nargs] [head: Val] [arg0: Val] [arg1: Val] ...
Law:   [hdr: n_ptrs=2]       [arity: u64] [name: Val] [body: Val] [bc: ptr]
Pin:   [hdr: n_ptrs=1]       [inner: Val]
Thunk: [hdr: n_ptrs=varies]  [law: Val] [offset: u32] [env0: Val] ...
BigNat:[hdr: n_ptrs=0]       [nlimbs: u32] [limb0: u32] ...
```

The bytecode pointer on a Law object is not a Val and is not traced by
the GC. It points into a separately managed bytecode buffer (either a
static array or a pinned heap allocation).

A Thunk's code pointer is a (Law Val, byte offset) pair. The Law Val
is a normal Val and gets updated by GC if the law moves. The offset is
a plain integer and never changes. This pair is sufficient to resume
execution at any bytecode position.

---

## Memory: Heap and Allocator

Each actor owns its own heap. The heap consists of two equal-sized
regions (from-space and to-space) used for semi-space copying GC.
Allocation is a simple pointer bump into from-space.

```c
typedef struct {
    Word *from_start, *from_end, *bump;
    Word *to_start,   *to_end;
} Heap;

static inline ObjHdr *heap_alloc(Heap *h, size_t words) {
    if (h->bump + words > h->from_end) return NULL;  // trigger GC
    ObjHdr *p = (ObjHdr*)h->bump;
    h->bump   += words;
    return p;
}
```

When `heap_alloc` returns NULL, the interpreter fires GC before
retrying the allocation.

---

## Garbage Collection

Semi-space copying GC using Cheney's algorithm. Because each actor has
its own heap, GC is per-actor and does not stop other actors.

The complete root set is the actor's explicit value stack. No other
roots exist — the interpreter loop holds no Vals in C locals (see
below), and pin-space Vals are stable and never traced.

```c
void actor_gc(Actor *a) {
    Heap *h = &a->heap;
    // Evacuate all roots
    for (int i = 0; i < a->interp.sp; i++)
        a->interp.stack[i] = gc_evacuate(h, a->interp.stack[i]);
    // Scavenge: follow pointers in to-space until done
    gc_scavenge(h);
    // Flip spaces
    Word *tmp      = h->from_start;
    h->from_start  = h->to_start;
    h->from_end    = h->to_end;
    h->to_start    = tmp;
    h->to_end      = tmp + heap_half_size;
    h->bump        = h->from_start;
}

Val gc_evacuate(Heap *h, Val v) {
    if (!in_working_heap(v)) return v;   // immediate or pin-space: skip
    ObjHdr *obj = PTR_OF(v);
    if (obj->hdr & FWD_BIT) return obj->fwd;   // already forwarded
    size_t  sz   = obj_size_words(obj);
    ObjHdr *copy = (ObjHdr*)h->to_bump;
    h->to_bump  += sz;
    memcpy(copy, obj, sz * sizeof(Word));
    obj->hdr = FWD_BIT;
    obj->fwd = make_val(copy, TAG_OF(v));
    return obj->fwd;
}

void gc_scavenge(Heap *h) {
    Word *scan = h->to_start;
    while (scan < h->to_bump) {
        ObjHdr *obj  = (ObjHdr*)scan;
        int     base = ptr_field_offset(obj);
        int     nptr = n_ptrs(obj);
        for (int i = 0; i < nptr; i++) {
            Val *field = (Val*)(scan + base + i);
            *field = gc_evacuate(h, *field);
        }
        scan += obj_size_words(obj);
    }
}
```

### Pin Space

Pins are mapped into a reserved region of the address space and never
moved. The GC recognizes pin-space pointers by address range and skips
them.

```c
#define PIN_SPACE_BASE  0x0000200000000000ULL
#define HEAP_BASE       0x0000400000000000ULL

static inline int in_working_heap(Val v) {
    if (IS_SMALL(v)) return 0;
    return (uintptr_t)PTR_OF(v) >= HEAP_BASE;
}
```

Pins are serialized to disk as content-addressed files keyed by
SHA-256 hash, then mmapped back into pin space at stable addresses.
Multiple processes loading the same pin share physical pages through
the OS page cache at no extra cost.

---

## The Explicit Value Stack

Each actor has an explicit value stack: a heap-allocated array of Val.
This stack is the complete GC root set and the complete execution state
of the actor. An actor can be suspended and resumed by any OS thread
simply by picking up its Actor struct.

```c
typedef struct {
    Val     *data;
    int      sp;
    int      cap;
    uint8_t *ip;        // instruction pointer into current law's bytecode
} Interp;
```

The stack holds only Val values. Return frame information is not stored
on the value stack as separate frame objects — instead it is stored in
the Thunk objects on the heap (see Thunk Evaluation below).

Stack overflow detection is a bounds check before each push. When
capacity is exhausted, the stack array is reallocated (realloc or a
fresh allocation with copy). Because the GC already knows the stack's
base address and length, resizing is safe as long as it happens at a
point when no pointers into the stack exist — which is always true
since the stack holds Vals, not pointers to Vals.

---

## The Flat Interpreter Loop

**The central constraint of this design**: no C function in the
evaluation path may hold a live Val in a C local variable across any
call that might allocate or trigger GC. The GC updates all Vals it
knows about (those on the explicit stack) but cannot update Vals in C
locals.

The solution is a single flat C function that drives all evaluation.
It never calls helper functions that call back into it. All evaluation
state lives on the explicit value stack. C call depth is O(1)
regardless of PLAN evaluation depth.

```c
void interp_run_slice(Actor *a, Scheduler *sched) {
    Interp *st = &a->interp;
    int fuel = FUEL_PER_SLICE;

    for (;;) {
        if (--fuel == 0) { sched_push(sched, a); return; }
        if (heap_exhausted(&a->heap)) actor_gc(a);

        switch (*st->ip++) {
        case OP_LOAD:    { ... break; }
        case OP_LIT:     { ... break; }
        case OP_CALL:    { ... break; }
        case OP_RET:     { ... break; }
        case OP_MK_THUNK:{ ... break; }
        case OP_FORCE:   { ... break; }
        case OP_PRIM:    { ... break; }
        case OP_JUMP:    { ... break; }
        case OP_JUMP_IF: { ... break; }
        }
    }
}
```

The only C locals are `st` (a pointer, not a Val) and `fuel` (an int).
`OP_PRIM` is the only opcode that calls C functions, and those
functions are always leaves — they never re-enter the interpreter.

### GC Discipline for Primitives

Primitive (jet) implementations that allocate must follow this rule:
push all live Vals onto the stack before any allocation, then re-read
them from the stack afterward. A Val in a C local is valid only until
the next allocation.

```c
// Example: Weld jet
case OP_PRIM_WELD: {
    // args are on the stack; read sizes before allocating
    int la = row_len(stack[sp-2]);
    int lb = row_len(stack[sp-1]);
    // reserve a result slot on the stack before allocating
    stack[sp++] = VAL_UNINIT;
    stack[sp-1] = alloc_app(&a->heap, la + lb);  // GC may fire here
    // re-read args from stack after potential GC
    Val result = stack[sp-1];
    Val av     = stack[sp-3];
    Val bv     = stack[sp-2];
    // fill result
    for (int i = 0; i < la; i++) app_set_arg(result, i,    app_arg(av, i));
    for (int i = 0; i < lb; i++) app_set_arg(result, la+i, app_arg(bv, i));
    sp -= 2;   // pop av, bv; result remains
    break;
}
```

---

## Bytecode

Law bodies are compiled to bytecode on first call and cached on the
Law object. A code pointer is a (Law Val, byte offset) pair. The Law
Val is traced by GC; the offset is a plain integer.

### Instruction Set

```
OP_LOAD   n       -- push stack[env_base + n]
OP_LIT    n       -- push literal[n] from the law's literal table
OP_CALL           -- reduction step: see below
OP_RET    n       -- unwind n slots, restore ip from thunk, return result
OP_MK_THUNK off   -- allocate thunk capturing env, pointing to offset off
OP_FORCE          -- normalize TOS (deep evaluation)
OP_PRIM   op      -- call C leaf function by index; never re-enters interp
OP_JUMP   off     -- unconditional branch
OP_JUMP_IF off    -- pop cond; branch if nonzero
```

The literal table is an array of Val values embedded in the compiled
bytecode object. `OP_LIT n` pushes `lits[n]`. Literal table entries
are Vals and are traced by GC as part of the bytecode object.

---

## Graph Reduction: Push-Apply

PLAN uses push-apply: the caller decides how many arguments to consume.
This concentrates the reduction logic in one place rather than
distributing it across every function's entry point.

### The Reduction Step (OP_CALL)

The reduction step is a single OP_CALL opcode, not a loop in C. Each
execution of OP_CALL does one step of the loop; if further reduction is
needed, it loops back through the bytecode dispatch.

The logic of one reduction step:

```
TOS is the function f; below it are arguments.

1. If f is a Thunk:
       force f (see Thunk Evaluation)
       retry with the forced result as f

2. If f is an App (closure):
       pop f
       push f's captured args (in order)
       push f's head
       // head is never an App (invariant), so this happens at most once
       retry

3. Compute arity = valArity(f)
   Compute have  = number of args below f on the stack

4. If have < arity:
       allocate App(f, args[0..have])
       pop f and all args from stack
       push the new App closure
       proceed (the closure is the result)

5. If have >= arity:
       pop f and exactly arity args
       push a return continuation (see Thunk Evaluation)
       jump to f's bytecode
       // when OP_RET fires, result lands where the continuation expects it
```

Because App heads are never Apps, step 2 executes at most once.

---

## Thunk Evaluation and Sharing

Thunks enable lazy evaluation with sharing: a deferred computation is
evaluated at most once, with subsequent references finding the cached
result.

A Thunk object contains a code pointer (law + offset) and a captured
environment (array of Vals). The thunk object is mutated in place
through three states:

**Eval** — the initial state. Contains the code pointer and environment.

**BlackHole** — set immediately when evaluation begins. If the same
thunk is forced again during its own evaluation, the BlackHole is
detected and evaluation aborts with an error. The BlackHole also stores
the return continuation: the code pointer (law + offset) to resume
after this thunk's evaluation completes. This information would
otherwise require a separate frame stack.

**Cached** — set when evaluation completes. Contains the result Val.
Subsequent forces return the cached result directly.

### Return Convention

The return continuation stored in the BlackHole is where OP_RET jumps
after a thunk's law body finishes. This means the "call stack" for
thunk evaluation lives on the heap as a chain of BlackHole thunks, not
as C stack frames. The interpreter holds no return addresses in C
locals.

OP_RET:
1. Pop result from stack top
2. Read return continuation (law + offset) from the current BlackHole thunk
3. Overwrite the thunk with Cached(result)
4. Set ip to the saved offset in the saved law
5. Push result

---

## Law Body Compiler

The law body is a PLAN value — a tree of Apps, Nats, Pins, and Laws.
The compiler walks this tree once and emits a flat bytecode array plus
a literal table. The compiled form is cached on the Law object and
reused for all subsequent calls.

### De Bruijn Environment

A law with arity N sets up an environment on entry:

```
env[0] = the law itself          (de Bruijn 0 = self)
env[1] = last argument           (de Bruijn 1)
env[2] = second-to-last argument (de Bruijn 2)
...
env[N] = first argument          (de Bruijn N)
```

`OP_LOAD n` pushes `env[n]`.

### Body Expression Forms

The compiler recognizes these patterns in the body expression at
current depth `d`:

| Pattern | Meaning | Emitted bytecode |
|---|---|---|
| `Nat(b)` where `b <= d` | variable reference | `OP_LOAD (d-b)` |
| `App(Nat(0), [f, x])` | application | compile f; `OP_MK_THUNK` for x; `OP_CALL` |
| `App(Nat(0), [x])` | literal quote | `OP_LIT n` (intern x in literal table) |
| `App(Nat(1), [v, k])` | let binding | `OP_MK_THUNK` for slot; compile v; `OP_UPD`; compile k |
| anything else | literal | `OP_LIT n` |

### Recursive Let Bindings

Let bindings may be self-referential. The compiler allocates the thunk
slot with `OP_MK_THUNK` before compiling the binding value, making the
slot referenceable via de Bruijn at the incremented depth. The binding
value is then compiled and `OP_UPD` overwrites the slot with the
result.

---

## BPLAN Primitive Dispatch

The runtime supports two primitive dispatch modes.

**Op 0** — the three core structural primitives, invoked via
`P(N(0))`:
- Sub-op 0: construct a Pin
- Sub-op 1: construct a Law
- Sub-op 2: match on Val type (the PLAN eliminator)

**Op 66** — named jets, invoked via `P(N(66))`. The first argument
is a Nat encoding the jet name as ASCII bytes (little-endian). The
runtime maintains a table mapping name Nats to C functions. In BPLAN
mode this table is hardcoded. After bootstrapping, PLAN code can
register compiled functions against laws via a registration primitive,
replacing the hardcoded table.

The op-66 table covers: arithmetic (Add, Sub, Mul, Div, Mod), bit
operations (Lsh, Rsh, Bor, Band, Bxor, Bex), comparisons (Eq, Lt,
Le), type inspection (IsNat, IsPin, IsLaw, IsApp, Type), law
introspection (Arity, Name, Body), row operations (Row, Weld, Slice,
Ix, Sz), sequencing (Seq, DeepSeq), and miscellaneous (If, Nat, Bits,
Bytes, Trunc, Force, Equal, Trace).

**Op 82** — IO and actor operations, invoked via `P(N(82))`:
read, write, spawn, send, recv, open, listen, accept, and related
socket operations.

---

## The Assembler

The assembler runs once at startup, before any actors start. It parses
PLAN assembly source files, evaluates names against an accumulating
environment, and produces pinned values as output.

The assembler uses the same bytecode interpreter as the rest of the
system. It can use arbitrary C call depth because it never needs to
suspend or be scheduled across OS threads. The constraint that drove the
flat loop design — no C frames holding live Vals across GC — still
applies, but GC during assembly can be triggered explicitly rather than
through fuel-based preemption.

Macros in PLAN assembly are PLAN functions. Evaluating a macro call
during assembly invokes the full PLAN evaluator. Because assembly and
macro expansion are interleaved, the assembler cannot be separated from
the evaluator.

---

## Actors

### Model

Each actor is a heap-allocated struct containing an interpreter state,
a private heap, an inbox, and a status flag.

```c
typedef struct Actor {
    Interp      interp;    // stack, ip
    Heap        heap;      // from-space, to-space, bump pointer
    Channel     inbox;     // ring buffer of pinned Vals
    ActorStatus status;    // RUNNABLE | BLOCKED_RECV | DONE
} Actor;
```

Actors communicate exclusively through pinned values. Before a value
crosses an actor boundary, it is pinned — serialized, hashed, and
mapped into pin space. This means:

- No shared mutable state between actors
- No GC coordination between actors
- Each actor's GC is completely independent

### Scheduler

A fixed thread pool with one OS thread per CPU core. All actors share
the pool. An actor is a plain struct — it requires no OS thread, no
C stack, and no context-switch mechanism. Suspending an actor means
returning from `interp_run_slice`; resuming it means calling
`interp_run_slice` again from any thread.

Preemption uses a fuel counter decremented on each bytecode step.
When fuel reaches zero, the actor is pushed onto the run queue and
`interp_run_slice` returns. No signals, no async-signal-safe
constraints.

When an actor executes Recv on an empty inbox, it sets its status to
BLOCKED_RECV and returns. It is not re-enqueued. When another actor
sends to it, the sender sets its status to RUNNABLE and enqueues it.

```c
void *worker_thread(void *arg) {
    Scheduler *sched = arg;
    for (;;) {
        Actor *a = sched_pop(sched);       // blocks if queue empty
        interp_run_slice(a, sched);
    }
}
```

---

## What Lives in C

The following must be implemented in C. Everything else runs as PLAN
code on this substrate.

- Tagged pointer representation and Val constructors
- Bump allocator and semi-space copying GC
- Explicit value stack with bounds checking and resizing
- Flat bytecode dispatch loop
- Law body compiler (PLAN value → bytecode)
- Op 0 primitives: pin, law, match
- Op 66 BPLAN jet table (~30 functions)
- Op 82 IO primitives: read, write, open, socket operations, spawn, send, recv
- Pin store: address space reservation, SHA-256 hashing, mmap management
- Assembler: s-expression parser, name resolution, macro expansion driver
- Scheduler: run queue, thread pool, send/wakeup logic

---

## Implementation Order

Each step has a clear testable output before the next begins.

1. **Values and memory** — tagged pointer representation, bump
   allocator, semi-space GC. Test GC thoroughly before proceeding;
   bugs here are invisible until they cause corruption much later.

2. **Bytecode interpreter** — flat dispatch loop, OP_LOAD / OP_LIT /
   OP_CALL / OP_RET, thunk object with three states, BlackHole return
   continuation storage.

3. **Law body compiler** — walk PLAN value body tree, emit bytecode,
   build literal table. Test with identity, const, and simple
   recursive laws.

4. **Op 0 primitives** — pin construction, law construction, match.
   These are sufficient to write self-referential PLAN programs.

5. **Op 66 jet table** — arithmetic, comparisons, type inspection, row
   operations. Test each jet independently.

6. **Op 82 IO primitives** — read, write, basic file operations.

7. **Pin store** — SHA-256 hashing, address space reservation, mmap
   load and store. Test round-trip: pin a value, write to disk, mmap
   back, verify identity.

8. **Assembler** — s-expression parser, name binding, macro expansion.
   Test by assembling small known programs and checking the resulting
   Val structures.

9. **Actors and scheduler** — Actor struct, run queue, thread pool,
   send/recv with pinning on send. Test with two actors exchanging
   messages.

---

## Estimated Scale

The complete implementation should be approximately 3000–5000 lines of C:

| Component | Lines |
|---|---|
| Values, allocator, GC | ~500 |
| Bytecode interpreter and law compiler | ~600 |
| Op 0 / Op 66 / Op 82 primitives | ~600 |
| Pin store | ~300 |
| Assembler | ~400 |
| Scheduler and actor machinery | ~400 |
| IO primitives | ~200 |

The codebase is intended to be small enough to read in an afternoon and
port to a new platform in a weekend. Complexity that can be pushed into
PLAN code should be.
