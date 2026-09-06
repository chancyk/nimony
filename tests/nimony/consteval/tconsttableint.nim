import std/[syncio, assertions]
import std/tables

# `Table[int, string]` — the mirror of `tconsttable.nim`'s `Table[string,
# int]`. The two are not the same walk: here the *value* side is the string,
# so the `HashEntry` object the serializer recurses into holds a string field
# rather than a string key, and the `hashes` seq is derived from int keys.

proc names(): Table[int, string] =
  result = initTable[int, string]()
  for i in 1 .. 4:
    result[i * 10] = "v" & $i

const t: Table[int, string] = names()

assert t.len == 4
assert t.getOrDefault(10, "?") == "v1"
assert t.getOrDefault(40, "?") == "v4"
assert t.getOrDefault(99, "?") == "?"
assert t.contains(20)
assert not t.contains(21)

# A table built with a literal rather than a loop, so the key set is not a
# contiguous run and the probe sequence differs.
proc sparse(): Table[int, string] =
  result = initTable[int, string]()
  result[1] = "one"
  result[1000] = "thousand"
  result[-7] = "minus seven"

const s: Table[int, string] = sparse()
assert s.len == 3
assert s.getOrDefault(1000, "") == "thousand"
assert s.getOrDefault(-7, "") == "minus seven"

echo t.len, " ", t.getOrDefault(30, "?")
echo s.getOrDefault(1, ""), "/", s.getOrDefault(-7, "")
