import std/[syncio, assertions]

# A `const` whose initializer reads another `const` that itself needed a
# sub-compile. The first value comes back from `runEval` as NIF and is then
# fed straight into the *second* expression's program — so what this pins
# down is that a sub-compile's result is usable as an ordinary constant by the
# next one, both when it is folded in-process (`base * 2`) and when it has to
# cross the boundary a second time (`describe(base)`).

proc compute(n: int): int =
  result = 1
  for i in 1 .. n:
    result = result * i

const base = compute(5)          # sub-compile
assert base == 120

const doubled = base * 2         # folded in-process, reading a sub-compiled const
assert doubled == 240

proc describe(n: int): string =
  result = "n="
  result.add $n

const label = describe(base)     # sub-compile whose argument is a sub-compiled const
assert label == "n=120"

const nested = describe(doubled)
assert nested == "n=240"

# Three deep: a string const built from a string const built from an int const.
proc wrap(s: string): string = "[" & s & "]"
const wrapped = wrap(label)
assert wrapped == "[n=120]"

echo base, " ", doubled
echo label
echo nested
echo wrapped
