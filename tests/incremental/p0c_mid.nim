## Middle module of the `incrementalLiveTests` fixture: it is what the
## "live-set edit" phase changes, by making it call `p0c_leaf.leafDead`.

import p0c_leaf

proc midValue*(x: int): int =
  leafUsed(x) * 10 + leafBonus
