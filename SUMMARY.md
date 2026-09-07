# fast-devloop: what changed, and why it fits the design

Branch `fast-devloop`, forked from `master` at f69b8afc. This is the short
version for the author; the plan is `JIT_IMPL.md`, the design rationale is
`JIT.md`, per-phase notes are under `notes/`, and every number below is in
`bench/results/<date>/progress.md` with its raw runs.

## The result

Native backend (`nimony n` / `nimony r`), interleaved A/B on one machine,
fork point vs branch:

| scenario | before | after |
|---|---|---|
| compiler compiling itself, one body edit in `sem.nim`, rebuild | 2.78 s | 1.26 s |
| the same edit, rebuild and run the compiler from memory (`nimony r`) | no such command | 1.34 s |
| hello world, one-line edit, rebuild and run | 0.32 s | 0.033 s |
| compiler, no change | 74 ms | 35 ms |
| one new compile-time evaluation (a `const` needing a sub-compile) | 450–490 ms, 32 processes | ~27 ms, 0 processes |
| a 5-`const` module, fresh nimcache / forced rebuild | 2.6 s / 5.4 s | 0.95 s / 0.94 s |
| compiler, cold | 5.29 s | 5.16 s |

Correctness is held by byte identity, not by review alone: `hastur boot
--boot-backend:native` self-hosts with stages 1, 2 and 3 byte-identical
(47–60 s); `tests/ctfe_diff` compares every compile-time result and the
calling module's `.s.nif` across all mode pairs (0 differences over 50
artifacts and 79 `.s.nif`); nativenif's `tools/refactor_gate.sh` is
byte-identical to the pre-refactor baseline (2583 artifacts, 774 listings).
The whole test tree is green in every mode (794/794).

## What was done, mechanism by mechanism

Each item names the design principle it rests on. Nothing below adds an
optimizer, a tier, speculation, or a second implementation of Leng
semantics (JIT.md section 2 non-goals); the artifacts on disk are the
same artifacts, and every switch has an escape hatch back to the old
behaviour.

### 1. Compile-time evaluation runs arkham's code from memory (B2, A2c)

`expreval` still folds what it folded. Everything it cannot fold still
becomes a real program through `exprexec.executeExpr`: same synthesis,
same `std/writenif` serializer, same sub-compile through the ordinary
build graph down to `.c.nif`. What changed is only what happens after
`.c.nif`: instead of lengc, a C compiler, a linker, an exec and macOS's
first-launch check, nimsem calls arkham on the modules in-process, hands
the asm-NIF to nifasm's `AsmSession`, lays the image into an arena, binds
the guest's dozen raw syscalls with `dlsym`, and calls `main`. The guest
already runs with `-d:nimNativeAlloc -d:nimNativeIo`, so the two heaps
never share a pointer. The bytes are arkham's AOT output; this is "CT eval
is real compilation and execution" with the container removed.

- Escape hatches: `--ctfe:subprocess`, `NIMONY_CTFE_ENGINE=off`. Any
  `AsmError` from arkham or nifasm falls back to the subprocess path, so
  the engine never has to be complete to be correct.
- The default is `--ctfe:auto`: the engine on macOS/arm64 (27/27 bootstrap
  tiers, the whole tree green under it), the subprocess elsewhere until
  those platforms are exercised.
- A runaway `const` is a diagnostic (a wall-clock budget), not a hang. A
  guest fault still kills nimsem; the subprocess flag is the answer today,
  an out-of-process guest (B3's `nimrun`) is the planned one.
- The sub-compile's own frontend runs in the parent's process (A2c):
  `semos.FrontendSnapshot` moves `pool`, `globalTags` and `prog` aside and
  back, so inside the window the process is a fresh `nimony s`. Evidence:
  277 artifacts byte-identical between the spawning and the in-process
  path.

### 2. The engine's inputs are a library, not a refactor of the tools (B1, nativenif)

arkham gained `generateAsmBuf` (a `TokenBuf` beside `render`); nifasm's
`assemble` became an `AsmSession` (`openSession`, `addModule`, `declare`,
`beginEmit`, `emitRoots`, `finishCode`, then the file writers);
`diagnostics.error` raises `AsmError` instead of `quit`; the ELF/Mach-O
patch loops moved to one `image/hostfixup.nim` shared by the file writers
and the new `image/memory.nim`, so the two cannot drift. The CLI tools are
byte-identical (the refactor gate), which is what makes "the engine's bytes
are `nimony n`'s bytes" a checked property rather than an intention.

### 3. Incremental assembly at symbol granularity (B3, B3c, nativenif)

nifasm's `emitRoots` was 97 % of a 127-module link. The cache unit is the
symbol (the worklist's own granule), the cache file is the module, so the
reachability worklist, and with it DCE and generic dedup, is untouched:
same pops, same order, each pop either splices a cached fragment or
generates one. Validity is the module's stamp, the stamps of the modules it
read declarations from, and a per-reference stamp of every type layout a
fragment baked in. Foreign procs are resolved from their signature without
reading their body (`core/declhead.nim`), which was the remaining cost.
Image sections are byte-identical to a from-scratch link in nine cache
states; the 127-module warm link went from 0.84 s to 0.086 s (0.28 s when
`sem.nim` itself changed, of which 0.16 s is generating its 540 genuinely
stale symbols).

### 4. `nimony r` (B1, nimony half)

The whole native build graph minus the link node; `engine.runWholeProgram`
assembles in-process (with the same blob cache as the `link` node) and
calls `main` from the arena. No executable is written unless `--out` is
given. The run boundary is one proc so an out-of-process guest can replace
it later without touching the command. It found and upstreamed a nativenif
bug (`hostsyms.cName` stripped the underscore on registration, so a
guest's `exit` killed the host).

### 5. The cheap wins that were bugs (P0a, P0b, P0c)

- `-f` was forwarded into every CTFE sub-compile, re-forcing ~30 nodes per
  `const`. Sub-compiles are content-addressed; forcing them is never
  needed.
- `runEval` never consulted the `.out.nif` it wrote last time. It now does,
  with the same `memoIsStale` model as `runPlugin`, and the sub-program
  reports the files it read at run time (`std/syncio`'s opt-in read log,
  written by `std/writenif` as `<sfx>.out.nif.reads`) so editing a data
  file behind `const x = readFile(...)` invalidates the memo, which it did
  not even before.
- The whole-program `.live.nif` serialized `HashSet[SymId]` in pool-index
  order, so `OnlyIfChanged` never held and every edit re-emitted all
  modules' `.c.nif` (1.6 s of CPU per edit to the compiler). It is sorted
  now, and each module gets its own `<M>.live.nif` with the resolve entries
  it consults, so `dceEmit` re-runs for the modules whose live set moved.
  127 `.c.nif` files byte-identical to before.
- The main module never owns a generic instantiation another module also
  offers (`resolveSymbolConflicts`), so a shared module's `.c.nif` does not
  depend on which main it was linked with; that is what makes the
  content-addressed `.o` cache (`nimcache/ocache/`) and the `.c.nif` cache
  for CTFE's stdlib closure hit.

### 6. The pipeline in one process, decided by measurement (A1, A2)

The four tools are callable as procs (`runNifler`, `runNimsem`, `runHexer`,
`runLengc`) with a reset of the process globals (`prog`, `pool`,
`globalTags`, identstyle, the file-line cache) between runs; `tests/inproc`
proves two runs in one process produce the bytes of two processes. nifmake
is a library (`nifmake/dag.nim`) with a `runNodeRelay` seam; `nimony`
registers nimsem, hexer, dceLive/dceEmit and lengc and decides per DAG depth
whether the registered nodes run in this process (serial) or fan out:
in-process iff `sum(node costs) <= max(largest, sum/cores) + spawn`, with
the costs coming from the cost ledger (JIT.md 5.2: every tool writes a
`.ledger/` fragment with its load/parse/produce/serialize/write times;
nifmake folds the spawn costs into `<nimcache>/ledger.nif`; `--stats`
prints the table). Escape hatches: `--spawn:always`, `--jobs:1`,
`--vfs:disk` (which implies spawn-always and is bit-identical to today).
nifler stays a process (three link blockers, documented). A booted compiler
compiled by nimony spawns `nifmake` as before (`dag.nim` is not
nimony-compilable yet), so the boot's correctness gate is unaffected.

The artifact store (`src/lib/artifactstore.nim`, `--vfs:memory|memory+spill|
disk|verify`) is the VFS adapter `vfs.nim` was written for. Its finding is
worth stating: everything the pipeline produces is read by another process,
so today it is a read cache with stat-revalidation and a write coalescer,
and `--vfs:verify` (compare every memory-served read against the disk) is
what proves a policy bug is a diagnostic rather than a stale build. The
`nimcache/` inspection workflow is unchanged in every mode.

## What was not done, and what is not a hack

- The per-module frontend is the floor now: nimsem 0.33 s, hexer 0.25 s,
  arkham 0.25 s on `sem.nim` for a one-line body edit. Symbol-granularity
  lowering (B3b) was measured and not built: sem's output is not
  declaration-stable (`makeLocalSym` numbers locals from a module-wide
  counter; line info shifts), so one appended proc changes 465 of 1227
  declarations, and arkham's labels are module-scoped. The `decl-stability`
  scenario pins those ratios. With the owner's agreement, F1 (per-
  declaration local numbering, line-info-blind digests) is in progress; it
  is the first change to the frontend's output rules and it churns goldens.
- Not done: hot reload / `nimony dev` (B4), Windows and linux/x64 for the
  engine (B5; arkham lacks `&threadvar` lowering under `--dev-single-thread`
  on x64), an out-of-process guest, a `nimNoLibc` arm of `std/rawthreads`
  on macOS (keeps the stdlib-wide corpus off the native backend there).
- Known trade-offs, each behind a flag: the blob cache validates by file
  stamp first and SHA-1 second (`--blobcache-hash` for the strict form);
  in-process phases share `~/.cache`-style state only through the resets
  the tests check; `--no-blobcache` changes the `.build.nif` (it is a token
  on the link command).

## How to check it yourself

```
nim c -r src/hastur/hastur build all          # needs ../nativenif at src/nativenif.commit
bin/hastur boot --boot-backend:native          # stages 1 == 2 == 3
bin/hastur tests/nimony                        # 794/794
bin/hastur test tests/ctfe_diff                # 0 differences over every mode pair
bench/devloop_ab.sh /tmp/devloop_base . self.editbody 5   # the headline, interleaved
```
