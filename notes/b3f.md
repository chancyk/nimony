# B3f feasibility memo — declaration-level incremental sem

Research only. Nothing in `/Users/chanc/Projects/nimony` or
`/Users/chanc/Projects/nativenif` was modified; no git state was changed; no
build was run. All numbers not explicitly marked "measured here" are carried
over from the branch's own notes and are cited as such. Where I could not
settle a question from reading plus the already-built toolchain at
`/tmp/merge-u1/bin/`, I say so and say what would settle it, per the
assignment's instruction (`notes/h1.md` is the standing warning: a plausible
premise turned out to be a measurement artifact, so a number I did not verify
is flagged as such rather than presented with false confidence).

---

## 0. One paragraph

B3f would make `SemcheckBodies` — the third of sem's three passes over a
module — skip a top-level declaration whose own sem-input digest, every
declaration it names, and every whole-module *answer* a body edit could have
changed are all unchanged since the last successful compile of this module,
splicing that declaration's previously-checked `.s.nif` fragment (and
replaying whatever it demanded of module-wide state — most importantly,
generic instantiations) instead of re-running `semStmt` over it. It is the
frontend analogue of B3e: B3e stopped arkham re-lowering an unchanged proc's
Leng; B3f would stop nimsem re-checking an unchanged proc's untyped body. It
is **not built and not scoped as a numbered phase** — `JIT_IMPL.md:710-712`
records it as an "open decision (project owner)... outside JIT.md's...
scope", and this memo is the evidence for making that decision explicit.

---

## 1. Where nimsem's 0.426 s goes — **largely unsettled, and here is exactly why**

**Read, not inferred:** nimsem runs the module through four stages, in this
order, all inside one `SemContext` (`src/nimony/semmain.nim`):

1. `phase1` (`semmain.nim:263-267`) — `phaseX(..., SemcheckTopLevelSyms)`:
   registers top-level symbol names only. Confirmed structurally, not timed:
   every guard template in `sem.nim` that gates real work on `c.phase`
   (`procGuard`, `constGuard`, `pragmaGuard`, `toplevelGuard`,
   `localSigGuard`, `sem.nim:5105-5143`) takes the "do nothing but
   `dest.takeTree it.n`" branch outside `{SemcheckSignatures,
   SemcheckBodies}`. A proc declaration in phase 1 is not even routed through
   `semProcImpl` (`whichPass`, `sem.nim:5103-5104`, only distinguishes
   signatures vs. body — phase 1 never reaches it). This phase should be
   cheap; it is not measured cheap.
2. `phase2` (`semmain.nim:269-281`) — `SemcheckSignatures`: full type
   resolution of every declaration's params, return type, pragmas; hook/
   converter/method registration (`attachSpecialProc`, `semdecls.nim:882`,
   called unconditionally once `status in {OkNew, OkExistingFresh}` —
   i.e., from the signature pass, not the body pass, confirmed by reading the
   call inside `semProcImpl` before the `case pass` dispatch,
   `semdecls.nim:1148-1163`); forward-declaration matching
   (`handleForwardDeclarations`, gated `pass == checkSignatures`,
   `semdecls.nim:1145`).
3. `phase3` (`semmain.nim:283-289`) — `SemcheckBodies`: full expression
   semchecking of every body, including demand-driven generic instantiation
   requests (`requestRoutineInstance`, `sem.nim:640-727`, called from body-
   level call matching, `sem.nim:4837` and `sem.nim:237`).
4. **Post-processing, not one of the three named passes, and not free**
   (`semcheckCore`, `semmain.nim:511-556`): `instantiateGenerics` (drains
   `c.procRequests` to a fixpoint, `sem.nim:521-526`), attaching requested
   hooks/methods to every instantiated type, `instantiateGenericHooks`,
   `injectDerefs`, and `analyzeContractsFinalIr`. This bucket is *entirely*
   demand-driven from what bodies asked for in phase 3, which is exactly why
   §5 below treats it as part of "the body phase" for hazard purposes even
   though it runs after phase 3 returns.

**What is not settled:** there is no per-phase timer in nimsem today. The
cost ledger's `LedgerKey.phase` field has one bucket named `"nimsem"`
(`JIT_IMPL.md:291`) — the whole tool is one line item, the same granularity
hexer had *before* B3b's investigation forced `passes.StageTimer` into
existence (`notes/b3b.md` §10, `src/hexer/passes.nim`). I looked for an
equivalent in nimsem and there is none: `grep -rn "PassTiming\|StageTimer"
src/nimony/` finds nothing (checked). I did not add one — that would be
exactly the "cheap instrumented run" the assignment allows, but it requires
recompiling nimsem, which is a build on a machine the assignment says is
busy, and the assignment says to prefer the already-built toolchain over
starting anything heavy. `/tmp/merge-u1/bin/nimsem` is a plain release
binary; I checked for `-d:dumpPhases`-style dump strings and found none
useful for timing (that define writes NIF *content* dumps, not times,
`semmain.nim` `when defined(dumpPhases)` blocks). So:

**This is unsettled.** What would settle it: an hour of work in the idiom
already proven twice on this branch — a `passes`-style stage timer wrapping
phase1/phase2/phase3/`instantiateGenerics`/`injectDerefs`/
`analyzeContractsFinalIr` in `semcheckCore`, gated behind the same
`NIMONY_PASS_TIMING` channel hexer already writes to, checked byte-neutral
the same way B3b did (381 artifacts, 0 differ, `notes/b3b.md` §13). That is
step 0 of B3f, not a prerequisite external to it — it is the same kind of
work B3b did before touching hexer's mechanism, and it should happen before
committing to the rest of the design, because **the whole phase is worth
nothing if phase 3 + post-processing is a small share of the 0.426 s.**

**What structural reading suggests, marked clearly as inference:** phase 1
is guarded to near-nothing (see above). Phase 2 does real work but over a
narrower surface than phase 3 — signatures are a minority of most modules'
token count (`sem.nim` is unusual in having very large bodies per proc; a
typical module's params+pragmas are a small fraction of its bodies). By
analogy with hexer's own measured split — `transform` (the per-declaration
body-shaped work) was 154/244 ms, 63%, against `funcsummary`+
`intraModuleInline` (whole-module analyses) at 36/244 ms
(`notes/b3b.md` §4, §10) — I would *guess* phase 3 + post-processing is the
majority of nimsem's 0.426 s, with phase 2 a meaningful minority and phase 1
near-zero. This is a guess by analogy to a different tool, not a measurement
of nimsem, and it is exactly the kind of guess `notes/h1.md` warns against
dignifying with a number. **I am not reporting a split for nimsem's 0.426 s.**

One structural fact *is* settled and matters for the design: `self.editbody`'s
nimsem cost is **one nimsection invocation of one module** (`sem.nim` itself),
not a cycle group. `notes/h1.md`'s §2a table and `notes/b3e.md`'s §6 table
both report `nimsem 0.33 s (1)` — one node. The compiler's own source modules
avoid import cycles by design (`semdata.nim:143-145`'s comment on the
callback vtable fields: "used by separately-compiled handler modules... to
break the otherwise mutual recursion with sem.nim" — the callbacks exist
*so that* `semcheckCycleGroup` is never needed for the compiler's own
sources). So B3f's unit of work is exactly what the assignment assumes: one
module, checked once, whose declarations we would like to partially skip.

---

## 2. Can `SemcheckBodies` be skipped per declaration?

**The unit** is a top-level declaration with a `SymbolDef` — the same unit
F1's `decldigest.nim` already keys on (`digestToplevel`, `decldigest.nim:150
-163`, skips "a child... with no `SymbolDef`... rather than keyed by
position"). For a `proc`/`func`/etc. this is one routine's `(stmts...)`
body-check invocation (`semBodyCheckBody`, `semdecls.nim:1123`); for a
top-level `let`/`var`/`const` it is `localSigGuard`'s body-phase branch
(`sem.nim:5121-5127`).

**What a body contributes to module-level state, read from the field
declarations and the call sites, is exactly the list the assignment expects,
plus generics (§ next) and a handful the assignment's list did not name:**

- Generic instantiation requests (`c.procRequests`, demand-driven from body
  call matching) — the hard one, § below.
- `c.freshSyms` — populated inside `subs`/template expansion
  (`addFreshSyms`, `sem.nim:367-369`; also `templates.nim:534`,
  `semos.nim:646`) whenever a body's expression triggers a generic/template
  substitution. Consumed inside the SAME semcheck run (`sembasics.nim:558,
  582,631`, deciding `OkExistingFresh`) — I read no cross-declaration
  consumer, so this looks safely re-derivable per declaration, but I did not
  trace every caller of `sembasics`'s three read sites to confirm nothing
  outlives one declaration's check. **Unsettled**, flagged as such in the
  hazard table.
- `c.genericInnerProcs` — a `HashSet[SymId]` populated inside `semProcImpl`
  itself (`semdecls.nim:1104`, gated `c.routine.inGeneric > 0 and
  c.routine.parent...inGeneric == 0`) and consumed once, after phase 3,
  by `reorderInnerGenericInstances` (`semmain.nim:556,658`) — a *global*
  reordering step over `dest`, so this is whole-module by construction and
  every skipped body's membership must be replayed for the reorder to see
  the same set it would have seen from a full run.
- **What is NOT body-scoped, contrary to what a naive read of the field list
  might suggest:** `typeHooks`, `converters`, `converterIndexMap`, `classes`
  are populated by `attachSpecialProc`/`registerHook`/`attachConverter`/
  `attachMethod`, all called from **phase 2** (signature checking,
  `semdecls.nim:1148-1163`, called once per declaration regardless of `pass`,
  before the `case pass` dispatch that separates checkSignatures from
  checkBody) — driven by the routine's header (params, pragmas, the mangled
  hook name), not by its body content. If phase 2 keeps running unmodified
  over the whole module (which this design assumes it does — only phase 3 is
  skippable), these four fields are **populated exactly as before whether or
  not phase 3 is skipped for that declaration**, and are not a hazard. This
  correction matters: the assignment's prompt lists `converters`,
  `converterIndexMap`, `classes`, `typeHooks` among "accumulators" to
  worry about; reading the call sites says they are declaration-header
  accumulators gated on phase 2, and phase 2 is not in scope for skipping.
- `c.pendingSumtypes` — populated from case-object ("sum type") synthesis
  during type-section semchecking (`sem.nim:2790-2811`); I read this as
  triggered by a `type` declaration's own body (its case-object syntax), not
  by an unrelated proc's executable body, so it is scoped to the type
  declaration that owns it, not a general body-skip hazard — but **I did not
  trace every call site of the sum-type synthesis path**, so treat this as
  inferred, not proven exhaustive.
- `c.toBuild` / `c.toBundle` — populated by `sempragmas.nim`'s `{.compile.}`/
  `{.link.}`/`{.bundle.}` handling (`sempragmas.nim:949-1018`), which is
  pragma processing on a declaration's own header, same status as the hooks
  above: not a body-content hazard if phase 2 is unmodified.
- `c.exports` — populated at `import`/`export` statements
  (`semimport.nim:342,350,439`), top-level statements processed once, not
  re-entered per body.
- `c.templateInstCounter` — a recursion-depth guard (`semcall.nim:1170-1175`,
  save/restore around one expansion), not a name-minting counter; the
  assignment's framing of it as a "counter" needing scoping is answered simply:
  it is already save/restore scoped per template call and carries no state
  across declarations.
- `c.usedTypevars` — incremented inside type classification (`sem.nim:1543,
  1924`) and read back by `semtypes.nim:653,689-690` as
  `usedTypevarsInitial`/`usedTypevarsFinal` around one type's own generic-param
  check — a delta within one declaration's own processing, not cross-
  declaration state. Not a hazard as far as I traced it.
- `c.fieldCounts` — explicitly documented as save/restored per object type
  (`semdata.nim:186-192`), already exactly what F1/F2 did for local-symbol
  counters, and already not a whole-module counter. Not a hazard.

This list is longer and more specific than the assignment's own enumeration,
because reading the field *declarations* in `semdata.nim` (which carry
unusually good doc comments — the codebase's convention, not mine) resolves
most of the "does this survive a skip" questions the field names alone would
leave open. The one I could **not** resolve by reading alone is generics.

---

## 3. Generic instantiation — the hard one, read in detail

**Read:** `requestRoutineInstance` (`sem.nim:640-727`) is called from body-
level call matching. It keys on `c.instantiatedProcs[(origin, key)]`
(`sem.nim:643`, `key = typeToCanon(typeArgs, 0)`) — **a table that is empty at
the start of every compile of every module** (it lives on `SemContext`,
constructed fresh per module per process, `initSemContext`,
`semmain.nim:299-...`). So today, **every single compile of a module that
uses a generic re-instantiates and re-semchecks that generic's body from
scratch**, even on a completely unchanged rebuild of that module — this is
not new inefficiency B3f would introduce; it is the status quo. The symbol
minted (`newInstSymId`, referenced at `sem.nim:672`) is
`<basename>.I<hash-of-typeargs>.<mod>` where `<mod>` is **the module doing the
instantiating**, not the generic's origin module. This is exactly why the
DCE ownership rule exists (`src/hexer/dce2.nim:20-52`,
`prefersOffer`/`resolveSymbolConflicts`): two modules that each call
`Table[int,int].get` each mint their own, differently-suffixed copy, and DCE
picks one canonical survivor after the fact. **This is read, not inferred —
the comment at `dce2.nim:24-40` states the rationale directly** ("the main
module never owns a symbol another module also offers... letting it win
would make a shared module's `.c.nif` depend on which main it happens to be
linked with").

**What happens to `c.procRequests` when the body that would have requested an
instantiation is skipped — this is inference, clearly marked:**

If declaration D's body is skipped, `requestRoutineInstance` never runs for
whatever D would have called, so `c.procRequests` never receives that entry,
and `instantiateGenerics` (`sem.nim:521-526`) never emits that instantiation
into `dest` for **this compile**. Two consequences:

1. If some OTHER still-checked declaration in the same module also demands
   the same `(origin, key)`, the instantiation is emitted anyway (by that
   declaration's own request) and D's skip cost nothing semantically — this
   is the common case for widely-used generics like `Table`/`seq`.
2. If D was the ONLY declaration in the module demanding that instantiation,
   skipping D's body silently drops the instantiation from this compile's
   `.s.nif`. Nothing downstream would complain locally — hexer/arkham never
   see a symbol they expected, because the *previous* compile's `.s.nif` is
   what is being spliced from, and the previous compile DID contain it. The
   danger is specifically at the digest/replay boundary: a correct B3f cannot
   just skip D's `semStmt`; it must **replay** D's previously-recorded set of
   `(origin, key) -> targetSym` instantiation demands into `c.procRequests`
   (or splice their previously-checked `.s.nif` fragments directly) so that
   `instantiateGenerics` still produces the same output this compile that it
   produced last compile. This is not optional — it is the generics
   analogue of B3e's "a spliced proc still owes the module" (rodata names,
   divider flags, `notes/b3e.md` §3.4) and it is **new mechanism sem does not
   have today**: nothing currently persists "which instantiations did this
   declaration demand" across compiles, because nothing currently needs to
   know that (every compile re-derives it from scratch).
3. Building that replay mechanism cheaply (i.e., without re-running
   `instantiateGenericProc`'s substitution+semcheck, which is exactly the
   cost we are trying to avoid) requires a NEW per-declaration cache: for a
   given `(origin, key)` demanded by an unchanged declaration D in an
   unchanged module, is the *previously checked* instantiation's `.s.nif`
   text still valid, keyed on the origin declaration's own current sem-input
   digest (already available, F1's `decldigest.nim`) plus a digest of the
   type arguments? If valid, splice the bytes; if not, fall back to full
   instantiation. **I did not find any existing sem-side infrastructure for
   this** — F1/F2/B3d/B3e all built per-declaration digest+splice machinery
   for exactly one kind of artifact each (sem-input locals, hexer lowering,
   asm-NIF, arkham's Leng-to-asm step); sem doing it for generic
   instantiation would be a fifth instance of the same pattern, but for the
   one place in the pipeline where the "declaration" being spliced is
   **synthesized on demand rather than written by the user**, which is new
   in kind, not just in file.

**Net assessment on generics, honestly:** this is buildable in the B3e idiom
(digest the demand, splice the previously-checked answer, fall back to full
instantiation on a miss) but it is genuinely the piece with no direct
precedent on this branch, and it is on the critical path for correctness, not
an optional refinement — skip it and B3f produces wrong `.s.nif` on the first
module where an instantiation's sole requester goes stale.

---

## 4. The key, in B3e's shape

Following `notes/b3e.md` §3.2's structure (context digest = build id + target
+ every non-proc declaration + every proc signature + the ANSWERS of
whole-body analyses), a sound per-declaration sem-skip key would need, at
minimum:

- the declaration's own sem-input digest (**already built**, F1's
  `decldigest.nim` / `<mod>.decls.nif`, one entry per declaration,
  `digestToplevel`, `decldigest.nim:150`);
- the sem-input digest of every declaration it named (an intra-module "what
  did this body read" map — **not built**; B3e's cross-module analogue,
  `Program.foreignDecl`/`procReads` per-proc read attribution,
  `notes/b3e.md` §4, is the closest precedent, but it is nativenif/arkham
  code operating on asm-NIF with no `pool`/`globalTags` globals, and would
  need a same-module equivalent built fresh against nimony's `nifprelude`
  layer);
- the module's imports and their stamps, at minimum, plus (per B3d/B3e's
  cross-module rule, `notes/b3d.md` §3.3, `notes/b3e.md` §4) the specific
  foreign declarations this body actually named, so a stamp move on an
  imported module does not drop the whole module's cache — same "stamp
  first, then per-reference" two-level check both prior phases used;
- **whole-module answers a body edit can change, the B3e-cautionary-tale
  slot.** I looked for sem's equivalent of `noReturnProcs`/`cleanSigProcNames`
  (a function computed by walking every body, whose ANSWER other
  declarations' correctness depends on) and did not find an exact analogue
  inside phase 3 itself — sem's per-body work does not currently feed a
  fixpoint back into a shared answer the way hexer's `funcsummary`
  (`annotateFunctionSummaries`) or arkham's `noReturnProcs` do. The closest
  candidates, and why each is not quite that shape:
  - `c.genericInnerProcs` (§2 above) is accumulated, not analyzed to a fixed
    answer, but its **consumer** (`reorderInnerGenericInstances`) is
    whole-module, so it is a "the set matters, and the set is built from
    every declaration" hazard even without being a fixpoint.
  - Generic instantiation identity (§3) is the real equivalent of B3e's
    finding: it is a per-declaration DEMAND whose satisfaction is
    module-wide (satisfied by whichever declaration asks first), so a skip
    can silently starve the module of something only the skipped
    declaration would have asked for. This is B3f's version of "a body edit
    can change another proc's frame" — here it is "a body's ABSENCE (from
    the check) can change whether an instantiation appears at all."
  - I explicitly checked whether `attachSpecialProc`'s hook/converter/method
    registration (the nearest thing to a "signature that is secretly a
    function of the body") has the same shape as hexer's `(smry ...)` bug
    B3e found (`notes/b3e.md` §3.3) — it does not, because it runs in phase 2
    (signatures), which this design does not skip, so it cannot be a
    function of a SKIPPED body. This is the one place I actively looked for
    B3e's exact failure mode recurring and did not find it recurring — noted
    so a future reader does not have to re-check it.
- arkham's build-id-equivalent for sem: the sem-checking tool's own version/
  feature-flag stamp, so a toolchain upgrade cannot be mistaken for "nothing
  changed" (same class of risk B3e records at `notes/b3e.md` §8, "arkham's
  build id is CompileDate/CompileTime").

---

## 5. Per-field hazard table

| field (`semdata.nim`) | dies with the declaration | accumulates, must be replayed | counter needing per-decl scoping | note |
|---|---|---|---|---|
| `procRequests`, `instantiatedProcs`, `typeInstDecls` | no | **yes — the hard one** | n/a | § 3. No existing cache; needs a new digest+splice mechanism keyed on origin digest + type-arg digest |
| `genericInnerProcs` | no | yes, whole-module consumer (`reorderInnerGenericInstances`) | n/a | small set; replay by re-including the skipped decl's own known membership if recorded |
| `freshSyms` | believed yes (same-run consumer only) | — | n/a | **unsettled**: did not trace every reader exhaustively |
| `typeHooks`, `converters`, `converterIndexMap`, `classes` | — | populated in **phase 2**, not phase 3 | n/a | **safe as long as phase 2 stays unmodified**: `attachSpecialProc` runs from the routine's header before the `case pass` split (`semdecls.nim:1148-1163`) |
| `pendingSumtypes` | scoped to the owning `type` decl, believed | — | n/a | type-section-triggered, not general-body-triggered, but not exhaustively traced |
| `toBuild`, `toBundle` | — | populated by pragma processing on the header (phase 2, effectively) | n/a | same status as hooks: not a body-skip hazard |
| `exports` | — | populated at import/export statements, not per-body | n/a | not a hazard |
| `templateInstCounter` | yes, already save/restore per call | — | already scoped | not a hazard |
| `usedTypevars` | yes, delta read within one type's own check | — | already scoped | not a hazard |
| `fieldCounts` | yes, explicitly save/restored per object type (doc comment, `semdata.nim:186-192`) | — | already scoped | precedent: this field already does what F1 did for locals, one level up, before F1 existed |
| locals / `c.locals`, `localNs` | yes, F1 already made this per-declaration | — | done (F1) | `notes/f1.md` — cited by the assignment as precedent, confirmed by reading `semdata.nim:170-183`'s doc comment, which explicitly names `notes/f1.md` |
| `matchedForwardDecls`, `forwardDecls` | phase-2 scoped (forward-decl matching happens in `pass == checkSignatures`) | — | n/a | not a phase-3 hazard |
| `deferredLocals`, `onDemandResolved` | explicitly documented as phase-2 → phase-3 handoff, cleared per-module at defined points (`semdata.nim:376-391`) | — | n/a | already carefully scoped by the existing code; a skip of phase 3 for one declaration must not disturb another declaration's use of these tables, and I did not verify this interaction in code, only read the intent from the comments — **unsettled** |

Fields the assignment named that I did not find independent evidence of a
distinct hazard for beyond what is captured above: `pending`. I read
`c.pending` (`createTokenBuf()`, no direct writer/reader pair found in the
files I read within budget) as likely a staging buffer analogous to hexer's
`c.pending` in `notes/b3b.md` §2 ("first-use ownership" pattern) but **did
not** locate its write sites in `sem.nim`/`semdecls.nim` within this
investigation's time budget — flagged unresolved rather than guessed.

---

## 6. The gate

Following the branch's existing byte-identity idiom exactly
(`hastur boot --boot-backend:native` stages 1==2==3, `tests/ctfe_diff` 0
differences, `decl-stability`'s per-declaration digest assertions), the sem
analogue would be:

- **`.s.nif` byte-identical** between a skip-enabled run and a full run, for
  every one of the cache states B3e's own self-test enumerates
  (`notes/b3e.md` §5): no cache / empty cache / warm cache / input
  reformatted (position-only change) / every sibling module restamped /
  every possible single-declaration-invalidated position (first, last,
  alternating, all) / a second run against a partially-spliced sidecar. A
  `decl-stability`-style scenario extended with a **generic-instantiation**
  edit shape specifically (change a generic's only caller) is the one B3e's
  own corpus does not need and B3f's does, per §3.
- **`instantiateGenerics`'s output set** (the syms actually emitted into
  `dest` after phase 3) must be identical between the two runs — this is
  strictly stronger than "`.s.nif` bytes match" in the failure mode that
  matters (a missing instantiation is a *smaller* file, which a naive byte
  digest of "did anything change" could miss if the digest is keyed
  per-declaration rather than validated against a manifest of "which
  instantiations exist").
- `hastur tests/nimony`, `tests/incremental`, `tests/ctfe_diff` green, same as
  every prior phase; `hastur boot` byte-identical (this is the strongest
  practical oracle available, since the compiler is by far the largest,
  most generic-instantiation-heavy self-hosted corpus on this branch).
- A new fallback flag in the family already established (`--no-blobcache`,
  `NIMONY_ARKHAMCACHE=off`, etc.): `NIMONY_INCSEM=off` / `--no-incsem`
  forcing full re-check, so the mechanism is provably inert when disabled and
  every existing gate can be re-run against it as a sanity check the way
  B3e's refactor gate proved the cache "never passes" when off
  (`notes/b3e.md` §5, "the check that the cache is inert when it is off").

---

## 7. Effort and risk, honestly

Sized in the idiom of the other phases:

- **F1/F2 precedent**: each was "measured, then a real branch, ~1 nimony
  branch, several commits, one nativenif-independent" (`notes/f1.md`,
  `notes/f2.md`), each solving ONE counter-scoping problem the previous
  attempt's measurement exposed.
- **B3e precedent**: "~1 nativenif branch, several commits", 651 self-test
  checks, and it still needed two follow-up fixes after the first working
  version (`(smry...)` exclusion, the read-index numbering bug, both found by
  measurement rather than by design review — `notes/b3e.md` §3.3, §4.2).
- **B3f is at minimum three of these, stacked, on a harder surface**: (a) the
  stage-timer instrumentation (§1, small, hours); (b) the intra-module "what
  did this body name" dependency map (§4, comparable to B3e's §4
  cross-module per-reference tracking, but INSIDE one module, which B3e
  explicitly did not have to solve — its per-module context digest treats
  same-module signature changes as invalidating everything, `notes/b3e.md`,
  "Risks", "a signature change still lowers the whole module"); (c) the
  generic-instantiation replay/splice mechanism (§3), which has no existing
  precedent anywhere in this codebase's incremental work and touches
  correctness directly (a miss is a missing symbol downstream, not a slow
  path). Each of (a)-(c) is independently roughly F1/F2-sized; this is not a
  one-branch phase.
- **What could make it not worth doing:**
  - If §1's instrumentation shows phase 3 + post-processing is a small share
    of 0.426 s (say, under a third), the entire phase buys little — this is
    explicitly unsettled and should be checked FIRST, cheaply, before any of
    (b)/(c) is attempted, exactly as the assignment frames it.
  - `self.editbody`'s own history on this branch (`notes/b3b.md` §10, "on
    this tip `self.editbody` costs arkham 0.000 s... its appended proc is
    private and dead") is a standing warning that the benchmark used to
    justify a phase can measure the wrong thing; any B3f gate must be stated
    on an edit that actually reaches phase 3's cost (a body EDIT to an
    existing, called, exported proc — not an appended dead one), and ideally
    on one that also exercises a generic-instantiation edge, which none of
    the current benchmarks do.
  - The generic-instantiation replay mechanism (§3) is a new correctness
    surface with no fallback-free proof it is exhaustive; every prior phase
    on this branch (F1, F2, B3d, B3e) found at least one subtle miss during
    implementation that a design review did not catch (F1's `hoistedConsts`,
    B3e's `(smry...)` exclusion and the index-numbering bug). There is no
    reason to expect B3f to be the first phase to get it right on paper, and
    the cost of getting it wrong here is a **silently incorrect compile**,
    not a slow one — worse than any prior phase's failure mode, because a
    stale asm/hexer splice degrades to "re-lower the whole module" on a
    cache miss, while a missed generic-instantiation replay produces a
    module that compiles and links wrong.
  - Sem is also the module the project's own contributors touch most often
    (it is the file this whole benchmark is stated on); a phase that makes
    THIS module's own correctness harder to reason about has a higher cost
    of a bug landing than the same bug in arkham or nifasm, which fewer
    people read.

---

## 8. What it would actually save — realistic floor

Anchor, read directly: hexer's measured floor after full instrumentation is
**112 ms of its 0.27 s, with zero declarations lowered** (`notes/b3b.md`
§10) — i.e. even a hypothetically perfect declaration-level hexer could not
go below ~112 ms on `sem.nim`, because ~89 ms of its cost is whole-module
analysis (`funcsummary`, `intraModuleInline`, serialize) that does not
decompose per declaration, plus I/O.

For nimsem, by the same reasoning and **without a measured split (§1
unsettled)**: phase 1 (near-zero, structurally), phase 2 (full-module,
unavoidable under this design since only phase 3 is proposed to be
skippable), the write/parse I/O, and the generic-instantiation replay cost
(not zero — even a "hit," under the design in §3, still needs a digest
lookup and a splice, and a "miss" pays the FULL instantiation cost, which for
a proc with several call sites of a widely-used generic could still be a
sizeable fraction of phase 3) all persist regardless of how many bodies are
skipped. **If phase 3 + post-processing turns out to be, say, 60-70% of
0.426 s** (a guess, explicitly not a measurement, by weak analogy to hexer's
63%), and a live edit touches one declaration whose neighbors are otherwise
unchanged, the realistic floor is **phase 1 + phase 2 + I/O + the unavoidable
per-declaration overhead of digesting and splicing every OTHER declaration**
— which, again by analogy to hexer's own experience that a "prefix-preserving
splice" and "zero counter interaction" turned out to be false in practice
(`notes/b3b.md` §11, "the prefix theorem is false"), could easily be **most**
of the 0.426 s rather than a small fraction of it, unless nimsem's own
per-declaration state turns out to be cleaner than hexer's was. **The one
comparison that IS available and directly relevant: F1 alone — which did
NOT touch phase 3's cost at all, only made phase 1's output declaration-
stable — cut `self.editbody`'s wall time 44% (`notes/f1.md` §7,
"1.209 → 0.703 s wall... −44%, from the prerequisite alone") purely by
letting arkham/nifasm's ALREADY-BUILT caches actually hit.** That number has
nothing to do with skipping sem's own work; it is what became available once
sem stopped *forcing* hexer/arkham to redo everything downstream. It is a
strong argument that the marginal value of ALSO skipping sem's own body
checks, on top of everything else this branch has already built, is smaller
than intuition from the original 0.426 s figure suggests — because a good
chunk of what nimsem's cost represents today is producing a `.s.nif` that,
once F1/F2 made it declaration-stable, downstream tools already know how to
reuse without nimsem's help. **This should be checked (§1) before deciding
the phase is worth building at all — the value of skipping nimsem's own work
may be much smaller than 42% suggests, precisely because the other 58%
(hexer/link/arkham/dceEmit) has already been attacked and the remaining
1.05 s loop's cost STRUCTURE may not look like the original profile once
nimsem is instrumented the same way.**

---

## 9. Reasons not to do this (explicit section, as requested)

1. **Unsettled value.** §1's split is the single most important open
   question and it is cheap to close; closing it might show the phase is not
   worth its risk before any design work starts.
2. **New correctness surface with the worst failure mode on the branch.**
   Every prior phase's cache-miss failure mode is "slow, not wrong" (full
   re-lowering, full re-linking). A missed generic-instantiation replay is a
   *wrong* compile that still produces output — the digest/splice mechanism
   for §3 must be proven, not just gated by a flag, before this is safe to
   default on.
3. **No existing precedent for the hardest sub-problem.** §3's generic
   replay is new in kind, not just in file, unlike F1/F2/B3d/B3e which each
   applied an already-proven pattern (per-declaration digest + splice) to a
   new tool. There is real risk the ordered-prerequisites list this memo
   implies (stage timer → intra-module dependency map → generic replay) is
   itself incomplete, the same way B3b's first attempt's own prerequisite
   list was revised twice (§7/§14 of `notes/b3b.md`) after each measurement.
4. **It touches the file everyone touches.** `sem.nim` is the benchmark's own
   edit target and the project's most-edited file; a correctness bug in its
   own incremental-checking logic is higher-cost than the same class of bug
   in arkham or nifasm, which most contributors never read.
5. **The marginal win may already be partly banked.** §8's F1-alone number
   (44% off `self.editbody` without touching sem's own body-check cost at
   all) suggests some of what looked like "sem is 42% of the loop and
   nobody has attacked it" was, before F1/F2, actually "sem's OUTPUT
   instability was forcing 100% re-work downstream" — a problem this branch
   already solved from the other end. What is left once that is accounted
   for might be a smaller number than 0.426 s suggests, and only the §1
   instrumentation can say how much smaller.
6. **Owner's own framing.** `JIT_IMPL.md:710-712` already calls this "outside
   JIT.md's... scope" and "the only lever left" — i.e., it was already being
   proposed only because everything ELSE cheaper had been done, not because
   it was independently the best next investment. This memo's own findings
   (§8) suggest the "only lever left" framing may understate how much of the
   original 0.426 s was already indirectly addressed by F1/F2's declaration-
   stability work, which this memo recommends re-measuring before deciding.

---

## Summary table for `JIT_IMPL.md`

| phase | status |
|---|---|
| B3f | **not measured in detail, not built.** §1's phase-level split inside nimsem is the prerequisite everything else depends on and is cheap (stage-timer instrumentation, hours, same idiom as `passes.StageTimer`). Generic-instantiation replay (§3) has no existing precedent and is the hard, correctness-critical part. Gate: `.s.nif` byte-identical to a full run across B3e's eight cache states plus a generic-instantiation-specific edit shape, `instantiateGenerics`'s emitted-symbol set identical, `hastur boot` byte-identical, `NIMONY_INCSEM=off` fallback. Estimated size: at least three F1/F2/B3e-scale efforts stacked, not one. Recommend measuring §1 before scoping further. |

---

## What I read vs. inferred vs. left unsettled — index

- **Read directly, with citations given inline throughout:** the three-pass
  structure and its guards (§1), the field declarations and their doc
  comments in `semdata.nim` (§2), `requestRoutineInstance` and the DCE
  ownership rule (§3), F1/F2/B3d/B3e/H1's own notes (throughout), the ledger
  and pass-timing infrastructure's actual granularity (§1).
- **Inferred, explicitly marked each time:** the likely majority-share of
  phase 3 in nimsem's total cost (§1, by weak analogy to hexer, explicitly
  not trusted as a number); that `freshSyms`/`pendingSumtypes` are safely
  same-run-scoped (§2, not exhaustively traced); the realistic floor
  estimate (§8, explicitly hedged both directions).
- **Left unsettled, with what would settle it stated:** nimsem's internal
  phase-level cost split (§1 — needs a `passes`-style stage timer, a small
  instrumentation commit, not a heavy build); `c.pending`'s writers/readers
  in sem (§5, not located within budget); whether `deferredLocals`/
  `onDemandResolved`'s phase-2→phase-3 handoff interacts safely with a
  partial-skip of phase 3 (§5).
