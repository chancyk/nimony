import std/syncio

# Several `const`s that each need their own sub-compiled program, so one
# compile produces several sub-programs sharing one nimcache. That sharing is
# what `tests/ctfe_engine`'s A2c checks are about: the seven stdlib modules of
# `std/writenif`'s closure are the same in every one of them.
proc triangle(n: int): seq[int] =
  result = @[]
  var acc = 0
  for i in 1 .. n:
    acc = acc + i
    result.add acc

proc repeated(s: string; n: int): string =
  result = ""
  for i in 1 .. n:
    result.add s

proc collatzLen(start: int): int =
  var n = start
  result = 0
  while n != 1:
    if n mod 2 == 0: n = n div 2
    else: n = 3 * n + 1
    inc result

const
  Triangle = triangle(4)
  Banner = repeated("ab", 3)
  Steps = collatzLen(27)
  Longer = repeated("-", 5)

for x in Triangle:
  echo x
echo Banner
echo Steps
echo Longer
