import std/[syncio, assertions]

# A `for` over a seq inside the evaluated expression. The iteration is not
# over a range (which `tmyops.nim` covers) but over a heap value built in the
# same sub-compile, so the seq is allocated, iterated and dropped on the far
# side of the boundary and only the scalar result comes back.

proc sumOf(xs: seq[int]): int =
  result = 0
  for x in items(xs):
    result += x

const s = sumOf(@[3, 1, 4, 1, 5, 9])
assert s == 23

const emptySum = sumOf(@[])
assert emptySum == 0

proc longest(xs: seq[string]): string =
  result = ""
  for x in items(xs):
    if x.len > result.len: result = x

const l = longest(@["a", "abcd", "ab"])
assert l == "abcd"

proc countPairs(xs: seq[int]): int =
  result = 0
  for i, x in pairs(xs):
    if i mod 2 == 0: result += x

const p = countPairs(@[10, 100, 20, 200, 30])
assert p == 60

echo s, " ", emptySum
echo l, " ", p
