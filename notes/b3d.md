# Phase B3d — per-symbol blob validity in nifasm, per-proc naming in arkham

Research and implementation notes per `JIT_IMPL.md`'s "Execution rules for
agents" rule 3. Worktree branch `jit/b3d`, forked from `fast-devloop`
(`cbf7b0ec`, everything through F2). nativenif is a private clone at
`/tmp/b3d/nativenif`, branch `jit/b3d-native`, forked from the pin `c3f27fc`;
its two commits are `259f7be` (nifasm) and `7b838ec` (arkham).
Numbers in `bench/results/2026-09-07/b3d.txt`.

The phase is one sentence: **F1 and F2 made the frontend's output a function of
the declaration it belongs to; B3d does the same for arkham's output and for
nifasm's notion of what a cached fragment depends on.**

---

## 1. The measurement this starts from

`bench/devloop_ab.sh`'s live edit (a statement inserted into `semStmt`'s body in
`sem.nim`), on a copy of `/tmp/devloop_base/src`, rebuilt with `--profile` and
`NIFASM_PROFILE=1`. Medians of three rounds; round 1 is the first edit after a
cold build (the only one where the whole-program live set moves, so `dceLive`
runs), rounds 2–3 are the steady state.

| stage | before (pin `c3f27fc`) | after (this branch) |
|---|---|---|
| nimsem | 0.334 | 0.337 |
| hexer | 0.271 | 0.273 |
| dceEmit | 0.051 | 0.053 |
| dceLive (round 1 only) | 0.357 | 0.356 |
| arkham (3 invocations) | 0.259 | 0.258 |
| **link (nifasm)** | **0.320** | **0.124** |
| nifasm `--profile` TOTAL | 312 / 303 / 318 ms | 116 / 117 / 116 ms |
| **`blobHits` / `blobStale` / `blobRecorded`** | **3415 / 18 / 627** | **4024 / 18 / 18** |
| wall, round 1 | 1.274 s | 1.077 s |
| wall, rounds 2–3 | 0.904 s | 0.721 s |

`notes/f2.md` §5 predicted exactly this starting point and named it as B3d's:
"nifasm still records 627 (per-module validity)".

---

## 2. Why 627, and the measurement that reframed the phase

`blobcache.sameSource` validated a fragment against its MODULE's file stamp, so
sem's `.asm.nif` changing at all dropped every fragment whose symbol lives in
sem. The brief's model was that after F2 the module barely changes, so
per-symbol validity would take 627 to ~3.

It does not, and the reason is arkham. Measuring the two `.asm.nif` corpora
directly — the asm-NIF carries no line information, so a declaration's raw bytes
ARE its identity and the embedded `(.index …)` gives every declaration's byte
range — the live edit changed **434 of sem's 974 asm-NIF declarations**, against
the 3 that hexer's `.decls.nif` sidecar reports.

Masking one name family at a time says where the other 431 came from:

```
mask none                       changed  434 of 974
mask `L<n>                      changed  255
mask + `aggtmp<n>/`nctmp<n>     changed    3
```

The three residuals are `semStmt` itself and the two procs
`intramodinliner` splices it into — F2's answer, unchanged.

So the ORDER in the brief is the reverse of the dependency: nifasm's
per-declaration validity cannot pay while arkham's names drift. Both were built;
the note keeps the brief's numbering because the commits do.

### The two counters, and why neither has to be module-wide

* **`CodeGen.labelCount`** ran for the whole module (`` `L<n>.0 ``). nifasm
  scopes a `(lab …)` to the proc that declares it — `pass2.collectLabels`
  defines into the proc's own scope, entered per `pass2Proc` — so these names
  never needed module-wide uniqueness. The AVR backend has restarted the counter
  per proc since it was written; x64 and risc did not.
* **`` `aggtmp<pos> `` / `` `nctmp<pos> ``** are named from the TOKEN POSITION of
  the expression that needs the temp (`cursorToPosition`). Unique, but
  module-relative: one token added anywhere above renames every temp below it.
  Subtracting the enclosing proc's own start position makes the number
  proc-relative and just as unique — `planer.nim:1378` already computed the same
  `procStart` for its `LocSpan` window, so the quantity was there.

`core/context.nim` gained `CodeGen.procBasePos` and `CodeGen.enterProc`, the one
place that says what "per proc" means for an arkham-minted name. It is called at
the TOP of each backend's `genProc`, ahead of the `{.assembler.}` early return:
an asm proc is a proc too, and leaving it on the previous proc's base would make
anything it mints depend on what came before it.

Result on the same edit: **434 of 974 changed declarations → 3**, and the other
126 modules are byte-identical as before.

---

## 3. Per-declaration validity in nifasm

### 3.1 The identity, and why it is free here

`src/nifasm/core/asmdecls.nim`. The measurement that decides the design is that
**asm-NIF carries no line information** — `grep -c '@'` over the whole 54 MB
compiler corpus is 0, because arkham builds its output with the enum builder and
never attaches a line-info token. So a declaration's raw bytes are already the
line-info-blind identity that `src/hexer/decldigest.nim` has to construct by
masking, and the module's embedded `(.index …)` — which records every global
`SymbolDef` at the byte offset of its declaration's `(` — gives the ranges for
free. One pass over the file digests all of them.

Everything between the directives and the first indexed declaration (`(stmts`,
`(arch …)`, the `(imp "…")` lines) belongs to no declaration and is folded into
EVERY declaration's digest, so one comparison answers the whole question. The
`(.nif27)` header and the `(.indexat N)` directive are deliberately outside it:
the offset that directive carries moves whenever anything above the index
changes, which would make the preamble differ for every edit and defeat the
mechanism.

The digest is a 64-bit content hash with the range's length mixed into the seed,
not SHA-1: `notes/b3.md` §3.2 measured 60–86 ms for SHA-1 over this corpus and
that is a third of the budget the whole incremental link has. Measured cost of
this one: **21 ms for all 127 modules**, and it is only ever paid for a module
whose stamp moved.

### 3.2 Why nifasm computes this and arkham does not hand it over

The brief proposes a `<mod>.asm.decls.nif` sidecar written by arkham as it
emits. It would be cheaper — arkham already holds the text — and it was
rejected on soundness. A sidecar is a SECOND source of truth for the same
bytes, and the failure mode of the two disagreeing (a stale sidecar beside a
rewritten module; a module produced by anything but that arkham run; a
hand-reindexed fixture) is a fragment declared valid that is not: a wrong image,
silently, with nothing to catch it. A digest taken from the very file the
assembler reads cannot disagree with that file.

The price is one `readFile` and one hash per module whose stamp moved — 2 ms for
the compiler's largest module against the ~160 ms of re-emission it saves — and
21 ms once on a cold link, which is inside the phase's ≤ +10 % gate with room to
spare (§5). It also means **the nimony side needs no change at all**: no new
artifact in the build graph, no new node output, nothing in `deps.nim`. That was
not the goal, but it is the right shape.

### 3.3 What a fragment now depends on

Three checks, of which the first two are new:

1. **its own declaration.** The module's stamp is still asked FIRST — an
   untouched file answers for all of its declarations at once and costs one
   `stat`, which is what keeps the steady state at 127 `stat` calls and no
   reads. Only a module whose stamp moved is read and digested, and then THIS
   declaration's bytes are compared.
2. **every declaration it NAMED.** A reference's emitted bytes depend on the
   referent's declaration — a callee's signature (the caller's argument setup),
   a foreign type's layout, an `extproc`'s library — and all of those are
   declarations. Each recorded reference therefore carries the digest of the
   declaration it resolved to, beside `RefRole.stamp`, which already covered the
   layout facts no file hash can see (`notes/b3.md` §3.2, check 3).

   This SUBSUMES B3's per-module `deps` list: every declaration read goes
   through `resolveForeignSym`, whose only caller is `lookupWithAutoImport`,
   which is also where a reference is recorded — so a module that can be
   digested needs no coarse dependency. One that cannot (no index, a binary
   module) keeps the whole-file check it always had, and the recorder puts it in
   `f.deps`. The failure mode is a colder cache, never a wrong image.
3. **every type it named still has the layout it had** — `RefRole.stamp`,
   unchanged.

A reference whose name is in no declaration of its module — nifasm's own trace
table and TLS-size cell — records `declMod = -1` and depends on nothing, which
is what it did before this phase too. Every declaration IS indexed (974 index
entries for sem's 975 top-level nodes; the odd one out is `(arch arm64)`), so
"absent from the index" really does mean "synthesized".

### 3.4 The one that took a second measurement: `dirtyModule`

With all of the above in place the count went 627 → **546**, not 18. The cause
is not validity at all:

`dirtyModule` threw a module's whole blob away as soon as its stamp had moved,
so the FIRST re-emitted proc of an edited module emptied the blob and every
later proc of it then missed at `m.index.hasKey(name)` — a plain miss, not even
counted as stale — instead of being asked whether its own declaration had
changed. (That is also why the old `blobStale 18` never read 627: 627 fragments
were recorded but only the first per module was ever CLASSIFIED.)

The fix makes a blob hold fragments of two versions of one file at once: each
fragment names the module VERSION it was recorded against (`ownMod`, an index
into the blob's module table, which `moduleSlot` matches on name AND stamp), so
each answers for itself. `flush` prunes the ones that can never be replayed
again, which is the job `dirtyModule`'s wholesale reset used to do.

That is the new hazard this phase introduces, and it is what the ninth state of
the image identity check in §4 exists for.

Result: **627 → 18**. The 18 are the 3 changed declarations and 15 fragments
that NAME one of them. That last part is honest over-invalidation: a caller
depends on its callee's SIGNATURE, and the digest covers the whole declaration,
body included. `core/declhead.nim` already knows where a proc's head ends, so
recording a second digest per proc — head for references, whole for the
fragment's own declaration — would take 18 to ~3. It was not built: 15 fragments
are ~5 ms, and it doubles the digest schema.

---

## 4. Byte identity

* **`tests/blobcache_selftest`**, all nine states over three corpora:
  234 macho + 237 elf + 87 raw, all equal. `nim r tests/tester.nim` green end to
  end, including 234 + 233 memory-image checks and 230 + 230 arkham/nifrun
  tests.
* **The 127-module compiler image**, nine states, all linked to ONE output path
  (macOS ad-hoc `codesign` derives the signature identifier from the output
  file's basename — `notes/b3c.md` §0):

```
before, scratch          94a2c53961d8ef63
before, cold populate    94a2c53961d8ef63
before, warm all hits    94a2c53961d8ef63
before, warm whole-decls 94a2c53961d8ef63
after,  scratch          ac8aac92f3459605
after,  from stale cache ac8aac92f3459605
after,  warm again       ac8aac92f3459605
before again, from mixed 94a2c53961d8ef63     <- the §3.4 hazard
before, scratch again    94a2c53961d8ef63
```

  The eighth line is the one that matters: the blob at that point holds
  fragments recorded from BOTH versions of `semygjvq21.asm.nif`, and the link
  that reads it produces the same bytes as a from-scratch link of the older
  corpus.
* **`tools/refactor_gate.sh`** against the `c3f27fc` baseline (2583 artifacts,
  774 listings): **byte-identical after the nifasm commit**. After the arkham
  commit, 137 of 2583 artifacts and 78 of 774 listings differ — all of them
  arkham's asm-NIF text and the listings that render its names, and **no
  assembled image hash changed at all**, which is the point: a label's spelling
  is not machine code. No fixture changed its exit code or its diagnostic.
* **`hastur boot --boot-backend:native`**: stages 1 == 2 == 3 (47.0 s).
* **`tests/nimony_r`**: "a cached link and a scratch link produce
  byte-identical executables" still passes.

## 5. Cost on a cold link

Same corpus, `nifasm` driven by hand over the 127 modules in the build graph's
order, `--profile` totals, release builds:

| link | pin `c3f27fc` | this branch |
|---|---|---|
| from scratch, no cache | 891.9 ms | 855.9 ms |
| cold, empty cache (records 4042) | 917.6 ms | **949.0 ms** (+3.4 % over scratch) |
| warm, nothing edited | 78.5 ms | 78.5 ms |
| warm, `sem.nim` edited | 433 ms (627 recorded) | **119 ms** (18 recorded) |

The cold delta is `blobDigest` 21.7 ms plus ~36 ms of `blobRecord` (a digest
lookup per recorded reference). Gate: ≤ +10 %. The warm-unedited column is
unchanged to the millisecond, which is the property that matters most — the
steady state does not read a single module.

Blob store: 7.6 MB → 8.8 MB (+16 %), for the per-reference declaration digests.

### One trap worth recording

`tools/refactor_gate.sh` rebuilds `bin/arkham` and `bin/nifasm` in DEBUG unless
`SKIP_BUILD=1`, and so does `tests/tester.nim`. A debug `nifasm` links this
corpus in 9.1 s instead of 0.86 s — an 11× difference that looks exactly like a
catastrophic regression if the binary is then copied into a toolchain `bin/`.
Both arms of the gate see the same debug build so the gate itself is unaffected;
what is affected is anything measured afterwards.

---

## 6. arkham per-proc splicing: measured, NOT built

The naming half of the brief's step 2 is done and is what makes everything above
pay. The SPLICING half — arkham replaying an unchanged proc's asm-NIF instead of
re-lowering it — is not built, and the measurement says the gate as stated
(`arkham ≤ 0.05 s`) is not reachable by splicing the emission alone.

A temporary probe around `generateA64Buf` (built, measured, reverted), arkham
over `semygjvq21.c.nif` on this machine, median of two:

```
[arkham probe] collect 1 ms, procs 139 ms (526 procs), rest 0 ms
total process: 196 ms
```

So of arkham's 196 ms for the compiler's largest module:

* **139 ms is the per-proc emission** — what a splice removes;
* **~56 ms is the parse of the 4.6 MB `.c.nif` and the serialization of the
  10.7 MB `.asm.nif`**, neither of which a per-proc splice touches;
* 1 ms is `collect` (the whole-module program model), which is not the problem
  anyone expected it to be.

And the splice is not free: the previous `.asm.nif` for the 523 unchanged procs
has to be read back into tokens, which at `loadParse`'s measured ~333 MB/s is
~30 ms for 10.7 MB unless the cache is stored as `bif` (resident, `addSubtree`
from an mmap). Realistically arkham's 196 ms → ~90–110 ms, i.e. **the same shape
of answer `notes/b3b.md` §10 reached for hexer**: the decomposable part is worth
having and the floor is set by the parse and the serialize, which have to become
incremental too (per-declaration byte offsets in the sidecar, splicing TEXT) for
the number to reach 50 ms.

What such a cache has to model, if someone builds it — this is the part the
measurement above does not show and the reason it was not attempted under time
pressure:

* **the key.** The proc's own `.c.nif` declaration with line info masked (arkham
  would need its own `decldigest`, since `src/hexer` is not this phase's), plus
  a digest of everything else the emission reads: every `(type …)` and
  `(gvar …)`/`(tvar …)` of the module, every foreign module's `.c.nif` identity,
  the target, and arkham's own build id. Anything left out of that set is a
  silent miscompile, exactly as `notes/b3b.md` §11 argued about hexer's
  counters.
* **the state a spliced proc must still contribute.** `genProc2` appends to
  `CodeGen.rodata` (module-level string literals, emitted after the bodies) and
  can set `needsUDiv64`/`needsSDiv64` on the firmware targets. A fragment has to
  carry that delta, the way `blobcache.Snapshot` carries nifasm's — and
  `unmodelled`'s discipline (refuse to record a fragment whose deltas are not
  modelled) is the pattern to copy, so a future arkham change costs hit rate
  rather than correctness.
* **the gate.** arkham run twice over the whole compiler corpus and the 230
  arkham fixtures, with and without the cache, `.asm.nif` byte-identical. That
  is mechanizable and should exist before the cache does.

Where the wall clock would go: the backend graph's critical path on the steady
state is `arkham 0.258 → link 0.124`, which is the 0.383 s the profile reports
as the backend wall. arkham at ~0.10 s would take that to ~0.22 s and the whole
edit to ~0.56 s.

## 7. `dceLive`, and what an incremental live set would need

`dceLive` costs 0.356 s and runs on the FIRST rebuild after any edit that
changes a module's `.dce.nif`; rounds 2 and 3 of the same edit do not run it at
all (P0c's `OnlyIfChanged` on `<M>.live.nif`), which is why the steady-state
wall is 0.72 s and the first-edit wall is 1.08 s. It is now the largest single
stage of that first rebuild after `nimsem`.

It re-runs the WHOLE-program live set when one module's `.dce.nif` changed. What
an incremental version needs, recorded here because nothing in the plan owns it
and it is hexer's, not this phase's:

* the live set is a fixpoint over the call graph, so the incremental question is
  "which symbols' reachability can this module's delta change" — the answer is
  the symbols the changed declarations name, plus their transitive callers
  through the ALREADY COMPUTED graph;
* that means `dceLive` has to persist the graph it walked, not just the answer.
  P0c already writes one `<M>.live.nif` per module with its resolve subset; the
  edge set behind it is what is missing;
* F1/F2's `<mod>.decls.nif` gives the per-declaration delta to seed it with, so
  the input side is ready. This is `notes/b3b.md` §14 step 3's shape applied to
  the analysis rather than the lowering.

## 8. Risks and what is left

* **The digest is 64 bits, not a cryptographic hash.** A collision between two
  versions of one declaration is a wrong image. The same trade is already made
  by the module STAMP (a file rewritten to the same byte count within the same
  nanosecond), and 64 bits over ~7 700 declarations is a far smaller exposure
  than that; but it is a trade, and `--blobcache-hash` does not cover it (it
  strengthens the module identity, not the declaration one).
* **A blob file can now hold fragments from more than one version of its
  module.** `flush`'s prune is what stops that from growing without bound, and
  it only runs for a module the link actually recorded into. A module that is
  edited, then never linked again, keeps its fossils until it is.
* **Over-invalidation through references is 15 fragments per edited
  declaration** (§3.4). Head-vs-whole digests would fix it; measured at ~5 ms.
* **`tests/nativecg/tinlinecond.x64.asm.nif` is still stale** and this branch
  cannot fix it — it is regenerable only on x64 and it already predated F1
  (`notes/f2.md` §6). The arm64 golden was regenerated here and its whole diff
  is three lines, `` `L23.0 `` → `` `L1.0 ``, plus the `.indexat` offset.
* **The arkham splice is not built** (§6), so the `arkham ≤ 0.05 s` half of
  `JIT_IMPL.md`'s B3b gate is untouched. Its prerequisite is landed and proved
  (434 → 3), which is the thing that was missing.
* `vtables_backend` routing iterators through its pass-through branch
  (`notes/f2.md` §7) remains the one known residual position dependence upstream
  of arkham; it did not show up in this phase's measurement either.
