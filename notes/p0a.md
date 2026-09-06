# Phase P0a — research notes

Findings collected before editing, per `JIT_IMPL.md` "Execution rules for
agents" rule 3. Line numbers are from the fork point (`f69b8afc`).

## 1. The `-f` leak

`src/nimony/nimony.nim` `handleCmdLine` declares `var forwardArg = true`
(line 219) inside the `cmdLongOption, cmdShortOption` branch and appends the
raw `--key[:val]` to `c.commandLineArgs` at the end (lines 303-312) unless the
option's branch clears it. Ten options already clear it (`run`/`r`,
`boundchecks`, `silentmake`, `profile`, `report`, `stats`, `ischild`,
`native`, `passc`, `passl`) — every option that is consumed locally into
`buildFlags`/`config` rather than needing to reach a downstream tool's own CLI
parser.

`forcebuild`/`f` (line 250) and `ff` (lines 251-253) do **not** clear it:

    of "forcebuild", "f": c.buildFlags.incl ForceRebuild
    of "ff":
      c.fullRebuild = true
      c.buildFlags.incl ForceRebuild

`c.fullRebuild` is write-only (declared line 166, set here, never read), so
`--ff` is today a synonym of `-f`.

Splice sites of `commandLineArgs` (every place it becomes a child argv):

| file:line | what |
|---|---|
| `nimony.nim:397,401,407,412,417` | into `processSingleModule` / `buildGraph` |
| `deps.nim:2113-2129` | `buildGraph` hands it to `generateFrontendBuildFile` |
| `deps.nim:795-814` (`emitFrontendArgs`), called at `1773,1782,1795` | splits on spaces, emits each token into the `nimsem`/`idetools`/`pluginbuild` `cmd` of the `.build.nif` |
| `nimsem.nim:101-145` | nimsem re-parses that argv; its own arm `of "forcebuild", "f", "ff": forceRebuild = true` (line 136) also leaves `forwardArg = true`, so the token is re-appended to nimsem's local `commandLineArgs` |
| `semdata.nim:219` | that string becomes `SemContext.commandLineArgs` |
| `semos.nim:359` (`selfExec`) | `nimony <args> --ischild m <file>` |
| `semos.nim:741-743` (`prepareEval`) | `nimony <args> --nimcache:... c std/writenif.nim` |
| `semos.nim:699-701` (`runProgram`, from `runEval:769`) | **`nimony <args> --nimcache:... s <sfx>.p.nif`** — the CTFE sub-compile |
| `macro_plugin.nim:279,321` | same shape for macro-plugin sub-compiles |

Plugin builds are *not* affected: `pluginCompileCmd` (`semos.nim:373-414`)
deliberately does not forward the raw command line.

End of the chain: the child `nimony s` re-enters `handleCmdLine`, sets
`ForceRebuild`, and `deps.nim:2134-2135` turns that into `nifmake --force`.
`nifmake.nim:342,404-405` short-circuits `needsRebuild` on `Force in opt` and
calls `removeOutdatedArtifacts` first, so every node of the CTFE sub-program
(nifler, nimsem, hexer, lengc, cc, link) is deleted and rebuilt on every
single const evaluation. Fix: `forwardArg = false` in both branches, and the
matching arm in `nimsem.nim`.

## 2. What `runEval` does, and what a memo must watch

`semos.nim:752 runEval` writes, into `nifcachePath`:

- `<sfx>.p.nif` via `nifindexes.writeFileAndIndex` — an **unconditional**
  `vfsWrite`, so the mtime bumps on every call even for byte-identical
  content.
- `<sfx>.s.idx.nif` as a side effect of `writeFileAndIndex` calling
  `createIndex`: the doc-mode check only special-cases `.sc.nif`, so a
  `.p.nif` input yields `.s.idx.nif`. That is the *sub-compile's own* index
  file, which the inner `nimony s` then overwrites from real semchecking.
  Rewriting it from the `.p.nif` on every call is itself a staleness trigger
  for the inner nimsem node.
- `<sfx>.p.deps.nif` via plain `writeFile` — also unconditional.

`<sfx>.out.nif` is **not** written by nimsem: `exprexec.executeExpr`
(line 728) bakes `setup("<abs>/<sfx>.out.nif")` / `teardown()` calls from
`lib/std/writenif.nim` into the generated program, and the *compiled binary*
writes it at run time. `runEval` only parses it back.

`<sfx>` = `thisModuleSuffix[0..2] & computeChecksum(mangle(expr, Frontend,
bits))` — a checksum of the triggering expression's mangled form only. It does
**not** cover the generated program body (which inlines same-module symbol
definitions via `collectUsedSymsFromExpr`), nor `importSnippets`. So the name
alone proves nothing; the memo's correctness has to come from mtimes.

The memo model to imitate is `runPlugin` (`semos.nim:634`):
`writeFileIfChanged` for the inputs, `programs.needsRecompile(exe, out)` for
"the tool is newer than its memo", `memoIsStale(out, deps)` for "a file the
cached output read has changed", the latter using `vfsMtime` nanoseconds.

Inputs that can change the result of one evaluation:

1. `<sfx>.p.nif` content (covers the expression *and* the inlined bodies).
2. `<sfx>.p.deps.nif` content (the import set).
3. The imported modules. The inner compile's `<sfx>.s.deps.nif` lists them as
   absolute `.nim` paths — verified by hand on
   `tests/nimony/consteval/tconstreadfile.nim`:
   `(stmts (import ".../system.nim" ".../writenif.nim" ".../syncio.nim"
   ".../strutils.nim" ".../assertions.nim"))`. That is the **direct** import
   set only; a transitively imported module that changed is not listed, so the
   memo additionally has to notice that *some* module in the nimcache was
   re-semmed. The cheap conservative proxy is the newest `*.s.nif` in the
   nimcache, computed once per nimsem process.
4. Files read during the sub-compile — the `(dependency ...)` entries of
   `<sfx>.s.deps.nif` (a `slurp` or a plugin inside the sub-program).
5. Files read **at run time by the sub-program binary**. This is the hard one
   and is discussed below.
6. The toolchain (`getAppFilename()`, i.e. the running nimsem).

## 3. The `readFile` hole

`tests/nimony/consteval/tconstreadfile.nim` is
`const version = readFile("doc/version.md").splitLines()[0]`.

`slurp`/`staticRead` is folded natively by `expreval.nim` in the *outer*
nimsem and calls `recordFileDep`, so it lands in the outer module's
`.s.deps.nif` and `deps.nim` makes it an input of the next build's nimsem
node. Plain `readFile` is not a magic: the expression falls through to
`executeExpr`, and the file is opened by the **generated binary** at run time,
in `runProgram`'s second `execCmdEx(runCmd, workingDir = sourceDir)`. Verified
on disk: the sub-program's `<sfx>.s.deps.nif` contains only the `(import ...)`
list, no `(dependency ...)` entry for `doc/version.md`.

So no NIF file anywhere records that read, and a memo keyed on the `.p.nif`
checksum plus imported-module mtimes would serve the stale string forever.
This is exactly the hazard `runPlugin`'s `(dependency ...)` sidecar closes for
plugins (nim-lang/nimony#1378) — a plugin *reports* its extra reads through
`plugins.dependsOn`.

Decision: give the sub-program the same reporting channel. `std/syncio` grows
an opt-in read log (off by default, one `bool` test per successful `fmRead`
`open`), `std/writenif.setup` turns it on and `teardown` writes the recorded
paths to `<sfx>.reads.nif` beside the result. `runEval` treats a missing
sidecar as "unknown" and re-runs, so an old nimcache costs exactly one extra
evaluation per expression.

## 4. `-d:vfsProfile`

`src/lib/vfs.nim` imports `std/[memfiles, syncio, times]` (line 31) but the
`when defined(vfsProfile)` wrapper procs (lines 264-311) call `getMonoTime()`,
which lives in `std/monotimes`. `inNanoseconds` is fine (it is in
`std/times`). `nim c -d:vfsProfile src/lib/vfs.nim` fails with
`undeclared identifier: 'getMonoTime'`. One-line fix.

`dumpVfsProfile` is already called by `lengc.nim:221`, `nifler.nim:96`,
`nimsem.nim:185`, `hexer.nim:159`, `nifmake.nim:835` — all in
`when isMainModule:` after the driver returns. Missing: `nimony.nim` (its
`when isMainModule:` ends with `compileProgram(c)`) and `niflink.nim` (no
`isMainModule` guard at all; the file ends with a bare `main()`).

## 5. `bench/` conventions

`bench/hastur.mode` contains `bench`; `src/hastur/category.nim:22-28` maps
that category to `c --silentMake -d:benchSmoke`. Every benchmark declares
`const smoke = defined(benchSmoke)` and sizes its workload with
`when smoke: <tiny> else: <real>`, printing only deterministic values.
`src/hastur/runner.nim:96-115` runs the produced exe and compares stripped
stdout against the `.output` golden.

## 6. `tests/incremental`

`bin/hastur test tests/incremental` sees `setup.nim` (`walk.nim:96`,
`walk.nim:58-66`), compiles and runs it, and that calls
`incrementaltests.incrementalTests()` through `kit.nim`.

The scenario DSL: a fixed `baseCmd` (`nimony c -r --silentMake --report
--nimcache:<cache> <src>`), a nested `run(label)` that runs it with `execCmdEx`
and returns `parseNifmakeReports(output)` (one inner seq per `nifmake-report`
line — index 0 is the frontend nifmake, index 1 the backend),
`reportField(r[i], "nimsem")` for per-command counts, and
`template expect(cond, msg)` which accumulates failures. Fixture sources are
**checked in** under `tests/incremental/` and edited in place, with
`restoreSources()` putting them back.

`nifmake --report` prints `nifmake-report <cmd>=<n> ... total=<N>`
(`nifmake.nim:697-715`). `runProgram` swallows the inner `nimony s`'s stdout
with `execCmdEx` and only surfaces it on failure, so the inner build is
invisible to the outer `--report`. Phase P0a adds a forwarding path for it so
the incremental test can assert on the inner node counts.
