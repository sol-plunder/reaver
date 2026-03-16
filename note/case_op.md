There is a jet called Case, which takes a key, a list of branches, and a else branch.

This semantics are that of indexing into an array.  Like Ix, but with a specific value as an alternative if the index is out of bounds.

In earlier versions of the system, this was the primary mechanism used to implement a switch on a contiguous range of keys.

However, recognizing which branches are statically known in an optimizer is somewhat complicated. 

Furthermore, This problem gets even more troubling when used with lazy laws.  If a law hasn't been normalized, then we're still guaranteed that constants are evaluated too weak head normal form, so a compiler can inspect constants shallowly, without changing evaluation order. 

The consonants within this array literal are not necessarily forced, which adds complexity to an optimizer.

Instead, the Case0-Case16 primops should be used in conjunction with the Nib primop to implement larger branches.

This also has the advantage that an unoptimizing runtime does not have to pay the cost of the allocation of the array of branches each time.