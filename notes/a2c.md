# Phase A2c — research notes

Written before the implementation, per `JIT_IMPL.md` "Execution rules for
agents" rule 3. Worktree branch `jit/a2c`, forked from `fast-devloop`
(`5de8445f`, i.e. with wave 1, wave 2, A2a, A2b and B2 in).

---

## 1. What one new evaluation costs today, step by step

Machine: macOS 26.6.2, Apple M5 (10 cores), Nim 2.2.10, `NIMONY_VFS=disk`,
`--ctfe:auto` (i.e. the engine, this being macOS/arm64).

The measurement the plan asks for is *five fresh evaluations of
`tests/nimony/consteval/tmyops.nim`'s consts on a warm stdlib nimcache*. The
recipe (`bench/results/2026-09-06/a2c.txt` carries the script):

1. `nimony c --nimcache:<nc> tmyops.nim` once, so the stdlib closure
   (`system`, `syncio`, `writenif`, `math`, `assertions`, `fenv`,
   `formatfloat`), the `std/writenif` precompile and the outer program are all
   warm;
2. delete only `<nc>/tmy<40 hex>*` (the five sub-programs, their `.p.nif`,
   `.out.nif`, `.s.nif` and backend directories) and the outer module's
   `.s.nif`;
3. re-run the same command and time it.

That run costs **0.23 s** and does exactly five evaluations. The same run with
the memo warm (only the outer `.s.nif` deleted) costs 0.01 s, so **one new
evaluation is ~44 ms end to end** — not the ~176 ms that dividing run 3's
`ctfe.cold` by five suggests. The difference is what `ctfe.cold` also pays for
once per nimcache and never again: the `std/writenif` precompile is a whole
`nimony c` with eight `cc`s and a link, the stdlib closure's nifler and nimsem,
and the outer program's own backend.

Where those 44 ms go (medians of 9, each step isolated by deleting exactly the
artifacts that force it):

| step | ms | how it was measured |
|---|---|---|
| parent: `writeEvalProgram`, `writeEvalImports`, memo check, `.out.nif` parse | 1.5 | end-to-end minus the two below |
| **spawn of `nimony s`** + its startup, config, `deps.buildGraph` graph generation, two mtime walks | **7.9** | a child re-run with nothing stale |
| child: `nimsem` of the snippet | 4.7 | delete `<sfx>.s.nif` only |
| child: `hexer` of the snippet | 1.0 | `--profile` of the `final1` graph |
| child: `dceLive` | 9.0 | `--profile` |
| child: `dceEmit` × 8 | 14.0 | `--profile` |
| child total | 32.6 | wall of the child alone |
| engine: arkham (1 run, 7 asm-cache hits, 8 modules) | 3.3 | `--verbose` `timingLine` |
| engine: assemble (nifasm) | 6.6 | idem |
| engine: lay + bind + run | 0.3 | idem |
| engine total | 10.3 | idem |
| **end to end** | **~44** | |

`nimony --version` on the same binary is 4.7 ms, so of the 7.9 ms above roughly
**4.7 ms is the process itself** (fork/exec, dyld, module init of a 4.8 MB
binary) and ~3.2 ms is the graph work a caller would still pay in-process.

Two facts that the plan's framing did not have, and that redirect the work:

* **hexer of the stdlib closure does NOT run per sub-program.** `.x.nif` and
  `.dce.nif` live at the top of the nimcache and are program-independent, so
  after the first compile they are up to date and their nodes are skipped. Only
  `dceEmit` — which writes `<sub-program>/<mod>.c.nif` — and `dceLive` are
  per-sub-program, and together they are **23 of the 44 ms, the single biggest
  item.**
* Across the five sub-programs the seven stdlib modules produce **12 distinct
  `.c.nif` files out of 35 `dceEmit` runs** (`assertions`, `fenv`,
  `formatfloat`, `math` 1 each; `system` 2; `syncio` 3; `writenif` 3). So
  content-addressing that output turns 23 of the 35 runs into hits.

## 2. The `nimony s` child, exactly

`exprexec.executeExpr` → `semos.runEval` → (engine) `evalThroughEngine` →
`buildEvalProgram`, which is one `execCmdEx` of

```
nimony <c.commandLineArgs> --ctfe-analysis-only --nimcache:<nc> s <sfx>.p.nif
```

In that child, `nimony.nim`'s `SemCheckNif` calls `deps.buildGraph`, which runs
two graphs and then returns early because `config.ctfeAnalysisOnly` is set:

* `<sfx>.build.nif` — 30 `nifler` + 5 `nimsem` nodes (the whole import closure;
  on a warm cache only the snippet's `nimsem` is stale),
* `<sfx>.final1.build.nif` — 8 `hexer` + 1 `dceLive` + 8 `dceEmit` (only the
  snippet's `hexer` is stale).

Since A2b the nodes of both graphs run **in-process inside that child**
(`nifmake-report … inproc=5` and `inproc=10`). So the child is not paying for
nifmake or for per-node processes any more; what it pays for is *being a
process at all*, plus re-deriving a build graph the parent already has all the
inputs for.

## 3. Why the parent cannot simply call `deps.buildGraph`

Three obstacles, each of which the implementation has to answer:

1. **`deps` imports `semos`**, so `semos` cannot import `deps`. The in-process
   entry point therefore has to be installed as a hook: `deps.nim` sets it at
   module init, `semos.nim` declares it. This is the one new module-level
   `var` the phase adds, and it is forced by the module graph the way
   `dag.runNodeRelay` is.
2. **Every in-process phase resets the frontend globals.** `phases.runPhaseInproc`
   calls `semmain.resetFrontendGlobals()` (pools, `prog`, identstyle,
   file-line cache) before each node, which is exactly right for a scheduler
   running unrelated modules back to back and exactly fatal for a *nested*
   build: the parent's live `SymId`/`StrId` universe would be replaced under
   it.
3. **`runMake` `quit`s when a graph fails.** The subprocess form returns a
   non-zero exit code and `runEval` turns the captured output into the `const`
   site's error message.

### The re-entrancy design: move the frontend aside, not share it

`notes/a2a-front.md` §4 proposed a fresh `SemContext` *sharing* `prog` and the
pool. This phase does something stronger and much simpler, because what has to
be re-entrant is not one `semExpr` but a whole nested *compilation* (nimsem,
hexer, dceLive, dceEmit, each of which insists on a reset):

```
snapshot = take the frontend globals    (pool, globalTags, prog)
install fresh, empty ones
  … run the sub-program's graphs exactly as a fresh process would …
put the snapshot back; drop the lazily-rebuilt style tables
```

`nifpools.pool` and `nifpools.globalTags` are `ref`s and `programs.prog` is a
plain object of tables, so taking and putting back is a handful of pointer
moves — O(1), not a copy of the pool. `nifcore.TokenBuf` captures the
`Pool`/`TagPool` it was created with, so the parent's buffers keep decoding
against the moved-aside pool the whole time and are correct again the moment it
is put back. A `ptr ToplevelEntry` handed out by `programs.getEntry` stays
valid too: moving `prog` moves the table *headers*, not the heap the entries
live in, and the nested build allocates its own.

This is a stronger guarantee than sharing would give: inside the window the
process is bit-for-bit a fresh `nimony s`, so the sub-program's `.dce.nif`
ordering (which A2a-hexer showed depends on how many strings were interned
before the module) is identical to the spawned form, and afterwards the parent
is exactly where it was. Nothing in `sem.nim` has to become re-entrant.

`identstyle`'s three tables are not exported and cannot be moved from outside;
they are indexes *derived* from `pool.strings` and rebuilt lazily, so the
restore calls the exported `resetStyleTables()` and lets them rebuild. That is
correct rather than merely cheap. `filelinecache` is keyed by path and holds
file text, not ids, so it needs neither.

## 4. What is deliberately not done

* **nimsem does not link hexer and lengc.** The plan asked for it, but since
  A2b the process that runs sem for an ordinary `nimony c` is `bin/nimony`,
  which already links all three and already has the phase relay installed:
  `deps.inProcessMakeAvailable()` is true there. `bin/nimsem` is only reached
  when the scheduler decided to *spawn* a nimsem node, and there the
  sub-compile keeps spawning `nimony s` exactly as before. Linking the tools
  into nimsem as well would double its binary and its build time to speed up a
  path the scheduler already avoids, and `phases.nim` imports `nimsem`, so
  nimsem cannot import `phases` back without a module cycle — and `phases.nim`
  is not this phase's to change. Measured consequence: see §7 of the
  implementation notes.
* **The `--vfs` default stays `disk`.** See §8.

## 5. Local workarounds outside the owned files

None. `identstyle.nim`, `programs.nim`, `nifpools.nim`, `phases.nim` and
`src/nifmake/dag.nim` are untouched: the snapshot is built from their
already-exported `pool`/`globalTags`/`prog` and `resetStyleTables`.

Two files outside the owner list were edited, neither of them on the DO-NOT
list, and both by one line each in service of a test the plan asks for:

* `src/hastur/ctfediff.nim` — "add that comparison to the ctfe_diff runner:
  compare the *parent* module's `.s.nif` too". The runner is that file;
  `tests/ctfe_diff/setup.nim` only calls into it.
* `src/nimony/semdecls.nim` — `compileMacroPlugin` needed the caller's
  `baseDir` to build a sub-compile's config, so its one call site passes it.

---

# Phase A2c — what was built

## 6. The two steps, and what each one measured

`bench/results/2026-09-06/a2c.txt` carries the tables and the raw runs. The
short version, one NEW evaluation of a `tmyops` const on a warm stdlib
nimcache:

| | per evaluation |
|---|---|
| before | 42.6 ms |
| after | 26.8 ms |

taken step by step while the phase was built, on a busier machine:

| | per evaluation |
|---|---|
| before | 42.8 ms |
| the `nimony s` process removed | 36.0 ms |
| the stdlib closure's `.c.nif` shared | 30.4 ms |

### 6.1 The sub-build, in the compiler's own process

`deps.runEvalBuild` is installed on `semos.evalBuildInProcess` at `deps`'
module init. It answers `EvalBuildUnavailable` when
`deps.inProcessMakeAvailable()` is false — a bare `bin/nimsem`, a nimony-built
nimony, or `--spawn:always` — and the caller then spawns exactly as before.
That is also what keeps `hastur boot` honest: a booted compiler takes the old
path and the phase is not in its picture at all.

`deps.childArgs` rebuilds the state a spawned `nimony <args> s <project>` would
have had. It only has to cover `--path`, `-d:release`/`-d:danger` and what
`cli.parseCommonOption` forwards, because every nimony-specific option sets
`forwardArg = false`; the epilogue of `compileProgram` (linker defaults,
`checkFlags`, the two `nimNative*` defines) is replayed after. The check that
this is right is not the reading: it is that `--spawn:always` and the default
leave 260 byte-identical `.nif` artifacts in one nimcache, the two
`*.build.nif` of every sub-program included.

`runMake` grew a `nested` mode that returns `false` instead of `quit`ting. A
sub-program that does not compile used to be a child's non-zero exit code; in
this process a `quit` would be a dead compiler for a bad `const`.

### 6.2 The frontend snapshot, and why it is not "share `prog` and the pool"

`notes/a2a-front.md` §4 proposed a fresh `SemContext` sharing `prog` and the
pool. What has to be re-entrant here is not one `semExpr` but a whole nested
*compilation*: nimsem, hexer, `dceLive` and `dceEmit`, each of which begins
with `semmain.resetFrontendGlobals()` inside `phases.runPhaseInproc`. Sharing
is not available to them.

So `semos.takeFrontendState` moves `pool`, `globalTags` and `prog` aside and
installs empty ones; `restoreFrontendState` moves them back and drops
`identstyle`'s lazy indexes. Inside the window the process IS a fresh
`nimony s` — every phase gets its reset, the pool starts empty, and the
sub-program's `.dce.nif` ordering (which A2a-hexer showed depends on how many
strings were interned before the module) is bit-for-bit the spawned form's.
Outside it the caller finds its own universe where it left it.

Why it is cheap: `Pool`/`TagPool` are `ref`s and `Program` is an object of
tables, so this is a handful of pointer moves. Why it is safe: `TokenBuf`
captures the pool it was created with, so the caller's live buffers keep
decoding throughout; and moving `prog` moves the table headers rather than the
heap its entries live on, so a `ptr ToplevelEntry` from `programs.getEntry`
stays valid while the nested build allocates its own.

The evidence is `tests/ctfe_diff`: every mode pair now compares the CALLING
module's `.s.nif` as well as each evaluation's `.out.nif`, and the pair that
makes the statement is `--ctfe:subprocess` (which still spawns a whole
`nimony s` and cannot touch this process's state at all) against the default.
79 `.s.nif` per pair, 0 differences, over four pairs.

### 6.3 The `.c.nif` cache

Described in `bench/results/2026-09-06/a2c.txt` §4 and in `deps.nim`'s own
comment. The key is the module's slice of `<main>.live.nif` plus the
`resolved` entries not owned by the main module plus a digest of its `.x.nif`.
Validated two ways: the keys partition `tmyops`' 35 emissions into exactly its
12 distinct outputs, and 518 `.c.nif` across eleven programs are byte-identical
to a `NIMONY_CCACHE=off` compile.

The `.x.nif` digest is memoized in a `<modname>.xdig` sidecar under the mtime
it was taken for. A stamp alone would have been cheaper, but the entry NAME has
to be nimcache-independent or `tests/nifcache` sees the same three files under
six names — which is exactly what the first cut did.

## 7. What was NOT done, and the number

* **nimsem does not link hexer and lengc.** The plan asked for it. Since A2b
  the process that runs sem for an ordinary `nimony c` is `bin/nimony`, which
  already links all three and already has the relay installed, so the whole
  win is available there. `bin/nimsem` is reached only when the scheduler
  decided to SPAWN a nimsem node, and there the sub-compile keeps spawning.
  Linking the tools into nimsem too would roughly double its size and its
  build time (A2b measured nimony at 2.91 -> 4.77 MB and ~1.6 -> ~4.0 s for
  exactly this) to speed up a path the scheduler already avoids — and
  `phases.nim` imports `nimsem`, so nimsem cannot import `phases` back without
  a module cycle, and `phases.nim` is not this phase's to change.
* **`runMacroPlugin`'s in-process handoff.** `compileMacroPlugin` goes through
  the new path (its `nimony s` spawn is gone), but `runMacroPlugin` itself
  execs a standalone plugin EXECUTABLE over the file protocol, which JIT.md
  calls a documented contract and which no registered phase can stand in for.
  There is nothing to hand over in-process until a plugin can be loaded as
  code, which is B3/B4's `nimrun`.
* **`--vfs` default.** Measured, no gain: 36.0 ms (disk) vs 35.9 ms
  (memory+spill) per new evaluation. Stays `disk`; nothing was added to the
  ephemeral list.
* **`dceLive`, 8.5 ms**, is now the largest single phase of an evaluation and
  cannot be content-addressed: its output depends on the main module's roots
  by construction. See a2c.txt §5 for the two ways out, both outside this
  phase's files.

## 9. The one regression, and what found it

The first cut of the graph split left the hexer and `dceLive` nodes in BOTH
the `fpLive` and the `fpAnalysis` graph. hexer writes `.x.nif` OnlyIfChanged,
so a node whose output kept its old mtime is stale forever under nifmake's
mtime rule, and it ran twice per sub-program. The fresh-evaluation measurement
could not see it — there hexer is up to date and a doubled node costs nothing.
A FORCED rebuild is the one scenario where hexer is genuinely stale, and there
it cost +48 ms per evaluation, a 31 % `ctfe.forced` regression.

`bench/devloop_ab.sh /tmp/a2c_before . ctfe.forced 5` is what found it, and
the same script is why it was not mistaken for drift: the block runs of the
same afternoon reported `hello.forced` at +12.6 % cpu, which the interleaved
run then measured at -4.3 %. Two block runs of a 12-scenario table are minutes
apart, and the drift between them is the same size as a 5 % signal.

Emitting hexer and `dceLive` for `fpLive` only — `fpAnalysis` is now the
`dceEmit`-only graph — brings `ctfe.forced` to 0.974x of the toolchain without
this phase and leaves the new-evaluation figure unchanged.

## 8. What still `quit`s

Unchanged from `notes/a2b.md` §3.1 for the phases themselves. One thing did
change class: a build GRAPH that fails inside a nested sub-build now returns
`false` instead of `quit`ting, so `runEval` reports it at the `const` site.
The diagnostics of the failing phase reach this process's stdout directly
rather than a child's captured output, so the text a user sees for a `const`
that does not compile is the phase's own message instead of the same message
re-emitted by the parent. `hastur tests/nimony` (794/794 in both `--ctfe`
modes) is what says no `.msgs` golden depended on the old spelling.

