## The incremental-build regression: drive `nimony c --report` through a fixed
## sequence of scenarios and assert which phases actually re-ran.

import std / [syncio, os, osproc, strutils, times, algorithm, sequtils]

# ---- Incremental-build regression test ------------------------------------
# `nifmake --report` prints a machine-readable summary of which commands
# actually executed during one nifmake invocation. We drive `bin/nimony c
# --report` over `tests/incremental/sample.nim` through a sequence of
# scenarios and assert on the per-phase counts. This catches mtime-tracking
# regressions (e.g. tools that drift back into "always rewrite" and trigger
# perpetual rebuilds, or staleness checks that miss real edits) without
# the brittleness of comparing file timestamps.

type ReportEntry = tuple[cmd: string, count: int]

proc parseNifmakeReports*(output: string): seq[seq[ReportEntry]] =
  ## Each `nifmake-report …` line in `output` becomes one inner seq. Lines
  ## without entries (an up-to-date no-op) yield an empty seq plus the
  ## sentinel `total=0` entry that nifmake always emits.
  result = @[]
  for line in output.splitLines:
    if not line.startsWith("nifmake-report"): continue
    var entries: seq[ReportEntry] = @[]
    for part in line.split(' '):
      if part.len == 0 or part == "nifmake-report": continue
      let eq = part.find('=')
      if eq < 0: continue
      try: entries.add((part[0 ..< eq], parseInt(part[eq+1 .. ^1])))
      except ValueError: discard
    result.add entries

proc reportField*(entries: seq[ReportEntry]; cmd: string): int =
  for e in entries:
    if e.cmd == cmd: return e.count
  result = 0

proc mainHexedPerBackend(cache: string): seq[(string, string)] =
  ## `(directory name, content of the main module's .x.nif)` for every backend
  ## directory under `cache`. `deps.backendDirName` gives each backend its own
  ## `<mainmod><tag>/`, and only the main module's `.x.nif` lives in one (the
  ## imported modules' copies are shared, at the cache root), so this is one
  ## entry per backend that has built here.
  result = @[]
  for kind, dir in walkDir(cache):
    if kind != pcDir: continue
    for f in walkFiles(dir / "*.x.nif"):
      result.add (dir.lastPathPart, readFile(f))
  sort result


proc ctfeStamps(cache: string; buildOnly: bool): seq[(string, string)] =
  ## `(name, mtime)` for the artifacts of every compile-time evaluation in
  ## `cache`. Each evaluation owns `<sfx>.out.nif` (rewritten when the
  ## sub-program RAN again) and a `<sfx>/` directory of `.c`/`.o`/exe
  ## (rewritten when its BUILD nodes ran again). `buildOnly` keeps just the
  ## second group, which is what `-f` on the outer compile must leave alone.
  ##
  ## The mtime is formatted rather than compared as a `Time` so a phase can
  ## diff two snapshots as plain values, and it keeps nanoseconds: a
  ## sub-program is fast enough to be rebuilt twice within one second.
  result = @[]
  const outSuffix = ".out.nif"
  for f in walkFiles(cache / "*" & outSuffix):
    let base = f.lastPathPart
    let sfx = base[0 ..< base.len - outSuffix.len]
    if not buildOnly:
      let t = getLastModificationTime(f)
      result.add (base, $t.toUnix & "." & $t.nanosecond)
    let dir = cache / sfx
    if dirExists(dir):
      for g in walkFiles(dir / "*"):
        let t = getLastModificationTime(g)
        result.add (sfx / g.lastPathPart, $t.toUnix & "." & $t.nanosecond)
  sort result

proc modeTag(mode: string): string =
  ## A directory-safe stem for a mode string, so two modes can be run in the
  ## same tree without sharing a nimcache. `--vfs:memory+spill` -> `vfsmemoryspill`.
  result = ""
  for c in mode:
    if c in {'a'..'z', 'A'..'Z', '0'..'9'}: result.add c

proc modeLabel(mode: string): string =
  if mode.len > 0: " (" & mode & ")" else: ""

proc incrementalTests*(mode = "") =
  ## Drive `bin/nimony c --report` through a fixed sequence of scenarios on
  ## `tests/incremental/sample.nim` and assert the per-nifmake-invocation
  ## command counts. Fails the run on the first divergence; restores the
  ## sample file regardless of outcome.
  ##
  ## `mode` is extra flags handed to every `nimony` invocation, and it also
  ## names this run's nimcache: the suite runs the whole sequence once per VFS
  ## mode (`tests/incremental/setup.nim`), and the counts asserted below must
  ## come out the same under each — a store that changed what nifmake
  ## considers stale would show up here as a rebuild count, which is the
  ## cheapest possible detector for it.
  let t0 = epochTime()
  let src = "tests/incremental/sample.nim"
  let dep = "tests/incremental/inlinedep.nim"
  let modeFlag = if mode.len > 0: " " & mode else: ""
  let suffix = if mode.len > 0: "-" & modeTag(mode) else: ""
  let cache = "nimcache" / ("incremental" & suffix)
  let nimony = "bin" / "nimony".addFileExt(ExeExt)
  for f in [src, dep]:
    if not fileExists(f):
      quit "incremental: " & f & " missing"
  if not fileExists(nimony):
    quit "incremental: " & nimony & " not found; run `hastur build nimony` first"
  removeDir cache

  # `-r` so every phase also RUNS the result: a rebuild that nifmake skipped
  # when it should not have leaves a stale binary behind, and a report count
  # alone would not notice (see the `inline-dep` phase).
  let baseCmd = nimony.quoteShell & " c -r --silentMake --report" & modeFlag &
                " --nimcache:" & cache.quoteShell & " " & src.quoteShell
  let originalSrc = readFile(src)
  let originalDep = readFile(dep)

  proc restoreSources() =
    writeFile(src, originalSrc)
    writeFile(dep, originalDep)

  var lastOutput = ""
  proc run(label: string): seq[seq[ReportEntry]] =
    let (output, ec) = execCmdEx(baseCmd)
    lastOutput = output
    if ec != 0:
      stdout.write output
      restoreSources()
      quit "incremental: '" & label & "' compile failed"
    parseNifmakeReports(output)

  var failures: seq[string] = @[]
  template expect(cond: bool; msg: string) =
    if not (cond): failures.add msg

  # Phase 1: cold cascade — both nifmake invocations should run real work.
  block:
    let r = run("cold")
    expect r.len == 2, "cold: expected 2 nifmake invocations, got " & $r.len
    if r.len == 2:
      expect reportField(r[0], "total") > 0, "cold: frontend ran 0 commands"
      expect reportField(r[1], "total") > 0, "cold: backend ran 0 commands"

  # Phase 2: no-op rebuild — both reports should show total=0.
  block:
    let r = run("noop")
    if r.len == 2:
      expect reportField(r[0], "total") == 0,
             "noop: frontend re-ran " & $reportField(r[0], "total") & " commands"
      expect reportField(r[1], "total") == 0,
             "noop: backend re-ran " & $reportField(r[1], "total") & " commands"

  # Phase 3: touch (no content change). nifler reruns to find content
  # unchanged — its OnlyIfChanged write preserves `.p.nif`'s mtime, so
  # nimsem and the backend must stay idle.
  block:
    setLastModificationTime(src, getTime())
    let r = run("touch")
    if r.len == 2:
      expect reportField(r[0], "nifler") >= 1,
             "touch: nifler did not re-run"
      expect reportField(r[0], "nimsem") == 0,
             "touch: nimsem ran " & $reportField(r[0], "nimsem") & " times (expected 0)"
      expect reportField(r[1], "total") == 0,
             "touch: backend ran " & $reportField(r[1], "total") & " commands (expected 0)"

  # Phase 4: real content edit — full cascade.
  block:
    writeFile(src, originalSrc & "\necho \"incremental edited\"\n")
    let r = run("edit")
    if r.len == 2:
      expect reportField(r[0], "nimsem") >= 1,
             "edit: nimsem did not re-run"
      expect reportField(r[1], "total") > 0,
             "edit: backend ran 0 commands"
    # Undo the edit and let the cache settle on the restored file, so the next
    # phase's only change is the one it makes itself.
    writeFile(src, originalSrc)
    discard run("resettle")

  # Phase 5: edit an IMPORTED module's `.inline` proc and nothing else. The
  # importer's own `.c.nif` still says only "call bump"; the body is spliced
  # in one stage later, by lengc, out of the callee's `.c.nif`. So the
  # importer's codegen depends on a file that is not its own input unless
  # `deps.addInlineSourceInputs` declares it, and without that edge nifmake
  # leaves the importer's `.c` untouched: a link error when the edit moves a
  # symbol the splice names, and a silently stale binary when it does not
  # (nim-lang/nimony#1897). Two `.c` files must be regenerated here — the
  # callee's, because its body changed, and the importer's, because of the
  # splice — and the program has to print the NEW value.
  block:
    writeFile(dep, originalDep.replace("x + 1", "x + 1000"))
    let r = run("inline-dep")
    if r.len == 2:
      expect reportField(r[1], "lengc") >= 2,
             "inline-dep: lengc ran " & $reportField(r[1], "lengc") &
             " times (expected the callee's and the importer's)"
    expect lastOutput.contains("1010"),
           "inline-dep: ran a stale inlined body; expected the program to print 1010"

  restoreSources()

  # Phase 6: switch backends without touching a source file. `nimony c` and
  # `nimony n` do not produce the same artifacts from the same input — hexer
  # alone runs with or without `--native`, which changes the main module's
  # `.x.nif` — and nifmake reruns a node only when its input or output FILES
  # changed, never when a tool's FLAGS did. So sharing one directory would not
  # make the second backend overwrite the first: it would make it reuse the
  # first one's artifacts, silently, for as long as the sources hold still.
  # `deps.backendDirName` keeps the two populations apart; assert that both
  # exist afterwards, that they disagree, and that the C build the native one
  # ran on top of came through untouched.
  var phases = 5
  let arkham = "bin" / "arkham".addFileExt(ExeExt)
  let nifasm = "bin" / "nifasm".addFileExt(ExeExt)
  if fileExists(arkham) and fileExists(nifasm):
    inc phases
    block:
      let before = mainHexedPerBackend(cache)
      expect before.len == 1,
             "backend-switch: expected 1 backend directory before, got " & $before.len
      let nativeCmd = nimony.quoteShell & " n -r --silentMake --report" & modeFlag &
                      " --nimcache:" & cache.quoteShell & " " & src.quoteShell
      let (nativeOut, nativeEc) = execCmdEx(nativeCmd)
      if nativeEc != 0:
        stdout.write nativeOut
        restoreSources()
        quit "incremental: 'backend-switch' native compile failed"
      let after = mainHexedPerBackend(cache)
      expect after.len == 2,
             "backend-switch: expected a directory per backend, got " & $after.len &
             " (" & after.mapIt(it[0]).join(", ") & ")"
      if after.len == 2 and before.len == 1:
        expect after[0][1] != after[1][1],
               "backend-switch: both backends stored the same main .x.nif"
        let cBefore = after.filterIt(it[0] == before[0][0])
        expect cBefore.len == 1 and cBefore[0][1] == before[0][1],
               "backend-switch: the native build rewrote the C backend's main .x.nif"

  # Phases 7-11: files read at COMPILE TIME that no source file mentions —
  # what a `.plugin` reports through `plugins.dependsOn` and what `slurp`
  # folds (nim-lang/nimony#1378). Nothing in the module's own inputs changes
  # when such a file is edited, so without the `(dependency …)` bookkeeping
  # the `.s.nif` looks current forever and the program keeps printing the old
  # contents. Driven from a fixture of its own so the plugin build node does
  # not perturb the counts asserted above.
  let depSrc = "tests/incremental/plugindep.nim"
  let pluginData = "tests/incremental/plugindata.txt"
  let slurpData = "tests/incremental/slurpdata.txt"
  let depCache = "nimcache" / ("incremental-deps" & suffix)
  if fileExists(depSrc) and fileExists(pluginData) and fileExists(slurpData):
    phases += 5
    let originalPluginData = readFile(pluginData)
    let originalSlurpData = readFile(slurpData)
    removeDir depCache
    let depCmd = nimony.quoteShell & " c -r --silentMake --report" & modeFlag &
                 " --nimcache:" & depCache.quoteShell & " " & depSrc.quoteShell

    var depOutput = ""
    proc runDep(label: string): seq[seq[ReportEntry]] =
      let (output, ec) = execCmdEx(depCmd)
      depOutput = output
      if ec != 0:
        stdout.write output
        writeFile(pluginData, originalPluginData)
        writeFile(slurpData, originalSlurpData)
        restoreSources()
        quit "incremental: '" & label & "' compile failed"
      parseNifmakeReports(output)

    # Phase 7: cold build establishes the baseline and records both files.
    block:
      discard runDep("dep-cold")
      expect depOutput.contains("plugin-one"),
             "dep-cold: plugin did not read its data file"
      expect depOutput.contains("slurp-one"),
             "dep-cold: slurp did not read its data file"

    # Phase 8: nothing changed — the extra inputs must not make the node
    # perpetually stale.
    block:
      let r = runDep("dep-noop")
      if r.len == 2:
        expect reportField(r[0], "total") == 0,
               "dep-noop: frontend re-ran " & $reportField(r[0], "total") & " commands"
        expect reportField(r[1], "total") == 0,
               "dep-noop: backend re-ran " & $reportField(r[1], "total") & " commands"

    # Phase 9: edit the file the PLUGIN reads. Two caches have to give way —
    # nifmake's (the module is re-semmed at all) and `runPlugin`'s memo of the
    # plugin output, which is keyed on the input tree and so did not change.
    block:
      writeFile(pluginData, "plugin-two")
      let r = runDep("dep-plugin-edit")
      if r.len == 2:
        expect reportField(r[0], "nimsem") >= 1,
               "dep-plugin-edit: nimsem did not re-run"
      expect depOutput.contains("plugin-two"),
             "dep-plugin-edit: ran a stale plugin expansion; expected 'plugin-two'"

    # Phase 10: same for the file `slurp` folded.
    block:
      writeFile(slurpData, "slurp-two")
      let r = runDep("dep-slurp-edit")
      if r.len == 2:
        expect reportField(r[0], "nimsem") >= 1,
               "dep-slurp-edit: nimsem did not re-run"
      expect depOutput.contains("slurp-two"),
             "dep-slurp-edit: folded a stale slurp; expected 'slurp-two'"

    # Phase 11: DELETE the plugin's data file. It cannot be listed as a
    # nifmake input any more, so the re-sem is forced by dropping the output
    # instead — and that must happen exactly once. A run that keeps forcing it
    # is the failure mode this phase exists to catch: the re-sem no longer
    # records the file, so the build after it has to be a clean no-op.
    block:
      removeFile(pluginData)
      discard runDep("dep-delete")
      expect depOutput.contains("plugin-data-missing"),
             "dep-delete: kept a stale plugin expansion after the data file vanished"
      let r = runDep("dep-delete-settle")
      if r.len == 2:
        expect reportField(r[0], "total") == 0,
               "dep-delete-settle: frontend re-ran " & $reportField(r[0], "total") &
               " commands; a missing dependency must force ONE rebuild, not a loop"
    writeFile(pluginData, originalPluginData)
    writeFile(slurpData, originalSlurpData)

  # Phases 12-16: compile-time evaluation. A `const` that `expreval` cannot
  # fold makes `exprexec` compile and run a whole program (`semos.runEval`),
  # and the result is memoized in `<sfx>.out.nif`. These phases pin the two
  # halves of that memo: it must be reused when nothing the evaluation
  # depends on moved, and it must give way when something did — including a
  # file the sub-program read at RUN time, which no compiler phase can see.
  # Its own fixture again, so the extra sub-compiles do not perturb the
  # counts asserted above.
  let ctfeSrc = "tests/incremental/ctfedep.nim"
  let ctfeData = "tests/incremental/ctfedata.txt"
  let ctfeCache = "nimcache" / ("incremental-ctfe" & suffix)
  if fileExists(ctfeSrc) and fileExists(ctfeData):
    phases += 5
    let originalCtfeData = readFile(ctfeData)
    removeDir ctfeCache
    let ctfeCmd = nimony.quoteShell & " c -r --silentMake --report" & modeFlag &
                  " --nimcache:" & ctfeCache.quoteShell & " " & ctfeSrc.quoteShell

    var ctfeOutput = ""
    proc runCtfe(label: string; extraFlags = ""): seq[seq[ReportEntry]] =
      let (output, ec) = execCmdEx(ctfeCmd & extraFlags)
      ctfeOutput = output
      if ec != 0:
        stdout.write output
        writeFile(ctfeData, originalCtfeData)
        restoreSources()
        quit "incremental: '" & label & "' compile failed"
      parseNifmakeReports(output)

    # Phase 12: cold. Both consts are evaluated for real and the one that
    # reads a file must see it.
    block:
      let r = runCtfe("ctfe-cold")
      if r.len == 2:
        expect reportField(r[0], "total") > 0, "ctfe-cold: frontend ran 0 commands"
      expect ctfeOutput.contains("ctfe label: ctfe-one"),
             "ctfe-cold: the const did not read its data file"
      expect ctfeStamps(ctfeCache, buildOnly = false).len > 0,
             "ctfe-cold: no evaluation artifacts under " & ctfeCache

    # Phase 13: nothing changed. The `.reads` sidecars and the `(dependency …)`
    # entries they produce are extra inputs of the module's nimsem node, and
    # extra inputs are exactly how a node becomes perpetually stale.
    block:
      let r = runCtfe("ctfe-noop")
      if r.len == 2:
        expect reportField(r[0], "total") == 0,
               "ctfe-noop: frontend re-ran " & $reportField(r[0], "total") & " commands"
        expect reportField(r[1], "total") == 0,
               "ctfe-noop: backend re-ran " & $reportField(r[1], "total") & " commands"

    # Phase 14: touch without changing the bytes. nifler reruns and finds the
    # `.p.nif` unchanged, so nimsem never reaches the consts at all and no
    # sub-program may move.
    block:
      let before = ctfeStamps(ctfeCache, buildOnly = false)
      setLastModificationTime(ctfeSrc, getTime())
      let r = runCtfe("ctfe-touch")
      if r.len == 2:
        expect reportField(r[0], "nifler") >= 1, "ctfe-touch: nifler did not re-run"
        expect reportField(r[0], "nimsem") == 0,
               "ctfe-touch: nimsem ran " & $reportField(r[0], "nimsem") & " times (expected 0)"
      expect ctfeStamps(ctfeCache, buildOnly = false) == before,
             "ctfe-touch: a sub-program was rebuilt or rerun for a content-preserving touch"

    # Phase 15: edit the file the sub-program reads WHILE IT RUNS. Nothing in
    # the module's own inputs changed and no compiler phase saw the read —
    # `readFile` is a plain call, not `slurp` — so two things have to work:
    # `runEval` reported the path through `recordFileDep`, which makes the
    # module stale at all, and the memo noticed the same path is newer than
    # its `.out.nif`.
    block:
      let before = ctfeStamps(ctfeCache, buildOnly = false)
      writeFile(ctfeData, "ctfe-two\nthe rest is ignored\n")
      let r = runCtfe("ctfe-data-edit")
      if r.len == 2:
        expect reportField(r[0], "nimsem") >= 1,
               "ctfe-data-edit: nimsem did not re-run; the file the const read " &
               "is not an input of its module"
      expect ctfeOutput.contains("ctfe label: ctfe-two"),
             "ctfe-data-edit: served a stale evaluation; expected 'ctfe-two'"
      expect ctfeStamps(ctfeCache, buildOnly = false) != before,
             "ctfe-data-edit: no evaluation artifact moved"
      discard runCtfe("ctfe-data-settle")

    # Phase 16: `-f`. It is an instruction about the graph the user named, and
    # a sub-program is content-addressed, so forcing must not reach it.
    # Before the fix `-f` was forwarded to the inner `nimony s`, which deleted
    # and rebuilt all ~30 of its nodes per const. The evaluations themselves
    # may re-run here (a forced build re-sems every module, which rewrites the
    # `.s.nif` files the sub-programs link), but their BUILD must not.
    block:
      let before = ctfeStamps(ctfeCache, buildOnly = true)
      let r = runCtfe("ctfe-force", " -f")
      if r.len == 2:
        expect reportField(r[0], "total") > 0,
               "ctfe-force: -f did not rebuild the outer graph, so this phase proves nothing"
      expect ctfeStamps(ctfeCache, buildOnly = true) == before,
             "ctfe-force: -f leaked into a CTFE sub-compile and rebuilt its objects"
      expect ctfeOutput.contains("ctfe label: ctfe-two"),
             "ctfe-force: wrong value after a forced build"

    writeFile(ctfeData, originalCtfeData)

  let dt = epochTime() - t0
  if failures.len > 0:
    for f in failures: stderr.writeLine "incremental" & modeLabel(mode) & ": " & f
    quit "FAILURE: " & $failures.len & " incremental phase(s) failed."
  echo "incremental", modeLabel(mode), ": ", phases, " / ", phases,
       " phases successful in ", formatFloat(dt, ffDecimal, precision=2), "s."

# ---- Compile-time-eval object cache ---------------------------------------
# Every `const` that `expreval` cannot fold costs a whole sub-program, and
# almost all of it is the `std/writenif` stdlib closure -- the same modules for
# every sub-program in the same nimcache. `deps.buildGraph` therefore routes a
# sub-program's non-main objects through the content-addressed
# `<nimcache>/ocache/`. These phases assert that the second program's
# sub-compile really reuses the first one's objects rather than recompiling
# them into its own backend directory.

proc ocacheObjects(cache: string): seq[(string, Time)] =
  ## `(path, mtime)` of every object in the content-addressed cache, sorted.
  ## An entry's path IS its identity, so a second build that adds no path and
  ## touches no mtime did not run `cc` for any module it shares.
  result = @[]
  for f in walkFiles(cache / "ocache" / "*.o"):
    result.add (f, getLastModificationTime(f))
  sort result

proc evalSubProgramDirs(cache: string): seq[string] =
  ## Backend directories of compile-time-eval sub-programs.
  ## `semos.runProgram` builds `<sfx>.p.nif` and runs
  ## `<cache>/<sfx>/<sfx>.p`, so that executable's name is what separates a
  ## sub-program's directory from an ordinary module's.
  result = @[]
  for kind, dir in walkDir(cache):
    if kind != pcDir: continue
    let name = dir.lastPathPart
    if fileExists(dir / (name & ".p")):
      result.add name
  sort result

proc countObjects(dir: string): int =
  result = 0
  for f in walkFiles(dir / "*.o"): inc result

proc incrementalOCacheTests*(mode = "") =
  ## Compile two modules that each need a compile-time-eval sub-program into
  ## one nimcache and assert the second one's sub-compile reused the first's
  ## objects. The inner `nimony s` runs under `execCmdEx` and never sees
  ## `--report`, so the assertions are on the cache directory itself.
  let t0 = epochTime()
  let srcA = "tests/incremental/ctfe_ocache_a.nim"
  let srcB = "tests/incremental/ctfe_ocache_b.nim"
  let modeFlag = if mode.len > 0: " " & mode else: ""
  let cache = "nimcache" / ("ctfe_ocache" & (if mode.len > 0: "-" & modeTag(mode) else: ""))
  let nimony = "bin" / "nimony".addFileExt(ExeExt)
  for f in [srcA, srcB]:
    if not fileExists(f):
      quit "ctfe-ocache: " & f & " missing"
  if not fileExists(nimony):
    quit "ctfe-ocache: " & nimony & " not found; run `hastur build nimony` first"
  removeDir cache

  var failures: seq[string] = @[]
  template expect(cond: bool; msg: string) =
    if not (cond): failures.add msg

  proc run(src, label: string): string =
    # `-r` so the program also runs: a wrongly reused object would either fail
    # to link or produce the wrong number.
    let cmd = nimony.quoteShell & " c -r --silentMake" & modeFlag & " --nimcache:" &
              cache.quoteShell & " " & src.quoteShell
    let (output, ec) = execCmdEx(cmd)
    if ec != 0:
      stdout.write output
      quit "ctfe-ocache: '" & label & "' compile failed"
    result = output

  # Phase 1: cold. The sub-program's non-main modules land in the cache.
  let outA = run(srcA, "cold-a")
  expect outA.contains("49"), "cold-a: expected the program to print 49, got: " & outA
  let cachedA = ocacheObjects(cache)
  expect cachedA.len > 0,
         "cold-a: <nimcache>/ocache/ holds no objects; the sub-program's " &
         "objects were not content-addressed at all"
  let subDirsA = evalSubProgramDirs(cache)
  expect subDirsA.len == 1,
         "cold-a: expected 1 compile-time-eval sub-program, got " & $subDirsA.len

  # Phase 2: a second program with a different `const`. Its sub-program shares
  # every non-main module with the first one, so nothing new may be compiled:
  # no new cache entry, no touched mtime, and one object (the main module) in
  # the sub-program's own backend directory.
  let outB = run(srcB, "cold-b")
  expect outB.contains("27"), "cold-b: expected the program to print 27, got: " & outB
  let cachedB = ocacheObjects(cache)
  expect cachedB == cachedA,
         "cold-b: the object cache changed (" & $cachedA.len & " -> " &
         $cachedB.len & " entries, or an mtime moved); the second sub-program " &
         "recompiled modules the first one had already cached"
  let subDirsB = evalSubProgramDirs(cache)
  expect subDirsB.len == 2,
         "cold-b: expected 2 compile-time-eval sub-programs, got " & $subDirsB.len
  for d in subDirsB:
    if d in subDirsA: continue
    let n = countObjects(cache / d)
    expect n <= 1,
           "cold-b: the second sub-program compiled " & $n &
           " objects of its own; only its main module may be left"

  let dt = epochTime() - t0
  if failures.len > 0:
    for f in failures: stderr.writeLine "ctfe-ocache" & modeLabel(mode) & ": " & f
    quit "FAILURE: " & $failures.len & " ctfe-ocache phase(s) failed."
  echo "ctfe-ocache", modeLabel(mode), ": 2 / 2 phases successful in ",
       formatFloat(dt, ffDecimal, precision=2), "s."

# ---- The in-process scheduler (JIT_IMPL.md A2b) ---------------------------
# `nimony` runs its build graphs in its own process and calls the registered
# phases as procs (`src/nimony/phases.nim`). Three things have to hold and none
# of them is visible from a compile's exit code:
#
# 1. `--report`'s new `inproc=` field says how many nodes never reached a
#    process, and for an edit of one module of a small program every node
#    before `cc` is one of them.
# 2. The artifacts are the same bytes either way. That is the whole safety
#    argument for the phase: a reset that misses a global, or a pool whose
#    interning order differs, shows up as a differing `.nif` and nowhere else.
# 3. A compile-time evaluation's own sub-compile is spawn-free before `cc`
#    too. Its `--report` is not forwarded (P0a made the inner compile silent on
#    purpose), so the evidence is the cost ledger: a phase that ran in a
#    process leaves a `spawn` sample, and one that never did leaves none.

proc ledgerSpawnedPhases*(cache: string): seq[string] =
  ## Phases with a non-zero `spawn` sample in `<cache>/ledger.nif`.
  ##
  ## Read by scanning the text rather than through `src/lib/ledger.nim`: the
  ## file is a flat `(entry (phase "x") ... (spawn ns N) ...)` list, the scan is
  ## six lines, and the test then depends on the file the compiler wrote
  ## instead of on the reader it wrote it with.
  result = @[]
  let p = cache / "ledger.nif"
  if not fileExists(p): return
  var phase = ""
  for line in readFile(p).splitLines:
    let s = line.strip
    if s.startsWith("(phase \""):
      var rest = s["(phase \"".len .. ^1]
      let q = rest.find('"')
      if q >= 0: rest = rest[0 ..< q]
      phase = rest
    elif s.startsWith("(spawn ns ") and phase.len > 0:
      let v = s["(spawn ns ".len .. ^1]
      var num = ""
      for c in v:
        if c in {'0'..'9'}: num.add c
        else: break
      if num.len > 0 and num != "0" and phase notin result:
        result.add phase
  sort result

proc buildArtifacts*(cache: string): seq[string] =
  ## Relative paths of every `.nif` and `.c` under `cache`, minus the ones that
  ## record HOW the build ran rather than what it produced: the ledger snapshot
  ## and the per-directory `.ledger/` fragments hold timings, and timings are
  ## exactly what changes when a phase stops being a process.
  result = @[]
  let frag = DirSep & ".ledger" & DirSep
  for f in walkDirRec(cache, relative = true):
    if f.startsWith(".ledger" & DirSep) or f.contains(frag): continue
    if f.lastPathPart == "ledger.nif": continue
    let ext = f.splitFile.ext
    if ext == ".nif" or ext == ".c": result.add f
  sort result

proc normalizedArtifact*(cache, rel: string): string =
  ## An artifact's bytes with its own nimcache path replaced by a placeholder.
  ## `*.build.nif` names every input and output absolutely and a `.c` can carry
  ## the directory in a `#line`, so two runs into two directories differ there
  ## and only there -- the comparison would be worthless if it either kept
  ## those bytes or skipped those files.
  result = readFile(cache / rel)
  result = result.replace(absolutePath(cache), "<nimcache>")
  result = result.replace(cache, "<nimcache>")

proc incrementalInprocTests*() =
  ## `--report`'s `inproc` field, byte identity against `--spawn:always`, and a
  ## compile-time evaluation whose sub-compile spawns nothing before `cc`.
  let t0 = epochTime()
  let src = "tests/incremental/sample.nim"
  let ctfeSrc = "tests/incremental/ctfedep.nim"
  let nimony = "bin" / "nimony".addFileExt(ExeExt)
  if not fileExists(src):
    quit "inproc: " & src & " missing"
  if not fileExists(nimony):
    quit "inproc: " & nimony & " not found; run `hastur build nimony` first"
  var failures: seq[string] = @[]
  template expect(cond: bool; msg: string) =
    if not cond: failures.add msg
  var phases = 0

  let originalSrc = readFile(src)
  proc restoreSources() = writeFile(src, originalSrc)

  proc compile(cache, file, extra: string): seq[seq[ReportEntry]] =
    let cmd = nimony.quoteShell & " c --silentMake --report" & extra &
              " --nimcache:" & cache.quoteShell & " " & file.quoteShell
    let (output, ec) = execCmdEx(cmd)
    if ec != 0:
      stdout.write output
      restoreSources()
      quit "inproc: `" & cmd & "` failed"
    result = parseNifmakeReports(output)

  let cache = "nimcache" / "inproc"
  removeDir cache

  # Phase 1: a cold build runs most of the graph without a process.
  block:
    inc phases
    let r = compile(cache, src, "")
    expect r.len == 2, "cold: expected 2 build graphs, got " & $r.len
    if r.len == 2:
      let inproc = reportField(r[0], "inproc") + reportField(r[1], "inproc")
      expect inproc >= 5,
             "cold: only " & $inproc & " node(s) ran in-process; the " &
             "scheduler is not routing the frontend and backend phases"
      expect reportField(r[1], "cc") >= 1,
             "cold: the backend graph ran no `cc`, so this phase proves nothing"

  # Phase 2: a one-line edit. Every node of the frontend graph that runs is a
  # registered phase, and in the backend graph the only processes left are the
  # C compiler and the linker.
  #
  # `nifler` is subtracted rather than expected to be absent: it is the one
  # frontend phase that is still a process (it links Nim's own parser, which
  # cannot go into nimony -- see the header of `src/nimony/phases.nim`), and
  # whether it appears in the graph at all depends on whether
  # `deps.execNifler` already re-parsed the edited module during dependency
  # discovery.
  block:
    inc phases
    writeFile(src, originalSrc & "\necho \"inproc-edit\"\n")
    let r = compile(cache, src, "")
    expect r.len == 2, "edit: expected 2 build graphs, got " & $r.len
    if r.len == 2:
      let feTotal = reportField(r[0], "total")
      let feSpawned = feTotal - reportField(r[0], "inproc") -
                      reportField(r[0], "nifler")
      expect feTotal > 0, "edit: the frontend graph re-ran nothing"
      expect feSpawned == 0,
             "edit: the frontend graph spawned " & $feSpawned &
             " node(s) that are not nifler"
      let beTotal = reportField(r[1], "total")
      let beInproc = reportField(r[1], "inproc")
      let spawnable = reportField(r[1], "cc") + reportField(r[1], "link")
      expect beTotal - beInproc == spawnable,
             "edit: the backend graph spawned " & $(beTotal - beInproc) &
             " node(s) but only " & $spawnable & " are cc/link"
      expect beInproc >= 3,
             "edit: only " & $beInproc & " backend node(s) ran in-process"
  restoreSources()

  # Phase 3: the same source built cold into two nimcaches, once with the
  # scheduler and once with `--spawn:always`. Every `.nif` and every `.c` must
  # match byte for byte with the nimcache path normalised away. This is the
  # phase that would catch a reset that missed a global: the pool's interning
  # order is what `.dce.nif` and `.live.nif` serialise.
  block:
    inc phases
    let cacheA = "nimcache" / "inproc-auto"
    let cacheB = "nimcache" / "inproc-spawn"
    removeDir cacheA
    removeDir cacheB
    discard compile(cacheA, src, "")
    discard compile(cacheB, src, " --spawn:always")
    let a = buildArtifacts(cacheA)
    let b = buildArtifacts(cacheB)
    expect a.len > 0, "identity: no artifacts under " & cacheA
    expect a == b,
           "identity: the two modes produced different artifact SETS (" &
           $a.len & " vs " & $b.len & ")"
    var differing: seq[string] = @[]
    for rel in a:
      if rel notin b: continue
      if normalizedArtifact(cacheA, rel) != normalizedArtifact(cacheB, rel):
        differing.add rel
    expect differing.len == 0,
           "identity: " & $differing.len & " artifact(s) differ between the " &
           "scheduler and --spawn:always: " & differing.join(", ")

  # Phase 4: a compile-time evaluation. Its sub-compile is a whole second
  # `nimony s` process with its own two build graphs, and those have to be
  # spawn-free before `cc` as well. The inner `--report` is deliberately not
  # forwarded (P0a), so the ledger is the witness: `runDag` folds a `spawn`
  # sample for every node that reached a process, and a phase that never did
  # has none.
  if fileExists(ctfeSrc):
    inc phases
    let ctfeCache = "nimcache" / "inproc-ctfe"
    removeDir ctfeCache
    discard compile(ctfeCache, ctfeSrc, "")
    let spawned = ledgerSpawnedPhases(ctfeCache)
    for p in ["nimsem", "hexer", "dce", "dceLive", "dceEmit", "lengc"]:
      expect p notin spawned,
             "ctfe: `" & p & "` has a spawn sample in the ledger, so some " &
             "build -- the outer one or a sub-program's -- ran it as a process"
    expect "cc" in spawned or "link" in spawned,
           "ctfe: the ledger recorded no spawn at all, so this phase cannot " &
           "tell a spawn-free frontend from a build that never happened"

  let dt = epochTime() - t0
  if failures.len > 0:
    for f in failures: stderr.writeLine "inproc: " & f
    quit "FAILURE: " & $failures.len & " inproc phase(s) failed."
  echo "inproc: ", phases, " / ", phases, " phases successful in ",
       formatFloat(dt, ffDecimal, precision=2), "s."
