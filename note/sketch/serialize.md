this is an LLM generated sketch based on notes, needs review and may contain mistakes.

# Silo: An Efficient Serialization System for PLAN

## Overview

This format is a compact, prefix-coded, byte-aligned binary encoding for PLAN.  Unlike Seed, it does no deduplication and it is byte-oriented instead of bit oriented.

**Goals:**
- Fast single-pass encode and decode  
- Streaming-friendly (hash without materializing the entire buffer)
- Compression-friendly  
- Space efficient.
- Encodes a single DAG node.

## Design Notes

- Similar in design to MessagePack.
- PLAN is simpler so more data fits in the dispatch byte.
- Dispatch byte branches on initial 0s instead of fixed size enum.
- This allows more metadata bits to be crammed in to cases that need it more (small numbers and adts)
- varint cases use the same encoding as normal data to keep logic small.
- edge list up-front is good for compression

## Compared to Seed

- no deduplication (much faster encoding).
- byte aligned (faster, better compression, less confusing).
- nats are encoded inline, instead of allocated up front. (faster encoding)

## Overall Format

Format:

    [num_refs:varint]
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

Places where a varint is needed (e.g. large pin reference) are just encoded like a normal plan value, but you reject the result if it is an app/etc.  this avoids separate logic for varints.

## Node Layout

Every node begins with one opcode byte:

    0 aaaa ttt   APP
    10 vvvvvv    SMOL
    110 sssss    MEDIUM
    1110 zzzz    BIG
    11110 lll      LAW
    11111 sss     PIN

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

# Alternate

- more direct numbers in exchange for explicit size byte for arrays w/ size>7

- swap tag encodings to make lzcnt work directly.

```
    1 vvvvvvv    SML (0-127)
    01 aaattt    APP
    001 sssss    MED (1-16 bytes)
    0001 zzzz    BIG
    00001 lll    LAW
    00000 sss    PIN

    1 vvvvvvv    SML
    01 aaattt    APP kids..
    01 000ttt    APP sz kids..
    01 aaa000    APP tag kids...
    01 000111    APP sz tag kids...
    001 sssss    MED bytes
    0001 zzzz    BIG byte-size bytes
    00001 lll    LAW metadata body
    00001 000    LAW Arity metadata body
    00000 sss    PIN
    00000 111    PIN sz
```