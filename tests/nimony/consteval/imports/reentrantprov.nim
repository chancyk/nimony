## Fixture for `tconstreentrant.nim`: a module whose OWN `const` needs a
## sub-compile, and which then goes on declaring ordinary procs, generics and
## templates after it.
##
## A2c runs that sub-compile inside the process that is semchecking this
## module, with the frontend's globals moved aside and put back
## (`semos.FrontendSnapshot`). Everything below the `const` is therefore
## semchecked with symbols this module interned BEFORE the nested build ran,
## which is exactly the state a leak would corrupt.

import std / syncio

proc collatzLen*(start: int): int =
  var n = start
  result = 0
  while n != 1:
    if n mod 2 == 0: n = n div 2
    else: n = 3 * n + 1
    inc result

const ProviderSteps* = collatzLen(27)
  ## Needs a sub-compile: a loop with a local variable.

# --- everything below is declared AFTER the nested build ran ---------------

proc pairUp*[T](x: T): (T, T) =
  ## A generic instantiated by the importing module, i.e. its instance is minted
  ## from this module's post-nested-build symbol table.
  result = (x, x)

template twice*(x: untyped): untyped =
  ## A template expanded in the importer, for the same reason.
  (x) + (x)

proc render*(n: int): string =
  result = "steps="
  result.add $n

const ProviderLabel* = render(ProviderSteps)
  ## A second sub-compile, from the state the first one left behind.

proc announce*() =
  echo ProviderLabel
