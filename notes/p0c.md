# Phase P0c — an edit re-emits only the modules whose live set changed

Research notes written before the implementation (`JIT_IMPL.md`, "Execution
rules for agents", rule 3). Machine: macOS 26, arm64, Nim 2.2.10, worktree
branch `jit/p0c` forked from `fast-devloop` (`acf637f6`, i.e. with P0a, P0b,
A1a–A1d, A2a×3, A2b and B2 already in).

Owner files: `src/hexer/dce2.nim`, `src/hexer/dce1.nim`, `src/hexer/hexer.nim`
(the `dl`/`de` commands), the `dceLive`/`dceEmit` node emission in
`src/nimony/deps.nim`, `tests/incremental/**`, a new proc in
`src/hastur/incrementaltests.nim`, `bench/results/2026-09-06/p0c.txt`.

---

## 1. The measurement reproduced

`/tmp/devloop_base/src` copied to `/tmp/p0c_repro/src`, then

```
nimony c --silentMake --nimcache:/tmp/p0c_repro/nc --out:… src/nimony/nimony.nim
printf '\nproc devloopBenchBody(): int = 1\n' >> src/nimony/sem.nim
nimony c --silentMake --profile --report --nimcache:… …
```

gives, verbatim:

```
nifmake-report nimsem=1 total=1 inproc=1
nifmake-report cc=1 dceEmit=127 dceLive=1 hexer=1 lengc=3 link=1 total=134 inproc=5
```

with `dceEmit 1.929s (127 invocations)` against `exec total 4.036s`.

Two facts settle what has to change:

- Of the 127 `.c.nif` files the 127 `dceEmit` nodes rewrote, **126 are
  byte-identical** to the ones from before the edit. Only `semygjvq21.c.nif`
  changed, and only because the appended proc consumed one local-name id
  (`result.125` -> `result.126`) — which is why the gate still expects `cc` = 1.
- `<main>.live.nif` **changed bytes but not content**: 508151 bytes before and
  after, and the two files' whitespace-split token multisets are identical
  (`tr -s ' ()\n' '\n' | sort` -> `cmp` clean). It is a pure PERMUTATION.

That second fact is the root cause and it is not the one JIT_IMPL.md's
sentence ("dceLive rewrites the whole-program file on every build") names.
`writeLiveFile` *already* writes `OnlyIfChanged` (`dce2.nim:290`,
`nifbuilder.close` byte-compares and preserves mtime). The file changes
anyway because it serializes `Table[string, HashSet[SymId]]` and
`Table[string, SymId]` in **hash order of `SymId`**, and `SymId`s are pool
indices assigned in the order `dl` interns them while reading the 127
`.dce.nif` files in sequence. One extra symbol in `sem.nim`'s analysis shifts
every symbol interned after it, so every hash bucket moves and the whole file
is re-rendered in a different order.

So P0c needs **two** changes, not one:

1. a deterministic serialization (sort by symbol *name*, not by `SymId`), and
2. per-module live files, so that a module whose live set genuinely moved does
   not drag the other 126 with it.

Without (1), (2) buys nothing: every per-module file would still be a fresh
permutation. Without (2), (1) alone would fix `self.editbody` but not the case
the tests must cover (a change that really moves one module's live set).

### A third, unreported symptom

Running the *same* command again immediately after the edit run, with nothing
changed:

```
nifmake-report total=0 inproc=0
nifmake-report dceEmit=126 lengc=2 total=128 inproc=0
```

126 `dceEmit` nodes are **perpetually stale**: their only output, the `.c.nif`,
is written `OnlyIfChanged`, so an emit that changes nothing preserves the old
mtime, which stays older than the freshly written `.live.nif` input. The build
therefore pays the fan-out twice for one edit. Per-module live files remove
this as a side effect: 126 of them are not rewritten either, so those nodes
are not stale in the first place.

This is also the trap for the *new* `dceLive` node, and it is what
`dag.needsRebuild`'s comment is about:

```nim
  # Use the *freshest* output as the staleness reference (max instead of
  # min). Tools may write some outputs OnlyIfChanged — when the content
  # didn't change those preserve their old mtime. Using min would treat
  # "preserved old" as the floor and re-fire the node forever even though
  # some other output (always written) is fresh enough to prove "we ran
  # since the inputs last changed".
```

If *every* output of `dceLive` were `OnlyIfChanged`, then a run that writes
nothing would leave `max(output mtimes)` behind the input that triggered it,
and `dceLive` (0.34 s) would re-fire on every subsequent build forever. The
node therefore needs one **always-written** output as its staleness anchor —
exactly the role `nimsem`'s `.s.nif` plays beside its `OnlyIfChanged`
`.s.idx.nif`.

---

## 2. What the artifacts are today

| artifact | writer | mode |
|---|---|---|
| `<M>.dce.nif` | `dce1.writeAnalysis` (`nifbuilder.open(…, OnlyIfChanged)`) | byte-compare |
| `<main>.live.nif` | `dce2.writeLiveFile` (same) | byte-compare |
| `<M>.c.nif` | `dce2.rewriteModule` -> `hexerio.writeSerialized(…, OnlyIfChanged, …)` | byte-compare |

So JIT_IMPL.md's step 3 ("`dceEmit` output written `OnlyIfChanged`") is
**already done**; that is why the edit above shows `cc` = 1 and not `cc` = 127.
Nothing is needed there beyond confirming it.

`FileWriteMode` (`src/lib/vfs.nim:81`) is `AlwaysWrite | OnlyIfChanged`; every
implementation of `OnlyIfChanged` in the tree is the same three lines — read
the existing bytes (missing/unreadable => `""`), compare to the rendered
content, skip `vfsWrite` when equal. `vfsWrite` is atomic-replace
(`vfsMoveInto`), so the PR #2396 invariant ("never truncate a file a reader may
have mmap'd") holds for both branches.

### Who reads `<main>.live.nif`

- `dce2.readLiveFile` <- `dce2.dceEmit(xnif, liveFile, …)` <- `hexer de`. This
  is the **only** production consumer.
- `tests/inproc/hexer/{setup,driver}.nim` byte-compare a `reference.live.nif`
  written by a spawned `hexer dl` against one written in-process. That test
  passes its own output path and does not use the split mode, so it is
  unaffected by anything below.
- `src/lib/ledger.nim:168` and `src/lib/artifactstore.nim:54,260` classify a
  path by `endsWith(".live.nif")`. Any new name has to keep that suffix.

No golden, fixture or checked-in `.live.nif`/`.dce.nif` exists anywhere in the
tree (`find tests examples bench -name '*.dce.nif' -o -name '*.live.nif'` is
empty), so the on-disk representation is free to change.

### The `.live.nif` shape (unchanged by this phase)

```
(stmts
  (resolved (kv "<instantiation key>" <winner Symbol>)*)
  (live (mod "<module suffix>" <Symbol>*)*))
```

Symbols carry their full module suffix (no dotted abbreviation) because the
file aggregates many modules. A per-module file is the SAME shape with one
`(mod …)` entry, so `parseLiveSet`, `readLiveFile`, `liveOf` and both
`dceEmit` overloads need no change at all.

---

## 3. The build graph today

`deps.generateFinalBuildFile` (`deps.nim:1478-1516`):

```nim
      let backend = c.config.backendDirName(c.rootNode.files[0])
      let backendDir = c.config.nifcachePath / backend
      let liveFile = backendDir / c.rootNode.files[0].modname & ".live.nif"
```

`dceLive` node: one `(input …)` per module's `.dce.nif`, one
`(output liveFile)`. Its `(cmd :dceLive hexer "dl" … (args) (input 0 -1)
(output))` template splices **all** inputs and **all** outputs into argv, which
matches `dl`'s CLI (`<dce-file>… <live-output>`).

`dceEmit` node, one per module: `(args "--outdir:<backendDir>")`,
`(input <M>.x.nif)`, `(input liveFile)`, `(output <M>.c.nif)`; its template is
`(input 0) (input 1)`, i.e. exactly two positional files reach `hexer de`.

`dag.addNode` maps **every** output of a node into `dag.nameToId`, so declaring
extra outputs on `dceLive` is enough to keep the dependency edge from each
`dceEmit` to it. The A2b scheduler groups by depth; all 127 `dceEmit` nodes
still depend only on `dceLive`, so the depth structure is unchanged.

P0b's two-graph path (`fpAnalysis` / `fpCodegen`, `deps.nim:1128-1161`,
`2466-2521`) goes through the same emission code; `fpAnalysis` stops after
`dceEmit`, so it gets the new live files for free and `fillObjectCache` keeps
hashing the `.c.nif` files exactly as before.

---

## 4. The design

### File layout

- **per module**: `<backendDir>/<M>.live.nif` — its own live set plus the
  resolve entries its emit consults. Written `OnlyIfChanged`.
- **whole program**: `<backendDir>/<main>.all.live.nif` — the aggregate file,
  unchanged in shape and still what a hand-run `hexer dl` produces. Written
  `AlwaysWrite` in split mode, because it is the `dceLive` node's staleness
  anchor (section 1).

The whole-program file is renamed rather than the per-module ones because the
main module needs a per-module file too and `<main>.live.nif` would otherwise
name two different things. `.all.live.nif` still ends in `.live.nif`, so
`ledger.artifactPhaseOf` and `artifactstore`'s stage list keep classifying it
as `dceLive` without either file being touched (neither is an owner file).

### Which resolve entries a per-module file carries

`dce2.tr` calls `translate(resolved, sym)` for exactly four kinds of token:

1. a `TypeS` symbol **def**,
2. a `ProcS`/`VarS`/`ConstS`/`GvarS`/`TvarS` symbol **def** that is non-local
   and alive,
3. every `Symbol` **use**,
4. any other `SymbolDef` (fields, params, locals).

`translate` is the identity unless `isInstantiation(name)`, and an
instantiation name always carries a module suffix, so local names never reach
the table. Everything that can therefore matter is recorded by
`dce1.analyzeModule` in that module's own `.dce.nif`:

- (1), (2) and the `fld` half of (4): `dce1.tr` puts every instantiation symbol
  def under `ProcS/TypeS/VarS/ConstS/GvarS/TvarS` and under `fld` into
  `a.offers`;
- (3): every non-local `Symbol` use lands in `a.roots` (top level) or
  `a.uses[owner]`.

So the subset for module `M` is: every key `removeModule(name)` of every
instantiation-named symbol in `M`'s `roots`, `uses` (keys and values), `offers`
and `live` set, intersected with the global resolve table. That is a superset
of what `M` can look up and a small fraction of the whole table (the
self-compile's table has 4445 entries / 310 KB, which duplicated 127 times
would be 39 MB per build).

The residual risk — a non-local instantiation `SymbolDef` in a construct
`dce1.tr` does not special-case — is checked empirically rather than argued:
the implementation compares all 127 `.c.nif` files of the self-compile,
byte for byte, against a build made by the pre-change toolchain.

### Determinism

`writeLiveFile` and the new per-module writer sort:

- `resolved` entries by key string,
- each module's live symbols by `pool.syms[sym]`,
- the `(mod …)` blocks by module name.

`dce1.writeAnalysis` gets the same treatment (roots, `uses` owners and their
deps, offers), which makes a `.dce.nif` byte-stable whenever the module's
analysis is semantically unchanged — so a body-only edit does not even wake
`dceLive`. Both readers build `HashSet`/`Table`s, so ordering is not
observable anywhere else.

`sort` needs an explicit comparator under Nimony (its stdlib has no generic
`cmp`); `deps.nim:552` already carries the idiom and hexer copies it.

### The three steps, concretely

1. `dce2`: sorted serialization; `writeLiveFile` gains a `FileWriteMode`;
   new `writeModuleLiveFiles(dir, inputs, ls)`; `computeLiveSet(dceFiles,
   liveOut, t, splitDir = "")`.
2. `hexer.nim`: a `--split:<dir>` long option, forwarded by the `dl` branch.
3. `deps.nim`: `liveFile` renamed to `.all.live.nif`; the `dceLive` node gains
   `(args "--split:<backendDir>")` and one `(output <M>.live.nif)` per module;
   its `cmd` template's output slot becomes `(output 0 0)` so only the anchor
   reaches argv; each `dceEmit` node's second input becomes its own
   `<M>.live.nif`.

`dceEmit` needs no code change: a per-module live file parses through the same
`parseLiveSet` and `liveOf` returns that module's set.

---

## 5. Tests

`incrementalLiveTests` in `src/hastur/incrementaltests.nim`, driven from
`tests/incremental/setup.nim`, over a new 3-module fixture (`p0c_leaf.nim`,
`p0c_mid.nim` importing it, `p0c_main.nim` importing that). It follows the
existing `incrementalTests` shape: run `nimony c -r --report`, parse the
`nifmake-report` lines with `parseNifmakeReports`/`reportField`, accumulate
failures in an `expect` template, and restore the sources at the end.

Phases:

1. cold build, output correct;
2. a **body-only** edit of the leaf (a private proc appended): `dceEmit` = 1,
   `lengc` = 1, `cc` = 1, output unchanged;
3. an edit that makes a previously **dead exported** proc of the leaf live from
   the middle module: `dceEmit` = 2 (leaf and mid, not `system`/`syncio`),
   `cc` = 2, and the program prints the new value;
4. a no-op rebuild after each: `total` = 0 on both graphs (the perpetual-
   staleness check from section 1).
