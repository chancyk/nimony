import std/[syncio, assertions]

# TODO: an enum result crashes the serializer today —
#   nifcore.nim(895, 3) `c.rem == 0` into: body did not consume all 14 children
# from `unravelEnum` (src/nimony/exprexec.nim:535). See README.md here.

# An enum result. `unravelEnum` does not go through the integer entry point:
# it maps the value back to the *enum field symbol*, so the serialised NIF
# names the field rather than its ordinal.

type
  Color = enum
    Red, Green, Blue

proc pick(n: int): Color =
  result = Red
  for i in 0 ..< n:
    result = succ(result)

const c0 = pick(0)
const c1 = pick(1)
const c2 = pick(2)

assert c0 == Red
assert c1 == Green
assert c2 == Blue
assert ord(c2) == 2

proc brighter(c: Color): Color =
  if c == Blue: Blue else: succ(c)

const b = brighter(Green)
assert b == Blue

echo c0, " ", c1, " ", c2
echo b, " ", ord(b)
