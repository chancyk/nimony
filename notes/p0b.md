# Phase P0b — content-addressed object cache for CTFE sub-programs

Research notes written before the implementation (JIT_IMPL.md, "Execution rules
for agents", rule 3). Machine: macOS 26, arm64, Nim 2.2.10, worktree branch
`jit/p0b` forked from `f69b8afc`.

## 1. Which graph a CTFE sub-program actually runs

`JIT_IMPL.md` names `deps.buildGraphForEval` as the emitter of the sub-program's
build graph. That is **not** the proc the CTFE path reaches:

- `exprexec.executeExpr` -> `semos.runEval` -> `semos.runProgram`
  (`src/nimony/semos.nim:691`) spawns `nimony <args> --nimcache:<outer cache>
  s <sfx>.p.nif`.
- `nimony s` is `Command.SemCheckNif` (`src/nimony/nimony.nim:153`, `:414`) and
  calls the **ordinary** `buildGraph` (`src/nimony/deps.nim:2113`).
- `buildGraphForEval` (`deps.nim:1911`) is called only from
  `nimsem.executeNif` (`src/nimony/nimsem.nim:93`), i.e. from the `nimsem e`
  command, and nothing in the tree ever execs `nimsem e`.

Confirmed on disk: compiling `tests/nimony/consteval/tconstseq.nim` with
`--nimcache:/tmp/p0b_nc` produces `<sfx>.build.nif` + `<sfx>.final.build.nif`
per sub-program (the two-graph `buildGraph` shape) and **no** `*.exec.build.nif`
(the file `buildGraphForEval` would have written).

So P0b's step 3 has to happen in the backend graph that `buildGraph` emits
(`generateFinalBuildFile`, `deps.nim:1049`), gated so that only a compile-time
eval sub-program takes the new path. `buildGraphForEval` is left alone: editing
it would change nothing that runs.

## 2. The duplication (step 1)

`tests/nimony/consteval/tconstseq.nim`, cold `/tmp/p0b_nc`: 4 CTFE
sub-programs, each with its own backend directory holding 8 modules.

`shasum -a1` of every non-main module across the four sub-program directories
`tco0279...`, `tco1CA1...`, `tco5AC9...`, `tcoD632...`:

| module | `.c.nif` | `.c` | `.o` |
|---|---|---|---|
| `assy765wm` (`std/assertions`) | same | same | same |
| `fen2xhzfd` (`std/fenv`) | same | same | same |
| `for2ybv4p1` (`std/formatfloat`) | same | same | same |
| `mat7cnfv21` (`std/math`) | same | same | same |
| `syn1lfpjv` (`std/syncio`) | same | same | same |
| `sysvq0asl` (`system`) | same | same | same |
| `wriwhv7qv` (`std/writenif`) | same | same | same |

All 7 non-main objects are byte-identical across all four sub-programs and are
recompiled from scratch every time, because each sub-program gets its own
`backendDirName` directory (`deps.nim:76`) and a fresh directory is cold for
nifmake's mtime check. That is the 7-of-8 figure from JIT.md 3.3.

The two directories that legitimately differ are the ones that are *not* CTFE
sub-programs: `tcoa2kads/` (the user program itself) and `wriwhv7qv/` (the
one-shot `std/writenif` precompile from `semos.prepareEval`). They differ
because they are different programs — a different main module means a different
DCE live set, which is exactly what `backendDirName`'s doc comment says.

## 3. Why a shared module's `.c.nif` can depend on the main module (step 2)

`dce2.resolveSymbolConflicts` (`src/hexer/dce2.nim:25`) picks, for every generic
instantiation key `foo.1.I<hash>`, the offering module whose **full symbol name
sorts lexicographically first**. Since all candidates share the `key & "."`
prefix, that reduces to "the smallest module suffix wins". The loser modules do
not emit the definition: `dce2.tr` turns their copy into an `(imp ...)` extern
that names the *winner's* symbol.

The candidate pool is "every module in this program". The main module is always
in it, and it is the one module that is guaranteed to differ between two CTFE
sub-programs. A CTFE main module's suffix is `<3 chars><40 hex uppercase>`; hex
digits and uppercase letters sort before lowercase, so a snippet main can and
does beat stdlib suffixes (`tco0279...` < `wriwhv7qv`). When that happens the
shared module's `.c.nif` degrades to an extern pointing into a snippet-specific
symbol, i.e. it differs per sub-program and the object cache misses.

**Ownership rule chosen**: *the main module never owns a shared instantiation
when some non-main module also offers it; among the non-main candidates the
existing "smallest name wins" rule is unchanged, and a symbol offered only by
the main module still stays there.* This is the smallest rule that removes the
one candidate which is guaranteed to vary between sub-programs. It does not (and
cannot) make ownership independent of the whole module set — adding or removing
any other offering module can still flip the winner — but that variation is the
same for every program that links the same set, which is what the cache needs.

`computeLiveSet` already receives the main module first: `generateFinalBuildFile`
emits the `dceLive` inputs as `for i, n in pairs c.nodes` and `c.nodes[0]` is the
root (`initDepContext`, `deps.nim:1903`). So the main module's name is available
inside dce2 without new plumbing through `hexer.nim`. The legacy single-shot
`deadCodeElimination` (used only by the dead `buildGraphForEval`) keeps the old
behaviour by passing an empty main name.

## 4. Cache-key design (step 3)

### The constraint

nifmake decides staleness from mtimes only (`nifmake.needsRebuild`). A
content-addressed output therefore cannot be made to work by "emit the node and
let nifmake skip it": a freshly written `.c.nif` is always newer than a cached
`<hash>.o` from an earlier sub-compile, so the node would rerun and rewrite the
cache entry every time. The lookup has to happen **at graph-emission time**: if
`<nimcache>/ocache/<hash>.o` exists, the `lengc` and `cc` nodes for that module
are not emitted at all and the link node simply consumes the existing path. That
is sound precisely because the path is content-addressed.

### The two-graph split

The hash has to cover the `.c.nif`, which is produced by `dceEmit` inside the
backend graph itself, so it does not exist when that graph is emitted. Hashing
the *inputs* instead (`.x.nif` + `.dce.nif` of every module) is not usable: the
live set genuinely depends on the main module, so every sub-program would get a
different key even where the emitted `.c.nif` is identical — which is exactly the
case the cache exists for.

nimony already runs two nifmake graphs per build (frontend `.build.nif`, then
backend `.final.build.nif`, `deps.nim:2154` and `:2195`), and the backend graph
is emitted only after the frontend one has run. P0b adds a third invocation for
compile-time eval sub-programs only:

1. `<sfx>.final1.build.nif` — hexer, `dceLive`, `dceEmit`. Stops before codegen.
2. Emission-time step: hash each non-main module, look the object up in
   `<nimcache>/ocache/`.
3. `<sfx>.final2.build.nif` — the full graph again with the cached paths
   substituted. Every phase-1 node is up to date, so nifmake re-executes
   nothing there; only the uncached `lengc`/`cc` pairs plus the main module's
   own codegen and the link run.

The extra nifmake process costs ~3 ms; each avoided `cc` costs 25–82 ms
(JIT.md 3.3).

### The key

`sha1` (via `nifchecksums.computeChecksum`, the same digest the CTFE module
suffix already uses) over, in order:

- the `lengc` argv fragment that varies per build (backend name, `--bits`,
  `commandLineArgsLengc`),
- the full `cc` argv (produced by the same `ccCmdFlags` helper that emits the
  `cc` command definition, so the two cannot drift apart),
- a stamp of the `lengc` and `hexer` executables (size + mtime), so a rebuilt
  toolchain invalidates the cache,
- the module's own `.c.nif` and, in the node's declared order, every `.c.nif`
  `lengc` splices inline bodies from (`addInlineSourceInputs`).

Outputs: `<nimcache>/ocache/<hash>.c` (written by `lengc`) and
`<nimcache>/ocache/<hash>.o` (written by `cc`). The `.c` sits beside the `.o`
for inspection, as JIT_IMPL.md asks.

The `-I` flag the `cc` command carries is `rootPath(c)`, i.e. derived from the
nimcache the ocache lives in, so a per-nimcache cache is the right granularity
anyway.

### Scope of the new path

Only when all of these hold, otherwise the single-graph behaviour is untouched
and the emitted build file is byte-identical to today's:

- the project handed to `buildGraph` is a `.p.nif` (that is what `nimony s`
  gets, and only `semos.runProgram` / `macro_plugin` produce those),
- the C backend, no Shoggoth optimizer, no `{.build.}`/`{.bundle.}` custom
  backend tools.

## 5. Bounding the cache (step 4)

No eviction in this phase. The cache is `<nimcache>/ocache/`, i.e. inside the
build cache: `--nimcache:<dir>` scopes it, `hastur clean` / removing `nimcache/`
removes it, and there is nothing to clean up outside the build directory. Two
sub-compiles that run concurrently and hash to the same key write identical
bytes to the same path; a future phase that adds eviction should also make the
write atomic (temp + rename).

## 6. How the test observes a cache hit

The inner `nimony s` is spawned through `osproc.execCmdEx` in
`semos.runProgram` (`semos.nim:703`), which captures stdout and discards it on
success, and `--report` is not forwarded to sub-compiles (`nimony.nim:271`
sets `forwardArg = false`). So the inner `nifmake-report` line is unreachable.

`incrementalOCacheTests` therefore asserts on the filesystem, which is what the
content-addressed design makes easy:

- count the `.o` files under `<nimcache>/ocache/` after compiling module A,
  then after compiling module B into the same nimcache: B must add no new
  object for the modules it shares with A,
- and the `.o` files that were already there must keep their mtime, proving
  `cc` did not rerun,
- plus both programs run and print their expected output.

This is the same "inspect nimcache directly" style as `mainHexedPerBackend` in
`src/hastur/incrementaltests.nim`.

## 7. What it measured, after the fact

Objects actually compiled on a cold nimcache (count of `.o` files written by
`cc`, i.e. excluding the cache's published copies):

| program | before | after |
|---|---|---|
| `tests/nimony/consteval/tconstseq.nim` (4 sub-programs) | 44 | 23 |
| `tests/nimony/consteval/tmyops.nim` (5 sub-programs) | 52 | 35 |
| `ctfe_ocache_a.nim` then `ctfe_ocache_b.nim` into one nimcache | 8 + 8 | 8 + 1 |

`tconstseq` is the ideal case from JIT.md 3.3: all four sub-programs agree on
all seven shared modules, so seven objects are compiled once instead of 28.
`tmyops` is the realistic one: its five `const`s exercise different parts of
`syncio`/`system`/`writenif`, the DCE live set genuinely differs, and the
distinct-`.c.nif` count for those seven modules is 15 rather than 7. The cache
delivers what the sharing actually is; making the *live set* itself
program-independent (not DCE-ing a sub-program's stdlib closure at all) is a
separate, larger change and is not attempted here.

Wall time on this 10-core machine is a wash (2.4 s cold either way): nifmake
already runs the `cc` fan-out in parallel and the extra nifmake process per
sub-compile eats most of what the saved compiles return. What the cache buys
today is CPU work and cache size (`tmyops`: 2.61 s user before, 1.91 s after),
which is what matters once A2's in-process scheduler removes the fan-out.

The ownership rule pays for itself on the seq/string cases rather than on these
two: a `const` that builds a `seq[string]` makes the snippet main module offer
`strlit.0.I…` instantiations that `std/syncio` also offers, and its
`tco…`/`pro…` suffix wins the lexicographic rule. Verified on a probe module:
before the rule, `syn1lfpjv.c.nif` inside the sub-program's directory names
`strlit.0.I7647587183126479795.pro1EE42…`, i.e. the shared module's Leng IR
carries the snippet's suffix; after it, no non-main `.c.nif` mentions the main
module at all.

Verified as well: for a build that is *not* a compile-time-eval sub-program the
emitted `<main>.final.build.nif` is byte-identical to the one before this
change.
