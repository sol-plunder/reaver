# TODO: Fix Hallucinations

This document was created by Claude based on extensive human notes, so the overall information is good, but it contains some hallucinations details which seem reasonable, but which are very misleading and incorrect.

This needs human attention before being used as the basis of an implementation.

# PLAN JS: Ultra-Minimal Implementation Plan

A single-file, directly-recursive, synchronous implementation. No
trampoline, no async, no actors, no persistence. Just correct PLAN
evaluation with flat Apps and thunk memoization. Target: ~300 lines.
The goal is a working evaluator that can run BPLAN jets and interpret
law bodies, testable against the Haskell reference.

### Key simplifications for this version

- **Nats are boxed heap objects**: `[TAG_NAT, n]`. No special-casing
  JS numbers. This means no fast-path/slow-path split, no cached thunk
  numeric wrapper issue, and uniform treatment of all values. Optimize
  later.

- **Apps are always WHNF**: an App with an undersaturated head is just
  a closure -- it's already in normal form. Only thunks need forcing.
  `isWhnf` is trivially true for everything except unevaluated thunks.

- **A thunk is just a function and its captured args**: `[fn, arg0,
  arg1, ...]`. No 'eval'/'blackhole'/'cached' state strings. The state
  is encoded in `fn` itself -- the blackhole fn throws, the cached fn
  returns a stored value.

- **`force` is the only entry point**: there is no separate `eval_`.
  Everything goes through `force`. `callLaw` forces its result before
  returning, so `force` on a thunk that ran a law always gets back an
  already-forced value.

---

## Step 1: Value Representation

Everything in one file: `plan.js`.

### Tag constants

```javascript
const TAG_NAT   = 0   // [TAG_NAT, n]           -- n is a JS number
const TAG_PIN   = 1   // [TAG_PIN, inner]
const TAG_LAW   = 2   // [TAG_LAW, arity, name, body]
const TAG_APP   = 3   // [TAG_APP, head, args]   -- head is never an App
const TAG_THUNK = 4   // [TAG_THUNK, fn, ...capturedArgs]
```

### Constructors

```javascript
// Nat: always boxed
const mkNat = (n) => [TAG_NAT, n]
const isNat = (v) => v[0] === TAG_NAT

// Pin: [TAG_PIN, inner]
const mkPin = (inner) => [TAG_PIN, inner]
const isPin = (v) => v[0] === TAG_PIN

// Law: [TAG_LAW, arity, name, body]
// arity is a JS number (not a boxed Nat) for internal convenience
const mkLaw = (arity, name, body) => [TAG_LAW, arity, name, body]
const isLaw = (v) => v[0] === TAG_LAW

// App: [TAG_APP, head, args]
// Invariant: head is never an App -- enforced by constructor
// args is a flat JS array of Vals
const mkApp = (head, args) => {
    if (isApp(head)) throw new Error('mkApp: head cannot be an App')
    return [TAG_APP, head, [...args]]
}
const isApp = (v) => v[0] === TAG_APP

// Thunk: [TAG_THUNK, fn, ...capturedArgs]
// fn is a JS function that takes no arguments and returns a Val.
// The captured args are closed over by fn -- they live in the array
// so the GC (in the C version) can trace them.
//
// Thunk states encoded in fn:
//   Eval:      fn does the actual computation
//   BlackHole: fn throws 'infinite loop'
//   Cached:    fn returns capturedArgs[0] (the cached result)
const mkThunk = (fn, ...capturedArgs) => [TAG_THUNK, fn, ...capturedArgs]
const isThunk = (v) => v[0] === TAG_THUNK
```

### Thunk in-place mutation

Because other values hold references to a thunk array, we overwrite
its contents rather than replacing it. The thunk array stays the same
JS object -- only its contents change.

```javascript
// Called before evaluating a thunk: marks it as being evaluated.
// If force() encounters this thunk again during evaluation, the
// blackhole fn will throw, detecting the cycle.
const setBlackHole = (thunk) => {
    thunk[1] = () => { throw new Error('<<loop>>') }
    thunk.length = 2
}

// Called after evaluating a thunk: stores the result.
// The cached fn ignores its args and returns the stored result.
const setCached = (thunk, result) => {
    thunk[1] = () => result
    thunk[2] = result   // stored so GC can trace it
    thunk.length = 3
}
```

### Arity

```javascript
const valArity = (v) => {
    switch (v[0]) {
    case TAG_NAT:   return 0
    case TAG_PIN: {
        const inner = v[1]
        if (isLaw(inner)) return inner[1]
        if (isNat(inner)) return 1   // P(N k): primitive dispatcher
        return 1
    }
    case TAG_LAW:   return v[1]
    case TAG_APP:   return Math.max(0, valArity(v[1]) - v[2].length)
    case TAG_THUNK: return 0   // can't know until forced
    }
}
```

Note: arity of a thunk is 0 because we don't know what it will produce
until forced. If a thunk produces a law, it will be forced before
arity matters.

### Test criteria for Step 1

```javascript
// Constructors produce right shapes
const n = mkNat(42)
assert(n[0] === TAG_NAT && n[1] === 42)

const p = mkPin(mkNat(0))
assert(p[0] === TAG_PIN && p[1] === n)   // err: p[1] should be mkNat(0)

const l = mkLaw(2, mkNat(0), mkNat(1))
assert(l[0] === TAG_LAW && l[1] === 2)

const a = mkApp(l, [mkNat(42), mkNat(99)])
assert(a[0] === TAG_APP && a[1] === l && a[2].length === 2)

// mkApp rejects App as head
const closure = mkApp(l, [mkNat(42)])   // undersaturated App
assertThrows(() => mkApp(closure, [mkNat(99)]))

// Arity
assert(valArity(l) === 2)
assert(valArity(mkApp(l, [mkNat(42)])) === 1)
assert(valArity(mkApp(l, [mkNat(42), mkNat(99)])) === 0)
assert(valArity(mkNat(42)) === 0)

// Thunk mutation
const t = mkThunk(() => mkNat(42))
assert(isThunk(t))
setBlackHole(t)
assertThrows(() => t[1]())   // blackhole fn throws
setCached(t, mkNat(99))
assert(t[1]() === mkNat(99))   // wrong: object identity
// Better: assert(t[2][1] === 99)
```

---

## Step 2: Force

`force(v)` is the sole entry point for evaluation. It reduces a value
to WHNF. For this implementation, only thunks require forcing -- every
other value type (Nat, Pin, Law, App) is already in WHNF.

### The force loop

When forcing a thunk, we have a function `fn` and some captured args.
The function encodes what the thunk should do. We call it to get a
head value, then resolve that head against the captured args using the
reduction loop:

```javascript
const force = (v) => {
    // Non-thunks are already WHNF
    if (!isThunk(v)) return v

    // Thunk is cached: return the cached result directly
    // (The cached fn returns thunk[2], so calling it works too,
    //  but checking thunk.length === 3 is cheaper)
    if (v.length === 3 && !isThunk(v[2])) return v[2]   // fast path
    // General: call the fn to get result (handles blackhole too)
    // Actually: distinguish states by fn identity is fragile.
    // Better: use a sentinel.

    // Simpler approach: use a state field.
    // See revised thunk representation below.
}
```

### Revised thunk representation

Using a state field is cleaner than encoding state in `fn`:

```javascript
// Thunk: [TAG_THUNK, state, fn, ...capturedArgs]
// state: 'eval' | 'blackhole' | 'cached'
// For 'eval':      fn() computes the result, capturedArgs are the args
// For 'blackhole': fn() throws
// For 'cached':    capturedArgs[0] is the result, fn ignored

const mkThunk = (fn, ...capturedArgs) =>
    [TAG_THUNK, 'eval', fn, ...capturedArgs]
const isThunk     = (v) => Array.isArray(v) && v[0] === TAG_THUNK
const thunkState  = (v) => v[1]
const isCached    = (v) => isThunk(v) && v[1] === 'cached'
const isBlackHole = (v) => isThunk(v) && v[1] === 'blackhole'
const isEval      = (v) => isThunk(v) && v[1] === 'eval'

const setBlackHole = (thunk) => {
    thunk[1] = 'blackhole'
    thunk.length = 2
}

const setCached = (thunk, result) => {
    thunk[1] = 'cached'
    thunk[2] = result
    thunk.length = 3
}

const getCached = (thunk) => thunk[2]
```

### force

```javascript
const force = (v) => {
    if (!isThunk(v)) return v
    if (isCached(v)) return getCached(v)
    if (isBlackHole(v)) throw new Error('<<loop>>')

    // isEval(v): extract fn and captured args, then reduce
    const fn   = v[2]
    const args = v.slice(3)

    // Mark as blackhole before evaluating to catch cycles
    setBlackHole(v)

    // Get the head value by calling fn with captured args
    let head = fn(...args)
    let rest = []   // leftover args (none yet from the thunk's own args)

    // Reduction loop: resolve head against rest until stable
    while (true) {
        // Force head to resolve any thunk
        head = force(head)

        // Unwrap closure: if head is an App, absorb its args
        if (isApp(head)) {
            rest = [...head[2], ...rest]
            head = head[1]   // head of the App, never an App itself
            continue
        }

        const arity = valArity(head)

        if (rest.length < arity) {
            // Undersaturated: result is a closure (App)
            // If no args at all, result is just head
            const result = rest.length === 0 ? head : mkApp(head, rest)
            setCached(v, result)
            return result
        }

        // Saturated or oversaturated: call head with exactly arity args
        const callArgs = rest.slice(0, arity)
        rest           = rest.slice(arity)

        // callLaw forces its result before returning
        const callResult = call(head, callArgs)

        if (rest.length === 0) {
            // Exactly saturated: done
            setCached(v, callResult)
            return callResult
        }

        // Oversaturated: loop with the result as the new head
        head = callResult
        // rest still has leftover args -- go around again
    }
}
```

### call

```javascript
const call = (f, args) => {
    if (isLaw(f)) {
        return callLaw(f, args)
    }
    if (isPin(f)) {
        const inner = f[1]
        if (isNat(inner)) return prim(inner[1], args)   // inner[1] = JS number
        if (isLaw(inner)) return callLaw(inner, args)
        throw new Error(`call: pin wraps non-callable`)
    }
    throw new Error(`call: not callable: tag=${f[0]}`)
}
```

### Test criteria for Step 2

```javascript
// force on a non-thunk returns it unchanged
const n = mkNat(42)
assert(force(n) === n)

// force on a cached thunk returns the cached result
const t = mkThunk(() => mkNat(42))
setCached(t, mkNat(99))
assert(force(t) === mkNat(99))   // object identity check

// force on an eval thunk calls fn and caches
let called = 0
const t2 = mkThunk(() => { called++; return mkNat(42) })
const r1  = force(t2)
const r2  = force(t2)
assert(called === 1)        // fn called only once
assert(r1 === r2)           // same cached result returned
assert(isCached(t2))        // thunk updated in place

// force detects cycles via blackhole
const t3 = mkThunk(function() { return force(t3) })
assertThrows(() => force(t3), '<<loop>>')

// force resolves a thunk that returns a closure
// thunk returns a law applied to one of two needed args: undersaturated
const law2 = mkLaw(2, mkNat(0), mkNat(2))   // const: returns first arg
const t4 = mkThunk(() => mkApp(law2, [mkNat(42)]))   // closure
const r4 = force(t4)
assert(isApp(r4))                // result is a closure
assert(r4[1] === law2)
assert(r4[2].length === 1)

// force on an oversaturated thunk loops correctly
// thunk returns id, with arg [42] leftover
const idLaw = mkLaw(1, mkNat(0), mkNat(1))   // body = var 1 = first arg
const t5 = mkThunk(() => idLaw, mkNat(42))
// wait -- thunk has fn=()=>idLaw and capturedArgs=[mkNat(42)]
// so head=idLaw, rest=[mkNat(42)], arity=1, exactly saturated
// callLaw(idLaw, [mkNat(42)]) should return mkNat(42)
// (requires callLaw to work -- test after Step 3)
```

---

## Step 3: Law Body Interpreter

### Environment and de Bruijn indexing

A law with arity N is called with N args. The environment is:

```
env[0] = the law itself   (de Bruijn 0 = self)
env[1] = last arg         (de Bruijn 1 = innermost = last)
env[2] = second-to-last
...
env[N] = first arg        (de Bruijn N = outermost = first)
```

De Bruijn index `b` at depth `n` maps to `env[n - b]`.

### callLaw

```javascript
const callLaw = (law, args) => {
    const arity = law[1]
    const body  = law[3]

    // env[0] = self, env[1..N] = args reversed
    const env = [law, ...args.slice().reverse()]

    // Interpret the body, then force before returning.
    // Forcing here means force() on a thunk that ran a law
    // always gets back an already-forced value.
    return force(evalExpr(body, arity, env))
}
```

### evalExpr

```javascript
const evalExpr = (expr, depth, env) => {
    const parts = unapp(expr)

    // Variable reference: Nat(b) where b <= depth
    if (parts.length === 1 && isNat(parts[0])) {
        const b = parts[0][1]   // JS number from boxed Nat
        if (b <= depth) return env[depth - b]
        // b > depth: literal nat
        return expr
    }

    // Let binding: (1 v k)
    // The Nat(1) here is a boxed nat, so parts[0][1] === 1
    if (parts.length === 3 &&
        isNat(parts[0]) && parts[0][1] === 1) {
        const v = parts[1]
        const k = parts[2]

        // Recursive let: create a thunk slot before evaluating v,
        // so v can reference itself via de Bruijn 1 in the new env.
        const slot = mkThunk(() => {
            throw new Error('<<recursive let evaluated before binding>>>')
        })

        const newEnv   = [...env, slot]
        const newDepth = depth + 1

        // Evaluate v lazily in the extended env.
        // Wrap in a thunk so self-reference works.
        const vThunk = mkThunk(
            (e, d, expr) => evalExpr(expr, d, e),
            newEnv, newDepth, v
        )
        setCached(slot, vThunk)

        return evalExpr(k, newDepth, newEnv)
    }

    // Application: (0 f x)
    if (parts.length === 3 &&
        isNat(parts[0]) && parts[0][1] === 0) {
        const fExpr = parts[1]
        const xExpr = parts[2]

        const fVal = evalExpr(fExpr, depth, env)
        // x is evaluated lazily: wrap in a thunk
        const xVal = mkThunk(
            (e, d, expr) => evalExpr(expr, d, e),
            env, depth, xExpr
        )

        // Apply fVal to xVal.
        // fVal might be anything. Force it and apply.
        const fForced = force(fVal)
        const arity   = valArity(fForced)

        if (arity === 0) throw new Error('evalExpr: applying non-function')

        if (arity === 1) {
            // Saturated immediately: call
            return call(fForced, [xVal])
        }

        // Undersaturated: build a closure
        if (isApp(fForced)) {
            // fForced is already a closure: extend it
            return mkApp(fForced[1], [...fForced[2], xVal])
        }
        return mkApp(fForced, [xVal])
    }

    // Literal quote: (0 x) -- two-element list with Nat(0) as head
    if (parts.length === 2 &&
        isNat(parts[0]) && parts[0][1] === 0) {
        return parts[1]   // return x unevaluated
    }

    // Literal: Pin, Law, or large Nat
    return expr
}
```

### unapp

Decompose a Val into its head and args:

```javascript
const unapp = (v) => {
    if (isApp(v)) return [v[1], ...v[2]]
    return [v]
}
```

### Test criteria for Step 3

```javascript
// id x = x  (arity=1, body=Nat(1))
const idLaw = mkLaw(1, mkNat(0), mkNat(1))
const idResult = force(callLaw(idLaw, [mkNat(42)]))
assert(idResult[0] === TAG_NAT && idResult[1] === 42)

// const x y = x  (arity=2, body=Nat(2))
const constLaw = mkLaw(2, mkNat(0), mkNat(2))
const constResult = force(callLaw(constLaw, [mkNat(42), mkNat(99)]))
assert(constResult[1] === 42)

// apply f x = f x  (arity=2, body=(0 (N 2) (N 1)))
// body as a Val: App(Nat(0), [Nat(2), Nat(1)])
const applyBody = mkApp(mkNat(0), [mkNat(2), mkNat(1)])
const applyLaw  = mkLaw(2, mkNat(0), applyBody)
// apply id 42 = id 42 = 42
const applyResult = force(callLaw(applyLaw, [idLaw, mkNat(42)]))
assert(applyResult[1] === 42)

// Thunk sharing through let:
// foo x = let y = expensive x in pair y y
// y should be evaluated only once
let expensiveCalls = 0
const expensive = mkThunk(() => {
    expensiveCalls++
    return mkNat(99)
})
// (We'll test this properly once pair is available via op66)
```

---

## Step 4: Op 0 — Pin, Law, Match

Op 0 is invoked via `P(N(0))` applied to one argument. The argument is
an App encoding the sub-operation and its arguments.

```javascript
const prim = (op, args) => {
    if (op === 0)  return primOp0(args)
    if (op === 66) return primOp66(args)
    throw new Error(`unknown prim op: ${op}`)
}

const primOp0 = (args) => {
    // args is the single argument to P(N(0)).
    // Unapp it to get the sub-operation and its args.
    const inner = force(args[0])
    const parts = unapp(inner)
    const subop = force(parts[0])

    if (!isNat(subop)) throw new Error('op0: subop must be a Nat')
    const s = subop[1]   // JS number

    if (s === 0) {
        // pin(x): wrap x in a Pin
        return mkPin(force(parts[1]))
    }

    if (s === 1) {
        // law(arity, name, body)
        const arity = force(parts[1])
        if (!isNat(arity)) throw new Error('law: arity must be Nat')
        return mkLaw(arity[1], parts[2], parts[3])
    }

    if (s === 2) {
        // match(p, l, a, z, m, x)
        const [_, p, l, a, z, m, x] = parts
        return primMatch(p, l, a, z, m, force(x))
    }

    throw new Error(`op0: unknown subop ${s}`)
}

const primMatch = (p, l, a, z, m, x) => {
    if (isPin(x)) {
        // p applied to inner
        return force(mkThunk(() => call(force(p), [x[1]])))
    }
    if (isLaw(x)) {
        // l applied to (arity, name, body)
        return force(mkThunk(() =>
            call(force(l), [mkNat(x[1]), x[2], x[3]])))
    }
    if (isApp(x)) {
        // a applied to (init, last)
        const head = x[1], xargs = x[2]
        const last = xargs[xargs.length - 1]
        const init = xargs.length === 1
            ? head
            : mkApp(head, xargs.slice(0, -1))
        return force(mkThunk(() => call(force(a), [init, last])))
    }
    if (isNat(x)) {
        const n = x[1]
        if (n === 0) return force(z)
        return force(mkThunk(() => call(force(m), [mkNat(n - 1)])))
    }
    throw new Error('match: not a Val')
}
```

### Test criteria for Step 4

```javascript
const op0 = mkPin(mkNat(0))

// pin construction via P(N 0)
// prim(0, [App(Nat(0), [Nat(42)])]) = Pin(Nat(42))
const pinResult = prim(0, [mkApp(mkNat(0), [mkNat(42)])])
assert(isPin(pinResult) && pinResult[1][1] === 42)

// law construction
const lawResult = prim(0, [mkApp(mkNat(1), [mkNat(2), mkNat(0), mkNat(1)])])
assert(isLaw(lawResult) && lawResult[1] === 2)

// match on Nat(0): returns z
const z = mkNat(99)
const matchZ = primMatch(null, null, null, z, null, mkNat(0))
assert(matchZ[1] === 99)

// match on Nat(5): returns m(4)
const idLaw = mkLaw(1, mkNat(0), mkNat(1))
const matchS = primMatch(null, null, null, mkNat(0), idLaw, mkNat(5))
assert(matchS[1] === 4)

// match on Pin
const pin42 = mkPin(mkNat(42))
const matchP = primMatch(idLaw, null, null, null, null, pin42)
assert(matchP[1] === 42)   // id applied to inner = inner = Nat(42)

// match on Law
const someLaw = mkLaw(1, mkNat(0), mkNat(1))
const constLaw = mkLaw(3, mkNat(0), mkNat(3))   // returns first of 3 args
const matchL = primMatch(null, constLaw, null, null, null, someLaw)
// constLaw(arity=1, name=Nat(0), body=Nat(1)) -> arity = Nat(1)
assert(matchL[1] === 1)
```

---

## Step 5: Op 66 Jets

Op 66 is invoked via `P(N(66))` applied to one argument. The argument
is an App whose head is a Nat encoding the jet name.

### Name encoding

```javascript
// Nat → ASCII string (bytes little-endian)
const natToStr = (v) => {
    let s = '', n = v[1]   // v is a boxed Nat
    while (n > 0) {
        s += String.fromCharCode(n & 0xFF)
        n = Math.floor(n / 256)
    }
    return s
}

// ASCII string → boxed Nat
const strToNat = (s) => {
    let n = 0
    for (let i = s.length - 1; i >= 0; i--)
        n = n * 256 + s.charCodeAt(i)
    return mkNat(n)
}
```

### Jet dispatch

```javascript
const primOp66 = (args) => {
    const inner = force(args[0])
    const parts = unapp(inner)
    const name  = natToStr(force(parts[0]))
    const jargs = parts.slice(1)   // unevaluated -- jets force what they need

    switch (name) {

    // Arithmetic -- strict in both args
    case 'Inc': { const x = force(jargs[0]); return mkNat(x[1] + 1) }
    case 'Dec': { const x = force(jargs[0]