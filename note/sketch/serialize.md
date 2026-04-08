this is an LLM generated sketch based on notes, needs review and may contain mistakes.

# Plan Binary Serialization Format v1

## Overview

This format is a compact, prefix-coded, byte-aligned binary encoding for PLAN.  Unlike Seed, it does no deduplication and it is byte-oriented instead of bit oriented.

**Goals:**
- Fast single-pass encode and decode  
- Streaming-friendly
- Compression-friendly  
- No hot-path varints  
- PIN references

A serialized value consists of:

    [pins table]
    [root node]

---

## Opcode Layout

Every node begins with one opcode byte:

    0 aaaa ttt   APP
    10 vvvvvv    SMOL
    110 sssss    MEDIUM
    1110 zzzz    BIG
    1111000      LAW
    1111 sss     PIN

**Field meanings:**

- aaaa — arity  
- ttt — small tag  
- vvvvvv — small natural value  
- sssss — payload byte width  
- zzzz — byte width of the length field  
- sss — PIN index width minus 1  

---

## Node Types

### APP

Opcode:

    0 aaaa ttt

- arity = aaaa (0–15)
- tag = ttt (0–7)

Encoding:

    [opcode][child0][child1]...[child(arity-1)]

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
- fixed endianness (recommended: big-endian)

---

### BIG

Opcode:

    1110 zzzz

- size_of_size = zzzz bytes (0–15)

Encoding:

    [opcode][length][payload]

- length is encoded in size_of_size bytes
- payload is length bytes

---

### LAW

Opcode:

    1111000

Encoding:

    [opcode]

---

### PIN

Opcode:

    1111 sss

- index_width = sss + 1 bytes (1–8)

Encoding:

    [opcode][index]

- index is fixed-width unsigned integer
- refers to reference table

---

## Reference Table

Optional header:

    [ref_count][ref0][ref1]...[refN][root node]

- ref_count is little endian, u64
- refs are all 256bits (SHA26)
- PIN indexes refer into this table.
- pin refs must not be duplicated.
- pin refs must be in traversal order.

---

## Prefix Classification

Decoding can be done via ordered tests:

    if (b < 0x80) APP
    else if (b < 0xC0) SMOL
    else if (b < 0xE0) MEDIUM
    else if (b < 0xF0) BIG
    else if (b == 0xF0) LAW
    else PIN

---

## Summary

    0 aaaa ttt   APP
    10 vvvvvv    SMOL
    110 sssss    MEDIUM
    1110 zzzz    BIG
    1111000      LAW
    1111 sss     PIN
