import std/[syncio, assertions]

# String building in a loop: `add` on a growing string is not something
# `expreval` folds, so the whole proc runs in the sub-compile and only the
# final string crosses back, through the string entry point.

proc build(n: int): string =
  result = ""
  for i in 1 .. n:
    if result.len > 0: result.add ","
    result.add $i

const s = build(5)

assert s == "1,2,3,4,5"
assert s.len == 9

proc repeatChar(c: char; n: int): string =
  result = ""
  for i in 0 ..< n:
    result.add c

const bar = repeatChar('#', 6)
assert bar == "######"

echo s
echo bar
