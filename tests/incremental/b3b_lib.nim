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
##   and the inserted proc goes in just after it, before `step6`;
## - `step10` is LAST, and the temp-minting edit goes there on purpose. The
##   counter that edit moves (`xelim`'s, carried module-wide in
##   `Pass.nextTemp`) is threaded across the eleven passes of
##   `pipeline.transform`, and `lowerExprs` runs three times over the whole
##   module, so an extra temp in the last proc renumbers the temps of the
##   FIRST one. Putting the edit at the end is what makes that visible.
##
## Do not renumber or reorder these procs casually: the scenario finds its
## four edit sites by plain string replacement over this file -- step5's
## string literal, step5's first statement, step6's signature, and step10's
## `let s` line -- and asserts bounds that depend on there being a dozen
## procs. For the same reason nothing here, comments included, may repeat one
## of those four strings: the first match wins, and a comment that quotes an
## edit site would be edited instead of the code.

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
