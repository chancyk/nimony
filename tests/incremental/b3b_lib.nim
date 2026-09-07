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
##   and the inserted procs go in just after it, before `step6`;
## - `step10` carries the temp-minting edit (`tempadd`) on purpose: the
##   counter that edit moves (`xelim`'s, carried module-wide in
##   `Pass.nextTemp`) is threaded across the eleven passes of
##   `pipeline.transform`, and `lowerExprs` runs three times over the whole
##   module, so an extra temp there renumbers the temps of the FIRST proc.
##   The procs after it (`guardOne` .. `total`) do not mint `xelim` temps
##   of their own, so the edit still shows what it was placed to show.
## - `guardOne`/`guardTwo` catch a ref exception, which is what makes
##   `derefs.nim` mint its `` `err `` temporary, and `loopOne` has the `while`
##   and `case` that drive `controlflow.nim`'s `` `cf `` temporaries. Both
##   counters used to number from MODULE-wide state, so a raising proc inserted
##   above them renumbered them; they sit AFTER the insertion point on purpose,
##   which is the only position where that would show.
##
## They are `proc ... =` rather than `proc ...: int =` because a value-returning
## proc whose body catches a ref exception does not survive the C backend today
## (`error: non-void function ... should return a value`, reproducible at the F1
## fork point and unrelated to anything measured here).
##
## Do not renumber or reorder these procs casually: the scenario finds its
## four edit sites by plain string replacement over this file -- step5's
## string literal, step5's first statement, step6's signature, and step10's
## `let s` line -- and asserts bounds that depend on there being a dozen
## procs. For the same reason nothing here, comments included, may repeat one
## of those four strings: the first match wins, and a comment that quotes an
## edit site would be edited instead of the code.

type
  B3bError* = ref object of Exception
    code*: int

var guardSink* = 0
  ## Where `guardOne`/`guardTwo` put their answer; a `var` because they cannot
  ## return one (see the header).

proc mayFail*(x: int) {.raises: B3bError.} =
  if x < 0:
    raise B3bError(msg: "b3b below zero", code: x)

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

proc guardOne*(x: int) =
  ## `derefs.nim` mints one `` `err `` here.
  try:
    mayFail(x - 11)
    guardSink = x + 11
  except B3bError as e:
    guardSink = e.code

proc guardTwo*(x: int) =
  ## ...and a second one here, which is the one an inserted raising proc used to
  ## renumber.
  try:
    mayFail(x - 12)
    guardSink = x + 12
  except B3bError as e:
    guardSink = e.code

proc loopOne*(x: int): int =
  var acc = 0
  var i = 0
  while i < x:
    case i mod 3
    of 0: acc = acc + 1
    of 1: acc = acc + 2
    else: acc = acc + 3
    inc i
  result = acc

proc total*(x: int): int =
  var acc = 0
  acc = acc + step1(x) + step2(x) + step3(x) + step4(x) + step5(x)
  acc = acc + step6(x) + step7(x) + step8(x) + step9(x) + step10(x)
  guardOne(x)
  guardTwo(x)
  acc = acc + guardSink + loopOne(x)
  result = acc
