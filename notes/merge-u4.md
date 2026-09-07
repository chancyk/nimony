# merge/u4 — upstream `c6be04e1` into `fast-devloop`

Step 4 of the six-commit upstream merge chain (`MERGE.md`). Base: `f61c0e58`
(= `merge/u3`, `fast-devloop`'s tip). Merged: `c6be04e1` "no globals in
nifcore (#2482)".

Written before any edit, per `JIT_IMPL.md` "Execution rules for agents" rule 3.
The point of this step is NOT the conflict count (two, both trivial); it is
the semantic question `notes/handoff.md` left open — whether upstream removing
globals from `nifcore` makes A2a's `resetPools`/`resetFrontendGlobals`
redundant, or silently insufficient. §2 answers it per global.

## 1. What upstream `c6be04e1` actually does

22 files, +263/-146. The title is precise and the precision matters: it is
"no globals in **nifcore**", not "no globals". `nifpools.pool` and
`nifpools.globalTags` — the two globals our whole reset story is about — are
**not touched**. What moves is `nifcore`'s two, and how a `TokenBuf` gets its
pools.

### 1.1 The two nifcore globals

| before | after | owner + lifetime | how call sites reach it |
|---|---|---|---|
| `nifcore.nim:445 var fallbackPool*: Pool = nil` | exists **only** `when defined(nimonyPlugin)`; in every other build the symbol does not exist at all. Two new templates stand in: `template defaultPool(): Pool = fallbackPool` under the define, `= nil` otherwise | plugin build only: set once at `src/nimony/lib/plugins.nim` module init from `pluginPool`, a module-level `let`. A plugin is a **separate executable, spawned** (`semos.execPlugin`), so that pool's lifetime is one plugin process | nothing "reaches" it in the compiler build. Every buffer carries its pools from construction (`createTokenBuf` / the new `initTokenBuf`) |
| `nifcore.nim:451 var fallbackTags*: TagPool = nil` | same | same (`pluginTags`) | same |

`-d:nimonyPlugin` is set by `semos.pluginCompileCmd` for a plugin sub-compile
and by nothing else. So after this commit the compiler's own nifcore has **no
mutable module-level state at all**.

### 1.2 The two nifpools globals: unchanged

`nifpools.nim:65 var globalTags*` and `nifpools.nim:76 var pool*` keep their
declarations, their types and their lifetimes byte for byte. The only line
`c6be04e1` removes from `nifpools.nim` is the two-line bridge that used to
publish them into nifcore:

```nim
var pool*: Pool = newPool()
-nifcore.fallbackPool = pool
-nifcore.fallbackTags = globalTags
```

and the only line it adds is a wrapper for the new constructor:

```nim
proc initTokenBuf*(): TokenBuf {.inline.} = nifcore.initTokenBuf(pool, globalTags)
```

### 1.3 The mechanism: eager binding instead of a fallback

* `ensurePools*(b)` → `requirePools*(b)`. The old one **invented** a private
  `newPool()`/`newTagPool()` for a buffer that had none; the new one asserts
  `b.pool != nil` / `b.tags != nil` and (only under the plugin define) binds
  the process defaults first.
* New `nifcore.initTokenBuf*(sharedPool, sharedTags)`: a `TokenBuf` with no
  storage (`data: nil, len: 0, cap: 0`) but both pools bound. This is the
  replacement for `default(TokenBuf)`, which is now "not a usable buffer".
* `strVal`/`strId`/`symName`/`symId` on a bare `Cursor`, `escapeTagOf`,
  `sharesPools`, `addBufferSamePool` all lose their fallback and assert
  instead (non-plugin build).
* `readonlyCursorAt` no longer returns an **ownerless** cursor: it mints the
  `CursorOwner` header on demand through a cast, so the cursor always carries
  the buffer's pools. Two call sites that were only using it to dodge `var`
  switch back to `cursorAt` (`sem.semExprSym`, `semcall.resolveOverloads`).

Everything else in the commit is the mechanical consequence: ~40 object
constructions across `hexer/`, `nimony/` and `validator/` gain an explicit
`field: initTokenBuf()` for every `TokenBuf` field that used to be left at its
zero value, and `xelim`/`controlflow` each gain a local
`proc initTarget(m: Mode): Target = Target(m: m, t: initTokenBuf())` because
their `Target(m: …)` literals are everywhere.

One drive-by that is not about pools at all: `renderer.gpragmas` now renders a
pragma's second and later arguments comma-separated instead of dropping them.

### 1.4 New globals introduced

**None.** `fallbackPool`/`fallbackTags` are re-scoped, not created; every other
addition is a local `var` inside a proc, a `template`, or a `proc`. So
`JIT_IMPL.md` execution rule 5 ("no new global `var`s") is not strained by
taking upstream's side anywhere here.

## 2. The question that matters: our reset paths against §1

Our machinery, from `notes/a2a-front.md` §3 and re-verified in this tree:

```
semmain.resetFrontendGlobals()   semmain.nim:762
  -> nifpools.resetPools()       nifpools.nim:80    pool, globalTags, + the two fallbacks
  -> programs.resetProgram()     programs.nim:76    prog
  -> identstyle.resetStyleTables()                  styleGroups, styleHighWaterMark, pragmaStyleIndex
  -> filelinecache.resetFileLineCache()             gFileLineCache
hexer.resetHexerGlobals()        hexer.nim:102      resetProgram + resetPools + resetInlinerStats
lengc.resetLengcGlobals()        lengc.nim:73       documented no-op
semos.takeFrontendState()        semos.nim:107      saves pool/globalTags/prog, then resets all three + style
semos.restoreFrontendState()     semos.nim:114      restores them, re-points the two fallbacks, drops style
```

Verdict per global that upstream moved:

| global | did our reset depend on it? | does the new owner span two in-process runs? | verdict |
|---|---|---|---|
| `nifcore.fallbackPool` | **yes**, twice: `resetPools` (`nifpools.nim:98`) and `restoreFrontendState` (`semos.nim:117`) assign it | **no.** In the compiler build the symbol is gone — the state did not move to a new owner, it was compiled out. In the plugin build its owner is `plugins.pluginPool`, a `let` in a **separately spawned** executable (`semos.execPlugin`); no nimony process ever holds it | **redundant, and no longer compilable.** Both assignments must be deleted. Nothing replaces them: after `resetPools` sets `pool = newPool()`, every buffer minted from then on binds the fresh pool eagerly through `createTokenBuf`/`initTokenBuf`, which read `nifpools.pool` at the moment of construction |
| `nifcore.fallbackTags` | same two sites | same | same |
| `nifpools.pool` | yes — it is the point of `resetPools` | yes, it is still a process-lifetime `var` | **still required, unchanged.** Upstream does not touch it |
| `nifpools.globalTags` | yes | yes | **still required, unchanged** |
| `programs.prog` | yes (`resetProgram`) | yes | **still required, unchanged.** Not in this commit except a `default(TokenBuf)` → `initTokenBuf()` in `ToplevelEntries.del` |

### 2.1 Why "redundant" and not "insufficient" — the argument, not the assertion

The failure this step was told to fear is a second in-process run inheriting
state that nothing resets. For that to happen here, some state would have to
have moved from a global we reset into an object that outlives a run and that
we do not reset. **No such object exists**, because upstream did not relocate
the state: it *deleted* the fallback in the compiler build and made the
binding eager. The three ways that could still bite, and why none does:

1. **A buffer that outlives a run and holds a stale pool.** Before, a nil-pool
   buffer followed `fallbackPool`, so a `resetPools` implicitly re-pointed it;
   now a buffer's pool is fixed at construction. This is only a change for a
   buffer that survives a reset. Every buffer that survives one in this repo
   is reached through `programs.prog` (`ToplevelEntry.buffer`), and
   `resetProgram()` throws `prog` away in the same breath — `resetPools` and
   `resetProgram` are called as a pair at all four call sites and each one's
   doc comment says never to call one without the other. `foreignmodules` and
   `bif` hold mmap'd data, not pool ids off the reset pool. There is no third
   holder: `notes/a2a-front.md` §3 is the full sweep and it still passes
   (`grep -n '^var' src/nimony/*.nim src/lib/*.nim src/nifler/**/*.nim`).
2. **A buffer minted with no pool at all.** Before, it silently got the
   fallback; now it asserts. This is a *loud* failure at the first interning
   add, on any path a test touches, in every build hastur produces (`nim c
   -d:release` keeps `assert`; only `-d:danger` removes it, and nothing here
   uses it). It is also the opposite of a silent inheritance: two runs cannot
   collide through a buffer that cannot be written to.
3. **A2c's snapshot.** `restoreFrontendState` put the fallbacks back so that
   nil-pool buffers decoded against the parent's pool again. With eager
   binding the parent's buffers already hold the parent's `Pool` ref directly
   (`FrontendSnapshot`'s own doc comment says exactly this: "`nifcore.TokenBuf`
   captures the `Pool`/`TagPool` it was built with"), so restoring `pool` and
   `globalTags` is the whole of the restore. The snapshot gets *stronger*, not
   weaker: there is no longer a second, implicit pointer to the pool world
   that could be left dangling if a code path returned early.

So: **redundant**, recorded here and in `MERGE.md` §4, and the deletion is
forced (it will not compile) rather than optional. There is no follow-up to
delete anything else — see §5.

### 2.2 The real hazard this commit creates for us

It is not in the reset path. It is that upstream audited the ~40
`default(TokenBuf)` / unset-`TokenBuf`-field construction sites **that exist
upstream**, and our branch owns construction sites upstream has never seen.
Audited, all of them:

| ours | site | state |
|---|---|---|
| A2a-hexer | `lengcgen.ExpandInput` | `ExpandInput(buf: createTokenBuf(0), …)` — bound |
| A2a-hexer | `lengcgen.ExpandResult` | `ExpandResult(x: createTokenBuf(0), …)` — bound |
| A2a-hexer | `lengcgen.EContext` in the buffer-level `expand` | ours rewrote this literal; it keeps `pending:`/`strLitBuf: createTokenBuf()` and takes upstream's added `initBody: initTokenBuf()` |
| A2a-front | `semmain.SemOutputs` | `SemOutputs(ok: true)` immediately assigns `code`/`deps`; `SemOutputs(ok: false)` leaves both at `default` — no caller writes to them (they check `ok`), but it is exactly the shape upstream just outlawed, so it is spelled `initTokenBuf()` here too |
| A2a-hexer, A2b, B1/B2 | `hexerio.nim`, `phases.nim`, `engine.nim`, `dag.nim`, `artifactstore.nim`, `ledger.nim`, `decldigest.nim` | every buffer is `createTokenBuf(…)` or a `var TokenBuf` parameter; no object field of type `TokenBuf` anywhere in the nine files the branch adds |
| F2 | `xelim.Context`, `lambdalifting.Context` | see §3 |

## 3. Collision map — the 18 shared files

18 of the 22 files are touched by both sides. Only two conflict.

| file | upstream's change | ours | our phase / commit |
|---|---|---|---|
| `src/lib/nifcore.nim` | the whole subject (§1) | **untouched by us** | — |
| `src/lib/nifpools.nim` | deletes the 2-line fallback bridge; adds `initTokenBuf()` | `resetPools`, `renderModule`/`writeRendered` split (+33/-3) | A2a-front `8b593d26` |
| `src/nimony/programs.nim` | `del`: `default(TokenBuf)` → `initTokenBuf()` | `resetProgram`, `setupProgramFromBuf` (+41/-4) | A2a-front `8b593d26`, A1b `f2e7189b` |
| `src/nimony/semmain.nim` | `buildIndexExports` + `initSemContext` + `semcheckCycleGroup` field inits | `SemOutputs`, `semcheckToBuf`, `indexBytes`, `writeOutputs`, `resetFrontendGlobals` (+181/-52) | A2a-front `8b593d26`, `1fa5f4e9`; F1 follow-ups `45180a3d` |
| `src/nimony/sem.nim` | 5× `default(TokenBuf)` → `initTokenBuf()`, 1× `readonlyCursorAt` → `cursorAt` | `c.localNs` save/restores; `asNimSym` renames | F1 `73f605d3`, F1 follow-ups `45180a3d` |
| `src/nimony/semcall.nim` | `earlyErr` → `initTokenBuf()`, `genericDest:`, `readonlyCursorAt` → `cursorAt` | `runCompiledMacroPlugin`, `asNimSym` | A2c/F1 follow-ups |
| `src/nimony/semdecls.nim` | `innerObjDecl` → `initTokenBuf()` | `c.localNs` in `semProcImpl`; `compileMacroPlugin(…, baseDir)` | F1 `73f605d3`, A2c `eb896a80` |
| `src/nimony/sigmatch.nim` | `createMatch` gains `args:`/`typeArgs: initTokenBuf()` | `getErrorMsg` + three renames | F1 follow-ups `45180a3d` |
| `src/nimony/controlflow.nim` | new `initTarget`, ~25 `Target(m: …)` rewrites, `ControlFlow(dest: initTokenBuf(), …)` | `cf` counter scoped per declaration | F1 follow-ups `8328879a` |
| `src/nimony/derefs.nim` | `dest: TokenBuf()` → `initTokenBuf()` | `err` counter scoped per declaration | F1 follow-ups `8328879a` |
| `src/nimony/contracts.nim`, `contracts_fir.nim` | `Context`/`FirContext` field inits | diagnostics render `sourceIdent` | F1 follow-ups `45180a3d` |
| `src/nimony/renderer.nim` | the pragma-comma fix | `asNimSym` | F1 follow-ups `45180a3d` |
| `src/nimony/indexgen.nim`, `src/validator/semvalidator.nim`, `src/hexer/lifter.nim` | `initTokenBuf()` | **untouched by us** | — |
| `src/hexer/xelim.nim` | `initTarget` + 20 rewrites | `TempNamer` | F2 `705addc8` |
| `src/hexer/coro_transform.nim` | `ProcContext(kind: IsNormal, cf:, resultSlotType:)` | `TempNamer` | F2 `705addc8` |
| `src/hexer/lengcgen.nim` | `initBody: initTokenBuf()` in `expand`'s `EContext` | A2a-hexer's buffer-level entry points, `HexerStatus`, decl digests, `TempNamer` (+183/-35) | `30a363df`, `4370cb8f`, `117c9cd6`, `a9d0b7e4`, `705addc8` |
| **`src/hexer/duplifier.nim`** | `MoverContext(cf: initTokenBuf(), bits: …)` | `swap(c.namer, pass.namer)` on the next line | **CONFLICT** — F2 `705addc8` |
| **`src/hexer/lambdalifting.nim`** | `Context(counter: 0, dest: initTokenBuf(), …)` | F2 **deleted** `Context.counter` | **CONFLICT** — F2 `705addc8` |

Plus one file that is **not** in upstream's 22 and breaks anyway:

| `src/nimony/semos.nim` | not touched by upstream | `restoreFrontendState` assigns `nifcore.fallbackPool`/`fallbackTags` (A2c `eb896a80`) | hard compile error after the merge: the symbols no longer exist outside `-d:nimonyPlugin` |

### 3.1 The two hazards handed forward, both clear

* **Step 1's `nearestIsUnique`.** `c6be04e1` touches `sem.nim`, `semcall.nim`
  and `sigmatch.nim` but **re-signatures nothing**: its whole footprint there
  is `default(TokenBuf)` → `initTokenBuf()`, two `readonlyCursorAt` →
  `cursorAt`, and two added object-literal fields. `git show c6be04e1 |
  grep -E 'nearestIsUnique|rawBuildSymChoice|buildSymChoice|semIdentImpl|
  semQuoted|semExprSym\(' ` is empty. The out-parameter is not at risk.
* **Step 2's `semTypeSection`.** Upstream's `semdecls.nim` hunk is one line
  inside the proc body (`innerObjDecl`); the signature and the three tail calls
  are untouched, and `outerRefOwner` does not appear in the commit.
  `semdata.nim` is **not in this commit at all**, so the "third addition above
  `localNs`" worry does not apply this time.

## 4. Resolution

Rule, unchanged from steps 1-3: upstream's semantics win, ours survive as a
re-application.

1. `src/hexer/duplifier.nim` — take upstream's line
   (`MoverContext(cf: initTokenBuf(), bits: pass.bits)`), keep our
   `swap(c.namer, pass.namer)` after it.
2. `src/hexer/lambdalifting.nim` — take upstream's `dest: initTokenBuf()`,
   drop upstream's `counter: 0` (F2 removed the field), keep the rest of ours.
3. `src/lib/nifpools.nim` — `resetPools` loses its two
   `nifcore.fallback* =` lines and its doc comment says why.
4. `src/nimony/semos.nim` — `restoreFrontendState` loses the same two lines;
   `FrontendSnapshot`'s doc comment updated.
5. `src/nimony/semmain.nim` — `resetFrontendGlobals`'s doc comment drops the
   fallbacks from its inventory; `SemOutputs(ok: false)` binds its buffers.
6. `src/hexer/hexer.nim`, `src/lengc/lengc.nim` — doc comments only.
7. Then the check of steps 1-3: every shared file diffed against
   `git show c6be04e1:<path>`, every remaining line accounted for as ours by
   name and phase.

## 5. What was actually done, and the results

Two conflicts, resolved as §4 planned. Four code changes beyond them, all
forced by the merge rather than chosen:

| file | change |
|---|---|
| `src/hexer/duplifier.nim` | upstream's `MoverContext(cf: initTokenBuf(), bits:)`; our `swap(c.namer, pass.namer)` re-applied after it |
| `src/hexer/lambdalifting.nim` | upstream's `dest: initTokenBuf()`; upstream's `counter: 0` dropped (F2 deleted the field) |
| `src/lib/nifpools.nim` | `resetPools` loses `nifcore.fallbackPool =` / `fallbackTags =` |
| `src/nimony/semos.nim` | `restoreFrontendState` loses the same two lines |
| `src/nimony/semmain.nim` | `SemOutputs(ok: false)` binds `code`/`deps` with `initTokenBuf()` |
| doc comments | `nifpools.resetPools`, `semos.FrontendSnapshot`, `semmain.resetFrontendGlobals`, `hexer.resetHexerGlobals`, `lengc.resetLengcGlobals` — each listed the two fallbacks in its inventory of what it resets or depends on |

The diff-against-upstream check: `nifcore.nim`, `lifter.nim`, `indexgen.nim`
and `semvalidator.nim` are **byte-identical** to `git show c6be04e1:<path>`;
the other 18 differ by exactly our hunks, each attributable to F1 `73f605d3`,
F1 follow-ups `45180a3d` / `8328879a`, F2 `705addc8`, A2a-front `8b593d26` /
`1fa5f4e9`, A2a-hexer `30a363df` / `4370cb8f`, B3 `117c9cd6` / `a9d0b7e4`,
A2c `eb896a80`, A1b `f2e7189b`.

Results (verbatim tails are in `MERGE.md` §4): `build all` exit 0 with no
`[deps]` line; `tests/inproc` 3/3 with every artifact byte-identical between
in-process and per-process runs — the gate for this commit; `tests/incremental`
all green with `decl-stability`'s digest counts unchanged from steps 1-3;
`ctfe_diff` 0 differences; `nifcache`, `nimony_r`, `ctfe_engine`, `ledger` all
passed; `tests/nimony` **795 / 795** (this commit adds no test file, so 795 is
the expected number, not a missed one); `boot --boot-backend:native` stages
1 == 2 == 3 byte-identical. `bench/devloop_ab.sh … self.editbody 5` twice:
B/A cpu 0.260 and 0.261 against step 3's 0.261, with both absolute sides ~8 %
high under a load average of 5.02.

## 6. For steps 5 and 6

* **`38f67463` "thread the tag space" (step 5)** is the sibling of this commit
  and lands on the same ground. It threads a `TagSpace` through `std/http`;
  if it also touches `nifpools.globalTags`, note that after step 4 the ONLY
  consumer of `globalTags` in the compiler build is
  `nifpools.createTokenBuf`/`initTokenBuf` and `nifpools.registerTag` — the
  nifcore side no longer mirrors it, so a tag-space change has exactly one
  place to be re-pointed and `resetPools` is still that place.
* **`e1da48e9` the nifsyms refactor (step 6)** changes how a symbol is
  represented and adds `symString`. Two things from this step it must respect:
  1. `default(TokenBuf)` is now a **bug**, not a shorthand. Any buffer the
     refactor introduces has to be `createTokenBuf` or `initTokenBuf`; the
     assert in `requirePools` is what catches it, at the first interning add.
  2. `readonlyCursorAt` now allocates a `CursorOwner` header when the buffer
     has none. Anything in our branch that calls it in a hot loop over a
     freshly built buffer pays one small allocation it did not pay before.
     Our call sites: `semmain.writeOutputs` (once per module) and
     `decldigest`/`hexerio` (once per declaration). Measured below; no move.
  3. Step 6 also carries the nativenif pin `83ced299`, whose `82ca1f38` fixes
     `core/declhead.nim` against the refactor's split-symbol mode — see
     `notes/merge-u3.md` §3. That fix is deliberately NOT on this step's pin
     `3ec73fef`, which this commit does not touch.
* **`src/nativenif.commit` stays `3ec73fef`** through step 4: `git show
  c6be04e1 --stat` does not list it.

## 7. One thing step 5 or 6 should not have to rediscover

The break this step had to fix was **not in upstream's 22 files**.
`src/nimony/semos.nim` is ours alone, and it named `nifcore.fallbackPool`
because A2c needed to. A file-by-file review of the commit's own file list
would have missed it; what caught it is grepping the WHOLE tree for every
identifier the commit deletes, before trusting the merge:

```
git show <sha> | grep -E '^-(var|  )[a-zA-Z]' # what the commit removes
grep -rn '<each removed identifier>' src/ tests/ tools/ bench/
```

`e1da48e9` (step 6) removes and renames far more than two identifiers — it is
the nifsyms refactor, and `pool.syms[...]` reads are all over our branch's
diagnostics (F1 follow-ups' `renderer.asNimSym` is literally
`sourceIdent(pool.syms[symId])`). Run that grep there.
