import std/[syncio, assertions]

# A proc with a `var` parameter in the evaluated expression. The mutation
# happens entirely inside the sub-compile — only the final value crosses the
# boundary — so what this pins down is that `collectUsedSymsFromExpr` pulls in
# a routine whose parameter is `var T`, and that the `block:` initializer
# shape (a local `var`, statements, then a value) is forwarded whole rather
# than being folded.

proc bump(x: var int; by: int) =
  x = x + by

proc appendTo(s: var string; part: string) =
  if s.len > 0: s.add "+"
  s.add part

const total = block:
  var acc = 0
  bump(acc, 5)
  bump(acc, 7)
  bump(acc, -2)
  acc

assert total == 10

const joined = block:
  var s = ""
  appendTo(s, "a")
  appendTo(s, "b")
  appendTo(s, "c")
  s

assert joined == "a+b+c"

echo total
echo joined
