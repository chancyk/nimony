import std/[syncio, assertions]

# TODO: the element type does not reach the sub-compile — "undeclared
# identifier: Point", then "got: Point but wanted: Point" for two different
# `Point` symbols. See README.md here.

# A `seq[T]` whose element type is a user object: the ptr-to-nif rule for the
# `data` field produces an `(aconstr (uarray Point) (oconstr Point …) …)`, so
# every element needs its own object walk AND its type slot normalised to a
# Symbol. The `Table` test reaches that through a *private* stdlib object;
# here the object is the test's own and carries a string field, so the
# elements are not flat.

type
  Point = object
    name: string
    x, y: int

proc grid(): seq[Point] =
  result = @[]
  for i in 0 ..< 3:
    result.add Point(name: "p" & $i, x: i, y: i * i)

const g: seq[Point] = grid()

assert g.len == 3
assert g[0].name == "p0"
assert g[2].name == "p2"
assert g[2].x == 2
assert g[2].y == 4

for p in items(g):
  echo p.name, " ", p.x, " ", p.y
