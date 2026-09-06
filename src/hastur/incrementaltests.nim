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

proc incrementalTests*() =
  ## Drive `bin/nimony c --report` through a fixed sequence of scenarios on
  ## `tests/incremental/sample.nim` and assert the per-nifmake-invocation
  ## command counts. Fails the run on the first divergence; restores the
  ## sample file regardless of outcome.
  let t0 = epochTime()
  let src = "tests/incremental/sample.nim"
  let dep = "tests/incremental/inlinedep.nim"
  let cache = "nimcache" / "incremental"
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
  let baseCmd = nimony.quoteShell & " c -r --silentMake --report --nimcache:" &
                cache.quoteShell & " " & src.quoteShell
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
      let nativeCmd = nimony.quoteShell & " n -r --silentMake --report --nimcache:" &
                      cache.quoteShell & " " & src.quoteShell
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
  let depCache = "nimcache" / "incremental-deps"
  if fileExists(depSrc) and fileExists(pluginData) and fileExists(slurpData):
    phases += 5
    let originalPluginData = readFile(pluginData)
    let originalSlurpData = readFile(slurpData)
    removeDir depCache
    let depCmd = nimony.quoteShell & " c -r --silentMake --report --nimcache:" &
                 depCache.quoteShell & " " & depSrc.quoteShell

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
  let ctfeCache = "nimcache" / "incremental-ctfe"
  if fileExists(ctfeSrc) and fileExists(ctfeData):
    phases += 5
    let originalCtfeData = readFile(ctfeData)
    removeDir ctfeCache
    let ctfeCmd = nimony.quoteShell & " c -r --silentMake --report --nimcache:" &
                  ctfeCache.quoteShell & " " & ctfeSrc.quoteShell

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
    for f in failures: stderr.writeLine "incremental: " & f
    quit "FAILURE: " & $failures.len & " incremental phase(s) failed."
  echo "incremental: ", phases, " / ", phases, " phases successful in ",
       formatFloat(dt, ffDecimal, precision=2), "s."
  echo "SUCCESS."
