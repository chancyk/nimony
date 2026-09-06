import std/syncio

# A `const` whose evaluation never finishes.
#
# `(i + 1) mod 1000` stays inside 0..999, so the guard is never true and no
# overflow ever ends the loop on its behalf either. `result` is `i`, so the
# loop is not dead code any optimizer may drop, and the value cannot be folded
# without running it.
proc spin(start: int): int =
  var i = start
  while i != -1:
    i = (i + 1) mod 1000
  result = i

const Never = spin(0)

echo Never
