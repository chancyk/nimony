# B1, the nimony half — `nimony r`: build with the native backend, run `main`
# from memory

Research for `JIT_IMPL.md` phase B1 (design: `JIT.md` 7.1 items 6-7 and 7.3),
written before any edit, per the execution rules. Branch `jit/b1-nimony`,
forked from `fast-devloop` at `ff427b65`. The nativenif half is `jit/b1` in the
sibling checkout, pinned here at `736b491` and used as is; B3 works on
`jit/b3` there in parallel.

---

## 1. What `nimony n` builds and links today

`deps.generateFinalBuildFile` (`src/nimony/deps.nim:1416`) emits ONE nifmake
graph for the backend. For `config.backend == backendNative` (`let native`, line
1435) the per-module codegen node is arkham and the link node is nifasm:

```nim
elif native:                                        # deps.nim:1954
  b.withTree "do":
    b.addIdent "arkham"
    b.withTree "input":
      b.addStrLit lengcInput                        # <backendDir>/<M>.c.nif
    addInlineSourceInputs(b, c, v, backend)
    b.withTree "output":
      b.addStrLit c.config.asmFile(v.files[0], backend)   # <backendDir>/<M>.asm.nif
```

```nim
elif c.cmd in {DoCompile, DoRun} and native:        # deps.nim:1616
  b.withTree "cmd":
    b.addSymbolDef "link"
    b.addStrLit findTool("nifasm")
    b.withTree "output":
      b.addStrLit "-o:"
    b.withTree "input":
      b.addIntLit 0
      b.addIntLit 0    # only the MAIN module's .asm.nif on the command line
```

and the `do` node for it (1866-1884) lists every module's `.asm.nif` as an
input purely to order them, because nifasm opens the foreign ones itself, by
suffix, from the same directory (`asmFile`'s doc comment, 131-138).

Facts that matter for `r`:

* **The backend directory is `<nimcache>/<mainmod>.n/`** (`backendDirName`,
  deps.nim:89, `BackendDirNative = ".n"`), and it holds `<M>.c.nif`,
  `<M>.asm.nif` and `<M>.live.nif` per module plus the executable.
* **There is no `.linkmanifest.nif` on the native path.** The manifest branch
  (1812) is for the C/LLVM backend and for a `{.bundle.}` custom linker;
  `elif customLinkerName.len > 0 or (not native and not nativeSysLink)`.
* **`nativeSysLink`** (1443) is set when a native build also has `.compile`d
  foreign C/Obj-C translation units (`c.toBuild.len > 0`). Then nifasm emits a
  relocatable object (`--emit-obj`) and the system linker finishes the job.
  Those programs need symbols nimsem does not link, so `nimony r` must refuse
  them rather than mis-resolve them.
* **codesign is nifasm's**, not nimony's: there is no `codesign` anywhere under
  `src/`. nifasm ad-hoc-signs the Mach-O it writes. Running from memory skips
  it, which is part of the (small) win.
* `findTool("arkham")` / `findTool("nifasm")` resolve next to `bin/nimony`
  (`src/lib/tooldirs.nim`). `NIMONY_NATIVENIF` is hastur's, for BUILDING those
  tools; `src/nimony/deps.nim` never sees it.

### `-r` / `--run` today

`nimony.nim:328`:

```nim
of "run", "r":
  c.doRun = true
  if c.cmd == FullProject and c.args.len >= 1:
    c.forwardArgsToExecutable = true
  forwardArg = false
```

Once `forwardArgsToExecutable` is set every later token is appended to
`c.executableArgs` shell-quoted (258-273), and `deps.buildGraphImpl` ends with

```nim
if cmd == DoRun:                                    # deps.nim:2788
  ...
  exec c.config.exeFile(c.rootNode.files[0], backend) & executableArgs
```

`exec` is `execShellCmd` + `quit "FAILURE: " & cmd` on a non-zero result
(`semos.nim:187`), so **today `-r` does not preserve the program's exit
status**: any failure becomes nimony's generic failure. `nimony r` fixes that
for its own path; `-r` is left exactly as it is.

### B2's graph split, and why `r` needs a different one

`FinalPhase` (deps.nim:1146) is private to `generateFinalBuildFile`:
`fpWhole`, `fpLive`, `fpAnalysis`, `fpCodegen`. `--ctfe-analysis-only`
(`cli.nim:195`, `config.ctfeAnalysisOnly`) makes `buildGraphImpl` return right
after the `fpAnalysis` graph, i.e. after `dceEmit` has written every `.c.nif`
and before any codegen — because for CTFE the engine runs arkham itself.

For a whole program that is the wrong stop point (see §4): `r` wants
everything INCLUDING arkham and only the link node dropped. That is one
`Command` value, not a new `FinalPhase`:

* `Command` (deps.nim:221) gains `DoRunMem`.
* The three link-command definitions (1586 `nativeSysLink`, 1616 `native`,
  1628 C) are already gated on `c.cmd in {DoCompile, DoRun}` and so emit
  nothing for `DoRunMem`.
* The "Build rules" gate (1643) and the "Link executable" rule (1738) are the
  only two places that have to learn the new value: the first must include it,
  the second must skip it.
* `generateFinalBuildFile` gives it its own stem (`.finalr.build.nif`) so a
  `nimony r` and a `nimony n` sharing a nimcache do not overwrite each other's
  build file with a differently shaped graph. The ARTIFACTS are shared: the
  `.c.nif` and `.asm.nif` paths are identical, so `nimony n` after `nimony r`
  only runs the link node.

## 2. `engine.nim` as it stands, and what a whole program needs differently

`evaluate` (engine.nim:336) is: guards -> `collectModules` (every `.c.nif` in
the backend dir) -> `createLengTagPool` once -> per-module arkham with the
content-addressed `<nimcache>/asmcache/` -> `openSession(mainPool, …,
singleThread = true)` + `addMainModule(move mainAsm.code)` (retry through
`openFileSession` on refusal) -> `declare/beginEmit/emitTopLevel/emitRoots/
finishCode` -> `reserveArena` + `loadImage` -> `defaultHostSymbols` +
`intercept("write")` + `intercept("kill")` -> `bindExternals` ->
`makeExecutable` -> `runImage(img, 1, ["nimony-ctfe", nil], [nil], budgetMs)`
-> `releaseArena`.

The only module-level `var` in the file is `gIo` (engine.nim:104), the capture
buffer the `write` intercept needs because a C function pointer carries no
context. `theEngine` lives in `semos.nim:1124`. Nothing new is needed.

What a whole program changes, item by item:

| CTFE (`evaluate`) | whole program (`runWholeProgram`) |
|---|---|
| arkham in-process, `asmcache/` | arkham already ran, as graph nodes (§4) |
| `addMainModule` from arkham's buffer | `openFileSession(<main>.asm.nif)` |
| `write` captured into `gIo` | not intercepted: fd 1 and 2 are the user's |
| `kill` neutralised | not intercepted (§3) |
| argv `["nimony-ctfe"]`, empty envp | the real program name + args, the host's `environ` |
| `budgetMs` = 10 s | 0 = no deadline |
| `setCurrentDir sourceDir` | the user's cwd, untouched |
| refusal -> subprocess fallback | refusal -> diagnostic + non-zero exit |

`singleThread = true` stays: `layInMemory` (`image/memory.nim:118`) REFUSES an
image that still carries thread-locals, so the lowering is not optional and
cannot be forgotten silently.

## 3. `hostrun.nim`, and the one thing that had to be measured

The API (`/Users/chanc/Projects/nativenif/src/nifasm/hostrun.nim`, pin
`736b491`):

```nim
proc reserveArena*(size = ArenaBytes): Arena       # ArenaBytes = 256 MB
proc releaseArena*(a: var Arena)
proc loadImage*(sess: var GenContext; a: Arena): MemImage
proc bindExternals*(img: MemImage; h: HostSymbols): seq[string]
proc makeExecutable*(a: Arena; img: MemImage)
proc runImage*(img: MemImage; argc: cint; argv, envp: pointer;
               budgetMs = 0): GuestResult
proc defaultHostSymbols*(): HostSymbols
proc guestExit*(code: cint) {.cdecl.}
```

One guest at a time: `runImage` raises `AsmError` when `gGuest.running`
(hostrun.nim:234), and `gGuest` is repopulated per call, so calling it again in
sequence is fine. Only `goTimedOut` leaves `running` set forever, on purpose —
a foreign frame cannot be stopped from outside. `nimony r` runs one program and
exits, so it never meets either.

**A native program's `main` does not return.** `lengcgen.genMainProc` ends in
`cExit(0)` on the native backend (`hexer/lengcgen.nim`), so EVERY successful
`nimony r`, not only a `quit`, goes out through the exit path and parks a
thread. That is the cost `JIT.md` 7.3 avoids by putting whole programs
out-of-process; it is accepted here because a `nimony r` process runs one
program and then exits, and B3's `nimrun` replaces the boundary (§5).

**And `exit` was not actually intercepted.** Measured with an ad-hoc host over
the pinned nativenif (`/tmp/b1n_probe`), on the `nimony n` image of
`echo "hello"`:

```
probe: externals(6): __exit,_write,_write,_mmap,_getpid,_kill
probe: before run (raw write)
hello
HOSTEXIT=0            <- nothing after runImage ever ran
```

`quit(3)` gave `HOSTEXIT=3` the same way: the guest's `exit` took the HOST
process with it. The cause is in `hostsyms.nim`: `cName` strips one leading
underscore, and it is applied on REGISTRATION as well as on lookup, so

```nim
result.intercept("exit",  …)   # key "exit"
result.intercept("_exit", …)   # key "exit"  -- the same key, not "_exit"
```

while Mach-O's external for C `_exit` is `__exit`, whose `cName` is `_exit` —
a key nobody registered. The CTFE guest never noticed because a C-backend
`main` RETURNS. Registering `intercept("__exit", guestExit)` from nimony fixes
it without touching nativenif, and the same probe then prints:

```
hello
probe: after run (raw write), outcome=goExited status=0
probe: after run (nim stderr)
probe: done
```

so the host keeps its stdout and stderr after the guest is done. `nimony r`
does that, because `--verbose` has to print the run's timings and because the
compiler must be the one that chooses the exit status. On ELF the external is
`_exit` -> `cName` -> `exit`, which the existing intercept already covers, so
the extra registration is additive on every platform. **Reported upward: this
is a nativenif bug and the fix belongs there.**

`kill` is deliberately NOT intercepted for a whole program. `cAbort` does
`kill(getpid(), SIGABRT)`; under `nimony n` + exec that gives the shell 134,
and in-process it gives the shell 134 for the same reason. Intercepting it
would turn an abort into a 127 that the linked binary never produces, i.e. it
would make the two paths disagree — which is the one thing `nimony r` must not
do. The CTFE engine intercepts it for the opposite reason: there the signal
would land on a compiler that has more work to do.

### `--dev-single-thread` and threads

nifasm's `singleThread` lowers every `(tvar …)` to an ordinary global at the
declaration site (`pass1.nim:183`, `core/typesem.nim:303`), and `layInMemory`
refuses anything that survived. Thread CREATION is a different question and
has no check anywhere yet (`notes/b1.md` risk 2 asked B2 for one; B2 shipped
`write` and `kill` only).

On this host the question is already answered by the stdlib:
`lib/std/rawthreads.nim:175` is

```nim
elif defined(nimNoLibc):
  {.error: "std/rawthreads has no thread implementation for this freestanding
           target; only Linux/x86-64 has one …".}
```

so a `nimony n` program that imports it does not compile at all on
macOS/arm64. `nimony r` adds the cheap half of JIT.md 7.1 item 7 anyway — a
scan of `img.externals` for `pthread_create` / `bsdthread_create` /
`thread_create`, refusing with a named reason — which covers the libc-linked
shapes. The Linux/x86-64 `clone` arm issues the syscall inline and has no
external to scan for; that is written down as a known gap rather than papered
over.

## 4. In-process arkham, or the graph's arkham nodes?

The engine's asm cache exists because a CTFE sub-program is EIGHT modules,
seven of them shared and unchanged between evaluations, and because spawning
eight arkham processes costs 12 ms of pure fork/exec. A whole program is a
different shape: the compiler is 130 modules, and run 6 measured

```
cold:   arkham 3.41 s cpu (127)   link (nifasm, whole image) 1.06 s
edit:   arkham 0.41 s (3 modules) link (nifasm, the WHOLE 127-module image) 1.38 s
```

The graph's arkham nodes are already parallel (nifmake fans out over the
cores) and already incremental (mtime against `<M>.c.nif`), and A2b runs the
narrow depths in-process anyway. Doing arkham serially inside `nimony r`
instead would turn 3.41 s of parallel cpu into 3.41 s of wall on a cold build
and would re-hash 130 `.c.nif` files on every warm one, to replace a staleness
answer nifmake already has. So:

**arkham stays in the graph; only the link node moves in-process.** The engine
takes `<backendDir>/<main>.asm.nif` and lets nifasm's own lazy loader open the
other 129 from the same directory — which is exactly what the `link` node's
`(input 0 0)` does today, so the two paths assemble the same bytes from the
same files.

Verified before writing any code, with the pinned `bin/nifrun` over the
artifacts `nimony n` had just produced:

```
$ bin/nifrun --dev-single-thread /tmp/b1n_self/nim08ho4n1.n/nim08ho4n1.asm.nif --version
0.6.0
```

i.e. the whole compiler, 130 `.asm.nif` modules, runs from memory today.

## 5. The run boundary

One proc, so B3's out-of-process `nimrun` guest can replace it without the
command changing:

```nim
proc runWholeProgram*(e: var Engine; p: RunProgram): RunResult
```

`RunProgram` carries the backend directory, the main module suffix, the argv
the program is to see and the verbosity; `RunResult` carries an outcome
(`roRan` / `roRefused`), the status, a reason and the same `EngineTimings`
`evaluate` fills. Everything B3 changes is inside it: the blob cache feeds the
same `AsmSession`, and the pipe-to-`nimrun` form returns the same
`RunResult`. `nimony.nim` only ever sees the record.

## 6. Tests and the gate

`tests/nimony_r/setup.nim` (a custom runner: hastur compiles it with host Nim
and takes its exit code as the directory's verdict, `walk.nim:37`) covers
hello, `quit(3)`, argv, stdout/stderr ordering, a runtime panic against the
linked binary's own message and status, five `tests/nimony` programs compared
`nimony n` + exec against `nimony r` on stdout AND exit code, and
`nimony r src/nimony/nimony.nim --version`. It carries `hastur.mode = skip`
for the same reason `tests/nativecg` does: without a sibling `../nativenif`
there is no arkham, no nifasm and nothing to test.

`bench/devloop_bench.sh` gains `hello.run` and `self.run`. The expectation,
stated before measuring: `self.run` is `self.editbody` minus the Mach-O write,
the ad-hoc codesign and the exec, because the 1.38 s whole-image assemble
moves into the compiler's process rather than disappearing. B3 is what turns
that number.
