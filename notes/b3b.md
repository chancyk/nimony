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
| `hexer_context.nim:47` | `EContext.tmpId` | `` `ii.<n> ``, `continueLabel.<n>`, `forStmtLabel.<n>`, `whileStmtLabel.<n>`, `` `coroResult.<n>.<mod> ``, `` `tc.<n> ``, `` `sc.<n> ``, `Dl.<lib>.<n>.<mod>`. Its comment says "per proc"; it is never reset per proc |
| `hexer_context.nim:46` | `EContext.instId` | `` `lf.<n> `` (`iterinliner.nim:401,702`) |
| `hexer_context.nim:50` | `EContext.localDeclCounters` (seeded 1000) | `<base>.<n>.<mod>` for every hoisted local proc/type/const (`lengcgen.nim:990`) |
| `hexer_context.nim:32` | `EContext.strLitCounter` | `anonArr.<n>.<mod>` (`lengcgen.nim:1618`) |
| `passes.nim:21` | `Pass.nextTemp` | xelim's temps; threaded across all eleven passes and into the nested CPS/lambda pipelines (`xelim.nim:1521,1531`) |
| `lifter.nim:59` | `LiftingCtx.hookNames` | `=destroy_<key>.<n>.<mod>` (`lifter.nim:319`) |
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

## 8. One pre-existing failure found on the way

`hastur test tests/ledger` fails here with *"nifmake must record a spawn
cost for nimsem"* (`tests/ledger/setup.nim:378`). Reproduced with this
branch's two modified files checked out at the fork point, so it is not
B3b's. The assertion wants at least one nimsem sample with
`ewma.spawnNs > 0`, but since A2b the scheduler runs a single-node depth
in-process — whether nimsem is spawned at all in that build is a scheduler
decision driven by the ledger's own cost estimates on the machine at hand.
The test asserts a spawn the scheduler is free not to make.

## 9. Risks in what was NOT done

* The 1.38 s edit loop keeps its 0.25 s hexer and 0.25 s arkham. B4's hot
  reload wants symbol granularity by definition, so this comes back.
* `JIT_IMPL.md`'s B3b gate (≤ 0.1 s there, ≤ 0.2 s in this phase's brief) is
  stated against a number the measurement cannot support; it should be
  restated after prerequisite 1, when the churn numbers change.
* The new scenario asserts an upper bound of three declarations for the
  line-info-blind statement edit. That bound is generous for a 13-declaration
  fixture; if the fixture grows it should be revisited rather than raised.

---

# Phase B3b, second attempt — after F1

Research notes per `JIT_IMPL.md`'s "Execution rules for agents" rule 3, for
the run that started from `fast-devloop` at `cbf1fbe9` (everything through
F1). Branch `jit/b3b`; nativenif from a private clone of the pin `c3f27fc`
(`/tmp/b3b2/nativenif`, branch `jit/b3b-native`), **left unmodified**. Numbers
in `bench/results/2026-09-07/b3b.txt`.

Everything above this line is the first attempt and is still accurate except
for §2's "prefix theorem", which §11 below disproves.

The short version: **F1 delivered exactly what it promised and it is not
enough, because the same disease exists one level down.** nimsem's output is
now declaration-local; hexer's is not, for the same reason nimsem's was not
before F1 — module-wide counters minting symbol names. None of the three
steps this attempt was asked to build can reach its gate before that is
fixed, and two of them measure at a fraction of the value the brief assumed.
Nothing was landed except the instrument and the regression that pins the
number.

---

## 10. What the tip actually costs, which is not what the brief says

The brief describes a 0.77 s loop as "nimsem ~0.33, hexer ~0.25, arkham ~0.2
on the one module". On this tip, `--profile` over a `self.editbody` rebuild
says:

| stage | editbody | live edit | growing edit |
|---|---|---|---|
| nimsem | 0.337 | 0.350 | 0.437 |
| hexer | 0.272 | 0.269 | 0.282 |
| dceEmit | 0.045 | 0.045 | 0.047 |
| dceLive | — | — | 0.385 |
| **arkham** | **0.000** | 0.260 | 0.267 |
| **link (nifasm)** | **0.000** | 0.337 | 0.328 |
| wall | **0.710** | 1.280 | 1.760 |

`self.editbody` appends `proc devloopBenchBody(): int = 1`. It is private and
never called, so `dce` deletes it, sem's `.c.nif` comes out byte-identical,
the arkham node is up to date and **nifasm never runs**. Confirmed three
ways: no `.c.nif` or `.asm.nif` mtime moves, the executable is not relinked,
and the backend graph's profile lists only `hexer` and `dceEmit`.

So on the gate's own benchmark the gate "hexer + arkham ≤ 0.1 s (from
~0.45 s)" reads "hexer ≤ 0.1 s (from 0.27 s)", and steps 2 and 3 of the brief
are aimed at 0.0 s. The other two columns are what a developer's edit costs;
`self.editbody` is the cheapest edit the compiler can be given, not a typical
one, and the phase should not be judged on it alone.

### Where hexer's 0.27 s is

The eleven passes were already logged (`NIMONY_PASS_TIMING`); the rest was
not, and §4 had to measure it with probes that were then reverted, so this
attempt began by rebuilding them. They are kept this time as
`passes.StageTimer` — same channel, stages prefixed `|`, off unless the
variable is set, and proved byte-neutral over 381 artifacts (§13).

| stage | ms | per declaration? |
|---|---|---|
| `loadParse` | 13.4 | no — the input must be parsed to be diffed |
| `digestInput` | 2.9 | no |
| `transform` (11 passes) | 153.9 | **yes** |
| `trToplevel+genInit` | 14.4 | yes |
| `arcopt` | 13.3 | yes, already per proc |
| `funcsummary` | 11.2 | no — fixpoint over the call graph |
| `intraModuleInline` | 22.5 | no |
| `digestOutput` | 6.1 | no |
| `analyzeModule` | 7.1 | yes, a disjoint union |
| `serialize` | 20.9 | no |
| `writeX`/`writeDce`/`writeDecls` | 12.4 | no |

188.7 ms is decomposable, 89.4 ms is not. A declaration-level hexer that
skipped *all* of the first group would still pay the second plus a re-parse
of the previous 7.58 MB `.x.nif` to splice into — ~23 ms at `loadParse`'s
measured 333 MB/s. **112 ms against a 100 ms gate, with zero declarations
lowered.**

## 11. The premise of step 1, and why the fallback is unsound

F1's `<mod>.decls.nif` records both digests per declaration, which is exactly
the pair step 1 consults: the input digest decides what to re-lower, the
output digest decides what may be spliced. sem has 1794 of them.

| edit | sem-input changed | lowering-output changed |
|---|---|---|
| editbody | 0 (+1 added) | 0 (+1 added) |
| live (token count preserved) | 1 | **3** |
| grow (one statement added) | 1 | **890** of 1794 |

The textual method the scenario uses (`splitNifDecls`/`diffDecls`) agrees on
the `grow` edit — 896 blind against the sidecar's 890 — but it overstates
churn wherever a child is ADDED, and the two numbers must not be confused:
1788 of sem's 3550 `.x.nif` children are anonymous (1268 `(x`, 494 `(h`, …),
`declNameOf` collapses them onto their tag, and `diffDecls` matches repeats
positionally within that group, so one inserted node shifts the rest. That is
why `editbody` reads 0 in the sidecar and 945 in a textual `.x.nif` split.
The sidecar is keyed by symbol and is the number to trust — a concrete reason
F1 was right to build it instead of diffing bytes.

One changed input declaration, half the module re-lowered. The cause is
visible in the diff of a proc the edit does not touch:

```
-   (var :`x.840 . xint.0.xincut4p51        +   (var :`x.841 . …
-    (var :t.0h65 .                         +    (var :t.0h91 .
-     (lab :returnLabel.0h74)               +     (lab :returnLabel.0h100)
```

`` `x.<n> `` is `xelim.Context.counter`, carried module-wide as
`Pass.nextTemp` (`src/hexer/xelim.nim:102,635,1223,1521,1531`,
`src/hexer/passes.nim:21`). `0h<n>` is `intramodinliner.InlinerCtx.counter`
(`src/hexer/intramodinliner.nim:400-417,1095-1097`). Both are §2's list, and
§2 was right about them; what §2 got wrong is the escape hatch it offered.

### The prefix theorem is false

§2 claimed:

> since every pass processes declarations in order, **if declarations 1..k
> are unchanged then after every pass the output prefix for 1..k is identical
> and every counter is at the same value.** A prefix-preserving incremental
> hexer is therefore sound without any counter checkpointing.

It is not. On `tests/incremental/b3b_lib.nim`, adding one `and` — which xelim
binds to a bool temp — to `step10`, the **last** declaration of the module,
changes 11 of its 23 declarations, and the diff of `step1`, the **first**, is

```
-   (var :`x.0 .        +   (var :`x.1 .
```

An edit at the end renumbers the beginning. `pipeline.transform` runs eleven
passes over the whole buffer and `lowerExprs` runs three of them sharing one
monotone counter, so the temps `step1` receives on the second run depend on
how many the first run minted in `step10`. The theorem holds *within* one
pass and fails for the pipeline, which is the only thing that matters.

There is therefore no cheap sound splice. Either the counters are scoped per
declaration, or all seven of §2 plus `EContext.hoistedConsts`, `c.pending`,
`c.strLits`, `c.newTypes`, `c.initBody` and `LiftingCtx`'s two hook tables
are checkpointed and restored per declaration in both directions. A mistake
in any of them is two declarations minting the same `` `x.N ``, which
`pool.syms.getOrIncl` interns to one `SymId` — a miscompile, not a slow path.
F1 §3 made exactly this argument about `hoistedConsts` and it applies
verbatim here.

## 12. arkham and nifasm, measured before touching either

The brief asks whether unchanged procs' asm-NIF is byte-identical, citing §5's
135-of-974 pure drift.

| edit | `.c.nif` changed | `.asm.nif` changed | pure drift |
|---|---|---|---|
| live | 1 | 1 | **0** |
| grow | 638 (blind 420) | 467 | **28** of 1949 |

**F1 already removed most of that drift**, because it was downstream of sem's
module-wide local renumbering shifting the token positions arkham names its
temps (`aggtmp<pos>`, `nctmp<pos>`, …) from. What is left of arkham's own
module-scoped state is 28 declarations. The 467 that change are inherited
from §11's 420 — hexer's counters, not arkham's.

nifasm's link (`NIFASM_PROFILE=1`), identical for both live edits:

```
blobHits 3415   blobStale 18   blobRecorded 627
emitRoots 296-305 ms of a 324-335 ms link
per-module emit: semygjvq21 187.8 ms / 867 syms
```

**18 stale, not the 540 the brief expected** — B3c narrowed that already. The
item that remains is `blobRecorded 627`: the cache's unit is the symbol but
its validity check is per MODULE. `blobcache.sameSource` (`:449`, at the pin
`c3f27fc`) compares the module file's stamp and, failing that, a hash of the
whole file; `:752` applies it to the fragment's own module and `:760` to
every module the fragment depends on. So sem's `.asm.nif` changing by two
lines drops every fragment whose symbol lives in sem *and* every fragment
elsewhere that references one — while the recorded per-symbol asm is what
actually decides whether a fragment is still good.
Per-symbol validity takes 627 down to ~467 today — **~55 ms of a 1.28 s loop,
4 %** — and to ~2 once §11's counters are scoped, i.e. ~180 ms, 14 %.

That is why the nativenif clone is unmodified: step 3's value is gated on a
change outside this phase's owner set, and landing it first buys 4 % at the
price of a nativenif release.

## 13. What was implemented

Two things, both instrument rather than mechanism.

**`passes.StageTimer`** (`src/hexer/passes.nim`) — an explicit state object
threaded through `expand`, `writeExpandResult` and `optimizeLengOutput`,
logging the fourteen non-pass stages of §10 on the existing
`NIMONY_PASS_TIMING` channel with a `|` prefix. AGENTS.md style: one object,
flat procs, no closures, no new global `var`. Under the nimony dialect the
timing fields and bodies vanish behind `when not defined(nimony)`, exactly as
`Pass.passStart` already did. `hastur boot --boot-backend:native` is green
with stages 1 == 2 == 3, so both dialects compile it. Byte-neutrality was
checked rather than assumed: the same 127-module compiler built twice from a
fresh nimcache, once with the variable set and once without, gives **381
artifacts compared, 0 differ** (127 each of `.x.nif`, `.dce.nif`,
`.decls.nif`).

**A fourth `decl-stability` edit** (`src/hastur/incrementaltests.nim`,
`tests/incremental/b3b_lib.nim`). The scenario the first attempt left behind
had a blind spot that is the reason this finding took a measurement to see:
the sidecar records two digests per declaration and the scenario asserted on
**only the sem-input one**. Hexer's output could churn over the whole module
without a single test noticing. The new phase `(d) tempadd` adds the `and` to
`step10` and asserts on the lowering-output digest; the existing `in-place`
and `stmtadd` phases now assert it too. On the 13-proc fixture it prints

```
decl-stability: … | decls digest 23 syms, sem-input changed 1/0/1/1
  | lowering-output changed 1/-/1/11 | .x.nif in-place changed 1
```

`1/-/1/11` is the phase's whole argument in one line: three edits keep hexer's
output local, and the one that mints a temp does not. The `tempadd` bound is
a ceiling with an assertion that the output churn strictly exceeds the input
churn, so when the counters are scoped the test fails loudly and tells whoever
fixed it to tighten the bound to 1 rather than silently passing.

## 14. Ordered prerequisites, revised

§7's list survives with one item promoted to the front and two struck.

1. ~~nimsem: `makeLocalSym` per routine~~ — **done, F1.**
2. ~~hexer: line-info-blind declaration digests and an info rebase~~ —
   **done, F1** (`src/hexer/decldigest.nim`, `<mod>.decls.nif`).
3. **hexer: scope `Pass.nextTemp` and `InlinerCtx.counter` per top-level
   declaration**, then the other five of §2. This is F1's move one level
   down and it is now the only thing standing in front of everything else.
   F1's spelling generalizes directly: the owner's name rides in the
   disambiguator (`` `x.3`semExpr`0 ``), one dot, so every `symparser`
   scanner still classifies it local and `extractBasename` still answers
   `` `x ``. The counter must be *persistent per owner* rather than pushed
   and popped, because `lowerExprs` visits the same routine three times and a
   counter that restarted would collide (`xelim.nim:1515`'s comment says so
   already, for the module-wide case).
   Expected: §11's 890 → 1, §12's 467 → ~2, and only then
4. **nifasm: per-symbol blob validity** (627 recorded → ~2, ~180 ms), and
5. **arkham: per-proc splicing** keyed on the `.c.nif` declaration, with
   proc-scoped labels and rodata for the 28 declarations of drift that
   remain. Non-byte-identical refactor gate, every `.asm.nif` golden
   regenerated — worth it only once 3 and 4 have landed.
6. **hexer: a declaration-level incremental `expand`.** Even with 3 done, §10
   says its floor is 112 ms unless `funcsummary`, `intraModuleInline` and the
   serialize are *also* made incremental and the splice is done on text with
   per-declaration byte offsets recorded in the sidecar. That is the shape
   that reaches 30-40 ms; the token-buffer version does not reach 100 ms.

## 15. Risks and what is left

* The 0.71 s / 1.28 s loop is unchanged by this branch. Nothing regressed and
  nothing improved; the deliverable is that the next attempt starts from a
  correct model instead of §2's theorem. `bench/devloop_ab.sh` against the
  fork point says `self.editbody` 2.704 → 0.700 s wall, 3.897 → 0.692 s cpu,
  116 → 105 MB (all of it F1's) and `self.cold` 15.589 → 14.130 s cpu,
  116 → 218 MB (all of it A2b's, run 10).
* `JIT_IMPL.md`'s B3b gate is stated on `self.editbody`, an edit whose proc
  is dead on arrival. Any gate for the arkham/nifasm half has to be restated
  on an edit that survives DCE, or it measures 0.0 s and passes for the wrong
  reason. The `live`/`grow` edits of `bench/results/2026-09-07/b3b.txt` §0 are
  offered for that.
* `dceLive` costs 0.385 s on the growing edit and is absent from the other
  two. It was not investigated here and is not in this phase's owner set, but
  it is the second largest single stage of a realistic edit after nimsem and
  nothing in the plan currently owns it.
* The `tempadd` phase depends on `and` still being lowered to a bool temp. If
  `xelim` ever stops doing that, the phase stops measuring anything and its
  `dTempOut > dTempIn` assertion fails — which is the right failure, but the
  fix is to pick another temp-minting construct, not to delete the phase.
