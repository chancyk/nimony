# Phase B3b — symbol-granularity lowering for the edited module

Research and measurement notes, per `JIT_IMPL.md`'s "Execution rules for
agents" rule 3. Worktree branch `jit/b3b`, forked from `fast-devloop`
(`bad14fbf`, i.e. everything through B3). nativenif from a private clone of
the pin `f8d2676`, left unmodified.

The numbers this note argues from are in `bench/results/2026-09-06/b3b.txt`.
The short version: **neither half of the phase was implemented, because the
measurement says neither can reach its gate, and both are blocked by causes
that live outside `src/hexer/**` and `src/arkham/**`.** What was implemented
is the harness that turns those causes into a tracked regression.

---

## 1. What `expand` actually is

`expand` is not in `hexer.nim`; it is `src/hexer/lengcgen.nim:2870` (the
buffer-level `ExpandInput`/`ExpandResult` overload A2a added) with the
path-based wrapper at `:2967`. In order:

1. `loadExpandInput` (`:2842`) — `programs.setupProgram` reads, indexes and
   parses the `.s.nif` in one call. The `TypeCache` is created BEFORE the
   parse and that is load-bearing (`notes/a2a-hexer.md`).
2. `pipeline.transform` (`src/hexer/pipeline.nim:46`) — `elimForLoops` over
   the whole module, then one `Pass` object through eleven passes:
   `desugar`, `lambdalift`, `xelim1`, `eraiser`, `duplifier`, `destroyer`,
   the hook merge, `cps`, `vtables`, `constparams`, `xelim_final`.
3. `trToplevel` (`lengcgen.nim:2757`) — the Nimony→Leng walk, splitting each
   top-level statement between `cdest` and `c.initBody`.
4. `initDynlib`, `strLitBuf`, `toplevels`, `c.pending`, `genInitProc`,
   `dynlibInit`, `c.initBody`, `genInitProcEnd`, optionally `genMainProc`.
5. `makeOutput` + `optimizeLengOutput` (`pipeline.nim:147`): `runArcopt`,
   `annotateFunctionSummaries`, `intraModuleInline`.
6. `dce1.analyzeModule` over the finished buffer.
7. `serializeModule` → `nifcoreparse.toModuleString` (which appends the
   embedded `(.index …)`), then `OnlyIfChanged` writes.

`src/hexer` has exactly two module-level `var`s, both under a `when`
(`passes.nim:32-35`, `intramodinliner.nim:1270`); everything else is on a
per-run state object, which is AGENTS.md's rule and happens to be what a
re-entrant tool needs. That is not the obstacle. The obstacle is that the
per-run state is **module-scoped and order-dependent**.

## 2. Everything in `expand` that is a function of a declaration's position

Enumerated so a future attempt does not have to rediscover it.

Monotone counters whose values end up in generated SYMBOL NAMES:

| where | field | names it mints |
|---|---|---|
| `hexer_context.nim:47` | `EContext.tmpId` | `` `ii.<n> ``, `continueLabel.<n>`, `forStmtLabel.<n>`, `whileStmtLabel.<n>`, `` `coroResult.<n>.<mod> ``, `` `tc.<n> ``, `` `sc.<n> ``, `Dl.<lib>.<n>.<mod>` |
| `hexer_context.nim:46` | `EContext.instId` | `` `lf.<n> `` (`iterinliner.nim:401,702`) |
| `hexer_context.nim:50` | `EContext.localDeclCounters` (seeded 1000) | `<base>.<n>.<mod>` for every hoisted local proc/type/const (`lengcgen.nim:990`) |
| `hexer_context.nim:32` | `EContext.strLitCounter` | `anonArr.<n>.<mod>` (`lengcgen.nim:1618`) |
| `passes.nim:21` | `Pass.nextTemp` | xelim's temps; threaded across all eleven passes and into the nested CPS/lambda pipelines (`xelim.nim:1521,1531`) |
| `lifter.nim:59` | `LiftingCtx.hookNames` | `=destroy_<key>.<n>.<mod>` (`lifter.nim:317`) |
| `intramodinliner.nim` | `InlinerCtx.counter` | `base.0h<n>`, `returnLabel.0h<n>` |

First-use ownership — a declaration "owns" a generated top-level node only
because it was the first to need it, so deleting it moves the node:
`EContext.strLits` (`:28`), `newTypes` (`:29`) and the `c.pending` tail
(`:30`) that carries synthesized named types, `moveToTopLevel`'d nested
decls and hoisted consts; `LiftingCtx.structuralTypeToHook` /
`nominalTypeToHook`.

Whole-module output with no declaration boundary: `c.initBody` — every
top-level executable statement and every non-static global initializer of
the module, in source order, in one proc body — plus
`c.importedModuleSuffixes`, which orders the init proc's calls.

Whole-module ANALYSES: `funcsummary.annotateFunctionSummaries`
(`funcsummary.nim:818`) is a least fixpoint over the in-module call graph
whose result is written into every proc's pragmas, so changing one body can
change another proc's emitted pragmas; `intramodinliner.intraModuleInline`
(`:2082`) splices this module's tiny procs into their same-module callers.

The two that are *not* obstacles: `arcopt` is genuinely per-proc
(`arcopt.nim:451`), and `dce1.analyzeModule` is a disjoint union over
top-level declarations, so the `.dce.nif` half of the phase (its step 3) is
the easy part — and worth 5.8 ms of a 244 ms `hexer c`.

There is a real theorem hiding here that a future attempt should use: since
every pass processes declarations in order, **if declarations 1..k are
unchanged then after every pass the output prefix for 1..k is identical and
every counter is at the same value.** A prefix-preserving incremental hexer
is therefore sound without any counter checkpointing. It is also worth only
about half the module on average, because the edit point is where the prefix
ends.

## 3. The premise does not hold

Measured on `src/nimony/sem.nim` — 5610 lines, 1227 top-level `.s.nif`
declarations — by splitting each artifact into the children of its root
`(stmts …)` and comparing them by content. Three edits; full tables in
`b3b.txt` section 3.

| edit | `.s.nif` changed | with line info ignored |
|---|---|---|
| a string literal replaced by one of the same length | 1 / 1228 | 1 |
| `proc devloopBenchBodyN(): int = 1` appended (`self.editbody`) | **465** / 1227 | 465 |
| two statements inserted into a proc body | **277** / 1228 | 49 |

Two causes, neither in hexer:

* **NIF line info.** Every top-level declaration anchors its own `@…` token,
  so an edit that shifts line numbers rewrites every declaration below it in
  the same file. Hexer can work around this — a line-info-blind digest for
  the DIFF plus an info rebase for every spliced fragment — but the rebase
  has to be exactly right for every token or byte-identity is gone.
* **`sembasics.makeLocalSym`** (`src/nimony/sembasics.nim:450-456`) numbers
  every local symbol from `SemContext.locals`
  (`src/nimony/semdata.nim:174`), a module-wide per-NAME counter. Insert one
  proc with an implicit `result` — which every non-void proc has — and every
  later `result.N` in the module is renumbered. Stripping line info does not
  help: these are genuine renames that also travel into `.dce.nif`'s `uses`
  sets and across modules. Only `src/nimony/**` can fix it, which is not
  this phase's owner set.

Note the shape of the second one: the benchmark the gate is stated on
(`self.editbody`, which appends a proc) is the *pessimal* case, not the
typical one, because in the compiler's own modules everything after an
appended proc is the generic instantiations spliced in from imports.

## 4. Where the time is, and what a perfect implementation would buy

`hexer c` on sem, from the cost ledger: parse 14.1 + produce 207.2 +
serialize 19.5 + write 3.6 = 244.4 ms. `produce`, from temporary probes
(reverted; the probe build's `.x.nif` was byte-identical):

* decomposable per declaration in principle — `transform` 154.4,
  `trToplevel`+`genInitProc`+`makeOutput` 14.8, `arcopt` 12.2,
  `analyzeModule` 5.8 → **187 ms**
* whole-module by construction — `funcsummary` 11.5 + `intraModuleInline`
  24.1 → **36 ms**

So a perfect declaration-level hexer costs 38 ms of I/O + 36 ms of
whole-module analysis + (changed fraction) × 187 ms, plus a re-parse of the
previous 7.1 MB `.x.nif` (~25 ms). On the gate's own edit that is ~170 ms;
with a perfect arkham splice on top (~68 ms) the pair lands at **~238 ms
against a ≤ 200 ms gate**. The gate is not reachable by this phase as
specified even with a flawless implementation.

## 5. arkham: measured, not assumed

The phase says to check whether an unchanged proc's asm-NIF is already
byte-identical. Cross-checked per declaration — how many `.asm.nif`
declarations changed whose `.c.nif` input declaration did not:

| edit | `.c.nif` changed | `.asm.nif` changed | pure drift |
|---|---|---|---|
| in-place | 3 | 3 | 0 |
| append | 140 | 140 | 0 |
| two statements inserted | 290 | 248 | **135** |

135 of 974 declarations get different asm from identical input. The causes
are all module-scoped in arkham at `f8d2676`: `CodeGen.labelCount`
(`core/context.nim:146`, reset per proc only on AVR), the rodata pool index
in `msg.<rodata.len>.<mod>` (`x64/value.nim:815`, `risc/value.nim:1734`),
and the temps named from the absolute token position in the input module
(`aggtmp<pos>`, `nctmp<pos>`, `botmp<pos>`, `rettmp<pos>`, `pairaddr<pos>`,
`lvaltmp<pos>`).

So splicing a previous `.asm.nif` per proc is not byte-identical today, and
what it would produce — two procs both emitting `L4856.0`, a stale `msg.7`
naming a different string — is a miscompile, not a cosmetic diff. Making
`labelCount` and the rodata index proc-scoped is the prerequisite, and it
rewrites every `.asm.nif` golden in nativenif.

And it would not help nifasm yet: after an edit that changes exactly ONE of
sem's 975 asm declarations, nifasm reports `hits 3415 / stale 18 /
recorded 627`. The blob cache's unit is the symbol but its validity check is
per module (`sameSource` on the module's `.asm.nif` stamp,
`src/nifasm/blobcache.nim:449,752`), so any change to sem drops all of sem's
fragments. That check is nifasm's, i.e. B3c's file.

Because the phase's own condition for the arkham half is "only if the hexer
half lands and arkham is still ≥ 0.2 s", and the hexer half does not land,
**no change was made in the nativenif clone.** It is at `f8d2676`,
unmodified.

## 6. What was implemented

`tests/incremental/b3b_lib.nim` + `b3b_main.nim` and
`incrementalDeclStabilityTests` in `src/hastur/incrementaltests.nim`, wired
into `tests/incremental/setup.nim`.

The scenario splits the fixture's `.s.nif` and `.x.nif` into the children of
their root `(stmts …)` — cutting the trailing embedded `(.index …)` at the
byte offset the header's `.indexat` names, because that index is a
whole-file artifact — and runs the same three edits the measurement used. It
prints the numbers and asserts the invariants that must hold whatever
happens upstream:

* an in-place, same-length literal edit changes **exactly one** declaration
  of the `.s.nif` and at most one of the `.x.nif`. This is the invariant a
  declaration-level incremental hexer is built on, and the one thing here
  that would silently rot;
* a proc inserted in the middle never invalidates a declaration **above**
  it, and ignoring line info never makes the churn worse;
* a statement inserted into one body leaves at most three declarations
  differing once line info is ignored — the fact prerequisite 2 rests on.

On the 13-declaration fixture it prints, today:

```
decl-stability: .s.nif 13 decls | in-place changed 1 | insert changed 7
  (blind 7, added 1) | stmtadd changed 8 (blind 2) | .x.nif in-place changed 1
```

`insert 7 → blind 7` is the local-counter rename; `stmtadd 8 → blind 2` is
line info. Both reproduce sem's ratios on a fixture that costs 0.8 s.

## 7. Ordered prerequisites for a future attempt

1. **nimsem**: `makeLocalSym` should number a local from its enclosing
   routine, not from `SemContext.locals`. Turns the gate's own edit from 465
   changed declarations into ~1, and makes every `.s.nif` diff readable.
   Small, self-contained, `src/nimony/**`.
2. **hexer**: line-info-blind declaration digests, plus an info REBASE for
   spliced fragments.
3. **hexer**: per-declaration counter checkpoints for the seven counters in
   §2; per-declaration fragments for `c.initBody`, `c.pending`, `c.strLits`,
   `c.newTypes` and the lifted hooks; an incremental `funcsummary` (cache the
   per-proc `ProcAnalysis`, re-run only `resolveSummaries` +
   `annotateSummaries`); and an intra-module inline dependency map so a
   changed tiny proc invalidates its same-module callers. Full re-lowering as
   the fallback whenever the diff cannot be trusted, `--no-incremental-hexer`
   / `NIMONY_INCHEXER=off` to force it, and the byte-identity oracle against
   a full run in `tests/inproc/hexer`.
4. **arkham**: proc-scoped `labelCount` and rodata index, then per-proc
   splicing keyed on the `.c.nif` declaration.
5. **nifasm**: per-symbol blob validity instead of per-module (B3c).

Steps 1 and 2 are worth doing on their own merits even if the rest never
happens: they are what makes any artifact diff in this compiler mean
"something changed" instead of "something moved".

## 8. Risks in what was NOT done

* The 1.38 s edit loop keeps its 0.25 s hexer and 0.25 s arkham. B4's hot
  reload wants symbol granularity by definition, so this comes back.
* `JIT_IMPL.md`'s B3b gate (≤ 0.1 s there, ≤ 0.2 s in this phase's brief) is
  stated against a number the measurement cannot support; it should be
  restated after prerequisite 1, when the churn numbers change.
* The new scenario asserts an upper bound of three declarations for the
  line-info-blind statement edit. That bound is generous for a 13-declaration
  fixture; if the fixture grows it should be revisited rather than raised.
