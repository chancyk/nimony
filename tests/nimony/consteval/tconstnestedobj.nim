import std/[syncio, assertions]

# An object result with an object field: the serializer's `unravelObj` recurses
# through `unravelObjField`, so the inner object gets its own `oconstr` with a
# Symbol type slot nested inside the outer one. The string field makes the
# walk mix the object path with the string entry point.

type
  Inner = object
    lo, hi: int
  Outer = object
    label: string
    span: Inner
    flag: bool

proc mk(label: string; lo, hi: int): Outer =
  result = Outer(label: label, span: Inner(lo: lo, hi: hi), flag: lo < hi)

const o = mk("range", 3, 9)

assert o.label == "range"
assert o.span.lo == 3
assert o.span.hi == 9
assert o.flag

const flat = mk("empty", 5, 5)
assert not flat.flag
assert flat.span.lo == 5

echo o.label, " ", o.span.lo, "..", o.span.hi, " ", o.flag
echo flat.label, " ", flat.flag
