this is an LLM generated sketch based on notes, needs review and may contain mistakes.

# Silo: An Efficient Serialization System for PLAN

## Overview

This format is a compact, prefix-coded, byte-aligned binary encoding for PLAN.  Unlike Seed, it does no deduplication and it is byte-oriented instead of bit oriented.

**Goals:**
- Fast single-pass encode and decode  
- Streaming-friendly
- Compression-friendly  
- avoid varints where possible
- PIN references

## Overall Format

Format:

    [num_refs:variant]
    [ref0]
    [ref1]
    ...
    [refN]
    [root node]

- refs are all 256bits (SHA26)
- PIN indexes refer into this table.
- pin refs must not be duplicated.
- pin refs must be in traversal order

## varint

same as a normal node, but rejecting things besides numbers.

## Node Layout

Every node begins with one opcode byte:

    0 aaaa ttt   APP
    10 vvvvvv    SMOL
    110 sssss    MEDIUM
    1110 zzzz    BIG
    1111lll      LAW
    1111 sss     PIN

**Field meanings:**

- aaaa — app size (number of elements, if small)
- ttt — app tag (if small nat)
- vvvvvv — small natural value  
- sssss — payload byte width  
- zzzz — byte width of the length field  
- sss — PIN index width minus 1
- lll - law arity

---

## Node Types

### APP

Opcode:

    0 aaaa ttt

- size = aaaa (0–15)
- tag = ttt (0–7)

Encoding:

    [opcode][child0][child1]...[child(arity-1)]

If size=0, that means that the Arity is too big and is encoded directly as a number.

    [opcode][size][child0][child1]...[child(arity-1)]

similarly, if tag=7 then that means that is explicit 

    [opcode][tag][child0][child1]...[child(arity-1)]

so, is Arity=0 and tag=7, then both are explicit.

    [opcode][size][tag][child0][child1]...[child(arity-1)]


---

### SMOL

Opcode:

    10 vvvvvv

- value = 0–63

Encoding:

    [opcode]

---

### MEDIUM

Opcode:

    110 sssss

- size = sssss bytes (0–31)

Encoding:

    [opcode][payload]

- payload is exactly size bytes
- unsigned integer
- little endian.

---

### BIG

Opcode:

    1110 zzzz

- size_of_size = zzzz bytes (0–15)

Encoding:

    [opcode][length][payload]

- length is encoded in size_of_size bytes
- payload is length bytes (little endian)
- (maximum size here is much larger than addressable memory).

---

### LAW

Opcode:

    11110aaa

Encoding (Arity = 0):

    [opcode][Arity][metadata][body]

Encoding (otherwise):

    [opcode][metadata][body]

---

### PIN

Opcode:

    11111ppp

Encoding (p < 7):

    [opcode] (p is index)

Encoding (p=7):

    [opcode][varint]

- the number is an index into the references table.

---

## Canonicalization

- Always use the smallest possible encoding for each node.
- Pin refs should appear in the table in traversal order, without duplicates.