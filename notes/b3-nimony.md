# B3, the nimony half — one blob cache, two native paths

Integration of nativenif's per-symbol code cache (`jit/b3`, `notes/b3.md`
there) into nimony, plus the upstreaming of the one nativenif bug B1 worked
around. `JIT_IMPL.md` phase B3; design `JIT.md` 7.3. Branch `jit/b3-nimony`,
forked from `fast-devloop` at `eba4333a`. nativenif is pinned at `f8d2676`
(`jit/b3-fixes`, one commit on top of `jit/b3`'s `713c819`).

---

## 1. What was already there, and what the integration actually is

nativenif's B3 branch is complete on its own side: `--blobcache:DIR` on the
CLI, `AsmSession.useBlobCache` / `saveBlobCache` for a library caller, three
validity checks per fragment, and a byte-identity gate over three corpora and
four cache states. `notes/b3.md` §5.5 names the nimony half in one sentence:

> the re-pin of `src/nativenif.commit` and the `--blobcache:<nimcache>/blobcache`
> on the `link` node of the build graph are the integration, and
> `AsmSession.useBlobCache` is the API for the in-process path.

So this phase is small by construction. What it had to get right is only
this: the two native paths must name the SAME directory, the cache must be
refusable, and the numbers must be visible.

### The one place the directory is decided

`deps.blobCacheDir(config)` = `<nimcache>/blobcache`, beside `ocache/`
(P0b's) and `ccache/` (A2c's), and with the same lifetime — inside the build
cache, so `--nimcache:<dir>` scopes it and `hastur clean` is the eviction.
`deps.blobCacheEnabled(config)` is the refusal. Both are exported and both
callers use them:

* `generateFinalBuildFile`'s native `link` node emits
  `--blobcache:<dir>` as an argument of the nifasm command;
* `nimony.runProject` reads the same pair off the config BEFORE
  `buildGraphForRun` consumes it, and puts the string in
  `RunProgram.blobCacheDir`.

`nativeSysLink`'s `nifasmObj` node deliberately gets nothing: it runs
`--emit-obj`, and nifasm turns the cache off for that path itself
(`notes/b3.md` §3.4).

### They share a directory, NOT fragments — and that is correct

A blob is addressed by `sha1(target ‖ flags ‖ tool build id ‖ module name)`,
and `flags` includes `singleThread` and `debugInfo` (nativenif
`blobcache.nim`'s `flagKey`). `nimony r` opens its session
`singleThread = true, debugInfo = false`; the `link` node's nifasm has neither.
Those are different machine code, so they are different keys, and a store
that let them share would be a store that produced wrong bytes.

Measured on the compiler: after one `nimony n` and one `nimony r` over one
nimcache, `<nimcache>/blobcache` holds 254 files — 127 modules under each key.
The sharing that matters is the DIRECTORY: one store per nimcache, one
`--nimcache` to scope it, one `hastur clean` to sweep it, and no second
convention to explain.

`tests/nimony_r`'s `checkSharedCacheDir` is written to assert exactly that and
not more, after a first draft asserted the false version (`nimony r` replaying
what `nimony n` recorded) and failed.

### `--no-blobcache` changes the build file, and that is deliberate

`ccacheEnabled`'s comment (`deps.nim`) says why `NIMONY_CCACHE` is an
environment variable and not a flag: a flag would be spliced into the
`*.build.nif` and the two settings would stop emitting identical bytes, which
`tests/nifcache`'s artifact comparison cares about.

The blob cache is the other case. The thing being switched IS a token on the
`link` node's command line, so a build file that claimed `--blobcache:…` while
the linker had not been given it would be a lie about what ran. `--no-blobcache`
and `NIMONY_BLOBCACHE=off` therefore both change the `.final.build.nif`, and
the invariant they have to keep instead is the stronger one: the ARTIFACT is
byte-identical either way. Checked three ways —

* `tests/nimony_r`: a cached link and a `--no-blobcache` link of the same
  program produce byte-identical executables;
* by hand on `tests/nativecg/tinlinecond.nim`: same sha256 for all four
  `.asm.nif` modules and for the executable;
* `hastur boot --boot-backend:native` run in both states: stages 1/2 and 2/3
  byte-identical within each run, and stage 3's `nimony`, `nimsem` and `hexer`
  byte-identical BETWEEN the runs.

The flag is not forwarded to children (`forwardArg = false`), for the reason
`--vfs` is not: a `nimony s` sub-compile never reaches a native link node, and
the setting that genuinely has to travel — to a `{.build.}` tool that does
link — travels in the environment, which is inherited already.

## 2. The numbers, and where the remaining time is

`self.editbody` 1.805 → 1.381 s and `self.run` 1.785 → 1.364 s (cache off vs
on, same toolchain, `bench/results/2026-09-06/b3n.txt`); interleaved by hand,
1.33× and 1.31×. Against the fork point, `self.editbody` is 2.263 → 1.381 s.

The `[run-engine]` line for the compiler, warm, after a `sem.nim` body edit:

    assemble=484.11ms emitRoots=477.96ms lay=5.37ms bind=0.19ms
    code=2347568B data=33488B ext=37 blobcache=on hits=3415 stale=18 recorded=627

against 849.91 ms with the cache off and 245.10 ms with nothing edited at all.
`code=` is the same in all three, which is the cheap half of the byte identity
(nativenif's `blobcache_selftest` proves the real one).

Inside those 478 ms of `emitRoots`, nifasm's own profile puts 155 ms in
`blobResolve` and 163 ms in `blobRefs` — following 4897 names into foreign
modules and checking the layout stamps of what they resolve to. That is
`notes/b3.md` §5.2's 0.07 s shortfall seen at full size and from the other
end: **what is left of a warm link is a symbol-table cost, not a code cost.**
JIT.md 7.3's "`.x.nif` feed with the cached resolve step" is the same
observation, and it is B4's work, not something the nimony side can reach.

## 3. `--verbose` and `--profile`

`evaluate` prints one `[ctfe-engine]` line under `--verbose`; `runWholeProgram`
printed one `[run-engine]` line the same way. It now carries two more things,
and both are there because they are the ANSWER to "why was this run the length
it was":

* `emitRoots=<ms>` — timed in `engine.nim` around `sess.emitRoots()` rather
  than read out of nifasm's profile, so the number is there whether or not
  profiling was turned on. It is 96.7 % of a cold link (`notes/b3.md` §1), so
  `assemble` minus `emitRoots` is "everything else", and the gap between them
  is small and boring on purpose.
* `blobcache=on hits=N stale=M recorded=K`, straight off `sess.bc` — the
  counters nifasm keeps unconditionally. A cache that quietly stopped working
  shows up here as `hits=0` rather than as a slow afternoon.

`--profile` (and `--verbose`, which implies it) additionally calls nifasm's
`enableProfiling` before the session and `profReport` after it: the full
per-stage table, the blob read/write rows, and the per-module emit cost that
says WHICH module an edit made expensive. Printed on stderr and BEFORE the
guest runs, for the reason the timing line already was — everything the
program writes belongs to the program, and `nimony r prog.nim > out` must put
the program's stdout in `out`.

`saveBlobCache` is called before the run too, and for a sharper version of the
same reason: `guestExit` parks the thread that called it, and a program is
free to take as long as it likes, so a flush at the end of the proc is a flush
a long-running `nimony r` never reaches.

## 4. The nativenif fix, and why the workaround could go

B1 found (`notes/b1-nimony.md` §3) that `hostsyms.cName` stripped one leading
underscore on REGISTRATION as well as on lookup, so `intercept("exit")` and
`intercept("_exit")` both landed under the key `"exit"` — while Mach-O's
external for C `_exit` is `__exit`, whose stripped form is `"_exit"`, a key
nobody had. The `_exit` intercept silently did not exist, the guest's exit
reached the real libc through the host-process tier, and the compiler exited in
the middle of its own work. B1 worked around it by registering the container
spelling `"__exit"` from nimony.

Fixed upstream (nativenif `f8d2676`): the tables are keyed verbatim and only
the lookup strips, asking for the C name first and the container's own spelling
second. One case stays undecidable without knowing the container — the external
`_exit` is C `exit` under Mach-O and C `_exit` under ELF — and is documented in
`hostsyms.nim`'s header; `resolve` answers `exit`, which is the pre-existing
behaviour and, since `defaultHostSymbols` points both names at `guestExit`, has
no observable side.

The nimony workaround is removed with the re-pin. `tests/nimony_r`'s `quit(3)`
and panic cases are what would have caught its absence: both go out through the
guest's `exit` and both compare the status against the linked binary's.
