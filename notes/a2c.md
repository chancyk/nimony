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
* Across the five sub-programs the seven stdlib modules produce **11 distinct
  `.c.nif` files out of 35 `dceEmit` runs** (`assertions`, `fenv`,
  `formatfloat`, `math` 1 each; `system` 2; `syncio` 3; `writenif` 3). So
  content-addressing that output would turn 24 of the 35 runs into hits.

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

None. `identstyle.nim`, `programs.nim`, `nifpools.nim` and `phases.nim` are
untouched: the snapshot is built from their already-exported
`pool`/`globalTags`/`prog` and `resetStyleTables`.
