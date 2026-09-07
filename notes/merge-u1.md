# merge/u1 — upstream `4aa797d5` into `fast-devloop`

Step 1 of the six-commit upstream merge chain (`MERGE.md`). Base:
`193e1577` (= `fast-devloop` tip). Merged: `4aa797d5` "sem: `import` is not
a shadowing boundary (fixes #2454) (#2479)".

Research done before any edit; the resolution follows in `MERGE.md` §1.

## 1. What upstream `4aa797d5` does

9 files, +270/-65. `doc/language.md`, `src/nimony/{sem,sembasics,semcall,
semdata,sigmatch}.nim`, three new files under `tests/nimony/lookups/`.
It does **not** touch `src/nativenif.commit` (checked: absent from
`git show 4aa797d5 --stat`).

**Old rule.** `rawBuildSymChoice` (sembasics) walked scopes innermost-out and
stopped at

```nim
if result == 1 and (option == InnerMost or
    (option == FindOverloads and nonOverloadable == 1)):
  return
```

Under `InnerMost` a *single* hit at any level ended the walk even when that
hit was overloadable, and imported symbols were only ever added after the
loop (`considerImportedSymbols`). So a local `proc red` hid the imported enum
field `Color.red` and `paint(red)` never saw the field — issue #2454.

**New rule** (new "Identifier lookup" section in `doc/language.md`): lookup
only *collects*. A module's own toplevel scope and everything imported into
it are ONE outermost level; `import` contributes scope *distance*, not
shadowing. Continuation past a level is decided by declaration KIND:
non-overloadable (`let`/`var`/`const`/`type`/param/field/`result`/block
label) shadows; overloadable (routines **and enum fields**) accumulates. A
collected choice is resolved by (1) context — overload resolution or
overload disambiguation against an expected type of *any* kind, not just a
`proc` type; (2) scope distance — nearest candidate wins; (3) otherwise
"ambiguous identifier".

**Carriers of the new rule.**

- `semdata.nim`: one new `SemFlag` enum value, `KeepChoices`. No new type, no
  new field, **no new global `var`** — so `resetFrontendGlobals` (A2a-front)
  has nothing to gain.
- `sembasics.nim`: `rawBuildSymChoice` loses the `InnerMost` special case
  (`if result == 1 and nonOverloadable == 1 and option != FindAll`) and gains
  an out-parameter `nearestIsUnique: var bool` reporting whether the nearest
  contributing level contributed exactly one candidate. `buildSymChoice` gains
  the same out-parameter plus a compatibility overload without it. `option`
  loses its `= FindAll` default.
- `sem.nim`: `semIdentImpl`, `semQuoted`, `semExprSym` each gain
  `nearestIsUnique` (with a compatibility overload / a defaulted parameter);
  `semExpr`'s `Ident` and `QuotedX` cases thread it. `semExprSym`'s
  `CchoiceY` branch becomes: narrow by expected type via the new
  `tryNarrowChoice` -> else `KeepChoices` leaves the choice alone -> else
  `nearestIsUnique` takes the first (nearest) candidate and recurses ->
  else the pre-existing `"ambiguous identifier"` error. `semConvArg`'s two
  hand-rolled narrowing branches collapse into one `tryNarrowChoice` call.
- `semcall.nim`: `semCall` sem-checks each argument with
  `{AllowEmpty, KeepChoices}` — the formal parameter, not lookup, picks the
  candidate.
- `sigmatch.nim`: `Match` gains a private `resolvedChoice: SymId`; `useArg`
  emits it in place of the choice; new exported `tryNarrowChoice*` unifies
  enum-field and routine narrowing and follows a NAMED type to its
  implementation; `singleArgOnFormal` records `m.resolvedChoice` instead of
  wrapping the argument in an `hconv` (the `hconv` hid an iterator symbol
  from the coroutine lowering).

**No new diagnostic string.** `"ambiguous identifier"` and `"undeclared
identifier"` are pre-existing; nothing in the commit prints a symbol name, so
the F1 follow-ups' `sourceIdent`/`asNimSym` treatment has no new call site to
cover.

**New tests.** `tests/nimony/lookups/deps/mimportshadow.nim` (exports
`Color = enum red, green`, `tint`, `proc thing`),
`tests/nimony/lookups/timportshadow.nim` (+ `.output` holding `OK`). No new
`.msgs` golden.

## 2. What fast-devloop changed in the same five files

`git diff f69b8afc..193e1577 -- src/nimony/{sem,sembasics,semcall,semdata,
sigmatch}.nim` is +62/-15 over five files. Per hunk:

| file | hunk | phase |
|---|---|---|
| `sem.nim` | `subsGenericType`, `subsGenericProc`, `requestRoutineInstance`: save/set/restore `c.localNs` around `subs` | F1 |
| `sem.nim` | `semExprSym`: `"undeclared identifier: " & asNimSym(s.name)` and `"module symbol '" & asNimSym(s.name) & "'"` | F1 follow-ups |
| `sem.nim` | the local `proc asNimSym` deleted (it moved to `renderer.asNimSym`, `src/nimony/renderer.nim:2085`) | F1 follow-ups |
| `sembasics.nim` | `localNamespaceOf*`, and `makeLocalSym` minting `` x.N`routine`0 `` with `c.locals` keyed by identifier+namespace | F1 |
| `sembasics.nim` | `makeTemplateSym` delegates its non-routine arm to `makeLocalSym` | F1 |
| `semcall.nim` | `runCompiledMacroPlugin`: `"macro '" & asNimSym(finalFn) & "' not compiled"` | F1 follow-ups |
| `semdata.nim` | `SemContext.localNs*: string` | F1 |
| `sigmatch.nim` | `getErrorMsg`: three `pool.syms[...]` -> `asNimSym(...)` | F1 follow-ups |

Three commits produced all of it: `73f605d3` "sem: number a local inside its
own routine, not the module" (F1), `d586482a` "symparser: name the two
spellings the compiler shares" (F1 follow-ups, lifts `localNamespace` /
`sourceIdent` into `src/lib/symparser.nim` and `asNimSym` into
`renderer.nim`) and `45180a3d` "nimony: a diagnostic names a symbol by the
identifier the user wrote" (F1 follow-ups). `resetFrontendGlobals`
(A2a-front) is in `src/nimony/semmain.nim:762` and none of the three touches
it; `SemContext.localNs` is per-context, not process-wide.

None of our hunks is in a proc upstream rewrote except `semExprSym`, and
there our hunk is in the `NoSym` arm while upstream's is in the `CchoiceY`
arm and in the signature.

## 3. Collision map (probe merge, no resolution)

A throwaway worktree (`git worktree add --detach /tmp/merge-u1-probe HEAD`;
`git merge --no-commit --no-ff 4aa797d5`; then `merge --abort` and
`worktree remove --force`) and `git merge-tree --write-tree HEAD 4aa797d5`
agree: **no textual conflict**. `merge-tree` returned a bare tree oid
`6f96bddeffff67a24ba251d6cf8a8f40e6552141` with no `CONFLICT` line.

Adjacency worth eyeballing rather than trusting:

- `sem.nim` `semExprSym`: upstream rewrites the signature (~1814) and the
  `CchoiceY` arm (~1836-1868); ours is the `asNimSym` rename in the `NoSym`
  arm (~1826) and in the `ModuleY` arm (~1912). Same proc, different arms.
- Everything else is 100+ lines apart in a different proc.

`src/nativenif.commit` is not in the merge at all; it stays at our pin
`5f6f011e`. One golden is ADDED (`timportshadow.output`); no `.msgs` or
`.nif` golden is touched.

## 4. For the next agents in the chain

- **Agent 4 (`c6be04e1`, "no globals in nifcore")** and **agent 6
  (`e1da48e9`, the nifsyms refactor)** land in the same region this commit
  did. After this merge, `sembasics.rawBuildSymChoice` /
  `buildSymChoice` have an extra `nearestIsUnique: var bool` parameter and a
  compatibility overload; `sem.semIdentImpl` / `semQuoted` / `semExprSym`
  likewise. Any refactor that re-signatures those procs has to carry the
  out-parameter through, or the scope-distance fallback silently stops
  firing (it degrades to "ambiguous identifier", which `tests/nimony/lookups/
  timportshadow.nim` catches).
- Our side of `sembasics.nim` is `localNamespaceOf` + `makeLocalSym` +
  `makeTemplateSym`, lines ~388-480, far from the lookup procs. The nifsyms
  refactor is the one likely to move `pool.syms` under it: `makeLocalSym`
  reads `pool.syms[sym]` only through `localNamespaceOf`, and
  `symparser.localNamespace`/`sourceIdent` are pure string functions on the
  symbol spelling, so they survive a symbol-table refactor as long as the
  spelling `` x.N`routine`0 `` is still what `pool.syms` yields.
- Diagnostics on this branch go through `renderer.asNimSym`
  (`src/nimony/renderer.nim:2085`), NOT `pool.syms`. A refactor that
  reintroduces `pool.syms[...]` into an error string re-opens the F1
  follow-ups' bug (a user sees `` s.0`foo`0 `` instead of `s`).
- `semdata.SemFlag` now carries `KeepChoices` between `AllowOverloads` and
  `PreferIterators`; `SemContext` carries `localNs`. Neither is process-wide,
  so `resetFrontendGlobals` (A2a-front) needs no change — confirm that again
  if a later commit moves either into a global.

## 5. The resolution

`git merge --no-commit --no-ff 4aa797d5` reported "Automatic merge went well"
for all five source files. Nothing was hand-edited; the check that this is
right is not "git said so" but the following, run after the merge:

```
for f in sem sembasics semcall semdata sigmatch; do
  git show 4aa797d5:src/nimony/$f.nim > /tmp/up_$f.nim
  diff -u /tmp/up_$f.nim src/nimony/$f.nim
done
```

The merged tree differs from UPSTREAM's version of those five files by
exactly our eight F1 / F1-follow-up hunks (the three `c.localNs`
save/restores, `localNamespaceOf`, `makeLocalSym`, `makeTemplateSym`,
`SemContext.localNs`, and the six `pool.syms[...]` -> `asNimSym(...)`
diagnostic renames plus the deletion of `sem.nim`'s private `asNimSym`) and
by nothing else. So upstream's side is present in full and ours is present in
full; there was no line where one had to give way to the other.

In `semExprSym`, the one proc both sides touch, the two live in different
arms: ours renders the symbol name in the `NoSym` and `ModuleY` error
messages, upstream rewrites the `CchoiceY` arm and the signature. Read the
merged proc at `src/nimony/sem.nim:1834` — both are there.

## 6. Verification (this worktree)

Environment: `XDG_CACHE_HOME=/tmp/cache-u1`,
`NIMONY_NATIVENIF=/Users/chanc/Projects/nativenif`,
`/Users/chanc/Projects/nativenif` left at `5f6f011e` on branch
`jit/b3e-native` (checked before and after; `hastur`'s `syncNativenif`
returns immediately because HEAD already equals the pin, so it neither
checked out nor warned).

Baseline taken BEFORE the merge on the same worktree: `bin/hastur
tests/nimony` = `794 / 794 tests successful in 170.91s.`

Results after the merge, all in `/tmp/merge-u1`:

| command | result |
|---|---|
| `nim c -r src/hastur/hastur build all` | exit 0 |
| `bin/hastur test tests/incremental` | every scenario green; `decl-stability: 4 / 4 phases successful` |
| `bin/hastur tests/inproc` | `3 / 3 tests successful` |
| `bin/hastur test tests/ctfe_diff` | `19 file(s), 50 artifact(s), 79 .s.nif, 0 difference(s)` |
| `bin/hastur test tests/nifcache` | `nifcache: all checks passed` |
| `bin/hastur test tests/nimony_r` | `nimony_r: all checks passed` |
| `bin/hastur test tests/ctfe_engine` | `ctfe_engine: all checks passed` |
| `bin/hastur test tests/ledger` | `[ledger] all ledger tests passed` |
| `bin/hastur tests/nimony` | `795 / 795` (was `794 / 794`; +1 = `tests/nimony/lookups/timportshadow.nim`) |
| `bin/hastur boot --boot-backend:native` | `stages 1 and 2 are byte-identical`, `stages 2 and 3 are byte-identical` |

`bench/devloop_ab.sh /tmp/devloop_base . self.editbody 5` was run because the
change removes an early exit from `rawBuildSymChoice`, i.e. from a sem hot
path. B/A cpu median **0.238** (recorded headline: 0.94 / 3.56 = 0.264), so
the ratio did not move against us. Both absolute sides are ~1.4x the logged
numbers on this run (A cpu 5.18 vs 3.56, B cpu 1.23 vs 0.94) because other
worktrees were building on the same machine; per `BENCHMARK.md` §0 the
interleaved ratio is the number to read under drift, and it is unchanged.
