# MERGE.md — upstream commits merged into `fast-devloop`

One entry per upstream commit, in merge order. `fast-devloop` forked from
`nim-lang/nimony` master at **f69b8afc** ("Fix/closure typeclass hasmore",
#2477); these are the six commits master gained after that, merged one at a
time so each conflict is resolved against a known-good base.

Read with `SUMMARY.md` (what this branch changed and why), `JIT_IMPL.md` (the
phase log and Status table), `BENCHMARK.md` (how every number is taken) and
`notes/handoff.md` (the merge routine and the upstream-drift analysis that
this file supersedes as it is filled in).

## The chain

| # | commit | subject | branch | status |
|---|---|---|---|---|
| 1 | `4aa797d5` | sem: `import` is not a shadowing boundary (#2479) | `merge/u1` | merged |
| 2 | `c6db98b6` | sem: sum type constructor over a `ref object` produces the `ref` (#2481) | `merge/u2` | merged |
| 3 | `b7c7daa6` | newest nativenif (#2478) — pin `d0781a48` -> `e201a816` | `merge/u3` | pending |
| 4 | `c6be04e1` | no globals in nifcore (#2482) | `merge/u4` | pending |
| 5 | `38f67463` | std/http: thread the tag space instead of keeping one per process (#2484) | `merge/u5` | pending |
| 6 | `e1da48e9` | nifsyms refactor (#2483) — pin `e201a816` -> `f9af5b24` | `merge/u6` | pending |

Plus a parallel track in `../nativenif`: rebase our `jit/b1 .. jit/b3e-native`
chain (fork point `d0781a48`) onto upstream nativenif master, which steps 3
and 6 need. See "nativenif track" at the end.

## Entry template

Each agent appends its section below, in chain order, using this shape:

```
## N. `<sha>` — <subject>

**What upstream changed.** Two or three sentences: the intent, not the diff.

**How it collided with us.** Every conflicted file, and for each one the
fast-devloop change it collided with (name the phase: P0*, A1*, A2*, B*, F1,
F2, M1, H1).

**What we did.** The resolution per file. Say explicitly where upstream's
version won, where ours won, and where the two had to be combined.

**Was anything of ours made redundant?** Code we could now delete, or a
follow-up to delete it.

**Was anything of ours broken?** Behaviour we had to restore by other means.

**Evidence.** The commands run and their verbatim tails: `hastur build all`,
`hastur tests/nimony`, `hastur boot --boot-backend:native` (stages 1 == 2 == 3),
`tests/incremental`, `tests/inproc`, `tests/ctfe_diff`, `tests/nimony_r`,
`tests/ctfe_engine`, `tests/ledger`, `tests/nifcache`, and the
`decl-stability` scenario. Note anything skipped and why.

**Numbers.** Only if the merge could plausibly move them: `bench/devloop_ab.sh
/tmp/devloop_base . self.editbody 5` cpu-sum first, per `BENCHMARK.md`.
```

---

## 1. `4aa797d5` — sem: `import` is not a shadowing boundary

**What upstream changed.** Lookup no longer treats the import table as an
outermost scope that a single local hit can cut off. A module's own toplevel
scope and everything imported into it are one, outermost level, and whether
the walk continues past a level is decided by the KIND of what was found
there: a lone non-overloadable declaration (`let`, `var`, `const`, `type`, a
parameter, a field, `result`, a block label) shadows; overloadable ones —
routines **and enum fields** — accumulate. The collected choice is resolved by
context first (overload disambiguation, widened so the expected type may be of
any kind, not only a `proc` type), by scope distance second, and only then
called ambiguous. Mechanically: `rawBuildSymChoice` drops its `InnerMost`
special case and reports a new `nearestIsUnique` out-parameter, threaded
through `buildSymChoice` / `semIdentImpl` / `semQuoted` / `semExprSym` (each
keeping a compatibility overload); `SemFlag` gains `KeepChoices`, which
`semCall` sets on every argument so the formal parameter, not lookup, picks
the candidate; `sigmatch` gains `tryNarrowChoice` (enum-field and routine
narrowing unified, following a named type to its implementation) and
`Match.resolvedChoice`, which replaces the `hconv` wrapper that used to hide
an iterator symbol from the coroutine lowering. `doc/language.md` gains an
"Identifier lookup" section stating the rule.

**How it collided with us.** It did not: there is no conflict hunk to report.
`git merge --no-commit --no-ff 4aa797d5` printed "Automatic merge went well"
for all five shared files, and a second opinion agreed — `git merge-tree
--write-tree HEAD 4aa797d5` returned a bare tree oid
`6f96bddeffff67a24ba251d6cf8a8f40e6552141` with no `CONFLICT` line. The five
files are shared, but the two sides sit in different procs:

| file | upstream | fast-devloop | our phase |
|---|---|---|---|
| `sem.nim` | `semConvArg`, `semIdentImpl`, `semQuoted`, `semExprSym` (signature + the `CchoiceY` arm), `semExpr`'s `Ident`/`QuotedX` cases | `subsGenericType`, `subsGenericProc`, `requestRoutineInstance` (`c.localNs` save/restore); `semExprSym`'s `NoSym` and `ModuleY` error strings; deletion of the private `asNimSym` | F1 (`73f605d3`), F1 follow-ups (`d586482a`, `45180a3d`) |
| `sembasics.nim` | `rawBuildSymChoice`, `buildSymChoice` (lines 132-193) | `localNamespaceOf`, `makeLocalSym`, `makeTemplateSym` (lines 413-480) | F1 |
| `semdata.nim` | `SemFlag` gains `KeepChoices` (line 52) | `SemContext.localNs` (line 179) | F1 |
| `semcall.nim` | `semCall` (line 1532) | `runCompiledMacroPlugin` (line 976) | F1 follow-ups |
| `sigmatch.nim` | `Match`, `useArg`, `tryNarrowChoice`, `singleArgOnFormal` | `getErrorMsg`, three renames (lines 236, 265, 271) | F1 follow-ups |

`semExprSym` is the one proc both sides land in, and even there they are in
different arms: ours renders a symbol NAME in the `NoSym`/`ModuleY` error
messages, upstream decides WHICH symbol wins in the `CchoiceY` arm.

**What we did.** Nothing was hand-edited, so "who won" is not answered by
trusting git but by comparing the merged files with upstream's own:

```
for f in sem sembasics semcall semdata sigmatch; do
  git show 4aa797d5:src/nimony/$f.nim > /tmp/up_$f.nim
  diff -u /tmp/up_$f.nim src/nimony/$f.nim
done
```

The merged tree differs from UPSTREAM's five files by exactly our eight
F1 / F1-follow-up hunks — the three `c.localNs` save/restores,
`localNamespaceOf`, `makeLocalSym`, `makeTemplateSym`, `SemContext.localNs`,
the six `pool.syms[...]` -> `asNimSym(...)` renames and the deleted private
`asNimSym` — and by nothing else. Upstream's semantics are present in full,
ours are re-applied in full, and no line had to give way. Per file: upstream
won every line it wrote, we won every line we wrote, and nothing was combined
because nothing overlapped.

Three obligations were checked by hand rather than by the merge:

- **Local symbol spelling (F1).** Upstream touches no symbol-minting proc:
  `makeLocalSym`, `makeGlobalSym`, `makeTemplateSym` and `newSymId` do not
  appear in `git show 4aa797d5`. The `` x.N`routine`0 `` shape and the
  module-wide uniqueness `hexer_context.hoistedConsts` consumes are untouched,
  and `decl-stability`'s `tempadd` phase — which asserts exactly 1 changed
  declaration on both the sem-input and the lowering-output digest — still
  passes.
- **Diagnostics (F1 follow-ups).** Upstream introduces no new message. Its two
  error sites reuse the pre-existing `"ambiguous identifier"` (which names no
  symbol) and `m.error InvalidMatch` (which renders through
  `sigmatch.getErrorMsg`, already routed through `asNimSym`). So there is
  nothing new to put through `symparser.sourceIdent`, and **no `.msgs` golden
  was touched**: `git diff HEAD --stat -- 'tests/**/*.msgs'` is empty. One
  golden is ADDED by upstream, `tests/nimony/lookups/timportshadow.output`,
  whose whole content is `OK`.
- **State objects (A2a-front) and the pin.** `KeepChoices` is a value of the
  existing `SemFlag` enum and `Match.resolvedChoice` a field of the existing
  `Match` object; the commit adds no global `var`, so `resetFrontendGlobals`
  (`src/nimony/semmain.nim:762`) needs no addition. `src/nativenif.commit` is
  not in the commit and did not move — it still reads
  `5f6f011e2885bd88d9bd75244937a22432aa38a9 2026-09-07`, and
  `/Users/chanc/Projects/nativenif` is still at `5f6f011e` on branch
  `jit/b3e-native` (`syncNativenif` returns before its `git checkout` because
  HEAD already equals the pin).

**Was anything of ours made redundant?** No. F1/F2 change how a symbol is
SPELLED; `4aa797d5` changes which symbol an identifier RESOLVES to. There is
no overlap to retire and nothing on the branch became dead.

**Was anything of ours broken?** No. Nothing had to be restored by other
means: the branch's own gate (`decl-stability`, four phases) and every
focused suite pass unchanged, and the full tree gained exactly the one test
upstream added.

**Evidence.** Worktree `/tmp/merge-u1`, branch `merge/u1`, with
`XDG_CACHE_HOME=/tmp/cache-u1` and
`NIMONY_NATIVENIF=/Users/chanc/Projects/nativenif`.

Baseline, taken on the same worktree BEFORE the merge:

```
794 / 794 tests successful in 170.91s.
SUCCESS.
```

After the merge:

```
$ nim c -r src/hastur/hastur build all
105975 lines; 1.430s; 269.852MiB peakmem; proj: /Users/chanc/Projects/nativenif/src/nifasm/nifasm.nim; out: /private/tmp/merge-u1/bin/nifasm [SuccessX]
(exit 0)

$ bin/hastur test tests/incremental
incremental-live (--spawn:always): 5 / 5 phases successful in 2.08s.
decl-stability: .s.nif 32 decls | in-place changed 1 | insert changed 11 (blind 1, added 2) | stmtadd changed 12 (blind 1) | decls digest 52 syms, sem-input changed 1/0/1/1 | lowering-output changed 1/-/1/1 | .x.nif in-place changed 1
decl-stability: 4 / 4 phases successful in 1.24s.
SUCCESS.

$ bin/hastur tests/inproc
[inproc/lengc] all in-process lengc tests passed
3 / 3 tests successful in 32.64s.
SUCCESS.

$ bin/hastur test tests/ctfe_diff
ctfediff: 19 file(s), 50 artifact(s), 79 .s.nif, 0 difference(s)
ctfe_diff: all checks passed

$ bin/hastur test tests/nifcache
  ok: both modes left the same 106 .nif artifacts, byte for byte
nifcache: all checks passed

$ bin/hastur test tests/nimony_r
  ok   a cached link and a scratch link produce byte-identical executables
  ok   the compiler itself runs from memory (--version -> 0.6.0)
nimony_r: all checks passed

$ bin/hastur test tests/ctfe_engine
  28 non-main `.c.nif` file(s) byte-identical to `NIMONY_CCACHE=off`
ctfe_engine: all checks passed

$ bin/hastur test tests/ledger
[ledger] all ledger tests passed

$ bin/hastur tests/nimony
795 / 795 tests successful in 235.15s.
SUCCESS.

$ bin/hastur boot --boot-backend:native
[boot] stages 0 and 1 differ.
[boot] stages 1 and 2 are byte-identical.
[boot] stages 2 and 3 are byte-identical.
[boot] total 83.02s.
SUCCESS.
```

794 -> 795 is accounted for exactly: upstream adds
`tests/nimony/lookups/timportshadow.nim` (`SUCCESS
tests/nimony/lookups/timportshadow.nim`, log line 3294). No other test
appeared, disappeared or changed category. Nothing was skipped.

**Numbers.** Taken because the change removes an early exit from
`rawBuildSymChoice`, i.e. from a sem hot path, so the loop could plausibly
have moved:

```
$ bench/devloop_ab.sh /tmp/devloop_base . self.editbody 5
self.editbody: A wall median 3.997  min 3.976 | cpu median 5.176  min 5.156 | peak rss 117 MB
self.editbody: B wall median 1.221  min 1.212 | cpu median 1.231  min 1.219 | peak rss 107 MB
B/A cpu (median): 0.238   B/A cpu (min): 0.236   B/A peak rss: 0.91
```

Read cpu first, per `BENCHMARK.md` §0: **B/A cpu 0.238** against the recorded
headline's 0.94 / 3.56 = 0.264, so the ratio did not move against us. Both
absolute sides are ~1.4x their logged values on this run (A cpu 5.18 vs 3.56,
B cpu 1.23 vs 0.94) because other worktrees on this machine were building
throughout; the interleaved ratio is what survives that, and it is unchanged.
The absolute 0.92 s headline should be re-taken on a quiet machine before it
is quoted again.

## 2. `c6db98b6` — sem: a sum type constructor over a `ref object` produces the `ref`

**What upstream changed.** `type T = ref object` is split by `semTypeSection`
into the alias `T` and a separate object declaration `T.Obj`, and a sum type's
synthesized `anum` recorded the OBJECT as its owner. A constructor with no
expected type — `eval(AddOpr(a: ..., b: ...))` — therefore produced `T.Obj`
instead of `T` (issue #2480). Upstream makes the owner the type the user
spelled: `SemContext` gains `refObjOwners: Table[SymId, SymId]` mapping
`T.Obj` -> `T`, filled at the two places `semTypeSection` performs the split;
`semTypeSection` loses the `outerRefOwner` parameter it used to thread through
its three recursive calls, because the split runs in `SemcheckTopLevelSyms`
and the object body is semchecked a phase later, so the context, not the call
stack, is where the answer has to live. In `sem.nim`, `sumTypeObjDecl` is
factored out of `findBranchFields` and `buildInferredInvoke` now takes
`typevars` rather than a whole `TypeDecl`, so a `ref` sum type can infer
through `T.Obj`'s freshly-named typevars and still invoke `T`.

**How it collided with us.** It did not; no conflict hunk. `git merge
--no-commit --no-ff c6db98b6` reported "Automatic merge went well" for all
three source files. The three overlapping files are touched in different
procs:

| file | upstream | fast-devloop | our phase |
|---|---|---|---|
| `sem.nim` | the `semTypeSection` forward decl (486), `SemObjectState.ownerSym`'s comment (1591), `sumTypeObjDecl`/`findBranchFields` (2496-2530), `synthSumTypeDiscriminator` (2775), `getAnumOwnerType` (4321), `buildInferredInvoke`/`inferSumTypeFromFields`/`inferObjTypeFromFields` (4388-4470) | `subsGenericType`, `subsGenericProc`, `requestRoutineInstance` (`c.localNs`); `semExprSym`'s two error strings; the deleted private `asNimSym` | F1, F1 follow-ups |
| `semdata.nim` | `SemContext.refObjOwners` (173) | `SemContext.localNs` (179) | F1 |
| `semdecls.nim` | `semTypeSection` (1414-1554) | `semProcImpl`'s `c.localNs` save/restore (1065-1195); `compileMacroPlugin(..., c.g.config.baseDir)` (1201) | F1, A2c |

The closest pair is in `semdata.nim`, where upstream's `refObjOwners` now sits
six lines above our `localNs` inside the same `SemContext` object.

**What we did.** Nothing was hand-edited. As in §1, the evidence is not that
git succeeded but that the merged files, diffed against UPSTREAM's own, differ
by exactly our hunks and nothing else:

```
for f in sem semdata semdecls; do
  git show c6db98b6:src/nimony/$f.nim > /tmp/u2_$f.nim
  diff -u /tmp/u2_$f.nim src/nimony/$f.nim
done
```

What remains is: the three `c.localNs` save/restores and the two
`asNimSym` renames plus the deleted private `asNimSym` in `sem.nim` (F1,
F1 follow-ups); `SemContext.localNs` in `semdata.nim` (F1); and in
`semdecls.nim` the `c.localNs` save/restore in `semProcImpl` (F1) and the
`c.g.config.baseDir` argument to `compileMacroPlugin` (A2c, `eb896a80`).
Nothing else. Upstream won every line it wrote, we won every line we wrote,
nothing had to be combined.

Note that `SemFlag.KeepChoices` — step 1's addition — does NOT appear in the
`semdata.nim` difference. That is the expected result and worth stating,
because it is the one thing that would show a step-1 regression: `c6db98b6`
is upstream's child of `4aa797d5`, so its base already carries `KeepChoices`,
and its absence from the difference confirms our step-1 merge kept upstream's
version of that file rather than a variant of it.

The three hand-checks the merge cannot do:

- **F1 spelling.** `git show c6db98b6 | grep -E 'makeLocalSym|makeGlobalSym|
  makeTemplateSym|newSymId|makeFieldSym|localNs'` is empty: no symbol-minting
  proc is touched, so `` x.N`routine`0 `` and the module-wide uniqueness
  `hexer_context.hoistedConsts` needs are untouched. `decl-stability` reports
  the same four phases and the same digest counts as on `merge/u1`
  (`sem-input changed 1/0/1/1 | lowering-output changed 1/-/1/1`).
- **Diagnostics.** The commit adds no `buildErr`, no error string and no
  `pool.syms` read (all three greps empty), so there is nothing new to route
  through `renderer.asNimSym`. **No golden was touched at all** — not a
  `.msgs` and not an `.output`: the three test files gain `assert`s above an
  unchanged `echo`, which is why the suite total does not move.
- **Process-wide state.** `refObjOwners` is a field of `SemContext`
  (`semdata.nim:173`), owned per module by `semmain.ModuleState`; it is not a
  global `var`, so `resetFrontendGlobals` (`semmain.nim:762`) needs no
  addition. It is no new hazard for A2c's `FrontendSnapshot` either: like
  `c.locals` and `c.globals` it is SymId-keyed state that lives and dies with
  its `SemContext`.

**Was anything of ours made redundant?** No. This commit is about which TYPE a
constructor yields; F1/F2 are about how a symbol is SPELLED and A2* about
which process a phase runs in. No overlap.

**Was anything of ours broken?** No. Nothing had to be restored.

**Evidence.** Worktree `/tmp/merge-u1`, branch `merge/u2`, with
`XDG_CACHE_HOME=/tmp/cache-u1` and
`NIMONY_NATIVENIF=/Users/chanc/Projects/nativenif`;
`/Users/chanc/Projects/nativenif` still at `5f6f011e` on `jit/b3e-native`
(`build all` printed no `[deps]` warning, i.e. `syncNativenif` returned on
`head == pin`), `src/nativenif.commit` untouched by the merge.

```
$ nim c -r src/hastur/hastur build all                    → exit 0

$ bin/hastur test tests/incremental
incremental-live (--spawn:always): 5 / 5 phases successful in 1.51s.
decl-stability: .s.nif 32 decls | in-place changed 1 | insert changed 11 (blind 1, added 2) | stmtadd changed 12 (blind 1) | decls digest 52 syms, sem-input changed 1/0/1/1 | lowering-output changed 1/-/1/1 | .x.nif in-place changed 1
decl-stability: 4 / 4 phases successful in 0.86s.
SUCCESS.

$ bin/hastur tests/inproc            → 3 / 3 tests successful in 27.37s. SUCCESS.
$ bin/hastur test tests/ctfe_diff    → ctfediff: 19 file(s), 50 artifact(s), 79 .s.nif, 0 difference(s)
$ bin/hastur test tests/nifcache     → nifcache: all checks passed
$ bin/hastur test tests/nimony_r     → nimony_r: all checks passed
$ bin/hastur test tests/ctfe_engine  → ctfe_engine: all checks passed
$ bin/hastur test tests/ledger       → [ledger] all ledger tests passed

$ bin/hastur tests/nimony
795 / 795 tests successful in 141.44s.
SUCCESS.

$ bin/hastur boot --boot-backend:native
[boot] stages 0 and 1 differ.
[boot] stages 1 and 2 are byte-identical.
[boot] stages 2 and 3 are byte-identical.
[boot] total 48.22s.
SUCCESS.
```

**795 -> 795 is the correct count, not a missed test.** The chain plan expected
three new test files; they are not new. `git status` after the merge shows
`tests/nimony/object/{tsumtype,tsumtype_generic,tsumtype_import}.nim` as `M`,
not `A` — upstream appended assertions to three tests that existed at the fork
point, and their `.output` goldens are unchanged. All six `tsumtype*` tests
pass (log lines 3428-3433, 3439-3440). Nothing was skipped.

**Numbers.** None taken, deliberately. The commit changes which type a sum
type constructor produces; it touches no lookup, lowering or scheduling path,
and `decl-stability`'s digest counts are unchanged, so there is nothing to
suggest the loop moved. Step 1's ratio measurement stands.
