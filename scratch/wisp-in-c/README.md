# wisp.c Modernization Plan

This is an LLM-generated document describing the changes needed to bring
wisp.c up to date with the current version of the Plan Assembly language.

Since this document is LLM-generated, take all of the specifics with a
grain of salt.  It probably contains a bunch of insidious little mistakes.

## Part 1 — Code Modernization (Summary)

The existing wisp.c is written in an extemely low level style, since it is
a prototype implementation mean to be ported to hand-written assembly.
An implementation intended for use in a runtime system written in C
should back out of this low level style and switch things back into a more idiomatic style:

- **Control flow**: convert `goto`-based loops and dispatch to `for`/`while`
  and `if/else if`; convert vstack slot indexing (`sp[0]`, `sp[1]`) to named
  local variables.
- **Portability**: replace pinned register globals (`asm("r13")` etc.) and
  direct syscalls with standard C; use `<stdint.h>` types; replace
  `__builtin_trap` with `abort` or `longjmp`.
- **Runtime context**: collect all mutable state (heap pointers, environment
  root, parser cursor, source directory) into a `WispRt *` struct passed
  through the call tree, replacing the current mix of pinned registers and
  file-scope globals.
- **Error handling**: replace `die` / `__builtin_trap` with a `longjmp`-based
  error path anchored at the `run_wisp` entry point, returning a status code
  to the caller rather than aborting.
- **Runtime integration**: remove `zcallN` wrappers (direct calls throughout)
  and adapt GC rooting to whatever mechanism the new runtime provides.

## Wisp -> Plan Assembley

### Random Notes

#### Thunks in Environments

> Because the environment can technically contain thunks (macros
> can put anything there), getenv needs to be careful to keep it's
> live values on the stack.

This older version of plan-asm allowed macros to update the environment, which meant that the environment could contain thunks and malformed nodes.  The current version no longer supports this, which means that environments are always guarenteed to be well formed and normalized, which should significantly simplify all of the code that has to do with environments.

### 2.1 Split `bind` into `#bind` and `#macro`

**Current (`wisp.c`)**: A single `bind` primitive takes four arguments —
`(bind nm isMacro val)` — where `isMacro` is an expression that is evaluated
at expansion time to determine whether the binding is a macro.

**Target (`PlanAssembler.hs`)**: Two separate primitives with fixed semantics:
- `(#bind nm val)` — always binds `val` as a plain value.
- `(#macro nm val)` — always binds `val` as a macro.

**Changes required**:
- Add `SYM_MACRO` to the primitive symbol table alongside `SYM_BIND`.
- Add `expand1_macro` mirroring `expand1_bind` but hard-coding `isMacro = 1`.
- Remove the runtime evaluation of the `isMacro` argument from `expand1_bind`.
- Update `getmacro` / `macroexpand` dispatch to recognise both symbols.

### 2.2 Change the `law` form to take an explicit tag argument

**Current (`wisp.c`)**: `(law (self arg...) bind... body)` — the law tag is
derived implicitly from `sig[0]` (the self-name symbol).

**Target (`PlanAssembler.hs`)**: `(#law tag (self arg...) bind... body)` — the
tag is an explicit first argument that is independently evaluated.

**Changes required**:
- Shift the form indexing in `expand1_law` / `law_build_locals`: what was
  `form[1]` (sig) becomes `form[2]`; the new `form[1]` is an evaluated tag
  expression.
- Evaluate `form[1]` with `wisp_eval` to produce the tag before building the
  locals array.
- Remove the current tag-derivation logic (`opix1` → `opix0` → `opnat`
  fallback).

### 2.3 Change law bind syntax from `(let nm val)` to juxtaposition

**Current (`wisp.c`)**: Bind forms inside a law body are written as explicit
`(let nm val)` triples. `law_build_locals` checks for the `N_LET` symbol at
`form[0]`.

**Target (`PlanAssembler.hs`)**: Bind forms use juxtaposition syntax —
`nm(val)` in surface text, which the parser produces as `(#juxt nm val)`.
`parseBind` matches `["#juxt", N nm, expr]`.

**Changes required**:
- Update `law_build_locals` to match `(JUXT nm expr)` triples instead of
  `(LET nm expr)`.
- Update `law_compile` to extract the expression from index 2 of a juxt
  triple rather than index 2 of a let triple (structurally the same, but
  the head symbol differs).
- Remove `N_LET` from the symbol table if it has no other uses.

### 2.5 Add the `#juxt "#" expr` escape inside law bodies

**Current (`wisp.c`)**: No equivalent. Inside a law body, all sub-expressions
are compiled as law IR via `compileExpr`.

**Target (`PlanAssembler.hs`)**: Inside `macroexpand`, when `loc` (the locals
list) is non-empty, the pattern `[N 0, "#juxt", "#", x]` is a special escape:
`x` is macroexpanded normally but the juxt-`"#"` wrapper is preserved, so that
`compileExpr` can later call `eval` on the inner expression directly (the
`["#juxt", "#", expr]` branch in `compileExpr`).

This allows a law body to splice in a fully evaluated value at compile time —
effectively a compile-time `eval` escape hatch.

**Changes required**:
- Add the `(JUXT "#" expr)` detection to `macroexpand` when a locals context
  is active (i.e., when called from within law compilation).
- Add the corresponding branch in `compileExpr` that calls `wisp_eval` on the
  inner expression and returns the result as a constant.

### 2.6 Add `#app`

**Current (`wisp.c`)**: No equivalent.

**Target (`PlanAssembler.hs`)**: `(#app expr...)` evaluates each sub-expression
and applies the first to the rest at macro-expansion time, returning the result
as a quoted constant `(1 result)`. It is a compile-time application.

**Changes required**:
- Add `SYM_APP` to the symbol table.
- Implement `expand1_app`: evaluate each argument with `wisp_eval`, apply
  using the runtime's apply primitive, wrap in `(1 result)`.
- Add to `getmacro` / `macroexpand` dispatch.

### 2.7 Add `#export`

**Current (`wisp.c`)**: No equivalent. The environment accumulates all bindings
for the lifetime of the interpreter.

**Target (`PlanAssembler.hs`)**: `(#export sym...)` declares the public
interface of the current module. It discards all bindings except the named
ones, leaving a minimal environment that represents the module's exports.

**Changes required**:
- Add `SYM_EXPORT` to the symbol table.
- Implement `expand1_export`: collect the nat keys for each listed symbol,
  walk the BST retaining only those entries, write the filtered BST back to
  `rt->env`.
- Add to `getmacro` / `macroexpand` dispatch.

### 2.8 Module system: caching and environment merging

**Current (`wisp.c`)**: `process_file` re-processes every `@include`
unconditionally, and all bindings from all loaded modules accumulate in a
single shared environment.

**Target (`PlanAssembler.hs`)**: Each module is processed in an initially
empty environment, producing a module-local binding set. On completion that set
is cached. At the call site, the cached module env is *merged* into the caller's
env (new bindings shadow old ones). A second `@include` of the same module is a
cache hit and does not re-process the file.

**Changes required**:

#### 2.8a Per-module isolated environments
- At the start of processing each file, snapshot and clear `rt->env`.
- After processing, the resulting `rt->env` is the module's export set.
- Restore the caller's environment and merge in the module's set.

#### 2.8b Module cache
- Add a module cache to `WispRt` — a BST (or hash table) mapping module-name
  nat → captured env BST.
- In `process_file`, check the cache first; on a miss, process and store the
  result; on a hit, skip processing and go straight to the merge step.

#### 2.8c `env_merge`
- Implement `env_merge(old, new)` that produces a balanced BST containing all
  entries from both, with `new` winning on key collisions.
- Port the Haskell strategy: flatten both BSTs to sorted lists, merge with a
  linear-time merge (new wins on ties), rebuild a balanced BST from the merged
  sorted array.

### 2.9 Top-level evaluation and execution modes

**Current (`wisp.c`)**: `wisp_input` has a hook mechanism — if the environment
root has a non-zero head, the incoming form is passed to the head value as a
function rather than being evaluated normally. This is a single undifferentiated
execution mode.

**Target (`PlanAssembler.hs`)**: Two distinct modes controlled by `vMode`:
- `BPLAN` ("build plan"): used when loading from source; top-level eval results
  are printed to stderr.
- `RPLAN` ("run plan"): used when executing a loaded function; the environment
  is cleared before the call, and the result is returned to the caller.

Additionally, `loadAssembly` / `runRepl` provide a higher-level entry point
that loads a module, looks up a named export, and invokes it with command-line
arguments as a string array.

**Changes required**:
- Add a `mode` field to `WispRt` (`MODE_BPLAN` / `MODE_RPLAN`).
- In `wisp_input` (or its successor), gate top-level printing on `MODE_BPLAN`.
- Add `wisp_load(rt, src_dir, module, mode)` — loads a module in the given
  mode, returns the resulting environment or a named value from it.
- Add `wisp_run(rt, fn, args, nargs)` — saves and clears the environment,
  switches to `MODE_RPLAN`, calls `fn` with `args`, restores the environment.
  Corresponds to `preserveState` + `runReplFn` in the Haskell.

### Summary of Language Changes

| Area | wisp.c current | Target (PlanAssembler.hs) |
|---|---|---|
| Macro binding | `(bind nm isMacro val)` | `(#bind nm val)` / `(#macro nm val)` |
| Law tag | Implicit from `sig[0]` | Explicit: `(#law tag sig ...)` |
| Law bind syntax | `(let nm val)` | `nm(val)` → `(#juxt nm val)` |
| Form encoding | Packed integers (`JUXT`, `BRAK`, `CURL`) | Interned strings (`#juxt`, `#brak`, `#curl`) |
| Compile-time eval | Not supported | `#(expr)` → `(#juxt "#" expr)` in law body |
| Compile-time apply | Not supported | `(#app f a...)` |
| Module export | Not supported | `(#export sym...)` |
| Module loading | Re-processes every include | Cached; isolated per-module envs; merged |
| Execution mode | Single mode with env hook | `BPLAN` / `RPLAN` |
| Entry point | `run_wisp(module)` | `wisp_load` + `wisp_run` |
