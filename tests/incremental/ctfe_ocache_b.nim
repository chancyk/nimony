## Sibling of `ctfe_ocache_a.nim`: a different expression, hence a different
## sub-program, but the same stdlib closure behind it.
import std / syncio

proc cube(x: int): int = x * x * x

const c = cube(3)

echo c
