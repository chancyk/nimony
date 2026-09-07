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
| 3 | `b7c7daa6` | newest nativenif (#2478) — pin `d0781a48` -> `e201a816` | `merge/u3` | merged, pin taken is **`3ec73fef`**, not upstream's `e201a816` (see §3) |
| 4 | `c6be04e1` | no globals in nifcore (#2482) | `merge/u4` | merged; A2a's two `nifcore.fallback*` re-points are now **redundant and deleted** (see §4) |
| 5 | `38f67463` | std/http: thread the tag space instead of keeping one per process (#2484) | `merge/u5` | pending |
| 6 | `e1da48e9` | nifsyms refactor (#2483) — pin `e201a816` -> `f9af5b24` | `merge/u6` | pending; `f9af5b24` does not exist in `nim-lang/nativenif` (it is `2c30a9ef` rebased away), so step 6 pins **`83ced299`** (`jit/upstream-master`) |

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

## 3. `b7c7daa6` — newest nativenif

**What upstream changed.** One line: `src/nativenif.commit`, `d0781a48
2026-09-05` -> `e201a816 2026-09-06`, i.e. four new nativenif commits.

**How it collided with us.** The only conflict in the chain so far, and an
unavoidable one: the pin is a single line and both sides rewrote it. Ours read
`5f6f011e 2026-09-07` (B3e's tip of the `jit/b1 .. jit/b3e-native` chain,
which forked from `d0781a48`); upstream's reads `e201a816 2026-09-06`.

```
<<<<<<< HEAD
5f6f011e2885bd88d9bd75244937a22432aa38a9 2026-09-07
=======
e201a8161f803defe128fa783c52fcda27b83ebe 2026-09-06
>>>>>>> b7c7daa6
```

**What we did.** Resolved to **neither side**: the file now reads

```
3ec73fef7bcf335f1077d0de67c574ddbd7e71ac 2026-09-07
```

`3ec73fef` is the tip of `jit/upstream-e201a816` in
`/Users/chanc/Projects/nativenif` — our entire 32-commit B1 -> B3e chain
replayed onto upstream's `e201a816` by the parallel nativenif agent (its
write-up is the "nativenif track" section at the end of this file). Taking
either side of the conflict would have been wrong in a way a green test run
would not have caught:

- upstream's `e201a816` is upstream's chain WITHOUT ours, so `bin/arkham` and
  `bin/nifasm` would lose B1 (nativenif as a library), B3/B3c (the blob cache
  and `declhead`), B3d (per-declaration asm digests) and B3e (the splice) —
  the compiler would still build and still pass, three times slower on the
  edit loop, with no test naming the loss;
- our `5f6f011e` does not contain upstream's four new commits, which is the
  entire content of this bump.

Verified as ancestry, not by reading the branch name: `git merge-base
--is-ancestor e201a816 3ec73fef` and `... d0781a48 3ec73fef` both succeed,
`git rev-list --count e201a816..3ec73fef` is `32`, and `5f6f011e` is NOT an
ancestor of `3ec73fef` (it was rebased, not merged, which is why the old pin
disappears rather than being reachable).

The format is byte-checked against the previous pin: 40 hex, one space,
`YYYY-MM-DD`, one `\n` (`od -c` on both).

**Was anything of ours made redundant?** No. The rebase preserved all 32
commits; nothing was dropped as redundant against upstream's four.

**Was anything of ours broken?** Not on this pin. The nativenif agent reports
that four of 2592 fixtures failed during the rebase and were fixed in
nativenif `82ca1f38` — but that fix is on `jit/upstream-master` and is
deliberately NOT on `3ec73fef`, because it is not needed there: the cause is
the nifsyms refactor turning on split-symbol mode on a module's SHARED reader,
so a module read once through `getDecl` left its reader split and B3c's
hand-copied `readDeclHead` walked out of a tree it had already opened. That
refactor is not in `e201a816`. **It is waiting at step 6**, and step 6 is
where the compensating fix arrives with it.

**Evidence.** Worktree `/tmp/merge-u1`, branch `merge/u3`,
`XDG_CACHE_HOME=/tmp/cache-u1`,
`NIMONY_NATIVENIF=/Users/chanc/Projects/nativenif`. The sibling checkout was
put on the new pin by hand — `git switch jit/upstream-e201a816`, a local
branch whose tip IS `3ec73fef`, so `syncNativenif` returns on `head == pin`
and `build all` prints no `[deps]` line. That was necessary, not incidental:
`syncNativenif` refuses to check a pin out over a checkout that sits on a
BRANCH (it warns and builds what is there), so leaving it on `jit/b3e-native`
would have silently built the OLD assembler under the NEW pin. Nothing was
pushed and no remote was added, in either repository.

```
$ nim c -r src/hastur/hastur build all                    → exit 0, no [deps] warning

$ bin/hastur test tests/incremental
incremental-live (--spawn:always): 5 / 5 phases successful in 1.49s.
decl-stability: .s.nif 32 decls | in-place changed 1 | insert changed 11 (blind 1, added 2) | stmtadd changed 12 (blind 1) | decls digest 52 syms, sem-input changed 1/0/1/1 | lowering-output changed 1/-/1/1 | .x.nif in-place changed 1
decl-stability: 4 / 4 phases successful in 0.87s.
SUCCESS.

$ bin/hastur tests/inproc            → 3 / 3 tests successful in 27.72s. SUCCESS.
$ bin/hastur test tests/ctfe_diff    → ctfediff: 19 file(s), 50 artifact(s), 79 .s.nif, 0 difference(s)
$ bin/hastur test tests/nifcache     → nifcache: all checks passed
$ bin/hastur test tests/nimony_r     → nimony_r: all checks passed
                                       (incl. "a cached link and a scratch link produce byte-identical
                                        executables" and "the compiler itself runs from memory")
$ bin/hastur test tests/ctfe_engine  → ctfe_engine: all checks passed
$ bin/hastur test tests/ledger       → [ledger] all ledger tests passed

$ bin/hastur tests/nimony
795 / 795 tests successful in 142.41s.
SUCCESS.

$ bin/hastur boot --boot-backend:native
[boot] stages 0 and 1 differ.
[boot] stages 1 and 2 are byte-identical.
[boot] stages 2 and 3 are byte-identical.
[boot] total 48.34s.
SUCCESS.
```

The splice counts, which are what says the new assembler still lowers per
proc. The fork-point sources in `/tmp/u3-self/src`, built cold, then
`devloop_bench.sh`'s `self.editbody` edit (`if isNewScope: discard 1` into
`semStmt`) and rebuilt with `ARKHAM_CACHE_STATS=1`:

```
[arkham cache] spliced 8 lowered 1 stale 1        <- the main module
[arkham cache] spliced 76 lowered 2 stale 2       <- the largest neighbour
[arkham cache] spliced 523 lowered 3 stale 3      <- sem.nim
0.85s user 0.10s system 101% cpu 0.935 total
```

Identical to `bench/results/2026-09-07/b3e.txt`'s record, line for line —
1, 2 and 3 procs re-lowered, 523 of `sem.nim`'s 526 spliced.

**Numbers.** Taken, because a new assembler is exactly the kind of change that
moves the loop:

```
$ bench/devloop_ab.sh /tmp/devloop_base . self.editbody 5
self.editbody: A wall median 2.276  min 2.252 | cpu median 3.533  min 3.516 | peak rss 117 MB
self.editbody: B wall median 0.904  min 0.894 | cpu median 0.921  min 0.912 | peak rss 107 MB
B/A cpu (median): 0.261   B/A cpu (min): 0.259   B/A peak rss: 0.91
```

cpu-sum first: B 0.921 s against the recorded 0.94, A 3.533 against the
recorded 3.56 — both sides land on their logged values, so the machine was
quiet for this run and these are absolute numbers, not just a ratio. The new
assembler did not move the loop; if anything it is a hair faster. This also
settles the caveat in §1: that run's inflated absolutes (A cpu 5.18, B 1.23)
were machine load, exactly as recorded there, and the headline **0.92 s wall /
0.94 s cpu stands and needs no re-taking**.


## 4. `c6be04e1` — no globals in nifcore

**What upstream changed.** `nifcore` stops having mutable module-level state.
Its two globals, `fallbackPool`/`fallbackTags` — the pool world a `TokenBuf`
built with no pools of its own fell back to — now exist only under
`-d:nimonyPlugin`, the define `semos.pluginCompileCmd` puts on a plugin
sub-compile and on nothing else; `src/nimony/lib/plugins.nim` installs them
there, from its own `pluginPool`/`pluginTags`, and a plugin is a separately
spawned executable. In every other build a buffer's pools are **threaded in at
construction**: `ensurePools` (which invented a private pool for a buffer that
had none) becomes `requirePools` (which asserts), `default(TokenBuf)` stops
being a usable buffer and the new `initTokenBuf` — bound to the pools, no
storage — replaces it at ~40 construction sites, and `readonlyCursorAt` mints
a `CursorOwner` on demand so a cursor is never ownerless. Note what it does
NOT touch: `nifpools.pool` and `nifpools.globalTags` keep their declarations
and their process lifetimes byte for byte. The title is "no globals in
**nifcore**", not "no globals".

**How it collided with us.** Two textual conflicts, both in hexer, both F2
(`705addc8`, `passes.TempNamer`) sitting on the same object-constructor line
upstream was inserting a pool-bound field into:

| file | upstream | fast-devloop | our phase |
|---|---|---|---|
| `src/hexer/duplifier.nim` | `MoverContext(bits:)` → `MoverContext(cf: initTokenBuf(), bits:)` in `injectDups` | `swap(c.namer, pass.namer)` on the line immediately after that constructor | F2 |
| `src/hexer/lambdalifting.nim` | `Context(counter: 0, …)` → `Context(counter: 0, dest: initTokenBuf(), …)` in `elimLambdas` | F2 **deleted** `Context.counter`, so our version of that literal has no `counter` field | F2 |

The other 16 shared files auto-merged, in the pattern of steps 1-3: upstream's
edits are mechanical (`default(TokenBuf)` → `initTokenBuf()`, `Target(m: …)` →
a new `initTarget(m)`) and ours are elsewhere in the same files — F1's
`c.localNs`, F1 follow-ups' `asNimSym` diagnostics and per-declaration `err`/
`cf` counters, F2's `TempNamer`, A2a-front's `SemOutputs`/`resetFrontendGlobals`,
A2a-hexer's `ExpandInput`/`ExpandResult`, A2c's `baseDir`, A1b's VFS relays.
The closest near-miss is `sem.semExprSym`'s `NoSym` arm, where upstream's
`readonlyCursorAt` → `cursorAt` sits one line above our `asNimSym(s.name)`;
checked by hand after the merge, both are present.

**And one collision that is not in the 22 files at all.** `resetPools`
(`nifpools.nim`, A2a-front `8b593d26`) and `restoreFrontendState`
(`semos.nim`, A2c `eb896a80`) both assign `nifcore.fallbackPool`/`fallbackTags`.
`semos.nim` is not in upstream's commit and would never appear in a
file-by-file review of it, yet after the merge both procs name symbols that do
not exist in the build they are compiled into. That is a hard compile error,
which is the good case: the branch could not have shipped this silently.

**What we did.**

* `duplifier.nim` — upstream's `MoverContext(cf: initTokenBuf(), bits: pass.bits)`
  won the constructor; our `swap(c.namer, pass.namer)` was re-applied after it.
  The two edits are independent (`MoverContext.cf` vs `Context.namer`).
* `lambdalifting.nim` — upstream's `dest: initTokenBuf()` won; upstream's
  `counter: 0` was dropped, because the field it names no longer exists on our
  side. Nothing of ours was given up: F2 replaced that counter with `namer`.
* `nifpools.resetPools` — the two `nifcore.fallback* =` lines **deleted**, with
  the doc comment rewritten to say why the remaining two assignments are the
  whole reset (below).
* `semos.restoreFrontendState` — the same two lines deleted; `FrontendSnapshot`'s
  doc comment now states that the buffer's own captured `Pool`/`TagPool` is the
  ONLY route to a pool world, so its three fields are the complete state to move.
* `semmain.resetFrontendGlobals`, `hexer.resetHexerGlobals`,
  `lengc.resetLengcGlobals` — doc-comment inventories corrected; they each
  listed the two fallbacks as part of the state they reset.
* `semmain`'s `SemOutputs(ok: false)` — its two `TokenBuf` fields are now
  `initTokenBuf()`. Nothing writes through them (callers check `ok`), but it is
  exactly the shape upstream just outlawed and no `SemOutputs` should leave
  that module in it.

Then the check of steps 1-3, `diff -u <(git show c6be04e1:<path>) <path>` for
all 22 files. `nifcore.nim`, `lifter.nim`, `indexgen.nim` and
`semvalidator.nim` come back **empty** — we do not touch them and upstream's
version stands whole. The other 18 differ by exactly our hunks and nothing
else, each traceable to a named phase: F1 `73f605d3` (`c.localNs` in `sem`,
`semdecls`, `plugins`), F1 follow-ups `45180a3d` (`asNimSym` in `sem`,
`semcall`, `sigmatch`, `contracts`, `contracts_fir`, `renderer`) and `8328879a`
(`freshCfSym`/`freshErrSym` in `controlflow`, `derefs`), F2 `705addc8`
(`TempNamer` in `xelim`, `coro_transform`, `duplifier`, `lambdalifting`,
`lengcgen`), A2a-front `8b593d26`/`1fa5f4e9` (`nifpools`, `programs`,
`semmain`), A2a-hexer `30a363df`/`4370cb8f` and B3 `117c9cd6`/`a9d0b7e4`
(`lengcgen`), A2c `eb896a80` (`semdecls`), A1b `f2e7189b` (`programs`).

**Was anything of ours made redundant?** **Yes — this is the entry's real
content, and `notes/handoff.md`'s hypothesis is now settled.** It guessed that
this commit "may make parts of `resetPools`/`resetFrontendGlobals` redundant".
It does, and precisely: **two of `resetPools`'s four assignments, and two of
`restoreFrontendState`'s five.** Nothing else. Per moved global:

| global | did our reset depend on it? | does the state's new owner span two in-process runs? | verdict |
|---|---|---|---|
| `nifcore.fallbackPool` | yes, at `nifpools.nim:98` (`resetPools`) and `semos.nim:117` (`restoreFrontendState`) | **no.** The state did not move to a new owner — in the compiler build it was compiled out. Under `-d:nimonyPlugin` its owner is `plugins.pluginPool`, a `let` in an executable `semos.execPlugin` **spawns**; no nimony process ever holds it | **redundant**, and deleted here — not as a tidy-up but because it no longer compiles |
| `nifcore.fallbackTags` | same two sites | same | same |
| `nifpools.pool` | yes | yes, still a process-lifetime `var` | **untouched by upstream; still required** |
| `nifpools.globalTags` | yes | yes | **untouched by upstream; still required** |
| `programs.prog` | yes (`resetProgram`) | yes | **still required**; upstream's only edit here is `ToplevelEntries.del`'s `default(TokenBuf)` |

Why that is "redundant" and not "silently insufficient", which is the answer
this step existed to produce. For a second in-process run to inherit something,
state would have to have moved from a global we reset into an object with a
longer life that nothing resets. **No such object exists here**: upstream
deleted the fallback rather than relocating it, and replaced the indirection
with eager binding. `createTokenBuf`/`initTokenBuf` read `nifpools.pool` and
`globalTags` *at the moment they are called*, so a buffer minted after
`resetPools` is bound to the fresh pools with nothing left to re-point, and one
minted before it stays bound to the old ones — the same guarantee the fallback
gave, arrived at eagerly. The three ways it could still have bitten, and why
none does:

1. *A buffer that outlives a run and now holds a stale pool.* The only buffers
   that survive a reset in this repo hang off `programs.prog`
   (`ToplevelEntry.buffer`), and `resetProgram` discards `prog` in the same
   breath — the two procs are called as a pair at all four call sites and each
   one's doc comment forbids calling one without the other. `notes/a2a-front.md`
   §3's sweep of every process-global `var` is still the complete list and
   still holds.
2. *A buffer minted with no pool at all.* It used to pick up the fallback
   silently; it now trips `requirePools`'s assert at the first interning add.
   That is loud, in every build hastur produces (`nim c -d:release` keeps
   `assert`; nothing here uses `-d:danger`), and it is the opposite of a silent
   inheritance. Our own construction sites were audited against it —
   `ExpandInput(buf: createTokenBuf(0))`, `ExpandResult(x: createTokenBuf(0))`,
   the buffer-level `expand`'s `EContext` (which took upstream's added
   `initBody: initTokenBuf()`), and `SemOutputs`, fixed above. The nine files
   the branch adds outright (`hexerio`, `phases`, `engine`, `dag`,
   `artifactstore`, `ledger`, `decldigest`, `toolhash`, `ctfediff`) contain no
   `TokenBuf` object field at all.
3. *A2c's snapshot.* `restoreFrontendState` put the fallbacks back so that
   nil-pool buffers would decode against the parent's pool again. With eager
   binding the parent's buffers hold the parent's `Pool` ref directly —
   `FrontendSnapshot`'s own doc comment already said so — so restoring `pool`,
   `globalTags` and `prog` is the whole restore. The snapshot gets *stronger*:
   there is no longer a second, implicit pointer into the pool world that an
   early return could leave dangling.

Follow-up, named: **none is outstanding.** The redundancy was not deferred, it
was deleted in this commit, because leaving it was not an option the compiler
would accept. What is left behind is documentation: five doc comments across
`nifpools`, `semos`, `semmain`, `hexer` and `lengc` that described the
pool-plus-fallback model were rewritten here rather than left to rot.

**Was anything of ours broken?** No. Nothing had to be restored by other means:
`tests/inproc` — the test that *is* the correctness premise for A2a/A2c —
reports every artifact of every tool byte-identical between N in-process runs
and N processes, and `decl-stability` reports the same four phases and the same
digest counts as `merge/u1`, `u2` and `u3`.

**Evidence.** Worktree `/tmp/merge-u4`, branch `merge/u4`, with
`XDG_CACHE_HOME=/tmp/cache-u4` and
`NIMONY_NATIVENIF=/Users/chanc/Projects/nativenif`.
`/Users/chanc/Projects/nativenif` left where step 3 put it — `3ec73fef` on
`jit/upstream-e201a816` — and `src/nativenif.commit` is not in this commit and
did not move (still `3ec73fef… 2026-09-07`). `build all` printed **no `[deps]`
line**, which per §3 is the evidence that the pin was honoured rather than
built over.

```
$ nim c -r src/hastur/hastur build all
… out: /private/tmp/merge-u4/bin/nifasm [SuccessX]     → exit 0, no [deps], 0 errors

$ bin/hastur tests/inproc                        ← this commit's gate
  ok: nifler: 4 output files byte-identical to two processes
  ok: nimsem: 6 output files byte-identical to two processes
[inproc/hexer] ok: hexer c: zzafpditq1.x.nif (2406 bytes)      … 9 checks
[inproc/hexer] all checks passed
[inproc/lengc] all in-process lengc tests passed
3 / 3 tests successful in 24.09s.
SUCCESS.

$ bin/hastur test tests/incremental
incremental: 16 / 16 phases successful in 8.47s.
incremental (--vfs:memory+spill): 16 / 16 phases successful in 6.78s.
incremental (--spawn:always): 16 / 16 phases successful in 7.31s.
inproc: 4 / 4 phases successful in 2.34s.
membudget: 5 / 5 phases successful in 2.96s.
incremental-live (--spawn:always): 5 / 5 phases successful in 1.52s.
decl-stability: .s.nif 32 decls | in-place changed 1 | insert changed 11 (blind 1, added 2) | stmtadd changed 12 (blind 1) | decls digest 52 syms, sem-input changed 1/0/1/1 | lowering-output changed 1/-/1/1 | .x.nif in-place changed 1
decl-stability: 4 / 4 phases successful in 0.91s.
SUCCESS.

$ bin/hastur test tests/ctfe_diff
ctfediff: 19 file(s), 50 artifact(s), 79 .s.nif, 0 difference(s)
ctfe_diff: all checks passed

$ bin/hastur test tests/nifcache
  ok: both modes left the same 343 .nif artifacts, byte for byte
  ok: both modes left the same 106 .nif artifacts, byte for byte
nifcache: all checks passed

$ bin/hastur test tests/nimony_r
  ok   a cached link and a scratch link produce byte-identical executables
  ok   the compiler itself runs from memory (--version -> 0.6.0)
nimony_r: all checks passed

$ bin/hastur test tests/ctfe_engine
  4 sub-program(s), 5 sub-build(s) in-process (the `std/writenif` precompile included), 0 spawned
  28 non-main `.c.nif` file(s) byte-identical to `NIMONY_CCACHE=off`
ctfe_engine: all checks passed

$ bin/hastur test tests/ledger
[ledger] all ledger tests passed

$ bin/hastur tests/nimony
795 / 795 tests successful in 143.12s.
SUCCESS.

$ bin/hastur boot --boot-backend:native
[boot] stages 0 and 1 differ.
[boot] stages 1 and 2 are byte-identical.
[boot] stages 2 and 3 are byte-identical.
[boot] total 46.72s.
SUCCESS.
```

**795 → 795 is the correct count.** `git show c6be04e1 --stat` lists 22 files,
none of them under `tests/`: this commit adds, removes and changes no test.
Nothing was skipped.

**Numbers.** Taken, because the commit changes how every `TokenBuf` in the
compiler is constructed and makes `readonlyCursorAt` allocate a `CursorOwner`
header where it used to return an ownerless cursor — 90 call sites outside
`nifcore` — so the pools' representation could plausibly have moved the loop.

```
$ bench/devloop_ab.sh /tmp/devloop_base . self.editbody 5
self.editbody: A wall median 2.601  min 2.595 | cpu median 3.816  min 3.801 | peak rss 117 MB
self.editbody: B wall median 0.971  min 0.966 | cpu median 0.992  min 0.988 | peak rss 107 MB
B/A cpu (median): 0.260   B/A cpu (min): 0.260   B/A peak rss: 0.91

$ bench/devloop_ab.sh /tmp/devloop_base . self.editbody 5     # repeat, load avg 5.02
self.editbody: A wall median 2.604 | cpu median 3.814 | peak rss 117 MB
self.editbody: B wall median 0.974 | cpu median 0.995 | peak rss 107 MB
B/A cpu (median): 0.261   B/A cpu (min): 0.259   B/A peak rss: 0.91
```

cpu-sum first, per `BENCHMARK.md` §0: **B/A cpu 0.260 and 0.261**, against
step 3's 0.261 on a quiet machine — the ratio is unchanged and reproduces
across two runs. Both absolute sides are ~8 % above their logged values (A cpu
3.81 vs 3.53, B cpu 0.99 vs 0.92) by nearly the same factor, which is the
signature of machine load and not of a one-sided regression; `uptime` reported
a load average of 5.02 during the second run, with another agent's worktree
building. The headline 0.92 s cpu stands as step 3 re-took it; the loop did
not move.

## nativenif track

Two of upstream's six commits are `src/nativenif.commit` bumps, and neither can
land until our nativenif branch chain sits on top of upstream's new nativenif
master. This section is that rebase. Nothing in it was committed to this repo;
the work is in `/Users/chanc/Projects/nativenif` on two new branches.

**The two pins this merge needs**

| nimony step | commit | pins | take instead |
|---|---|---|---|
| 3 | `b7c7daa6` "newest nativenif" (#2478) | `d0781a48` → `e201a816` | `jit/upstream-e201a816` = **`3ec73fef`** |
| 6 | `e1da48e9` "nifsyms refactor" (#2483) | `e201a816` → `f9af5b24` | `jit/upstream-master` = **`83ced299`** |

Both branches exist in the nativenif checkout and are unpushed. The main
checkout is back on `jit/b3e-native` where it was found.

### Our chain as it was

32 commits, linear, from the merge-base `d0781a48` to `jit/b3e-native`
(`5f6f011e`): `jit/b1` 13, `jit/b2-fix` 1, `jit/b3` 7, `jit/b3-fixes` 0 (it
points at the same commit as `jit/b3`; `notes/handoff.md` lists it as a seventh
segment, but it carries nothing of its own), `jit/b3c` 4, `jit/b3d-native` 2,
`jit/b3e-native` 5. 114 files, +7354/-464.

### Upstream's drift is four commits, not three

`b6cb8d0e` "ithaqua: a C-linkage gvar pair must share one linear-memory slot"
(#162) sits below `3061c29b` and was jumped over by nimony's own pin, which is
why the handoff names only three. In order:

* `b6cb8d0e` — wasm32 only, one linear-memory slot per C-linkage gvar pair.
  Does not touch arkham or nifasm.
* `3061c29b` — "better death point analysis" (#163). A local whose last use is
  inside a call's argument list may keep a volatile register: new
  `DiesAtCall`/`RetRegOk` properties. Changes emitted machine code on every
  native target.
* `e201a816` — the bug #163 left behind: `releaseStaleName(RAX)` was missing on
  the FLOAT call path. One line plus a fixture.
* `2c30a9ef` — "the role goes in the identifier" (#165). Two things: the
  syscall/extern wrapper asm names become `` write`sys.0.<mod> `` /
  `` write`c.0.<mod> ``, and `pool.syms[id]` / `pool.syms.getOrIncl` become
  `symString` / `symId` throughout arkham and nifasm.

### `f9af5b24` is `2c30a9ef`

`f9af5b24` is genuinely not in the nativenif object database — not as an object
(`git cat-file --batch-all-objects` over all 29,583 objects has no such
prefix), not on any ref, not in any reflog. The evidence that `2c30a9ef` is what
it became is mechanical, not circumstantial:

1. **Only `2c30a9ef` can satisfy a pin set by `e1da48e9`.** `e1da48e9` is the
   commit that *introduces* `symString` (`src/lib/nifcore.nim`, +380 lines).
   `2c30a9ef` is the only nativenif commit in existence that *calls* it — and
   it does not merely call it, it requires it. Upstream nativenif master will
   not build against a pre-refactor nimony at all:

       src/arkham/core/programs.nim(897, 14) Error: undeclared identifier: 'symString'

   A pin set by `e1da48e9` must name a nativenif commit that needs
   post-refactor nimony. No other commit in the repository does.
2. **`2c30a9ef` says so.** `core/typeutil.nim`'s new comment: "`symString`
   builds the spelling from the pool's taken-apart form (nimony#2457)".
3. **Timing and shape.** `e1da48e9` is authored 2026-09-07 23:36:55 +0200,
   `2c30a9ef` 23:42:40 +0200 — six minutes apart, same author, single-parented
   onto `e201a816` (exactly where `f9af5b24` had to sit), committer
   `GitHub <noreply@github.com>` with `AuthorDate == CommitDate`: the signature
   of a squash- or rebase-merge minting a new object for content that already
   existed on a PR branch.

`f9af5b24` was the pre-merge tip of nativenif PR #165, pinned by nimony while
both PRs were in flight; GitHub rewrote it into `2c30a9ef` on merge and the PR
branch went away before this mirror fetched it. This also fixes the order of
the two pins: `e201a816` builds against nimony either side of the refactor,
`2c30a9ef` only after it — so step 3's pin and step 6's pin must land with
their nimony halves and not before.

### `2c30a9ef` does not collide with B3d/B3e

This was expected to be the hard one, since B3d/B3e name labels and temps per
proc so an unchanged proc assembles byte-identically. It is not the same
ground. `2c30a9ef` renames **C-linkage wrapper symbols** — the asm name of a
syscall syproc and of a libc extproc, in `core/programs.nim`. B3d's `7b838ec3`
renames `` `L<n> ``, `` `aggtmp<n> `` and `` `nctmp<n> `` — arkham-minted
per-proc labels and constructor temps, in `avr/gen.nim`, `core/context.nim`,
`risc/{driver,value}.nim` and `x64/{driver,mem,value}.nim`, none of which
`2c30a9ef` opens. **Nothing of ours became redundant against it, and nothing of
ours had to move.**

### Conflicts

`git rebase` raised **none**. `git range-diff` reports all 32 commits replayed
identically onto `e201a816`, and identically again onto `2c30a9ef`. That is
also the trap: the one real conflict is semantic and git could not see it.

**`core/declhead.nim` (B3c, `ff8e7404`) against the nifsyms refactor.**
`declhead.nim` is a hand copy of `nifcoreparse.parse`'s token dispatch with one
extra rule, so a `(proc …)` head is read without its body. The refactor changed
what `parse` dispatches over: in the reader's new split-symbol mode a `Symbol`
token carries only `<name>` and one `ExtendedSuffix` follows per remaining
component. `parse` turns that mode on for every read it does, and the mode
belongs to the module's **shared** reader — so a module read once through
`getDecl` leaves its reader split, and the next head parse on it meets a token
the copied loop has no case for, breaks out of a tree it has already opened,
and hands `beginRead` a buffer with unclosed tags:

```
nifasm/{x64,arm64,linux_arm64,cortex_m}/const_rodata_reloc_foreign
  EXIT:1  `b.openTags.len == 0` beginRead with unclosed tags
```

Four artifacts of 2592 and three listings that stopped being produced — the
four fixtures that resolve a foreign symbol both ways inside one link. It is
order-dependent, which is why it is four and not all of them.

*Resolution* (upstream's semantics win, ours re-applied): the head is read with
split mode off and the reader is put back as it was found, through the reader's
own exported `splitSymbols(r, false)`. `parse` consumes the components in
`addSplitSymbol`, which `nifcoreparse` does not export; re-implementing it here
would put a second copy of the pool's interning rules under the same
faithfulness duty the token dispatch already carries. Both paths intern the
same symbol — `addSplitSymbol` rebuilds a spelling itself for three of its five
shapes — and `blobcache_selftest` is what proves it rather than the argument,
since it links every fixture with and without `--whole-decls`, the flag that
chooses between the two readers, and requires one image out of both. **If
nifcoreparse ever exports `addSplitSymbol`, this should become a call to it.**

On `jit/upstream-master` only, as commit `82ca1f38` — the split-symbol mode
does not exist at `e201a816`, so `jit/upstream-e201a816` is a pure replay of
the 32 with nothing added.

### The gate, verbatim

`tools/refactor_gate.sh` was run on five trees, each in its own workspace with
its own sibling `nimony` and its own `XDG_CACHE_HOME`, so that a moved artifact
can be attributed. (nativenif's `nim.cfg` reaches nimony by the relative path
`../../../nimony/src`, so a worktree under `/tmp` needs a `nimony` beside it;
and `2c30a9ef` needs a **post-refactor** nimony, so the two upstream tips could
not share one.)

```
    2583 artifacts,      774 listings -> /tmp/gate/base-d0781a48.sums    (fork point,  nimony fast-devloop 193e1577)
    2583 artifacts,      774 listings -> /tmp/gate/base-5f6f011e.sums    (our old tip, nimony fast-devloop 193e1577)
    2592 artifacts,      777 listings -> /tmp/gate/base-e201a816.sums    (upstream,    nimony fast-devloop 193e1577)
    2592 artifacts,      777 listings -> /tmp/gate/reb-e201a816.sums     (jit/upstream-e201a816)
    2592 artifacts,      777 listings -> /tmp/gate/base-2c30a9ef.sums    (upstream,    nimony e1da48e9)
    2592 artifacts,      777 listings -> /tmp/gate/reb-master2.sums      (jit/upstream-master)
```

Upstream's own deltas, for scale: `d0781a48` → `e201a816` moves **1773**
artifact lines (`3061c29b`'s register allocation, across every target, plus
nine new arm64 fixtures); `e201a816` → `2c30a9ef` moves **2032** artifact lines
and **1386** listing lines (the wrapper renaming, in every asm-NIF that names a
libc extern). Neither is ours.

Ours is the number that had to stay put, and it did — measured the same way on
both sides of the rebase:

```
diff base-d0781a48.sums  base-5f6f011e.sums      137 artifacts, 78 listings   (pre-rebase control)
diff base-e201a816.sums  reb-e201a816.sums       137 artifacts, 78 listings   (jit/upstream-e201a816)
diff base-2c30a9ef.sums  reb-master2.sums        137 artifacts, 78 listings   (jit/upstream-master)
```

and all three name the **same 137 labels**:

```
  53  arkham/cortex_m/*
  30  arkham/x64/*
  27  arkham/linux_arm64/*
  27  arkham/arm64/*
   0  nifasm/*
```

That is B3d's per-proc rename and nothing else, exactly as `notes/b3d.md`
recorded it against the `c3f27fc` baseline: arkham's asm-NIF text and the
listings that render its names move, and **every assembled image is
byte-identical**. The label sets are equal as sets, not just equal in count —
`diff` of the two sorted label lists is empty.

Before the `declhead.nim` fix, `jit/upstream-master` differed in 141 artifacts
and 81 listings: the same 137 plus the four `const_rodata_reloc_foreign` images
and the three listings that vanished with them. After it, 137 and 78.

### The other gates

`nim r tests/tester.nim`, both branches, exit 0, every suite `N / N`. The
byte-identity self-tests, which are the ones that matter here:

```
235 / 235 memory-image byte-identity checks (mach-o) successful
234 / 234 memory-image byte-identity checks (elf) successful
235 / 235 blob-cache byte-identity checks (macho) successful (3 fixtures the assembler refuses)
238 / 238 blob-cache byte-identity checks (elf) successful (2 fixtures the assembler refuses)
 87 /  87 blob-cache byte-identity checks (raw) successful (52 fixtures the assembler refuses)
238 / 238 arkham splice byte-identity checks (arm64) successful (15 fixtures arkham refuses)
240 / 240 arkham splice byte-identity checks (x64) successful (13 fixtures arkham refuses)
130 / 130 arkham splice byte-identity checks (cortex_m) successful (8 fixtures arkham refuses)
 25 /  25 arkham splice byte-identity checks (riscv32) successful (10 fixtures arkham refuses)
 20 /  20 arkham splice byte-identity checks (avr) successful (0 fixtures arkham refuses)
231 / 231 arkham tests successful (0 known-unsupported skipped)
231 / 231 in-memory (nifrun) tests successful (0 known-unsupported skipped)
230 / 230 arkham arm64 stress tests successful (k=3, 1 known-broken)
228 / 228 ithaqua wasm32 emit tests successful (25 refused as expected)
AsmError self-test: all checks passed
hostsyms self-test: all checks passed
foreign-decl bounds self-test: OK
```

(qemu-system-arm, qemu-system-riscv32 and `bin/avrtest` are absent on this
machine, so the cross-target *execution* suites skip loudly, as they did for
B3d and B3e. The emit and rejection halves of those targets do run.)

### Against nimony

A worktree of `fast-devloop` (`193e1577`) under `/tmp`, `NIMONY_NATIVENIF`
pointed at the rebased checkout, `src/nativenif.commit` set to `3ec73fef`,
private `XDG_CACHE_HOME`. `nim c -r src/hastur/hastur build all` succeeds, and:

```
ctfe_engine: all checks passed
nimony_r:    all checks passed
  ok   `nimony n`'s link node replays 112 cached fragment(s)
  ok   `nimony r` warms its own half of the same directory (112 fragments)
  ok   a cached link and a scratch link produce byte-identical executables
  ok   the compiler itself runs from memory (--version -> 0.6.0)
nifcache:    all checks passed
  ok: both modes left the same 343 .nif artifacts, byte for byte
  ok: both modes left the same 106 .nif artifacts, byte for byte

hastur boot --boot-backend:native
  [boot] stages 1 and 2 are byte-identical.
  [boot] stages 2 and 3 are byte-identical.
  [boot] total 86.18s.
  SUCCESS.
```

### Splice ratios: unchanged

The `self.editbody` live edit (a statement into the body of `semStmt`),
`ARKHAM_CACHE_STATS=1`, against `jit/upstream-e201a816`:

```
[arkham cache] spliced  11 lowered 1 stale 1
[arkham cache] spliced  82 lowered 2 stale 2
[arkham cache] spliced 522 lowered 3 stale 3
```

`notes/b3e.md` recorded `8/9`, `76/78` and `523/526`, i.e. **1, 2 and 3**
procs re-lowered. The three totals moved (12, 84, 525 against 9, 78, 526)
because the compiler's own sources have moved since B3e was measured, but the
number that B3e is *about* — how many procs an edit costs — is **1, 2 and 3,
identical**. Upstream's register-allocation change re-lowers no proc it did not
have to.

Not yet measurable for `jit/upstream-master`: the ratio needs a nimony that has
both our arkham-cache wiring and the nifsyms refactor, and that tree only
exists once merge step 6 lands. Worth re-taking then; the mechanism (a
per-proc content digest of the source declaration plus a module-wide context
digest) has nothing in it that `2c30a9ef`'s wrapper renaming can move, but that
is an argument, not a measurement.

### What remains

* **`jit/upstream-master` has not been exercised against a nimony that is both
  post-refactor and ours.** It was gated against upstream nimony `e1da48e9`,
  which is where the `symString` it needs comes from, but `fast-devloop` does
  not have that refactor until step 6 merges it. After step 6, re-run
  `hastur build all`, the four suites, `boot --boot-backend:native` and the
  splice-ratio measurement against pin `83ced299`. The gate (137/78/0) says the
  tools themselves are right; what is untested is the seam.
* **`declhead.nim` should call `addSplitSymbol` once nifcoreparse exports it.**
  The mode switch is correct and gated, but the module's own contract is to be
  a faithful copy of `parse`'s dispatch, and a copy that asks for a different
  reader mode is one step further from that than a copy that calls the same
  helper.
* Nothing is pushed. Both branches are local to
  `/Users/chanc/Projects/nativenif`.
