proc bindExternals*(img: MemImage; h: HostSymbols): seq[string]  # unresolved names
proc makeExecutable*(a: Arena; img: MemImage)
proc runImage*(img: MemImage; argc: cint; argv, envp: pointer): GuestResult
proc defaultHostSymbols*(): HostSymbols
proc guestExit*(code: cint) {.cdecl.}            # the `exit` intercept
```

**CLI**: `tools/nifrun.nim` → `bin/nifrun [--dev-single-thread] [--entry:NAME]
[--time] file.asm.nif [args…]`, and `nifasm --dev-single-thread`.

## The CTFE demonstration

Corpus regenerated with

```
bin/nimony c --nimcache:/tmp/b1_nc tests/nimony/consteval/tconstseq.nim
```

(five sub-program directories; four of them are real evaluations, the fifth is
the `writenif` precompile and produces no `.out.nif` on either path). For each,
arkham per module and then the loader:

```
for f in <dir>/*.c.nif; do
  bin/arkham --os:macosx --cpu:arm64 -o:<asm>/$(basename $f .c.nif).asm.nif $f
done
bin/nifrun --dev-single-thread <asm>/<sfx>.asm.nif
```

All four evaluations run **from memory** and write a `.out.nif` byte-identical
to the one the file-linked binary writes (sha256 compared against the reference
taken before the run).

## Timings (macOS 26.6.2 / Apple M5, arm64, release builds, warm cache)

One CTFE sub-program, `tconstseq`'s 8 `.c.nif` modules:

| step | ms |
|---|---|
| arkham per module, sum of 8 medians | 30.70 |
| of which process-spawn floor (8 × 1.51) | 12.1 |
| — slowest module `sysvq0asl` (307 KB) | 12.57 |
| **nifrun**, in one process: | |
| assemble (parse + declare + emit + finishCode, 8 modules) | 7.5 – 8.0 |
| lay into the arena (`layInMemory`) | 0.09 |
| resolve 8 externals + `mprotect` + icache | 0.02 |
| call `main`, guest runs to completion | 0.12 |
| **total in-process** | **~7.8** |
| for comparison: `nifasm -o:prog` (Mach-O + codesign) | 18.85 |
| for comparison: B0's cold C-backend CTFE sub-compile | 450 – 490 |

The image: 27904 B of code, 13256 B of data, 8 external slots.

So the assemble+load+run half of a CTFE evaluation costs about 8 ms in-process
against 19 ms through the file path — and against 450 ms for the C backend. The
30 ms of arkham above it is still eight processes; B2 removes that by calling
`generateAsmBuf` instead of spawning.

## Test results

* `tools/refactor_gate.sh`: **2583 artifacts, 774 listings, byte-identical to
  the pinned commit's baseline after every one of the eight commits.**
* `nim r tests/tester.nim`, macOS/arm64:
  * 230 / 230 arkham, 229 / 229 arkham stress, 227 / 227 ithaqua,
    6 / 6 AVR rejections, 12 / 12 RV32 rejections, 8 / 8 Cortex-M rejections,
    5 / 5 vgreq (qemu and `bin/avrtest` absent, so those suites skip — same as
    the pinned commit)
  * `AsmError self-test: all checks passed`
  * `234 / 234 memory-image byte-identity checks (mach-o)`
  * `233 / 233 memory-image byte-identity checks (elf)`
  * `230 / 230 in-memory (nifrun) tests successful`

## What is not done, and why

* **x86-64 `&threadvar` is not lowered by `--dev-single-thread`.** The flag
  works everywhere nifasm decides the shape of a thread-local access, which is
