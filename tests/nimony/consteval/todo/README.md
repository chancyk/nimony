# consteval cases that do not work today

These are the compile-time-evaluation shapes phase A1c set out to cover and
could not. They are **not run by hastur**: `collectTests` (`src/hastur/walk.nim`)
treats a directory holding `.nim` files as a leaf and does not descend into its
subdirectories, so `tests/nimony/consteval/` sees its own tests and `todo/`
stays inert — exactly like the neighbouring `doc/` fixture directory. Do not put
a `setup.nim` or a `hastur.mode` in here: the walk quits with a hard failure if
a leaf directory's subdirectory carries either.

Each file is a finished test. Fix the compiler, `git mv` it up one level, run
`hastur --overwrite test tests/nimony/consteval/<file>.nim`, review the golden
and delete its entry below.

## `tconstenum.nim` — an enum result crashes the serializer

Any `const` whose value is an enum, produced by a sub-compile, aborts nimsem:

```
Error: unhandled exception: nifcore.nim(895, 3) `c.rem == 0` into: body did not consume all 14 children (left 6) [AssertionDefect]
```

`unravelEnum` (`src/nimony/exprexec.nim:535`) walks the enum body with
`enumDecl.into:` and a `while enumDecl.hasMore` loop over `takeLocal(...,
SkipFinalParRi)`; the loop leaves children unconsumed, and `into:` asserts that
it did not. Reproduces with a three-field enum and no explicit values, so it is
not about hole enums — the whole `EnumT/OnumT/AnumT` branch of `unravel` is dead
today. `const c = Blue` still works: that is `expreval`'s in-process fold, which
never reaches the serializer.

## `tconstsetres.nim` — a `set` result crashes the serializer

```
Error: unhandled exception: exprexec.nim(413, 13) `not err`  [AssertionDefect]
```

`unravelSet` (`exprexec.nim:507`) computes the loop bound as
`bitsetSizeInBytes(orig) * createXint(8'i64)` and hands it to
`indexVarLowerThanArrayLen`, which converts it with `asSigned` and then
`asUnsigned` and asserts the second conversion succeeded. Both fail. Reproduces
for `set[char]` and for `set[uint8]`. As with enums, a `set` *literal* const is
fine — `tests/nimony/const/tconstset.nim` covers that; it is only a set coming
back from a sub-compile that breaks.

## `tconstdistinct.nim` — a `distinct` result loses its conversion

`entryPoint` (`exprexec.nim:557`) wraps the value in `(conv <distinct type>)`
and recurses with `typ.childCursor`, but passes the recursion the original,
still distinct-typed argument. The generated call does not type-check:

```
tconstdistinct.nim(23, 18) Error: Type mismatch at [position]
writeNifInt(walk(0))
[1] expected: int64 but got: Meters (declared in lib/std/writenif.nim(29, 1))
```

A distinct *string* fails one step earlier, because `unravel`'s
`isSomeStringType(orig)` short-circuit fires before the `DistinctT` case is
reached:

```
[1] expected: string but got: Tag (declared in lib/std/writenif.nim(67, 1))
```

The fix is a conversion to the base type around `arg` in that branch.

## `tconstseqobj.nim` — `seq[T]` where `T` is a user object

The element type does not reach the sub-compile:

```
tconstseqobj.nim(15, 9) Error: undeclared identifier: Point
tconstseqobj.nim(18, 21) Error: expected type symbol for object constructor
[1] BUG: unhandled type: err
lib/std/system/seqimpl.nim(167, 89) Error: type mismatch: got: Point but wanted: Point
```

`collectUsedSymsFromExpr` re-emits the symbols the expression touches, but the
`seq[Point]` instantiation of `seqimpl` needs `Point` as a *declaration* in the
generated program and gets an unresolved ident instead — the "got: Point but
wanted: Point" pairs are two different `Point` symbols. A nested object
(`tconstnestedobj.nim`) and a seq whose elements are a *stdlib* object
(`tconsttable.nim`'s private `HashEntry`) both work, so this is specific to a
user type behind a generic instantiation.

## `tconstraise.nim` and `tconstmissingfile.nim` — a failed evaluation has no diagnostic

Both failure modes the phase asked for — an evaluation that raises
(`parseInt("x")`) and one that reads a missing file (`readFile`) — end the same
way. `exprexec.executeExpr` wraps the synthesised program in a `try/except`, the
handler writes no result, and the compiler then reports only that it could not
read the file it was going to parse:

```
[Error] cannot open: nimcache/tco2FE06BEDB3BA9682845674B5724CFE798972656F.out.nif
```

Two separate problems, and the second is why these cannot be `.msgs` tests even
as goldens for the bad behaviour:

1. The message names no source location and no cause. What the user must see is
   a diagnostic at the `const`, naming the exception or the missing path.
2. `hastur`'s `.msgs` contract infers the expected compiler exit code from the
   golden: `expectedExitCode = if msgSpec.contains(ErrorKeyword): 1 else: 0`
   with `ErrorKeyword = "Error:"` (`src/hastur/runner.nim:82`,
   `src/hastur/context.nim:21`). `[Error]` is not `Error:`, so hastur expects
   exit 0 while the compiler exits 1, and the test fails *with a byte-exact
   golden in place*. Verified.

The golden would also embed `tco<sha1 of the mangled expression>`, which churns
with any change to expression mangling. Fixing (1) removes that too, since a
proper diagnostic names the const rather than the cache file.

`tconstunsupported.nim`, up one level, is the failure mode that *does* reach the
user properly today, and is the `.msgs` test for it.
