## Fixture for `incrementalOCacheTests`: a `const` that `expreval` cannot fold,
## so it costs a compile-time-eval sub-program. Its sibling `ctfe_ocache_b.nim`
## does the same with a different expression; both are compiled into one
## nimcache and must share the sub-programs' object files.
import std / syncio

proc square(x: int): int = x * x

const c = square(7)

echo c
