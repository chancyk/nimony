import std/[syncio, assertions]

# Float arithmetic through a proc. `expreval` folds float literals and the
# arithmetic operators in-process, but a *call* is not folded, so the whole
# computation runs in the sub-compile and comes back through `writeNifFloat`.
# The point of interest is the round trip: the value must survive being
# printed into NIF and parsed back, so only exactly representable results are
# compared.

proc area(w, h: float): float = w * h

const a = area(2.5, 4.0)
assert a == 10.0

proc average(xs: seq[float]): float =
  result = 0.0
  for x in items(xs):
    result = result + x
  if xs.len > 0:
    result = result / float(xs.len)

const avg = average(@[1.0, 2.0, 3.0, 6.0])
assert avg == 3.0

proc powi(base: float; n: int): float =
  result = 1.0
  for i in 1 .. n:
    result = result * base

const p = powi(0.5, 3)
assert p == 0.125

const neg = area(-1.5, 2.0)
assert neg == -3.0

echo a, " ", avg
echo p, " ", neg
