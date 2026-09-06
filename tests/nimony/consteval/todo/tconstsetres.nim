import std/[syncio, assertions]

# A `set[T]` result. `unravelSet` does not copy the bitset: it emits a
# `setconstr` and re-derives the members by testing every ordinal of the base
# type against the value at run time in the sub-compile, so the size of the
# walk is the base type's range, not the set's cardinality.

proc evens(hi: int): set[uint8] =
  result = {}
  var i = 0
  while i <= hi:
    result.incl uint8(i)
    inc i, 2

const e = evens(8)

assert 0'u8 in e
assert 2'u8 in e
assert 8'u8 in e
assert 1'u8 notin e
assert 9'u8 notin e

proc vowels(): set[char] =
  result = {}
  for c in items("aeiou"):
    result.incl c

const v = vowels()
assert 'a' in v
assert 'u' in v
assert 'b' notin v

const none: set[char] = vowels() - vowels()
assert 'a' notin none

echo 0'u8 in e, " ", 1'u8 in e, " ", 8'u8 in e
echo 'e' in v, " ", 'z' in v
