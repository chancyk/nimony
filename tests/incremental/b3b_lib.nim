## Fixture for `incrementalDeclStabilityTests` (JIT_IMPL.md B3b).
##
## Symbol-granularity lowering rests on one premise: a body edit changes ONE
## top-level declaration of the module's `.s.nif`, so hexer can re-lower that
## declaration and splice the rest of the previous `.x.nif`. This module is
## shaped to measure that premise rather than to compute anything:
##
## - every proc returns a value, so every one of them declares an implicit
##   `result` -- `sembasics.makeLocalSym` numbers those from a MODULE-wide
##   per-name counter (`SemContext.locals`), so inserting a proc renumbers
##   `result.N` in every proc after it;
## - every proc shares the local names `acc` and `s`, so the same counter
##   renumbers those too;
## - each proc owns a distinct string literal, so an in-place edit of one
##   literal is a change to exactly one declaration and nothing else;
## - `step5` sits in the middle, which is where the line-shifting edit goes,
##   and the inserted proc goes in just after it, before `step6`.
##
## Do not renumber or reorder these procs casually: the scenario edits them
## by name (`b3b step five`, `var acc = x + 5`, `proc step6*(x: int): int =`)
## and asserts bounds that depend on there being a dozen of them.

proc step1*(x: int): int =
  var acc = x + 1
  let s = "b3b step one"
  result = acc + s.len

proc step2*(x: int): int =
  var acc = x + 2
  let s = "b3b step two"
  result = acc + s.len

proc step3*(x: int): int =
  var acc = x + 3
  let s = "b3b step three"
  result = acc + s.len

proc step4*(x: int): int =
  var acc = x + 4
  let s = "b3b step four"
  result = acc + s.len

proc step5*(x: int): int =
  var acc = x + 5
  let s = "b3b step five"
  result = acc + s.len

proc step6*(x: int): int =
  var acc = x + 6
  let s = "b3b step six"
  result = acc + s.len

proc step7*(x: int): int =
  var acc = x + 7
  let s = "b3b step seven"
  result = acc + s.len

proc step8*(x: int): int =
  var acc = x + 8
  let s = "b3b step eight"
  result = acc + s.len

proc step9*(x: int): int =
  var acc = x + 9
  let s = "b3b step nine"
  result = acc + s.len

proc step10*(x: int): int =
  var acc = x + 10
  let s = "b3b step ten"
  result = acc + s.len

proc total*(x: int): int =
  var acc = 0
  acc = acc + step1(x) + step2(x) + step3(x) + step4(x) + step5(x)
  acc = acc + step6(x) + step7(x) + step8(x) + step9(x) + step10(x)
  result = acc
