import std/[syncio, assertions]

# A `case` inside the evaluated expression: over an integer with a range and
# an `else`, and over a string (which is a chain of comparisons rather than a
# jump table). `expreval` folds neither, so both run in the sub-compile.

proc grade(score: int): string =
  case score
  of 90 .. 100: "A"
  of 80 .. 89: "B"
  of 70 .. 79: "C"
  else: "F"

const g1 = grade(95)
const g2 = grade(83)
const g3 = grade(12)

assert g1 == "A"
assert g2 == "B"
assert g3 == "F"

proc arity(op: string): int =
  case op
  of "not": 1
  of "+", "-", "*": 2
  of "?": 3
  else: -1

const a1 = arity("not")
const a2 = arity("*")
const a3 = arity("nope")

assert a1 == 1
assert a2 == 2
assert a3 == -1

echo g1, g2, g3
echo a1, " ", a2, " ", a3
