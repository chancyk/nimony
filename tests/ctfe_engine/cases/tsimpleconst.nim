import std/syncio

# A `const` too complex for `expreval` to fold: a loop that builds a `seq`, so
# it becomes a whole sub-compiled program and reaches `semos.runEval`.
proc triangle(n: int): seq[int] =
  result = @[]
  var acc = 0
  for i in 1 .. n:
    acc = acc + i
    result.add acc

const Triangle = triangle(6)

for x in Triangle:
  echo x
