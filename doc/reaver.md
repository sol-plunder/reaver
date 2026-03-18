# Reaver Scheme --- User Guide

Reaver Scheme is a Scheme-family language that compiles to PLAN. It
provides a small set of primitive forms; everything else --- `define`,
`if`, `cond`, `lambda`, and so on --- is expected to be built on top
using the macro system.

## Syntax

### Basic Tokens

**Symbols** start with a letter, digit, `_`, `-`, `#`, or any byte above
127. Runic characters (see below) are allowed at the end of a symbol,
which is how names like `is-empty?` or `set!` work.

**Numbers** are plain decimal digit sequences: `0`, `42`, `1000`.

**Strings** are double-quoted: `"hello"`. Strings are PLAN nat values
with their bytes packed in.

**Comments** begin with `;` and run to the end of the line.

### Delimiters

Three kinds of brackets are available. Parentheses produce a plain list;
square brackets and curlies produce tagged lists:

    (f x y)      ; standard list: (f x y)
    [a b c]      ; expands to: (BRAK a b c)
    {a b c}      ; expands to: (CURL a b c)

`BRAK` and `CURL` are just tags. Their meaning is entirely determined by
whatever macros are in scope. Common conventions are to use `[...]` for
data literals or pattern lists, and `{...}` for lambda shorthand, but
these are not built in.

### Juxtaposition

If a token is immediately followed by a bracketed form with no space
between them, it becomes a `JUXT` node:

    f(x y)     ->  (JUXT f (x y))
    f[a b]     ->  (JUXT f (BRAK a b))
    f{a b}     ->  (JUXT f (CURL a b))

This is how many Scheme-style "special" syntaxes can be supported as
macros. For example, quoting and quasiquotation are not built in to
Reaver, but because runic characters like `'` and `` ` `` produce `JUXT`
nodes, a macro can give them their conventional meaning:

    'foo        ->  (JUXT ' foo)
    `(a ,b)     ->  (JUXT ` (a (JUXT , b)))

A macro that handles `'` rewrites `(JUXT ' x)` to `(quote x)`, and
similarly for `\``, `,`, and `,@`. The standard quote/quasiquote
syntax is thus fully available even though it is not a primitive.

### Infix Runes

These characters are "runic":

    !,+'@.?*/<=>&^~:%`

Runes written *between* tokens with no spaces form infix expressions,
also represented as `JUXT` nodes:

    Foo.bar      ->  (JUXT . Foo bar)
    a+b          ->  (JUXT + a b)
    a+b+c        ->  (JUXT + a b c)   ; same operator chains into one node

Precedence is intrinsic to the characters themselves. Characters
appearing later in this sequence:

    ,:$`~@?\|^&=!<>+*/%.

Binds more tightly, so `.` binds tightest and `,` binds loosest. For
multi-character rune strings, characters are compared left-to-right
by rank; if all are equal, the shorter string binds more tightly (`.`
binds tighter than `..`.

No operator declarations are needed.

This system is borrowed from Rex, which will be used in future languages
for PLAN.

## S-Expression Encoding

S-expressions are ordinary PLAN values. Understanding the encoding is
important when writing macros, since macros construct and return
s-expressions directly.

| Shape                     | Meaning                                         |
| ------------------------- | ----------------------------------------------- |
| `n` (any nat)             | Symbol --- the packed string of the name        |
| `(1 v)`                   | Atom --- the PLAN value `v` embedded directly   |
| `(0 x ...)`               | Parenthesised list                              |
| `(0 "BRAK" x ...)`        | Bracket list `[x ...]`                          |
| `(0 "CURL" x ...)`        | Curly list `{x ...}`                            |
| `(0 "JUXT" s x)`          | Juxtaposition `s` immediately followed by `x`   |
| `(0 "JUXT" op x y ...)`   | Infix `x op y op ...`                           |
| `(2 macro arg ...)`       | Pre-resolved macro call (see below)             |

### Atom Embedding: `(1 val)`

The `(1 val)` form allows a PLAN value to be embedded directly into an
s-expression, bypassing the normal name-lookup process entirely. When
the compiler encounters `(1 val)`, it uses `val` as a constant without
consulting the environment at all.

This is the key mechanism for hygienic macro output. Instead of emitting
a symbol like `cons` and hoping it resolves correctly at the call site,
a macro can capture the actual `cons` function value at definition time
and embed it as `(1 cons-fn)`. The resulting code carries a direct
reference to the function, not a name that could be shadowed or rebound.
This makes syntactic closures unnecessary: wherever the expanded code
ends up, embedded values mean exactly what the macro author intended.

Combined with `uniq` (for generating fresh symbols that won't collide
with anything in scope), `(1 val)` provides a sufficient foundation for
implementing robust hygienic macro systems entirely in user code ---
including things like `syntax-rules`.

### Pre-resolved Macro Calls: `(2 macro arg ...)`

The `(2 macro arg ...)` form lets a macro output a call to a transformer
function directly, without going through name lookup. When the compiler
encounters this form, it calls `macro` immediately with the full form,
threading `uniq`, `glo`, `locals`, and `depth` through as normal.

This is more convenient than manually invoking a macro transformer as a
function, and it preserves hygiene naturally: the macro value is
embedded directly (like `(1 val)`), so it is immune to shadowing at the
call site. The `(2 ...)` form is the idiomatic way for one macro to
invoke another in its output.

## Primitive Forms

All built-in compiler forms are prefixed with `#`. Because these names
are recognized by the compiler before macro expansion, they cannot be
shadowed by macros. This means they are entirely outside the hygiene
system and can be used freely as compilation targets inside macro output
without any special handling.

### `#bind` --- Top-level Value Definition

    (#bind name expr)

Defines a top-level name. Evaluates `expr` immediately and binds the
result globally. Only valid at the top level.

    (#bind pi 3)
    (#bind greeting "hello")

### `#macro` --- Top-level Macro Definition

    (#macro name transformer-expr)

Like `#bind`, but registers the value as a macro transformer. When
`name` subsequently appears as the head of a form, the transformer is
called with the whole form and its return value is compiled in its
place. Only valid at the top level.

### `#fun` --- Function

    (#fun pin|nopin  inline|noinline  tag  (self arg...)  body)

The primitive lambda form. Fields:

- `pin` / `nopin` --- if `pin`, the compiled law is pinned.
- `inline` / `noinline` --- if `inline`, calls to this function will
  always be inlined when possible.
- `tag` --- a name nat attached to the PLAN law as metadata.
- `(self arg...)` --- the parameter list. `self` is the name for
  self-reference in recursive calls; the remaining names are the
  arguments.
- `body` --- the function body.

In practice, `#fun` is the target that higher-level `lambda`/`define`
macros compile to.

### `#let` --- Non-recursive Let

    (#let ([name expr] ...) body)

Binds each name to its expression in sequence. Bindings are
non-recursive: each `expr` is evaluated in the environment *before* the
new name is added. Later bindings can reference earlier ones.

### `#letrec` --- Recursive Let

    (#letrec ([name expr] ...) body)

Like `#let`, but all names are in scope in all `expr` forms and in the
body. Used for mutually recursive definitions.

### `#letmacro` --- Local Macro Binding

    (#letmacro ([name transformer-expr] ...) body)

Binds macro transformers that are only in scope for `body`. Transformer
expressions are compiled and evaluated at compile time; they cannot
reference runtime locals from the enclosing scope. Transformers defined
in the same `#letmacro` form do not see each other (they are parallel,
not recursive).

No runtime code is emitted for the macro bindings themselves --- they
exist only during compilation of the body.

`#letmacro` is the intended foundation for implementing Scheme's
`let-syntax` as a macro.

### `#inline` --- Inline Request

    (#inline expr)

Marks `expr` for inlining. When the compiler encounters a fully-applied
call that has been marked --- either here or because the function itself
was declared `inline` --- it expands the function body in place.
Inlining is never done speculatively; it only happens when explicitly
requested.

Two equivalent ways to write an inline call:

    (#inline (my-function a b))
    ((#inline my-function) a b)

Both forms are intentionally a bit ungainly, since they are meant to
appear as output from macros rather than being written by hand.

### `#pin` --- Pin a Value

    (#pin expr)

Evaluates `expr` at compile time and wraps the result in a PLAN `Pin`.
The pinned value is embedded as a constant.

### `#const` --- Compile-time Application

    (#const f arg ...)

Evaluates all sub-expressions at compile time and applies them together,
embedding the result as a constant. The application must be safe to run
at compile time.

### `#module` --- Load a Module

    (#module name)

Loads the file `reaver/<n>.rvr` and returns its final environment as a
value. Module names must match `[0-9A-Za-z_-]+`. Results are cached by
file stamp so a module is only loaded once per session.

### `#import` --- Import Bindings

    (#import module)           ; import everything from module
    (#import module a b c)     ; import only the named bindings

Merges bindings from a previously loaded module into the current global
environment.

### `#export` --- Restrict Exports

    (#export name ...)

Restricts the current global environment to only the listed names,
discarding everything else. Typically placed at the end of a file to
define the module's public surface.

### `#in` --- Qualified Name Lookup

    (#in)                     ; returns the current global namespace as a value
    (#in module name)         ; looks up name inside module
    (#in module sub name)     ; walks a chain of nested environments

Resolves a name by walking through nested environments without importing
anything into the current namespace.

## Macros

Macros are ordinary functions. A macro transformer has the signature:

    (transformer ctx uniq glo locals depth form) -> [uniq glo expanded-form]

**`form`** is the entire form being expanded, including the macro name
as its head. This is what the macro pattern-matches on and rewrites.

**`ctx`** carries source location information (file, line, column).
This exists to make more useful error messages possible.  This will
eventually be extended to include the "whole input" as well.

**`uniq`** is a counter used to generate fresh, unique symbols. If your
macro needs to introduce a binding that should not clash with anything
at the call site, draw a name from `uniq` and return the incremented
counter. It must be threaded through and returned even if unused.

**`glo`** is the global environment at the point of expansion. Macros can
inspect it to look up what names are bound and what their values are.
This is how a macro can implement `syntax-rules`-style definition-site
resolution, for example. It must be threaded through and returned.

**`locals`** is the local scope at the point of expansion --- a mapping
from names to their binding depths. A macro implementing something like
`syntax-rules` can use this to determine which symbols in a template are
free (and should be resolved to `(1 val)` atoms) versus bound (and
should be left as symbols for the call site to supply).

**`depth`** is the current binding depth, unclear if this is actually
helpful or if `locals` is enough, might be removed later.

The macro returns `[uniq glo expanded-form]`. The compiler then compiles
`expanded-form` in the same environment.

### Hygiene

Reaver does not provide a built-in hygienic macro system, but the
primitives are a sufficient foundation to build one. The two key tools
are:

- **`(1 val)` atoms** --- embed values directly into output, bypassing
  name lookup entirely. A macro can capture the actual function or
  transformer it needs at definition time and embed it, rather than
  emitting a name that might be shadowed at the call site. This replaces
  the need for syntactic closures.

- **`(2 macro param..)`** --- embed macro calls directly into output,
  agian bypassing name lookup entirely. A macro can capture the actual
  function or transformer it needs at definition time and embed it,
  rather than emitting a name that might be shadowed at the call
  site. This replaces the need for syntactic closures.

- **`uniq`** --- can be used to generate fresh symbols guaranteed not
  to collide with any name in the user's code.

Together, these allow a macro to produce output where every introduced
binding uses a `uniq`-generated name and every reference to a
definition-site value uses `(1 val)` --- giving full hygiene without any
special compiler support. `syntax-rules` can be implemented as a macro
on this foundation.

## What Is Not Built In

Reaver's primitive forms are intentionally minimal. The following are
all expected to be provided by a macro layer:

- `define` / `defun` --- top-level definitions
- `lambda` / `fun` --- user-facing function syntax
- `let` / `let*` / `letrec` --- friendlier binding forms
- `if`, `cond`, `when`, `unless` --- conditionals
- `begin` --- sequencing
- `and`, `or`, `not` --- boolean combinators
- `quote`, `quasiquote` --- data literals (but `'` and `` ` `` syntax is
  available via `JUXT`)
- `syntax-rules` --- declarative pattern-matching macros
- `let-syntax`, `letrec-syntax` --- hygienic local macro binding (built
  on `#letmacro`)
- Any standard library (lists, strings, arithmetic operators, etc.)

The `[...]`, `{...}`, and juxtaposition (`f(x)`) syntaxes also have no
built-in meaning until macros give them one.
