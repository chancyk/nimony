## Leaf of the three-module fixture for `incrementalLiveTests` (JIT_IMPL.md
## P0c). `p0c_mid.nim` imports it and `p0c_main.nim` imports that, so the
## three modules form a chain in which each phase can point at exactly one
## `dceEmit`.
##
## `leafDead` is exported and called by nobody: the DCE live set drops it, and
## making `p0c_mid.nim` call it is the smallest edit that moves a module's
## live set without touching any module's interface. `leafBonus` gives the
## "body-only edit" phase something to assign to, so that the appended private
## proc is reachable and the leaf's `.c.nif` really does change.
##
## The test machinery edits and restores this file in place, so keep it tiny.

var leafBonus* = 0

proc leafUsed*(x: int): int =
  x + 1

proc leafDead*(x: int): int =
  x + 2
