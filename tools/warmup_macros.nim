# `tools/warmup.nim` plus one macro, for the tests that have one: invoking it
# fills `<nifcache>/macro_plugins.host`, which every macro's plugin build
# shares. See `WorkItem.macros` in `src/hastur/parallel.nim`.

import std/[assertions, syncio, macros]

macro warm(): untyped =
  result = newCall("echo", [newStrLitNode("warmup")])

proc main =
  # Touch each import so nothing is dead-code-eliminated before it lands
  # in the cache.
  let s = "warmup"
  assert s.len == 6
  if s.len == 0:
    warm()

main()
