# Ordering PLAN Values

## The Order

```
N < P < L < A
```

Then within each type, lexicographically:

- **Nat**: natural number order
- **Pin**: recurse on inner value
- **Law**: compare arity, then name, then body (`{a m b}`)
- **App**: compare head, then args left to right (`(f x y ...)`)

## Why Apps Are Largest

The key insight: because Apps are ordered last, **size dominates
comparison for Apps**. A larger App is always greater than a smaller
App, regardless of contents. This means you only need to compare
elements lexicographically when two Apps have the same number of
arguments — no special casing needed for size, you just iterate over
elements in order.

## Why Pins Before Laws

Arbitrary, but it makes the rule easy to remember: it is just the
acronym **PLAN** with N moved to the front.

```
P L A N  →  N P L A
```
