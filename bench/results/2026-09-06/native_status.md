# Phase B0 status — nativenif on this machine

Date: 2026-09-06. Machine: Apple M5 (10 cores), macOS 26.6.2 (25G83),
Darwin 25.6.0, arm64. Host Nim 2.2.10, Apple clang 21. Warm page cache.
nimony: `/Users/chanc/Projects/nimony`, branch `fast-devloop` (fork point
`f69b8afc`). **No file in the nimony repo was changed by this phase.**

nativenif: cloned to `/Users/chanc/Projects/nativenif`, detached at
`d0781a4884e3f681f8dc773fc30a204cbb508d62` — exactly the pin in
`src/nativenif.commit` ("arkham x64: a pair-homed aggregate marshalled onto the
stack needs an address (#161)", 2026-09-05).

## Headline

macOS/arm64 is **not** a second-class native target on this machine. It passes
the whole bootstrap ladder, it builds a working `nimony` binary end to end with
no C compiler and no system linker, and both JIT memory-mapping strategies work
for an unsigned `nim c` binary with no entitlements. B1 should start here.

## 1. Build status: arkham and nifasm

`nim c -r src/hastur/hastur build native` — **exit 0**, no errors, warnings only
(`XDeclaredButNotUsed`, `UnreachableCode`, `HoleEnumConv`). It cloned nothing
(the checkout was already at the pin) and produced:

    bin/arkham   2185800 bytes   arkham 0.1.0
    bin/nifasm   1461928 bytes   nifasm 0.1.0
    bin/shoggoth 1100936 bytes

built with
`nim c -d:release --warningAsError:ProveInit:off --warningAsError:Uninit:off --outdir:bin ../nativenif/src/<tool>/<tool>.nim`.
No macOS-specific build workaround was needed; the direct `nim c -d:release`
fallback was never required.

`tools/refactor_gate.sh` **does exist in nativenif at the pin** (it is absent
from nimony, where the plan docs name it — that reference is to nativenif's
copy). It runs green on macOS: 39.5 s, `2583 artifacts, 774 listings`, driving
every fixture through arkham for `arm64 / linux_arm64 / x64 / win_x64 /
cortex_m` and nifasm for `arm64 / linux_arm64 / x64 / win_x64 / cortex_m / raw`.
423 of the 2583 lines are recorded `EXIT:<n>` + diagnostic rather than a sha256
— those are the deliberately cross-target fixtures (`assembler_x64` under
`arm64`, etc.), which the gate records deterministically rather than skipping.
A baseline is captured at `refgate_baseline.sums` (+ `.listings`); B1 can `diff`
against it after each refactor stage. **B1's gate is usable on this machine.**

## 2. Tier count on macOS/arm64

`bin/hastur tiers native` (i.e. `bin/nimony n` per bootstrap module, nimcache
wiped between modules) — **exit 0**:

    0 / 27 bootstrap regressions in 72.62s.
    SUCCESS.

All 27 modules OK, including the two `-r` runnables (`src/lib/bitabs.nim`,
`src/lib/argsfinder.nim`) and both DAG tips, `src/nimony/nimony.nim` (Tier 20)
and `src/lengc/lengc.nim`. Full log: `tiers_native.log`. There is no first
failing module and no failure class to report per tier: the table is clean.

For contrast, `bin/hastur native` (the native regression *test suite*, a
different and broader corpus) is **111 / 117 in 41.05 s**, with 6 failures:

    tests/nimony/threads/threads1.nim
    tests/nimony/threads/tthreadlocals.nim
    tests/nimony/threads/tpool1.nim
    tests/nimony/threads/tparfib.nim
    tests/nimony/threads/tparfor.nim
    tests/nimony/threads/tconcurrentdecref.nim

All six are **one root cause, and it is not arkham or nifasm** — see next
section. Nothing failed in codegen, assembly, linking or at run time.

## 3. The one macOS/arm64 blocker: `std/rawthreads` under `nimNoLibc`

`src/nimony/nimony.nim:385` defines `nimNoLibc` **only** for the native backend
(the truly freestanding target — nifasm links no libc at all).
`lib/std/rawthreads.nim:175` then takes the `elif defined(nimNoLibc):` branch,
whose entire body is

    {.error: "std/rawthreads has no thread implementation for this freestanding
             target; only Linux/x86-64 has one (see the `clone` path above).
             Every other `nimNoLibc` target would link against pthreads, which
             is not there.".}

so `SysThread`, `Pthread_attr` and the `pthread_*` importc's are never declared,
and every later use is an undeclared identifier. The failure is in **nimsem**,
long before arkham runs:

    lib/std/rawthreads.nim(178, 81) Error: expression of type `string` must be discarded
    lib/std/rawthreads.nim(231, 11) Error: undeclared identifier: SysThread
    lib/std/rawthreads.nim(353, 23) Error: undeclared identifier: Pthread_attr
    lib/std/rawthreads.nim(354, 8)  Error: undeclared identifier: 'pthread_attr_init'
    lib/std/rawthreads.nim(357, 15) Error: undeclared identifier: 'pthread_attr_setstacksize'
    lib/std/rawthreads.nim(358, 8)  Error: undeclared identifier: 'pthread_create'
    lib/std/rawthreads.nim(360, 13) Error: undeclared identifier: 'pthread_attr_destroy'
    lib/std/rawthreads.nim(391, 13) Error: undeclared identifier: 'pthread_join'
    lib/std/rawthreads.nim(481, 36) Error: undeclared identifier: SysThread
    lib/std/rawthreads.nim(488, 35) Error: undeclared identifier: 'SysThread'

Two independent observations follow:

- Line 178's "expression of type `string` must be discarded" says nimony does
  not implement `{.error: ...}` as a compile-time error here, so the intended
  clean diagnostic degrades into ten confusing follow-on errors. Worth a
  separate issue; it is what makes this look like a codegen problem when it is a
  stdlib-configuration problem.
- This is also exactly why the **stdlib-wide native corpus cannot be built on
  this machine**: `bin/nimony n tests/nimony/stdlib/tall.nim` fails here, because
  `tall.nim` imports every `lib/std` module. `bin/nimony c` on the same file is
  fine.

**Consequence for B1:** CTFE (B2) evaluations are serialized and single-threaded
by design (`--dev-single-thread`, JIT.md 7.1 item 7), so this blocker does not
touch the CTFE customer at all. It blocks only the stdlib-wide *native test
corpus* and any threaded dev-runtime guest. A macOS/arm64 `nimNoLibc`
`rawthreads` implementation (or letting the native backend link libc's pthreads
on Darwin) is a self-contained, non-B1 piece of work.

## 4. M0 numbers

Full detail and method in `native_m0.txt`. Median of 3 runs per module, wall
clock around the process, serial. Process-spawn floor measured with `--help`:
**arkham 1.71 ms, nifasm 1.60 ms** — that is the per-module tax B1 deletes.

### One CTFE sub-program (`tconstseq.nim`, 8 `.c.nif` modules)

    arkham --os:macosx --cpu:arm64, 8 modules, sum of medians   30.1 ms  (8/8 ok)
        of which spawn floor 8 x 1.71                           13.7 ms
        slowest module: sysvq0asl (system, 301 KB)              12.4 ms
    nifasm -o:prog <main>.asm.nif                               17.0 ms  (ok)
    ----------------------------------------------------------------------
    TOTAL, one CTFE sub-program                                 47.1 ms

The resulting Mach-O arm64 binary runs (exit 0), same as the C-backend `.p`.

Against the `master` baseline on this same machine (JIT.md Appendix C):

    one NEW CTFE evaluation, C backend      450-490 ms  (32 processes, 146 ms Gatekeeper)
    RE-RUN of an existing CTFE binary        38- 45 ms
    arkham+nifasm from .c.nif                    47 ms  <-- this measurement

So the native path already costs about what merely *re-running* an existing
CTFE binary costs, and roughly a tenth of a cold C-backend sub-compile — and
that is still paying 13.7 ms of process spawn and all of the file I/O that B1
removes. The M0 result supports the B2 thesis.

### Stdlib-wide corpus (`tall.nim`, C-backend nimcache, 99 `.c.nif` modules)

    arkham over all 99 modules, sum of medians   236.1 ms   (99 ok, 0 failed)
        of which spawn floor 99 x 1.71           169.3 ms   (72% of the wall)
    top 5: sysvq0asl 13.3, sloap07qk 7.3, bac9cb0gi 7.1, thrg2zran1 7.0, kqun1kpxb1 4.4

    nifasm on tal87c5a51.asm.nif                 FAILS (~12 ms)
        [Error] Type mismatch: expected (u 8), got (u 64) at ??? (kind=TagLit,
                tag=(mov) in proc kqueuePoll.0.kqun1kpxb1
            (mov `tmp41.0 `desugar.5)

Caveat, and it matters: this corpus was lowered by the **C** backend, which does
not define `nimNoLibc`/`nimNativeIo`, so it is not a shape the native pipeline
would ever produce. arkham accepting it 99/99 while nifasm rejects one proc is a
genuine arkham/nifasm disagreement worth filing upstream, but it is **not**
evidence about the native pipeline's health. The native pipeline cannot produce
this corpus at all here (section 3).

### The compiler itself, native pipeline end to end (substitute corpus)

`bin/nimony n src/nimony/nimony.nim` — **exit 0, 5.24 s wall**, 127 `.c.nif`
modules, producing `/tmp/b0_nc4/nim08ho4n1.n/nimony`, a Mach-O 64-bit arm64
executable that runs: `--version` prints `0.6.0`. No C compiler, no system
linker involved.

    arkham over all 127 modules, sum of medians  1321.8 ms   (127 ok, 0 failed)
        of which spawn floor 127 x 1.71           217.2 ms   (16%)
        slowest: semygjvq21 (3.6 MB .c.nif)       196.3 ms
    nifasm -o:prog nim08ho4n1.asm.nif             846.4 ms   (ok, runs)
    ----------------------------------------------------------------------
    TOTAL arkham+nifasm, whole compiler             2.17 s serial

arkham is close to linear in `.c.nif` bytes: ~18 MB in, 1.32 s, ~55 us/KB.

### Known nativenif gaps observed here

- `nifasm --emit-obj` (the macOS `nativeSysLink` path, `src/nimony/deps.nim:1268`)
  fails on **both** corpora with `nifasm: --emit-obj does not yet support
  thread-local variables`. The standalone-executable path works. This does not
  affect B1 (which wants an in-memory image, not an object file), but it is the
  reason a macOS native build that needs the system linker — anything with
  `.compile`d foreign objects or `passL` — cannot work today.
- The `kqueuePoll` `(u 8)` vs `(u 64)` mismatch above.

## 5. Memory-mapping facts (JIT.md 7.1)

Probe: `jitprobe.nim` (this directory), built with plain `nim c` (debug, no
flags). Payload is arm64 `mov w0, #42; ret` = `40 05 80 52 c0 03 5f d6`.
The binary is **adhoc, linker-signed, with no entitlements at all**
(`codesign -dvvv`: `flags=0x20002(adhoc,linker-signed)`;
`codesign -d --entitlements -` prints none).

**(a) plain anonymous `mmap` RW -> `mprotect` RX -> `sys_icache_invalidate` -> call — WORKS**

    (a) plain anonymous mmap RW -> mprotect RX -> sys_icache_invalidate -> call
      mmap ok at 0x0000000100648000
      payload written
      mprotect(RX) ok
      sys_icache_invalidate ok
      called -> 42
      RESULT: OK

**(b) `MAP_JIT` + `pthread_jit_write_protect_np(false/true)` -> call — WORKS**

    (b) MAP_JIT + pthread_jit_write_protect_np(false/true) -> call
      mmap ok at 0x00000001047FC000
      pthread_jit_write_protect_np(false) returned
      payload written
      pthread_jit_write_protect_np(true) returned
      sys_icache_invalidate ok
      called -> 42
      RESULT: OK

Both exit 0. This is **stronger than what JIT.md 7.1 recorded** — that note says
both were verified "with an ad-hoc *signed* binary"; here they work with the
stock linker-adhoc signature and **no `com.apple.security.cs.allow-jit`
entitlement**. B1 needs no signing step, no entitlement plist and no system
setting on this machine. (Keep JIT.md's advice: add the entitlement only if
nimsem is ever notarized; never `jit-write-allowlist`.)

**256 MB contiguous code arena** (JIT.md 7.1's requirement for arm64 `bl` reach)
— `reserve.nim`, `PROT_NONE` reserve then `mprotect` the first 64 K RW:

    plain:   256MB reserve ok at 0x00000001051A8000
    plain:   mprotect(first 64K, RW) -> ok
    MAP_JIT: 256MB reserve ok at 0x0000000115228000
    MAP_JIT: mprotect(first 64K, RW) -> ok

Both reservation strategies are available. Since path (a) works, B1 can use the
simpler reserve + `mprotect` model on macOS and keep `MAP_JIT` +
`pthread_jit_write_protect_np` as the fallback for a future hardened-runtime
build, rather than committing to the `MAP_JIT` write-protect dance (which is
per-thread and would constrain the engine's threading model).

## 6. Recommendation for B1's platform order

JIT_IMPL Phase B0's gate: *"linux/x64 first is the default; if macOS/arm64
passes the tiers it moves first because it is where development happens."*

**macOS/arm64 passed the tiers 27/27. Do macOS/arm64 first.**

Supporting evidence beyond the gate's own condition:

1. arkham and nifasm build clean from the pin here, and `refactor_gate.sh` — the
   gate every B1 commit must pass — runs green and deterministic here in 40 s.
   Iterating on B1 on the machine where the gate runs is the whole point.
2. The full native pipeline already produces a *running* `nimony` on this host.
   B1's gate ("arena bytes hash-equal to the file writer's code for the same
   input") has a real, large, self-hosted input available locally.
3. Both memory-mapping strategies work unsigned and un-entitled, and a 256 MB
   arena reserves fine. The thing that would have made macOS expensive — code
   signing — is a non-issue.
4. M0 says the CTFE win is real: 47 ms of arkham+nifasm against 450-490 ms per
   cold CTFE sub-compile, with 30% of that 47 ms being process spawn that B1
   deletes outright.

Two caveats to carry into B1, neither of which changes the order:

- JIT.md 7.1's reason for preferring linux/x64 ("no dynamic imports, existing
  TLS mechanism") applies to items 5 and 7 — `hostsyms.nim` and thread-locals.
  On macOS, item 5 needs the Mach-O writer's 12-byte arm64 stub reused for
  IAT-style slots, and item 7 needs own TLV descriptors *for the dev runtime*.
  For **B2 (CTFE)** item 7 is a non-issue by design (`tvar` -> global under
  `--dev-single-thread`), and item 5 is nearly a non-issue too because nifasm's
  macOS standalone output already links no libc. So the macOS-specific work is
  concentrated in **B3/B5 (the dev runtime)**, not in B1/B2. Order B1 macOS-first
  for the engine and CTFE; revisit for the dev runtime.
- The `std/rawthreads` `nimNoLibc` gap (section 3) should be fixed independently
  so that `hastur native` and a stdlib-wide native corpus become available on
  macOS. It is not on B1's critical path but it is what currently keeps 6 tests
  red and hides the stdlib-wide M0 number.

## Artifacts in this directory

    research.md              subagent report on hastur's nativenif integration
    build_native.log         hastur build native
    tiers_native.log         hastur tiers native (27/27)
    native_tests.log         hastur native (111/117)
    native_m0.txt            full M0 tables and method
    m0_*.txt                 raw per-module timings
    tall_native.log          failed `nimony n tall.nim` (rawthreads)
    nimony_native.log        successful `nimony n nimony.nim`
    refactor_gate.log        nativenif tools/refactor_gate.sh run
    refgate_baseline.sums(.listings)   B1 byte-identity baseline (2583 + 774)
    jitprobe.nim jitprobe    memory-mapping probe (a) and (b)
    reserve.nim reserve      256 MB arena reserve probe
    timeit.py timeall.py     timing harnesses
