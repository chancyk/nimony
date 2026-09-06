import std/[syncio, assertions]

# A fixed-size array result: `unravelArray` emits an `aconstr` with the
# array's own type, element by element — no `ptr UncheckedArray` indirection,
# unlike a seq. An int array and a string array, so the element walk covers a
# flat entry point and the string one.

proc squares(): array[4, int] =
  result = [0, 0, 0, 0]
  for i in 0 ..< 4:
    result[i] = (i + 1) * (i + 1)

const sq = squares()

assert sq[0] == 1
assert sq[3] == 16
assert sq.len == 4

proc names(): array[3, string] =
  result = ["", "", ""]
  for i in 0 ..< 3:
    result[i] = "n" & $i

const ns = names()
assert ns[0] == "n0"
assert ns[2] == "n2"

echo sq[0], " ", sq[1], " ", sq[2], " ", sq[3]
echo ns[0], ns[1], ns[2]
