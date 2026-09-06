import std/[syncio, assertions]

# A tuple result: `unravelTuple` walks the fields positionally. Mixed field
# types on purpose — an int, a string and a bool — so one value crosses three
# different entry points of the serializer.

proc divmod2(a, b: int): (int, int) =
  result = (a div b, a mod b)

const dm = divmod2(17, 5)
assert dm[0] == 3
assert dm[1] == 2

type Named = tuple[name: string; count: int; ok: bool]

proc tally(name: string; n: int): Named =
  result = (name: name, count: n * 2, ok: n > 0)

const t = tally("items", 7)
assert t.name == "items"
assert t.count == 14
assert t.ok

echo dm[0], " ", dm[1]
echo t.name, " ", t.count, " ", t.ok
