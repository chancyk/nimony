# Phase A1d — research notes

Written before the implementation, per `JIT_IMPL.md` "Execution rules for
agents" rule 3. Worktree branch `jit/a1d`, forked from `fast-devloop`
(`400c091e`, i.e. with P0a, P0b, A1a, A1b and A1c already in).

A1d is the phase where the two halves of A1 start using each other: nifmake
learns what a spawn costs, the store learns what an entry costs to get back,
and `--stats` prints both.

## 1. The ledger API as it stands (`src/lib/ledger.nim`, 597 lines)

Types, verbatim:

```nim
LedgerKey* = object
  phase*: string   # "nifler" | "nimsem" | "hexer" | "dceLive" | "dceEmit" | …
  module*: string  # module suffix, "" for whole-program nodes
LedgerSample* = object
  produceNs*, serializeNs*, writeNs*, loadNs*, parseNs*, spawnNs*: int64
  bytes*: int64
LedgerEntry* = object
  key*: LedgerKey
  ewma*: LedgerSample      # alpha 0.3, integer: new = (7*old + 3*x) / 10
  samples*: int
  updated*: int64
  toolhash*: string
Ledger* = object
  path*: string
  entries*: seq[LedgerEntry]   # sorted by (phase, module)
  current*: string             # the toolhash `estimate` accepts
  dirty*: bool
```

Procs A1d builds on:

| proc | line | what it does |
|---|---|---|
| `moduleSuffixOf(path)` | 119 | basename up to the first dot |
| `record(l, key, s, toolhash)` | 211 | fold one measurement; a changed toolhash restarts the average |
| `estimate(l, key, toolhash)` | 231 | own entry -> phase mean -> `defaultSample(phase)` |
| `estimate(l, key)` | 260 | same for `l.current` / `toolhash()` |
| `fragmentPath(dir, key)` | 380 | `<dir>/.ledger/<phase>_<module>.nif` |
| `openFragment(dir, key)` | 386 | that one key's history as a one-entry ledger |
| `writeFragment(dir, key, s, th)` | 392 | read, fold, atomic write |
| `recordSpawn(dir, key, ns, th)` | 407 | attach a spawn cost without bumping `samples` |
| `openLedger(path)` | 435 | snapshot + fold `<root>/.ledger/` and `<root>/*/.ledger/` |
| `saveLedger(l)` | 450 | publish the folded table |
| `consolidate(nimcache)` | 458 | `openLedger` + `saveLedger`, fragments left alone |
| `statsTable(l)` | 522 | the `--stats` table: phase, samples, produce, ser+parse, write, bytes |
| `PhaseTimer` | 541 | `initPhaseTimer(dir, phase, module)`, `noteLoad/noteParse/noteProduce/…`, `finish` |

`defaultSample(phase)` (line 165) is the JIT.md 3.3 table: every phase carries
`spawnNs = 3 ms`; `produceNs` is 3 ms nifler, 7 ms nimsem, 7 ms hexer, 6 ms
lengc, 54 ms cc, 33 ms link, 0 for anything else.

### 1.1 The bug `recordSpawn` has today

`recordSpawn` is dead code at the fork point — A1a wrote it *for* A1d and
nothing calls it. It does not survive contact with its intended caller:

```nim
if find(l, key, pos) and l.entries[pos].toolhash == toolhash:
  l.entries[pos].ewma.spawnNs = ewmaStep(l.entries[pos].ewma.spawnNs, spawnNs)
else:
  var s = default(LedgerSample); s.spawnNs = spawnNs
  record(l, key, s, toolhash)          # <- overwrites the entry at `pos`
```

The observer of a spawn is *nifmake*, and nifmake's `toolhash()` is the hash of
`bin/nifmake` — never the hash of the `bin/hexer` that wrote the fragment. So
the `==` fails on every single call, `record` falls into its else branch, and
because `find` had matched the key, `record` *overwrites* the tool's entry with
a sample that holds nothing but `spawnNs`. Every `produce`, `bytes` and
`samples` the tool measured would be destroyed by the observer that ran a
millisecond later.

The fix is to make the entry's toolhash belong to whoever measured `produce`:
an observation *about* a sample must not restamp it. A1d rewrites `recordSpawn`
to fold into the existing entry whatever its stamp is, and to use the caller's
toolhash only when it is creating the entry from nothing (`cc`, `link` — see
§2.3).

### 1.2 `parse` is not attributable, so the store records `load` only

`PhaseTimer` carries all six buckets, but a grep over the four tools shows
which are actually filled:

```
src/nimony/nimsem.nim:76   initPhaseTimer(outfiles[0].parentDir, "nimsem", moduleSuffixOf(outfiles[0]))
src/nifler/nifler.nim:91   initPhaseTimer(outp.parentDir, "nifler", moduleSuffixOf(outp))
src/hexer/hexer.nim:151    initPhaseTimer(dir, "hexer", moduleSuffixOf(files[0]))
src/hexer/hexer.nim:164    initPhaseTimer(files[^1].parentDir, "dceLive", "")
src/hexer/hexer.nim:175    initPhaseTimer(dir, "dceEmit", moduleSuffixOf(files[0]))
src/lengc/lengc.nim:59     initPhaseTimer(outp.parentDir, "lengc", splitModulePath(inp).name)
```

Every one of them calls `noteProduce` and nothing else. `noteParse` has **no
call site anywhere in the tree** — notes/a1a.md §6 deviation 6 says why: the
phase procs open their own inputs and write their own outputs from the inside,
so load/parse/serialize/write are not separable until A2a's buffer-level entry
points exist. Those four files belong to A2a agents and A1d must not touch
them.

So JIT_IMPL.md A1d step 1 ("`vfsOpenMmap` and `vfsRead` on a store entry record
`load`; parse time is recorded by the tools at the parse call") is implementable
in its first half only. **A1d records `load` and leaves `parse` at zero**, which
is the fallback the task statement names. `load + parse` is therefore `load`
today, and the spill decision is written against the sum so that A2a's
`noteParse` calls light it up without another change here.

## 2. nifmake (`src/nifmake/nifmake.nim`, 918 lines)

### 2.1 The DAG

```nim
Node* = object
  cmdIdx*: int          # index into Dag.commands
  inputs*, outputs*, args*: seq[string]
  deps*: seq[int]
  state*: NodeState
  depth*: int
Dag* = object
  nodes*: seq[Node]
  nameToId*: Table[string, int]
  maxDepth*: int
  commands*: seq[Command]   # Command.name is "nifler", "hexer", "cc", "link", …
  baseDir*: string
```

`dag.commands[node.cmdIdx].name` is the `cmd` name from the build file, and it
is spelled exactly like the ledger's phase: a `tall.nim` build file contains
`(do nifler …)`, `(do nimsem …)`, `(do hexer …)`, `(do dceLive …)`,
`(do dceEmit …)`, `(do lengc …)`, `(do cc …)`, `(do link …)`.

### 2.2 Where a command's wall time is known

`runDag` (line 418) has two paths and both already measure, but only when
`--profile`/`--report` handed it a non-nil `profile: ptr ProfileData`:

- **sequential** (line 521-553): `let start = if profile != nil: getMonoTime() …`
  around `offerNode`/`executeCommand`, and `recordCmdTime(cmdName, sec)` after.
- **parallel** (line 483-511): `startTimes[idx] = getMonoTime()` in
  `beforeRunEvent`, `toSeconds(getMonoTime() - startTimes[idx])` in
  `afterRunEvent`, which `execProcesses` calls per finished command.

Nimony always runs nifmake with `-j`, so the parallel path is the one that
matters; `--profile` is off in an ordinary build, so `startTimes` is not even
allocated. A1d makes the two clock reads unconditional (two `getMonoTime()`
calls per command against a process spawn — three orders of magnitude apart)
and threads a per-command `outDir`/`module` alongside `cmdNames` so the
`afterRunEvent` callback can name the fragment.

`ProfileData` and `recordCmdTime` (line 351) stay exactly as they are: the
ledger is a second consumer of the same measurement, not a change to
`--profile`.

### 2.3 Which key a node's spawn belongs to

The task fixes it: `phase = cmdName`, `module = moduleSuffixOf(outputs[0])`,
`""` when the node has no output. Checked against what the tools actually
write, from a real `hello.nim` build (`/tmp/a1d_probe`):

| node | first output | derived key | the tool's own key | agrees? |
|---|---|---|---|---|
| nifler | `<nc>/sysvq0asl.p.nif` | `nifler/sysvq0asl` | `nifler/sysvq0asl` | yes |
| nimsem | `<nc>/sysvq0asl.s.nif` | `nimsem/sysvq0asl` | `nimsem/sysvq0asl` | yes |
| hexer | `<nc>/sysvq0asl.x.nif` | `hexer/sysvq0asl` | `hexer/sysvq0asl` | yes |
| hexer (main) | `<nc>/<main>_c/<main>.x.nif` | `hexer/<main>` | `hexer/<main>` | yes |
| dceLive | `<nc>/<main>_c/<main>.live.nif` | `dceLive/<main>` | `dceLive/` **(empty)** | **no** |
| dceEmit | `<nc>/<main>_c/sysvq0asl.c.nif` | `dceEmit/sysvq0asl` | `dceEmit/sysvq0asl` | yes |
| lengc | `<nc>/<main>_c/sysvq0asl.c` | `lengc/sysvq0asl` | `lengc/sysvq0asl` | yes |
| cc | `<nc>/<main>_c/sysvq0asl.o` | `cc/sysvq0asl` | — (no fragment) | n/a |
| link | `<nc>/<main>_c/hello` | `link/hello` | — (no fragment) | n/a |

The one disagreement is `dceLive`, which `hexer.nim:164` keys with an empty
module because it is a whole-program node. A1d therefore probes the derived key
first and falls back to `(phase, "")` before it creates anything, so the spawn
lands on the sample the tool actually took. That fallback costs one extra
`vfsExists` on exactly one node per build.

`cc` and `link` have no fragment at all — they are not our tools and nothing
reports their `produce`. For them `spawnNs = wall`, which is what the task
prescribes and what `--stats` will show. It is the honest number for a
scheduler that only ever asks "is this worth a process": for a node that can
never run in-process, the whole wall time is the price of the process.

The fragment directory is `parentDir(outputs[0])`, which is by construction the
directory the tool wrote into (every row above), so nifmake writes the same file
the tool did.

### 2.4 The nimcache, and where `consolidate` points

`--base:<dir>` is **not** the nimcache. `nifconfig.nim:105` calls `baseDir` "base
directory for the configuration system" and `nifmake` uses it for exactly one
thing: `findArgs(baseDir, extractArgsKey(tool) & cmd.ext)` inside
`expandCommand` (line 112), i.e. locating `.args` files. Consolidating there
would fold the wrong tree.

The rule A1d uses instead:

> **The nimcache is `parentDir` of the build file nifmake was handed.**

Every `.build.nif` nimony generates is written into `config.nifcachePath`:

- `deps.nim:907` `nifcachePath / …".doc.build.nif"`
- `deps.nim:1237-1242` `.final.build.nif` / `.final1.` / `.final2.`
- `deps.nim:1916` `nifcachePath / … ".build.nif"`
- `deps.nim:2075` `nifcachePath / … ".exec.build.nif"`

so the DAG file's own directory *is* the nimcache, exactly, with no guessing and
no new flag. `openLedger` already folds `<nimcache>/.ledger/` **and**
`<nimcache>/*/.ledger/`, which is precisely the two levels the pipeline writes
into (`<nimcache>/<main>_c/` for the backend phases), so one `consolidate` at
that directory sees every fragment of the build.

Two consequences worth writing down:

- A node whose first output is *not* in the nimcache or one directory below it
  gets its fragment at the nimcache root instead. Without that guard a `link`
  node pointed at `--out:/home/me/project/hello` would create
  `/home/me/project/.ledger/`, and a fragment written more than one level deep
  would never be folded back. The guard makes "every fragment nifmake writes is
  under the nimcache and is seen by `consolidate`" an invariant rather than a
  hope.
- `nifmake run` on a hand-written DAG outside a nimcache still records; it just
  records into that DAG's own directory, which is the same thing the tools
  already do.

## 3. The store (`src/lib/artifactstore.nim`, 706 lines)

`Payload` is the entry: `bytes`, `repr`, `generation`, `diskMtime`, `onDisk`.
Resident size is always `bytes.len`; `stats.residentBytes` is the running total
`enforceBudget` compares against `budgetBytes`.

Eviction today (`dropLargest`, line 416) has two ranks and no ledger:

```nim
if not p.onDisk and store.policy == spMemory: continue
if victimSize < 0 or (p.onDisk and not victimFree) or
   (p.onDisk == victimFree and p.bytes.len > victimSize):
```

i.e. an entry that already has a disk copy is shed before one that does not,
largest first inside each rank. Its own comment names A1d as the phase that
replaces the size ranking.

The distinction the ledger applies to matters and A1d keeps it explicit:

- **shedding a written-through entry** costs nothing now and the only way back
  is a re-read, because the bytes are on the disk. There is no recompute
  alternative to weigh it against, so the ledger has nothing to say: it stays
  free, and it stays first.
- **spilling a memory-only entry** is the case JIT.md 5.2 legislates: it costs a
  write now, and the choice later is between `load + parse` and `produce`.

So the ledger factor gates the second rank only, and the decision itself is
exposed as a pure predicate so the unit test can be exhaustive over it without
constructing megabytes of entries.

### 3.1 Where `load` is measured

`storeRead` (line 481) and `storeOpenMmap` (line 495) both fall through to
`store.prevRead` / `store.prevOpenMmap` on a miss. That fall-through *is* "time
to read it from disk into the entry", so a monotonic pair around it is the
`load` of the entry that `putEntry` then installs. Two `getMonoTime()` calls per
disk-backed read, against a read that just touched the filesystem.

### 3.2 How the store finds the ledger

The store sees paths, not configuration. `applyRequestedStore` (line 626)
already exports `NIMONY_VFS`/`NIMONY_VFS_BUDGET` so every child inherits the
policy; A1d adds `NIMONY_LEDGER` on the same seam, set by `nimony.nim` from
`c.config.nifcachePath` right before `applyRequestedStore()` (nimony.nim:452,
which is after `handleCmdLine` and before the first artifact is touched). A
process that was given no such directory derives one from the first path it is
about to evict. Either way `openLedger` runs **at most once per process**, and
only when the budget is actually exceeded — an ordinary build with the default
512 MB budget never reads the ledger at all.

## 4. `--stats` today

`deps.nim:2377-2413`. Prints `[stats] <n> modules, <n> LOC, <n> bytes`, then
`ledger.statsTable` (phase | samples | produce ms | ser+parse ms | write ms |
bytes) if there is a row, then `saveLedger`. `artifactstore.storeStatsLine`
exists (line 650) and is documented as "One line for `--stats` (A1d prints it
beside the phase table)" but has exactly one caller today: `storeFlush`, under
`NIMONY_VFS_STATS=1`, to stderr.

A1d adds the `spawn ms` column to `statsTable` and prints `storeStatsLine`
after the table. The store line the *driver* prints is the driver's own store;
the child processes' stores die with them, which is what `NIMONY_VFS_STATS`
is for and is a fact of the process-shaped pipeline, not of this phase.

## 5. Test harnesses

- `tests/ledger/setup.nim`: seven blocks, six unit and one integration. The
  integration block compiles `tests/ledger/hello.nim` and asserts produce/bytes/
  toolhash per phase and that `--stats` prints the table. A1d adds spawn
  assertions to it (`nifler`, `nimsem`, `hexer`, `lengc`, `cc` must each have
  `spawn ns > 0`, and `ledger.nif` must exist *without* `--stats` because
  nifmake consolidated it).
- `tests/vfs/setup.nim`: nine cases over the store, driven through the `vfs*`
  wrappers. A1d adds the exhaustive spill-decision matrix and a ranking case.
- `tests/nifcache/setup.nim:153,160` already excludes `.ledger/*` and
  `ledger.nif` from its two-mode artifact comparison, so nifmake writing more
  fragments does not disturb it.

## 6. Constraints carried over from A1a/A1b

- `src/lib/*.nim` is compiled by **nimony** as well as by Nim (`hastur boot`
  self-compiles nimony, nimsem and hexer). No floats, no `swap`, no
  `{.discardable.}`, no `s[i] = s[i-1]` on one mutable seq, `walkDir`/`createDir`
  behind a `when defined(nimony)`. `nifmake.nim` is **not** in the boot set, so
  it is host-Nim only.
- Fragments are never deleted; `ledger.nif` is a snapshot.
- The overhead gate is 1 % of a forced hello world, measured the way
  `bench/results/2026-09-06/a1a.txt` describes: nine interleaved runs per side,
  separate nimcaches, both warmed first.

## 7. Files A1d owns

`src/lib/artifactstore.nim`, `src/lib/ledger.nim`, `src/lib/toolhash.nim`,
`src/nifmake/nifmake.nim`, the `Stats` block in `src/nimony/deps.nim`,
`src/nimony/nimony.nim`, `tests/vfs/**`, `tests/ledger/**`, `tests/nifcache/**`.
Not A1d's, and being edited in parallel by the A2a agents: `src/hexer/**`,
`src/lengc/**`, `src/nimony/nimsem.nim`, `src/nimony/semmain.nim`,
`src/nifler/**`, `src/nimony/programs.nim`, `src/lib/nifpools.nim`,
`src/lib/nifcore.nim`. That is what forces §1.2's "`load` only".

---

# Phase A1d — what was built

## nifmake's half

`runDag` measures every command it spawns and folds the result into the
fragment the tool inside it just wrote.

- The two `getMonoTime()` calls are unconditional now. They were `--profile`
  only; the ledger wants every build's numbers, and two clock reads against a
  process spawn are three orders of magnitude apart.
- The parallel path carries `ledgerDirs` and `modules` alongside the existing
  `cmdNames`/`labels`, for the same reason those exist: `afterRunEvent` is
  handed an index, not a node.
- The sequential path records for `RunSpawn` nodes only. A node the A2b relay
  ran in-process had no process to charge for, and the existing comment already
  says the relay reports its own timings.
- A command that *failed* is still recorded. It cost a process, and what that
  cost is exactly what the next run's scheduler wants to know.

`ledger.recordSpawnWall(dir, phase, module, wall, observer)` is the new entry
point. One `vfsExists` + one `vfsRead` + one atomic ~350-byte write, the same
budget the tool inside already pays for its own fragment.

### The consolidation rule

> **The nimcache is `parentDir` of the build file nifmake was handed**, and
> `consolidate` runs there at the end of a `runDag` that spawned at least one
> command.

`Dag.nimcache` is set once, in `parseNifFile`. Why the DAG file's directory is
the nimcache, exactly: every `.build.nif` nimony generates is written into
`config.nifcachePath` (`deps.nim:907` doc, `:1237-1242` final/final1/final2,
`:1916` frontend, `:2075` exec). `--base` is not it -- that is the `.args`
search root and `expandCommand` is its only reader.

`openLedger` folds `<nimcache>/.ledger/` and `<nimcache>/*/.ledger/`, which is
the two levels the pipeline writes into, so one `consolidate` there sees the
whole build. `ledgerTargetOf` keeps that true from the other side: a node whose
first output is neither in the nimcache nor one level below it -- `link` under
`--out:`, pointed at the user's own source directory -- has its sample written
at the nimcache root instead of creating a `.ledger/` where it does not belong.

`executed > 0` gates the consolidation. An up-to-date rebuild is 11 ms today
(JIT_IMPL.md 0) and has nothing new to fold; making it pay for a directory walk
would be a bigger regression than the phase is a win.

## The keys, and the one that did not line up

`(phase = the DAG's `cmd` name, module = `moduleSuffixOf(outputs[0])`)`. Seven
of the eight node kinds agree with the key the tool wrote (table in §2.3
above). `dceLive` does not: `hexer.nim:164` keys it with an empty module
because it is a whole-program node, while an observer outside the process can
only read a module suffix off `<main>.live.nif`. `recordSpawnWall` therefore
probes `(phase, module)` and then `(phase, "")` before it creates anything, so
the spawn lands on the sample the tool took. Verified on a real build: the
fragment directory holds `dceLive_.nif` and no `dceLive_<main>.nif`.

`cc` and `link` have no fragment at all, so their whole wall time is the spawn
cost. Measured on `tests/ledger/hello.nim`: `cc` 48.7 ms, `link` 31.4 ms,
against JIT.md 3.3's table of 54 ms and 33 ms.

## Two bugs in `recordSpawn`, fixed before it could be called

1. **The observer restamped the entry.** `recordSpawn` compared the entry's
   `toolhash` against the caller's, and nifmake's can never equal the tool's, so
   `record`'s else branch overwrote the tool's `produce`/`bytes`/`samples` with
   a spawn-only sample on every build. An entry now keeps the stamp of whoever
   measured it; the caller's is used only for an entry created from nothing.
2. **The first observation blended against a zero that was not a
   measurement.** The tool creates the entry with `spawnNs = 0` because it does
   not measure its own process. Blending 4 ms into that gives 1.2 ms and takes a
   dozen builds to converge. A first observation now seeds the average -- no
   process has ever started in zero nanoseconds, so 0 is unambiguously "unset".

## The store's half

- `Payload.cost: LedgerSample`. `storeRead`'s fall-through to the disk backend
  is timed and the result hangs on the payload it admits; `storeOpenMmap`'s is
  timed into `StoreStats.loadNs` only, because a served mmap creates no entry.
- `parse` stays 0. `PhaseTimer.noteParse` has no call site in the tree and the
  four files that would add one are A2a's (§1.2). The decision is written
  against `load + parse` so A2a lights it up without another change here.

### The spill decision

`maySpill(policy, overBudget, reloadNs, produceNs, marginPercent)` is JIT.md
5.2's rule as a pure function, which is what makes the unit test exhaustive
over its inputs rather than over a store big enough to shed. Three gates:

| gate | answer | why |
|---|---|---|
| under the budget | keep | residency is what the store is for |
| policy is `memory` | keep | it has nowhere to spill to; `memory+spill` is named after having one |
| `reload * 100 >= produce * margin` | keep | JIT.md 5.2: never spill what is cheaper to recompute than to reload |

`produce == 0` means "no phase in the pipeline claims this suffix", not "cost
unknown": a sidecar, a build file, something a plugin invented. Nothing could
recompute it, so reloading is the only way back and spilling is always right.

`evictOne` keeps two ranks and only the second is the ledger's:

- An entry that **already has a disk copy** costs nothing to shed and has no
  recompute alternative -- the bytes are on the disk, so the way back is a read
  whatever the ledger says. It stays free and first.
- A **memory-only** entry is the one JIT.md 5.2 legislates about, and its rank
  is `size * maySpill(...)`, i.e. size when spilling is allowed and never
  chosen when it is not.

`reloadCost` is measurement first: the entry's own `loadNs` if a read filled
it, then the ledger's `load + parse`, then a size-derived fallback
(`NifReloadNsPerKB`, from JIT.md 5.2's 1.14 MB / 9.7 ms parse and 3.3's ~0.1 ms
per MB read). The fallback exists because both measured sources are zero until
A2a; without it the decision would degenerate into "size alone", which is what
A1d was supposed to replace.

`ensureCostLedger` reads `<nimcache>/ledger.nif` at most once per process and
only from inside `enforceBudget`, i.e. only when the budget has actually bitten.
An ordinary build with the default 512 MB never reads it. `costsLoaded` is set
*before* the read and `enforceBudget` carries an `evicting` guard, because
`openLedger` goes through the relays -- through this store -- and must neither
recurse nor mutate `store.entries` under `evictOne`'s iteration.

The nimcache reaches the store the way the policy does: `nimony.nim` calls
`requestLedgerDir(c.config.nifcachePath)` before `applyRequestedStore()`, which
exports `NIMONY_LEDGER` for every child. A process that was given none guesses
from the path it is about to shed.

## `--vfs-spill-margin`

Parsed in `nimony.nim`'s own option loop rather than beside `--vfs` in
`cli.parseCommonOption`, because the tools that share that parser are the ones
that never see the flag anyway: like the policy and the budget it travels in
the environment (`NIMONY_VFS_SPILL_MARGIN`), so two settings still emit
byte-identical `*.build.nif` files. `cli.nim` is also not this phase's file.

## `--stats`

`statsTable` gains a `spawn ms` column between `produce ms` and
`ser+parse ms`; `deps.nim`'s `Stats` block prints `storeStatsLine()` after the
table. Under `--vfs:disk` that line says there is no store rather than printing
a table of zeros, and the store it describes is the *driver's*: the tools'
stores lived and died in their own processes, which is what
`NIMONY_VFS_STATS=1` is for.

## Caveat on the spawn number

It is wall time, and nimony runs nifmake with `-j`. On a wide DAG depth it
therefore carries the CPU contention of the fan-out as well as the process
start. That is the number A2b's rule wants -- what a process costs *in this
build* is what decides whether the node is worth one -- but it is not process
startup in isolation, and a busy depth reads higher than an idle one. Visible
in the two `--stats` runs recorded in `bench/results/2026-09-06/a1d.txt`: the
same hexer node reads 1.2 ms on a quiet depth and tens of milliseconds on a
forced whole-stdlib rebuild.

## What is deliberately not here

- **`parse`.** A2a's problem, above.
- **A ledger-driven eviction in a real build.** Everything the pipeline
  produces is written through (notes/a1b.md §3), so every entry is rank 1 and
  the second rank is never reached. `spillCandidate` exists so the plumbing --
  suffix to phase to `produce` to decision -- is still tested end to end
  through a real `ledger.nif`. A2b and A2c populate `addEphemeralSuffix`, and
  that is when the rank starts firing.
- **A per-run `produce` channel.** `recordSpawnWall` subtracts the fragment's
  running average, because a separate process cannot see this run's raw
  measurement. The residual is damped again by the EWMA the spawn itself goes
  through. A tool that wanted to hand its exact `produce` to its parent would
  need a channel that does not exist, and the number does not justify one.
