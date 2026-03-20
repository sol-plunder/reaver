# Balanced BST Merge for Assembly Environments

When a Plan Assembly file imports a module, the two environments must
be unioned into a single BST. A naive insertion-based merge leaves the
tree arbitrarily unbalanced. Instead, we rebuild a perfectly balanced
tree from scratch in three simple linear passes.

## The Three Passes

**1. Flatten.** Walk each BST in-order (left, node, right) to produce
a sorted array of `(key, value, macro-flag)` triples. Any in-order
walk of a BST produces a sorted sequence, so no sorting step is needed.

**2. Merge.** Walk both sorted arrays simultaneously with two pointers,
always advancing the pointer with the smaller key and appending that
entry to the output array. On a key collision, take the entry from the
*new* (importing) environment and advance both pointers. This is the
standard sorted-merge from merge sort, with a tie-breaking rule.

**3. Rebuild.** Given a sorted array of length `n`, build a balanced
BST recursively: the root is the element at index `n/2`, the left
subtree is built from `[0, n/2)`, and the right subtree from
`(n/2, n)`. Each level of recursion halves the remaining array, so the
resulting tree has depth `ceil(log2(n))` — perfectly balanced.

## Why This Is Easy to Implement in Machine Assembly

Each pass is a simple loop with no complex data structures:

- Flatten is a standard iterative in-order traversal using an explicit
  stack, or a recursive walk if the call stack is available.
- Merge is two read pointers and one write pointer advancing through
  flat arrays.
- Rebuild is a single recursive function with two integer arguments
  (offset and length) indexing into the merged array.

No rotations, no height tracking, no rebalancing heuristics. The
balance is a structural consequence of always picking the midpoint.
