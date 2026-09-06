# Fast development workflow for nimony — plan

Status: design proposal, revision 2, 2026-09-06. Synthesized from ten research
reports (five surveys of nimony, nativenif, LuaJIT, Julia and the wider
literature; three design studies) plus direct measurements of this toolchain
on macOS arm64, including a run with the VFS profiling build. Reports and
reproduction commands are in the appendix.

Direction from the project owner:

- A fast development workflow, not a highly optimized JIT for production.
  Production deployments use AOT.
- The goal is essentially a cache optimization. Hold preprocessed artifacts in
  memory when going to disk would cost more than the processing; avoid
  spawning a process when its processing time is less than the spawn cost.
- Measure the processing of each artifact and keep the measurements alongside
  the artifacts, so the engine can decide empirically what is and is not
  worth offloading.
- Keep an escape hatch that forces the current disk-and-process behaviour.

---

## 1. The decision in one page

Two tracks, developed in parallel on the `fast-devloop` branch, joining at
compile-time evaluation and then at `nimony r`:

**Track A — the pipeline in memory.** An artifact store behind the existing
VFS seam (`src/lib/vfs.nim`, PR #1829, which already names an in-memory
adapter as an intended use) keeps artifacts as parsed NIF (binary `bif` blobs
or `TokenBuf`s), spills them to disk on request or by policy, and carries a
cost ledger: per artifact, how long it took to produce, serialize, load and
parse, and what a spawn cost. An in-process scheduler over the existing build
DAG calls a phase as a proc when the ledger says its work is below the spawn
cost and spawns (with inputs spilled) when fan-out across cores pays. The
escape hatch `--vfs:disk` restores today's behaviour exactly. This track
removes the 32 processes, the two make graphs and every text reparse from a
`const` evaluation (about 0.3 s of 0.47 s) and every spawn from a one-module
edit, with no new compiler technology.

**Track B — the Leng engine: JIT-like execution built on arkham + nifasm.**
The native backend already lowers Leng to position-independent machine code
in one pass, assembles the whole image in memory, and writes a file only as
its last step. The engine turns it into an in-process library that compiles
a proc or module on demand and returns a function pointer; adds a
memory-mapped executable arena, a symbol resolver, and a per-module
relocatable machine-code cache (the Julia package-image idea); and drives it
from three commands: compile-time evaluation inside nimsem (removing cc,
link, exec and the macOS first-launch validation, the other ~0.25 s), `nimony
r` (cold start from the code cache in milliseconds, no linker, no C
compiler), and `nimony dev` (a persistent guest process with hot reload of
proc bodies, unsafe changes detected and turned into a fast restart). It is
not a JIT in the LuaJIT sense: no speculation, tiering or optimizer; it runs
arkham's AOT output from memory, byte-identical to `nimony n`, which is what
keeps it consistent with the project's stance against JITs in production.

Neither track is a substitute for the other. Track A alone leaves a `const`
at ~0.2 s and `nimony r` dependent on clang and a linker; track B alone still
pays the spawns and reparses around every engine call. Together they reach
~25 ms per new `const`, ~1 ms per repeat, and an edit-to-running-program loop
in tens of milliseconds. Track B's first two items (the nativenif library
split and the memory image writer) depend on nothing in track A and start on
day one.

Two fixes should land this week regardless, both verified in source:

- `nimony c -f` forwards `-f` into every CTFE sub-compile (the
  `forcebuild`/`f` branch in `src/nimony/nimony.nim` never clears
  `forwardArg`), which re-forces 69 build nodes per const: 0.011 s → 0.451 s
  per warm sub-compile.
- `semos.runEval` never consults the `.out.nif` it wrote last time; unchanged
  expressions are re-executed on every compiler run (about 40 ms each instead
  of 1 ms). `runPlugin`'s `memoIsStale` is the model.

---

## 2. Goals and non-goals

Goals, in priority order:

1. Compile-time evaluation, classic macros and plugins in tens of
   milliseconds, executed in-process by the engine, results memoized across
   compiler runs.
2. `nimony r`: edit → running program with no C compiler or linker on the
   critical path, cold start from a per-module machine-code cache, the
   changed module compiled in-process by the engine.
3. `nimony dev`: a persistent guest process with hot reload of proc bodies,
   restart on unsafe changes, with the unsafe cases detected rather than
   documented.
4. Identical semantics to the AOT build. Bounds checks, overflow checks and
   ARC are in Leng already; the dev build differs from release only in the
   optimizer stages nimony already controls (shoggoth).
5. Every decision to keep an artifact in memory or to spawn a process is made
   from recorded measurements, and can be overridden.

Non-goals, written down so they stay non-goals:

- No optimizer in the engine; arkham's output is the permanent answer.
- No tiering, OSR, trace recording, profile-guided recompilation,
  speculation or deoptimization.
- No production use; `nimony c` and `nimony n` are unchanged.
- No replacement of `expreval.nim`, the tier-1 folder that handles literals
  and whitelisted magics in microseconds.
- No removal of on-disk artifacts as a debugging and persistence facility.
  Anything in memory can be spilled on demand; the `nimcache/` inspection
  workflow in AGENTS.md keeps working.

---

## 3. What exists today, measured

### 3.1 The pipeline is process-shaped by design

- Phases: nifler (`.p.nif`) → nimsem (`.s.nif`, `.s.idx.nif`, `.s.deps.nif`)
  → hexer (`.x.nif`, Leng) → DCE (`.live.nif`, `.c.nif`) → shoggoth
  (`.oc.nif`, release only) → lengc (`.c`) → cc → niflink. Backends `c`,
  `l` (textual LLVM IR), `n` (arkham + nifasm), `w` (ithaqua).
- Each phase is a separate executable with a path-based entry point:
  `semcheck(infiles, outfiles)`, `expand(infile, ..., outdir)`,
  `computeLiveSet(dceFiles, liveOut)`, `dceEmit(xnif, liveFile, outdir)`,
  `generateCode(inp, outp)`. Internally each is `TokenBuf` → `TokenBuf`
  (hexer's `Pass` object, arkham's `generateX64(var TokenBuf)`); only the
  first and last lines touch files.
- nifmake is a make: staleness by mtime, parallelism by fanning out processes
  per DAG depth (`execProcesses`, `-j`). nimony runs it twice per build.
- Process-per-module is the implicit contract for global state: `prog:
  Program` in `programs.nim`, the interning `pool` and `globalTags` in
  `nifpools.nim`, `fallbackPool` in `nifcore.nim` ("set this once at
  startup"), identstyle tables; in nativenif, `asmWord`, `targetWord`, three
  tag pools and 53 `quit` sites. Process exit is the cleanup.
- Design goals behind this (`doc/design.md`): incremental recompilation, low
  memory consumption, every intermediate inspectable, and "CT eval is real
  compilation and execution". The plugin file protocol is a documented
  contract.
- Already memory-friendly: `nifreader.openFromBuffer` builds a reader over a
  string; `foreignmodules.nim` loads binary `bif` modules by zero-copy mmap
  and parses one declaration at a time by index offset; `vfs.nim` has seven
  relays (mmap open, read, write, exists, mtime, now, remove) with a
  `VfsBlob` cookie for backend-owned lifetime, atomic replace, and a
  `-d:vfsProfile` counter mode. Adoption is partial: about 30 call sites go
  through the relays, about 71 direct OS calls remain in nimony, hexer, lengc
  and nifmake.

### 3.2 Timings (macOS arm64, Apple clang, warm toolchain)

| scenario | wall |
|---|---|
| hello world, cold nimcache | 1.21 s |
| hello world, forced rebuild | frontend 0.18 s + backend 0.22 s |
| hello world, no change | 0.026 s |
| hello world, one-line edit + relink | 0.107 s |
| stdlib-wide test (101 modules), cold | 5.4 s |
| stdlib-wide, forced debug | frontend 1.29 s + backend 0.91 s wall (8.4 s cpu; cc 5.4 s cpu) |
| stdlib-wide, forced release | + shoggoth 3.5 s cpu; backend 1.32 s wall |
| edit `strutils.nim`, rebuild stdlib-wide | 1.37 s |
| touch a file, content unchanged | 0.02–0.04 s (content-hashed) |

### 3.3 Where the time is, and where it is not

Time inside the VFS layer, summed over every process of a forced build
(`-d:vfsProfile` build of the toolchain):

| build | processes | VFS total | largest item |
|---|---|---|---|
| hello world (0.5 s + 0.9 s wall) | 122 | ~34 ms | nifler writes: 147 files, 18 ms |
| `tconstseq.nim` (5 const evals) | 109 | ~50 ms | nifler writes: 141 files, 38 ms |
| stdlib-wide, frontend only | 512 | ~95 ms | nifler writes: 696 files, 85 ms |

mmap'd reads cost about 0.1 ms per MB (nimsem: 66 opens, 8.4 MB, 0.95 ms).
Disk is not the cost. What an in-memory store saves is the text
serialize-and-reparse at each boundary and the process spawn, plus the mtime
walks of the make graphs.

Costs that do matter, measured:

| item | cost |
|---|---|
| process spawn + tool startup | ~3 ms (nifler 2.7 ms measured in `semos.nim`) |
| nimsem of a CTFE snippet | 7 ms |
| hexer of a CTFE snippet | 5–9 ms |
| lengc per module | ~6 ms |
| cc per module (clang, debug) | 25–82 ms; ~54 ms average |
| niflink | ~33 ms |
| arkham, 8-module CTFE program | 45 ms total (13 ms for `system`) |
| nifasm, whole image | 19 ms |
| macOS first launch of any new Mach-O | 0.12–0.23 s; second launch 1.8 ms |
| same for `dlopen` of a new dylib | 0.176–0.201 s |
| `mmap` RW → `mprotect` RX → call | 7.5 µs |
| one new CTFE evaluation, total | 0.45–0.49 s, 32 processes |
| repeat evaluation, unchanged | 38–45 ms (binary re-run, no memo) |
| the computation in `@[10,20,30,40,50]` | microseconds |
| 10 000-entry formatted `Table` at run time | 0.40 ms |

Two artifacts illustrate the waste: 7 of the 8 object files in every CTFE
sub-program are byte-identical across sub-programs and are recompiled each
time (37 MB of a 142 MB `nimcache/`), and the nifler write count is high
because each run writes several small files atomically (temp + rename).

### 3.4 What triggers a sub-compile

`expreval.nim` folds literals, ordinal and float arithmetic, comparisons,
`and`/`or`/`not`, `cast`/`conv`, array/set/tuple/object literals, `sizeof`,
`addr`, and a whitelist of magics (string `&`, `==`, `len`, `slurp`,
`newSeqUninit(0)`). Anything else goes to `SemContext.executeExpr`: a call to
a user proc, a loop, `@[]`, a `Table`, nearly any stdlib proc.

```nim
const a = 2 + 3 * 4            # folded in-process
const b = "abc" & "def"        # folded (whitelisted magic)
proc square(x: int): int = x * x
const c = square(7)            # sub-compile: 32 processes
const d: seq[int] = @[1, 2]    # sub-compile: 32 processes
```

The Leng such programs exercise is small: 88 distinct tags in the 8-module
program, 97 of 134 declared tags across 289 cached modules. Exceptions never
reach Leng (checked-return tuples), and the linked CTFE binary imports twelve
libc symbols, all integer/pointer-only.

### 3.5 The native backend (nativenif, pinned in `src/nativenif.commit`)

arkham (35k lines) lowers Leng in one analyser → planner → emitter pass with a
fixed frame and no emit-time spilling; nifasm (29k lines) type-checks asm-NIF,
encodes x64/arm64 by hand, resolves symbols lazily by index with a
reachability worklist that is also DCE and generic dedup, and writes
ELF/Mach-O/PE from an in-memory image in one late call. Hosted code is
PC-relative; internal calls are direct; external calls go through IAT-style
slots; x64 thread-locals bake `fs:[disp32]` as an immediate. Boot-qualified on
linux/x64, linux/arm64 and windows/x64; macOS/arm64 is a supported target but
not boot-qualified. Known gaps: >8 stack-passed params, float params/results
on x64, Linux arm64 TLS, no line numbers.

---

## 4. Lessons taken from LuaJIT, Julia and others

From LuaJIT: self-managed executable arenas with page-protection windows and
in-place patching of cross-fragment links; a small, table-driven core. Not
taken: tracing, hot counting, snapshots, side exits, blacklisting, the
assembly interpreter. They speculate on dynamic types and escape an
interpreter; Leng is statically typed and already native.

From Julia: one codegen serving AOT and JIT (ours is arkham); package
images, that is cached native code per module relocated at load (Julia 1.9
reported 39–137× time-to-first-X); GOT-style slots as the seam between cached
and fresh code (nifasm's `(extcall)`); load-time validation as a hash check;
an interpreter as a valid latency fallback. Not taken: world ages and runtime
backedges, since nimony resolves every call at compile time and its interface
checksums already answer "what changed"; the boxed calling convention; LLVM
ORC, whose compile latency is what Julia spends its time fighting.

From elsewhere: Zig's in-place patching of individually relocatable
declarations (our per-module blobs with per-proc slots); CPython's
copy-and-patch as a reminder that a small JIT can be built from prebuilt
stencils (arkham is our stencil generator); Nim's hcr as a list of things to
avoid (every module a DLL, indirection on every proc, live-frame rule left to
the user); Zig/D/Clang/Rust choosing an interpreter for CTFE, which is why
the interpreter stays on the table (section 8).

---

## 5. Track A: the artifact store and the cost ledger

### 5.1 The store

An `ArtifactStore` implemented as a VFS adapter, wrapping the previous relays
as `vfs.nim` intends:

- **Entry**: path → {representation, generation, size, spilled?, ledger}.
  Representation is one of: text bytes (as on disk today), a `bif` blob (the
  binary NIF that `foreignmodules.nim` already loads zero-copy with an
  embedded index), or a resident `TokenBuf`. Readers get a `VfsBlob` whose
  cookie owns the lifetime, as designed.
- **Policies**: `memory` (default in dev commands), `memory+spill` (write
  through on error, on `--dump`, or for named artifacts), `disk` (today's
  behaviour, the escape hatch `--vfs:disk`). Artifacts the cross-run cache
  depends on (`.s.idx.nif`, `.x.nif`, `.s.deps.nif`, the plugin memo files)
  are always written through: they are why a no-change rebuild is 26 ms.
  Ephemeral products (CTFE programs, per-eval build files, their `.c`/`.o`)
  default to memory.
- **Generations replace mtimes.** `mtimeRelay` is the only way nifmake asks
  "is this stale", so an in-memory entry answers with a generation counter and
  the DAG logic does not change. The invariant from PR #2396 (never truncate a
  mapped file) becomes "never mutate a blob a reader holds": entries are
  replaced, never edited.
- **Verify mode**: `--vfs:verify` runs both representations and compares
  bytes, so a policy bug shows up as a diagnostic rather than a stale build.
- **Finish the relay adoption**: the ~71 remaining direct OS calls, and
  nifmake's `execProcesses` behind a run-node relay.

Serialize-to-text on spill keeps the debugging story: every artifact that
exists today can still be produced on request, and `--vfs:disk` produces all
of them unconditionally.

### 5.2 The cost ledger

Every artifact carries its own measurements, stored alongside it (a small NIF
sidecar on disk, a field in memory), and aggregated per phase and per module
across runs:

```
(ledger
  (phase "hexer") (module "sysvq0asl")
  (produce   ms 13.2  cpu 12.9)      ; time to run the phase on this input
  (serialize ms 1.8   bytes 1140000) ; TokenBuf -> text (or bif)
  (write     ms 0.4)                 ; vfs write incl. atomic replace
  (load      ms 0.1)                 ; mmap/open
  (parse     ms 9.7)                 ; text -> TokenBuf (0 for bif, resident)
  (spawn     ms 3.1)                 ; process start + tool init, when spawned
  (samples 12) (updated "2026-09-06T11:48Z") (toolhash "..."))
```

The instrumentation already half exists: `-d:vfsProfile` counts and times
every relay per process (it is bit-rotted by one missing `std/monotimes`
import, and only nifler, nimsem, hexer, lengc and nifmake call
`dumpVfsProfile`), and `nifmake --profile` times every command. The ledger
makes both always-on, cheap (one monotonic clock read per operation), and
attached to the artifact instead of printed at exit. Samples use an
exponentially weighted average keyed by (phase, module, toolhash), so a
rebuilt toolchain resets the estimate.

What the ledger is used for:

- **Keep in memory or spill**: spill an artifact when its resident size is
  above the store's budget and `load + parse` is below its `produce` cost by
  the recorded margin; never spill something that is cheaper to recompute
  than to reload.
- **Spawn or call in-process** (section 6).
- **Report**: `nimony --stats` gains a per-phase table of where time goes,
  which today requires the profile build.

### 5.3 What it does not fix

The store removes serialize/parse and lets phases share buffers; it does
nothing about spawns by itself (a process cannot see another process's
memory) and nothing about cc, link, exec or the Gatekeeper tax. Those are
the scheduler (section 6) and the engine (section 7).

---

## 6. Track A: the in-process scheduler

### 6.1 Phase registry

Each DAG node names a phase. A phase registered as in-process is a proc that
takes and returns store paths (signatures unchanged, resolved through the
store) or buffers directly:

| phase | in-process entry | notes |
|---|---|---|
| nifler | `parse(TokenBuf)` | uses Nim's own parser; links in today |
| nimsem | `semcheck` | needs `prog`/`pool` re-initialized per module until made a context |
| hexer | `expand(Cursor): TokenBuf` | buffer-to-buffer internally already |
| DCE | `computeLiveSet`, `dceEmit` | keep the `resolved` generic table cached |
| lengc | `generateCode` | |
| arkham, nifasm | `generateAsmBuf`, `AsmSession` | section 7.1 |
| cc, link, external tools, plugins | always spawn | plugin file protocol is a contract |

Global state is handled in the cheapest correct way first: in-process phases
run **sequentially** in one process, and each phase resets its globals on
entry (`prog`, `pool`, `fallbackPool`, `globalTags`). Turning them into a
context object is the prerequisite for threads and is deferred until the
ledger shows a workload where in-process threads would beat process fan-out.

### 6.2 The rule

For a node whose inputs are in the store:

```
estimated = ledger.produce(phase, module)          ; EWMA, default from phase-wide mean
if phase is not registered:                spawn
elif estimated < spawnCost * k:            call in-process        ; k ≈ 3, spawnCost ≈ 3 ms
elif ready nodes at this depth < cores:    call in-process
else:                                      spill inputs, spawn, fan out
```

With today's constants every node of a `const` evaluation and of a one-module
edit runs in-process (all are under 10 ms), while a cold 100-module build
still fans out (cc alone is 5.4 s of CPU). `--jobs:1` forces sequential,
`--vfs:disk` forces today's behaviour entirely, and `--spawn:always` forces
spawning while keeping the store, which isolates scheduler bugs from store
bugs.

### 6.3 What it removes, measured

For a new CTFE evaluation: the `nimony s` process, two nifmake runs, 10 hexer
+ 8 lengc + 1 nimsem spawns, the 69-node mtime walk, and every text reparse
between them. That is roughly 0.3 s of the 0.47 s. The remaining 0.17 s is cc
(0.09 s wall), link (0.03 s) and the exec with its first-launch tax, which
only the engine removes.

For an edit-run of one module: the spawns of nifler, nimsem, hexer, dceEmit
and lengc, roughly 15–20 ms of the 107 ms; cc and link remain.

---

## 7. Track B: the Leng engine

### 7.1 nativenif as a library

All changes keep the CLI tools byte-identical, provable with
`tools/refactor_gate.sh`.

1. arkham returns a `TokenBuf`: `AsmBuf.finish` beside `render`;
   `generateAsmBuf(buf, target)`. One shared asm tag pool (arkham mints its
   own in `asmbuf.nim` and `layout.nim` today).
2. nifasm's `assemble` split into an `AsmSession`: `openSession`,
   `addMainModule`, `declare`, `beginEmit`, `emitRoots(roots)` (generalizes
   `pass2` + `processReachableSymbols` to a caller-supplied root set:
   "compile these procs and what they reach"), `finishCode`,
   `synthesizeProcessEntry` (file writers only).
3. `diagnostics.error` raises `AsmError` instead of `quit`; the driver catches
   `CatchableError` and `Defect` and falls back (7.5).
4. `image/memory.nim`: the ELF writer minus the container. Base addresses
   become arena addresses; the gvar/rodata/bss patch loops are pure base
   arithmetic already and move to a shared `image/hostfixup.nim` so the file
   and memory paths cannot diverge. Layout passes are kept so the bytes match
   the AOT build.
5. `core/hostsyms.nim`: resolver `proc(name, extName): pointer`; intercept
   table → arena symbols → `dlsym`/`GetProcAddress`. On Linux the guest has no
   dynamic imports at all. x64 needs no encoder change (`emitIatCall` already
   emits `call [rip+slot]`); arm64 reuses the Mach-O writer's 12-byte stub.
6. Skip the entry stubs; call `main.0(argc, argv, envp)` directly; intercept
   `cExit` (the only exit path nimony's synthesized `main` uses).
7. Thread-locals: for CTFE, evaluations are serialized, so `tvar` → global
   (`--dev-single-thread`, failing loudly on thread creation). Dev runtime:
   save/restore FS around guest entry on Linux x64, or out-of-process; own TLV
   descriptors on macOS; `TlsAlloc` thunk on Windows, last.

Platform memory: Linux `mmap` reserve + `mprotect`; macOS `MAP_JIT` +
`pthread_jit_write_protect_np` on one thread + `sys_icache_invalidate`
(both this and plain RW→RX verified working here with an ad-hoc signed
binary; add `com.apple.security.cs.allow-jit` only if nimsem is ever
notarized; never `jit-write-allowlist`); Windows `VirtualAlloc` +
`VirtualProtect` + `FlushInstructionCache`. Reserve 256 MB of contiguous code
arena for arm64 `bl` reach.

### 7.2 Customer 1: compile-time evaluation

The seam is `SemContext.executeExpr`, wired in `semmain.initSemContext`, with
three call sites in `expreval.nim` that never change. `exprexec.executeExpr`
keeps its synthesis and its tested `entryPoint`/`unravel*` serializer and
replaces `rewriteSymsToIdents` + `runEval` with: sem in-process (7 ms) →
hexer in-process (5–9 ms) → resolve table (cached) → arkham (3 ms) → nifasm
one module (3–5 ms) → map, call, read (~2 ms). About 25 ms for a new
expression, ~1 ms for a memoized one, ~60 ms once per compiler run for the
stdlib closure. Stdlib procs compile on demand from cached Leng via
`emitRoots` into a `SymId → pointer` table and an on-disk per-proc code
cache keyed by the proc's Leng checksum (immune to the generic
canonicalization wobble that makes per-module `.c.nif` keys unstable).

Results come back through `writenif` at first (bind `open`/`write` in the
resolver to a memory buffer); reading the value's memory directly through the
type is a later optimization. The guest already runs with
`-d:nimNativeAlloc -d:nimNativeIo`: its own `mmap`-backed region allocator
and raw-syscall I/O, so two heaps never share a pointer. Fresh region per
evaluation, dropped afterwards; intercept `cExit` and `write(2, …)`; step and
allocation budgets so a runaway `const` is a diagnostic. `errv`/`onerr` is not
an issue: hexer never emits it and arkham does not implement it.

Classic macros use the same engine (`runMacroPlugin` is already
buffer-in/buffer-out; a call site becomes a function call). Module plugins
move last, behind an in-process implementation of the documented file
protocol.

### 7.3 Customer 2: `nimony r` and the dev runtime

Out-of-process guest for whole programs (`nimrun` loader over a pipe: crash
isolation, trivial TLS and exit, scoped macOS entitlement); in-process for
CTFE. Cache and load at module granularity; compile at symbol granularity for
the edited module; no call-time trampolines (nimony knows the static call
graph). Feed `.x.nif` rather than `.c.nif` so cached stdlib code survives
edits to user code, with the DCE `resolved` table as a cached step (verified:
arkham on pre-DCE `.x.nif` fails on an unresolved generic instance without
it).

Code cache: one NIF blob per (module, target, flags) with code, data, bss
size, symbol table (from nifasm's `ctx.unwind[]`), needed symbols, fixups
(the relocation classes `writeMachOObject` already enumerates), and the
thread-local layout it baked. Key = SHA-1 of the `.x.nif` + flags + tool
build id + layout hash of exported types. Expected load for 100 stdlib
modules: single-digit milliseconds against 5.4 s of C-compiler CPU. This is
the Julia package-image win. The ledger records blob load and fixup time so
the same policy decides whether a module is cheaper to reload or recompile.

Linking: same blob → direct call; frozen module → load-time direct patch;
reloadable module → slot indirection (the `extproc` branch of `pass1`, an
existing tested path). ABI between blobs is arkham's own convention with
nifasm-checked clobber sets.

### 7.4 Hot reload

Watch → nifmake frontend → hexer for changed modules → `compileModule` →
classify → swap slots and bump generation, or restart the guest (fast, since
blobs load in milliseconds). Safe: non-inline body edits, new procs, new
globals (append-only data arena). Unsafe, detected: signature changes
(interface checksum), type layout changes (per-module `(layouts …)` sidecar
from nifasm's `typesem`), changed global initializers, the main module's top
level, changed thread-local set. Live frames are checked with nifasm's
16-byte-per-proc trace table (fixed-frame CFA, no CFI interpreter): a swap is
deferred while a frame of the replaced proc is live; old code is never
unmapped in a session. This gives the guarantee Julia gets from world ages by
a static mechanism, and it is what Nim's hcr left to the user.

### 7.5 The C-backend fallback is part of the design

The engine must be able to say "this module hit an arkham limitation; using C
for it" (per-module `clang -O0` + dylib for the runtime, the sub-compile for
CTFE). arkham is totality-first and rejects what it does not understand,
which is what makes the fallback trustworthy, and it is the only reason the
engine can ship before macOS/arm64 is boot-qualified.

---

## 8. The interpreter, held in reserve

A Leng interpreter was studied in depth and is a sound design: real host
memory in a range-checked arena, a flat 8-byte bytecode compiled once per
proc, a ~12-entry FFI shim table (intercepting the allocator removes ~60 of
131 reachable `system` procs), lazy loading through `foreignmodules.nim`,
type-directed readback. About 6.6k lines for the full surface; ~30× native
as a planning number. Break-even against today's sub-compile is a `const`
needing ~20 ms of native compute (a ~500 000-entry formatted table); nothing
in the repository is within two orders of magnitude.

It is not the primary plan because it reaches the same CTFE latency as the
engine (both are dominated by sem + hexer), cannot serve the whole-program
loop, and is a second implementation of Leng semantics to keep in agreement
with the real one. Pick it up if macOS/arm64 qualification stalls, when
sandboxed CTFE is wanted, or for hosts arkham does not target. Its layout
engine, FFI table, lazy loader, readback and the `executeExpr` seam are the
engine's components too, so nothing is wasted either way.

---

## 9. Phased plan

Two tracks run in parallel; each phase ships alone and is gated by a
measurement recorded per section 12. Track A is phases A1–A2; track B is
phases B1–B5; phase 0 precedes both. The join points are marked.

| week | track A (pipeline in memory) | track B (Leng engine) |
|---|---|---|
| 1 | phase 0: cheap wins | phase 0: macOS/arm64 qualification starts (`hastur tiers native`) |
| 2–5 | A1: artifact store + cost ledger + differential harness | B1: nativenif as a library; memory image writer; `nimony r` runs `main` from memory on linux/x64 |
| 6–9 | A2: in-process scheduler; CTFE with no spawns | B2: engine behind `executeExpr` on linux/x64 → **join: CTFE ~25 ms** |
| 10–14 | ledger-driven tuning | B3: per-module code cache; `nimony r` cold start from cache |
| 15–18 | | B4: hot reload, `nimony dev` |
| 19–24 | | B5: macOS/arm64 and Windows runtime; debugging registration |

### Phase 0 — cheap wins (2–4 days, ~150 lines)

- `nimony.nim`: `forwardArg = false` for `forcebuild`/`f`.
- `semos.runEval`: consult `<sfx>.out.nif` when newer than the `.p.nif` and
  every `recordFileDep` input; `writeFileIfChanged` for `.p.nif`/`.p.deps.nif`
  (warm sub-compile 44 ms → 11 ms).
- Content-addressed `.o` cache for the non-main modules of sub-programs;
  make `resolveSymbolConflicts` prefer a stable non-main owner.
- Fix `-d:vfsProfile` (the missing `std/monotimes` import) and add
  `dumpVfsProfile` to the tools that lack it; add a per-evaluation latency
  benchmark under `bench/`.

Gate: repeat evaluation ≤ 2 ms; new evaluation ≤ 0.36 s; `-f` no longer
doubles CTFE cost.

### Phase A1 — artifact store and cost ledger (3–4 weeks)

- `ArtifactStore` adapter over the relays: text, `bif`, resident `TokenBuf`;
  policies `memory`, `memory+spill`, `disk`; `--vfs:disk` and `--vfs:verify`.
- Ledger sidecars and the EWMA per (phase, module, toolhash); `--stats`
  table.
- Finish relay adoption (the ~71 direct calls; nifmake's run-node relay);
  generation counters behind `mtimeRelay`.
- Differential test harness for CTFE: every expression in
  `tests/nimony/consteval/` (grown to cover seq, string, Table, object,
  array, tuple, enum, set, distinct, `ptr UncheckedArray` fields, empty
  `@[]`, and the failure modes) run through both paths, NIF compared byte
  for byte. This is the oracle for everything after.

Gate: `--vfs:memory` and `--vfs:disk` produce identical artifacts on the
whole test suite; the ledger reports produce/serialize/parse per phase.

### Phase A2 — in-process scheduler (3–4 weeks)

- Phase registry with sequential in-process execution and per-phase global
  reset; buffer overloads for `expand`, `computeLiveSet`, `dceEmit`,
  `generateCode`, `semcheck`; reuse `semmagics.semCompiles`'s save/restore
  set for re-entrant sem.
- The scheduling rule of 6.2 with `--jobs`, `--spawn:always`.
- CTFE through the in-process path with the C backend still at the end;
  macro-plugin call sites as buffer handoffs.

Gate: zero spawns before cc for a `const` and for a one-module edit; a new
evaluation ≤ 0.2 s; cold stdlib-wide build within 10 % of today's wall time.

### Phase B1 — nativenif as a library and `nimony r` from memory (3–5 weeks)

- nativenif items 1–7 of section 7.1: `generateAsmBuf`, `AsmSession` with
  `emitRoots`, `AsmError`, `image/memory.nim` + `hostfixup.nim`,
  `hostsyms.nim`, direct `main` call, `--dev-single-thread`. Linux/x64
  first: no dynamic imports, existing TLS mechanism.
- `nimony r` bypasses the `link` node and runs `main` from the arena.
- M0 measurement first (2–4 days): in-process arkham + nifasm per module on
  the stdlib corpus, recorded in the ledger.

Gate: `nimony r` of the stdlib-wide test runs with no linker; arena bytes
hash-equal to the ELF writer's code for the same input; refactor gate green
in nativenif.

### Phase B2 — the engine for CTFE (3–4 weeks, joins track A)

- `executeExpr` on the engine behind `--ctfe:subprocess|engine`, falling
  back on any `AsmError`/`Defect`; per-proc on-disk code cache keyed by Leng
  checksum; stdlib closure compiled on demand via `emitRoots`.
- With A2 in place the snippet's sem and hexer run in-process; without it the
  engine still removes cc, link, exec and the Gatekeeper tax.
- macOS/arm64 qualification (`hastur tiers native`, then
  `--boot-backend:native`) continues in parallel; the CTFE closure over the
  stdlib already works there today.

Gate: new evaluation ≤ 30 ms on linux/x64 and macOS/arm64; arena bytes
hash-equal to the ELF writer's code; `hastur boot` green with the engine in
the loop.

### Phase B3 — the module code cache (3–5 weeks)

`nimrun` guest and pipe protocol; blob format; frozen-vs-reloadable slot
policy; `.x.nif` feed with the resolve step; deterministic TLS layout; blob
load/fixup times in the ledger.

Gate: cold `nimony r` of the stdlib-wide test loads cached modules in ≤ 20 ms;
a one-line edit runs in ≤ 40 ms end to end.

### Phase B4 — hot reload and `nimony dev` (3–4 weeks)

Layout sidecar and classifier, slot swap with generation counter, trace-table
stack walk at reload (x64 first), `nimony dev` watcher and hooks, explicit
restart diagnostics. Needs a real demo application to be judged.

### Phase B5 — macOS/arm64 and Windows for the dev runtime (4–6 weeks)

`MAP_JIT` path and entitled helper, TLV thunk, arm64 stub islands, `dlsym`
for libSystem; then Windows (`VirtualAlloc`, IAT slot patch reusing `pe.nim`,
`TlsAlloc` thunk). Windows is where the payoff is largest (no MinGW; 61 s vs
601 s bootstrap) and TLS is least charted.

Later, optional: direct memory readback (delete `writenif`); reuse the
parent's resolved tree instead of re-sem; GDB JIT interface and `perf`
jitdump; threads inside one process once `prog`/`pool` are context objects.
Line numbers do not exist in the native backend and are a separate project.

Rough total: within the first quarter, track A delivers the store, the
ledger and a spawn-free pipeline, and track B delivers `nimony r` from memory
and CTFE on the engine; the second quarter delivers the code cache, hot
reload and the remaining platforms. The engine work is on the critical path
from week 2, not deferred behind the cache.

---

## 10. Risks

| risk | severity | mitigation |
|---|---|---|
| a memory-only artifact the persistent cache expected on disk: silently stale build | high, silent | always write through cache-bearing artifacts; `--vfs:verify`; `--vfs:disk` |
| the ledger drives a bad decision (stale estimate after a toolchain rebuild) | medium | key by toolhash; EWMA with bounded age; overrides `--jobs`, `--spawn:always` |
| global state in phases run in-process (`prog`, `pool`, `fallbackPool`, tag pools) | medium | sequential first, reset on entry; context objects before threads |
| arkham maturity: stack params, float signatures, arm64 TLS, no line numbers | high | C fallback built alongside; arkham rejects loudly; `hastur tiers native` |
| macOS/arm64 not boot-qualified | high, schedule | qualify in parallel from phase 1; CTFE closure already works there |
| engine-compiled code takes down nimsem | high impact | fresh region per evaluation; intercept `cExit`; budgets; `--ctfe:subprocess`; differential harness; out-of-process guest for programs |
| byte-identity drift between arena and file paths | medium | shared `hostfixup.nim`; hash equality asserted in tests |
| code cache returns wrong code | medium | key on Leng checksum + toolhash + layout hash; `--no-jit-cache`; verify mode |
| x64 TLS offsets baked as immediates | medium, silent | deterministic layout, recorded pairs, recompile on mismatch |
| scope creep into a real JIT | medium | section 2 non-goals |

---

## 11. Open questions for the project owner

1. Store budget and spill policy defaults: how much resident memory may a dev
   session hold before the ledger starts spilling? (Low memory consumption is
   a stated nimony goal.)
2. Should the ledger persist per artifact only, or also as a per-machine
   profile that seeds estimates for modules never built here?
3. Is hot reload wanted, or is `nimony r` from cache enough?
4. `.x.nif` instead of `.c.nif` for the dev loop, with the cached resolve
   step?
5. Out-of-process guest for programs, in-process for CTFE: confirm.
6. Must the engine's bytes stay identical to `nimony n`'s? The plan assumes
   yes.
7. Platform priority: linux/x64 is cheapest, macOS/arm64 is where development
   happens, Windows has the largest payoff.
8. `--dev-single-thread` for CTFE: acceptable if it fails loudly on thread
   creation?
9. Treat the `-f` forwarding as a bug (recommended: sub-compiles are
   content-addressed, forcing them is never needed)?
10. Should the plugin file protocol get an in-process twin, or stay
    file-based by contract?

---

## 12. Measurement protocol

All work happens on the `fast-devloop` branch so every phase can be compared
against `master` on the same machine with the same commands. The headline
benchmark is compiling the compiler: `hastur boot` self-hosts the full
toolchain in three stages with `-d:release` and reports per-stage and total
wall time, and its byte-identical stage1 == stage2 == stage3 check is also
the correctness gate (the engine and the store must not change the produced
compiler). The smaller benchmarks isolate what each phase is meant to change.

| benchmark | command | what it measures |
|---|---|---|
| self-host bootstrap | `nim c -r src/hastur/hastur boot` | whole-toolchain build, release, the production path; stage times and total |
| self-host, C backend forced | `hastur boot --boot-backend:c` | comparable across machines where the native boot is available |
| tier ladder | `hastur tiers` / `hastur tiers native` | per-module native-backend coverage (27/27 is the current linux/arm64 bar) |
| stdlib-wide build | `bin/nimony c -f --profile tests/nimony/stdlib/tall.nim` | cold parallel build; cc and process fan-out |
| one-module edit | edit `lib/std/strutils.nim`, rebuild `tall.nim` | incremental rebuild and relink |
| hello world edit | one-line edit, `bin/nimony c hello.nim` | the minimum edit-run loop |
| CTFE, new expressions | `bench/ctfe_bench.nim` (phase 0 adds it; N fresh consts) | per-evaluation latency and process count |
| CTFE, repeat | same file, second run | result memo |
| test suite | `hastur test tests/nimony` | wall time and correctness |

Rules for a comparison:

1. Baseline first: record every benchmark on `master` at the commit the
   branch forked from, three runs each, median reported, on a quiet machine
   with a warm page cache; keep the raw logs under `bench/results/<date>/`
   (or a location the owner prefers) with `git rev-parse HEAD`, the OS and
   the Nim version.
2. Each phase in section 9, on either track, re-records the same table before its gate is
   declared met, in both `--vfs:disk` (the escape hatch, which must match the
   baseline within noise) and the phase's default mode.
3. `hastur boot` must remain byte-identical across stages in every mode; any
   divergence is a correctness failure regardless of speed.
4. Per-phase attribution comes from the ledger (`--stats`) once phase 1
   lands, and from `--profile` / the `-d:vfsProfile` build before that.
5. Report both wall and CPU-sum: the store and scheduler are expected to
   lower wall time for small builds without lowering CPU-sum much, while
   the code cache is expected to lower both for cold builds.

Baseline numbers for this machine (macOS arm64) are recorded in appendix C as
they are collected.

---

## Appendix A — research inputs

Reports from the session that produced this document (scratchpad):
`r1_pipeline.md`, `r2_backend.md`, `r3_luajit.md`, `r4_julia.md`,
`r5_comptime.md`, `r6_web.md`, `r7_nativenif.md`, `o1_ctfe.md` (CTFE
profiling and architecture comparison), `o2_interp.md` (Leng interpreter
study), `o3_devruntime.md` (nativenif refactoring spec with line
references), `measurements.md`, and the `prof_*.log` files from the
`-d:vfsProfile` runs.

## Appendix B — reproducing the key numbers

```sh
nim c -r src/hastur/hastur build all

bin/nimony c -f --profile tests/nimony/stdlib/tall.nim
bin/nimony c -f --profile --report tests/nimony/consteval/tconstseq.nim

# one CTFE sub-compile in isolation (<tco> from nimcache/)
bin/nimony --nimcache:nimcache --report s nimcache/<tco>.p.nif        # warm: 0 commands, ~11 ms
bin/nimony --nimcache:nimcache --f --report s nimcache/<tco>.p.nif    # 69 commands, ~450 ms

# macOS first-launch tax
cp nimcache/<tco>/<tco>.p /tmp/copy.p && time /tmp/copy.p && time /tmp/copy.p

# VFS time per tool (after adding `import std/monotimes` under vfsProfile)
nim c -d:release -d:vfsProfile -o:<dir>/nimsem src/nimony/nimsem.nim   # and the other tools
<dir>/nimony c -f --profile file.nim 2>&1 | grep '^\[vfs\]'

# arkham + nifasm on a real CTFE program (nativenif next to nimony)
nim c -d:release src/arkham/arkham.nim; nim c -d:release src/nifasm/nifasm.nim
for f in <tco>/*.c.nif; do arkham --os:macosx --cpu:arm64 $f; done   # ~45 ms
nifasm -o:prog <tco>.asm.nif                                        # ~19 ms
```

## Appendix C — baseline on `master` (fork point of `fast-devloop`)

Machine: macOS 26.6.2, Apple M5 (10 cores), Apple clang 21, Nim 2.2.10,
warm page cache, single runs unless stated. Commit: `f69b8afc`, the fork
point of `fast-devloop`. Raw bootstrap log: `baseline_boot.log` (session
scratchpad); the boot used the C backend because no native backend is built
for this host.

| benchmark | mode | wall | notes |
|---|---|---|---|
| hello world, forced rebuild | C backend, debug | 0.18 s + 0.22 s | frontend + backend graphs |
| hello world, one-line edit | C backend, debug | 0.107 s | rebuild + relink + run |
| hello world, no change | C backend, debug | 0.026 s | |
| stdlib-wide (`tall.nim`), cold | C backend, debug | 5.4 s | 840 files in nimcache |
| stdlib-wide, forced | C backend, debug | 1.29 s + 0.91 s | 8.4 s cpu; cc 5.4 s cpu |
| stdlib-wide, forced | C backend, release | 1.18 s + 1.32 s | + shoggoth 3.5 s cpu |
| `strutils.nim` edit → `tall.nim` | C backend, debug | 1.37 s | |
| `tconstseq.nim`, forced | C backend, debug | nimsem 3.4 s cpu | 5 CTFE sub-compiles (with `-f` leak) |
| one new CTFE evaluation | | 0.45–0.49 s | 32 processes; 0.146 s of it Gatekeeper |
| repeat CTFE evaluation | | 38–45 ms | binary re-run |
| VFS time, hello forced | all 122 processes | ~34 ms | `-d:vfsProfile` |
| VFS time, `tconstseq` forced | all 109 processes | ~50 ms | |
| self-host bootstrap (`hastur boot`) | C backend, release | 62.1 s | stage 1: 21.0 s, stage 2: 20.1 s, stage 3: 20.7 s; stages 2 and 3 byte-identical; 74 s including the hastur build |
