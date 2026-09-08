#       Nimony
# (c) Copyright 2026 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## `nimony dev` — JIT.md 7.4's loop.
##
## > Watch → nifmake frontend → hexer for changed modules → `compileModule` →
## > classify → swap slots and bump generation, or restart the guest (fast,
## > since blobs load in milliseconds).
##
## Which is, here, exactly:
##
## 1. build the program the way `nimony r` builds it, plus `-d:nimonyDev` so
##    `std/devreload`'s safepoint is a real external;
## 2. digest it (`devclassify`) and start it in a `nimrun` process
##    (`engine.startDevGuest`);
## 3. watch the sources; on a change, rebuild and digest again;
## 4. `classify` the two digests. **Reload**: ask the guest to swap the changed
##    procs at its next safepoint. **Restart**: stop the guest, say why in one
##    sentence, and start the new build.
##
## The one sentence is not decoration. A restart that happens without saying
## why is indistinguishable from a bug in the reloader, and it is the failure
## mode this command exists to avoid — so `rvRestart` always carries a reason
## naming the declaration and what about it changed, and it is printed before
## the guest is stopped.
##
## What the watcher is
## -------------------
##
## Modification times, polled. `lib/std/posix/kqueue.nim` is in the tree and is
## the event-driven answer, but it is the NIMONY standard library: it is
## importable by a program nimony compiles, and `nimony` itself is compiled by
## `nim c`. Polling is portable to all three hosts for free, and the interval
## below is far under the time a rebuild takes, so it is not what bounds the
## loop. Replacing it with kqueue/inotify/`ReadDirectoryChangesW` is a
## self-contained follow-up (`notes/b4.md`).
##
## The watched set is every `.nim` file under the project file's directory,
## minus the nimcache. That covers a program kept in one place, which is what a
## dev loop is for; an edit to the standard library is not noticed, and the
## command says so on startup rather than being quietly wrong about it.

import std / [os, times, tables, strutils, syncio, algorithm]

import engine
import devclassify

type
  Watcher* = object
    ## The files being watched and what they looked like last time. An explicit
    ## record rather than two parallel tables: the answer wanted is "what
    ## changed", and that needs the previous state and the current one side by
    ## side.
    root*: string
    skip*: string                    ## the nimcache, which the build rewrites
    stamps*: Table[string, Time]

  DevOptions* = object
    ## What `nimony dev` was asked for, minus everything `CmdOptions` already
    ## carries. `intervalMs` is here so a test can make the loop tight.
    intervalMs*: int
    verbose*: bool
    once*: bool
      ## Stop after the first edit has been handled. What makes the loop
      ## testable: a test that has to kill a watcher to end it cannot tell
      ## "finished" from "hung".
    maxEdits*: int
      ## Stop after this many edits (0 = unlimited). `once` is `maxEdits == 1`
      ## spelled for a person.

proc initWatcher*(root, skip: string): Watcher =
  result = Watcher(root: root, skip: skip, stamps: initTable[string, Time]())

proc scan(w: var Watcher; into: var Table[string, Time]) =
  into = initTable[string, Time]()
  for f in walkDirRec(w.root):
    if not f.endsWith(".nim"): continue
    if w.skip.len > 0 and f.startsWith(w.skip): continue
    try:
      into[f] = getLastModificationTime(f)
    except OSError:
      discard

proc prime*(w: var Watcher) =
  ## Record the starting state. Separate from `changed` so the first call to
  ## that cannot report every file as new.
  scan(w, w.stamps)

proc changed*(w: var Watcher; names: var seq[string]): bool =
  ## Which watched files have a different modification time than last time.
  ## Updates the record, so an edit is reported once.
  var now = initTable[string, Time]()
  scan(w, now)
  names = @[]
  for f, t in now:
    if not w.stamps.hasKey(f) or w.stamps[f] != t: names.add f
  for f in w.stamps.keys:
    if not now.hasKey(f): names.add f
  w.stamps = now
  names.sort()
  result = names.len > 0

# ── the loop ────────────────────────────────────────────────────────────────

type
  BuildOnce* = proc (ctx: pointer; backendDir, mainModule: var string): string
                    {.nimcall.}
    ## Rebuild the program and report where its backend directory and main
    ## module ended up; "" on success, a diagnostic otherwise.
    ##
    ## A proc pointer plus an explicit context rather than a closure
    ## (AGENTS.md), and a hook at all because the build graph lives in
    ## `nimony.nim` -- `deps` is not importable from here without dragging the
    ## whole driver in, and the loop below is about the LOOP, not about how a
    ## build is spelled.

  DevLoop* = object
    ## Everything one `nimony dev` session is.
    opts*: DevOptions
    watcher*: Watcher
    guest*: DevGuest
    program*: RunProgram
    digest*: ProgramDigest
    build*: BuildOnce
    buildCtx*: pointer
    reloads*, restarts*, edits*: int

proc note(d: DevLoop; msg: string) =
  ## Everything this command says goes to stderr, and for the reason
  ## `runWholeProgram` puts the timing line there: stdout belongs to the
  ## PROGRAM, and `nimony dev prog.nim > out` must put the program's output in
  ## `out`.
  stderr.writeLine "[dev] " & msg
  flushFile stderr

proc startGuest(d: var DevLoop): bool =
  let err = startDevGuest(d.program, d.guest)
  if err.len > 0:
    d.note "cannot start the program: " & err
    return false
  result = true

proc rebuild(d: var DevLoop): bool =
  ## Build, and pick up where the artifacts went. False means the build failed,
  ## which is NOT a restart: the running program is still the last one that
  ## compiled, and leaving it alone is the whole point of a dev loop.
  var backendDir = ""
  var mainModule = ""
  let err = d.build(d.buildCtx, backendDir, mainModule)
  if err.len > 0:
    d.note "build failed; the running program is unchanged"
    return false
  d.program.backendDir = backendDir
  d.program.mainModule = mainModule
  result = true

proc handleEdit(d: var DevLoop; files: seq[string]) =
  var shown = ""
  for f in files:
    if shown.len > 0: shown.add ", "
    shown.add f.extractFilename
  d.note "changed: " & shown
  let before = d.digest
  if not rebuild(d): return
  let after = digestProgram(d.program.backendDir)
  let plan = classify(before, after)
  d.digest = after

  case plan.verdict
  of rvUnchanged:
    d.note "nothing the program can see changed"
  of rvReload:
    var reason = ""
    var stack = ""
    var gen = 0
    var names = ""
    for c in plan.changed:
      if names.len > 0: names.add ", "
      names.add c
    let reply = askSwap(d.guest, d.program.backendDir, d.program.mainModule,
                        d.program.blobCacheDir, plan.changed, reason, stack, gen)
    case reply
    of srSwapped:
      inc d.reloads
      d.note "reloaded generation " & $gen & ": " & names
      if d.opts.verbose and stack.len > 0:
        d.note "  guest stack at the swap: " & stack
    of srDeferred:
      # A deferral is not a failure and not a restart: the guest is asked again
      # at its next safepoint, which is where JIT.md 7.4 says a swap waits.
      d.note "deferred: " & reason & "; retrying"
      let again = askSwap(d.guest, d.program.backendDir, d.program.mainModule,
                          d.program.blobCacheDir, plan.changed, reason, stack, gen)
      if again == srSwapped:
        inc d.reloads
        d.note "reloaded generation " & $gen & ": " & names
      else:
        d.note "restart: the swap could not be applied (" & reason & ")"
        stopDevGuest d.guest
        inc d.restarts
        discard startGuest(d)
    of srFailed:
      d.note "restart: " & reason
      stopDevGuest d.guest
      inc d.restarts
      discard startGuest(d)
    of srGone:
      d.note "the program ended before the swap could be applied"
  of rvRestart:
    # The gate's second half: the reason comes FIRST, and it names the
    # declaration.
    d.note "restart: " & plan.reason
    stopDevGuest d.guest
    inc d.restarts
    if startGuest(d):
      d.note "restarted"

proc run*(d: var DevLoop): int =
  ## The loop. Returns what the shell should see: the program's status if it
  ## ended on its own, 0 if the loop stopped because it was told to.
  d.digest = digestProgram(d.program.backendDir)
  d.watcher.prime()
  if not startGuest(d): return 1
  d.note "watching " & $d.watcher.stamps.len & " file(s) under " &
    d.watcher.root & "; edit a proc body to reload, a signature to restart"

  let limit = (if d.opts.once: 1 else: d.opts.maxEdits)
  while true:
    if pollDevGuest(d.guest):
      if d.guest.final.outcome == roRefused:
        d.note "the program could not be run: " & d.guest.final.reason
        return 1
      d.note "the program ended (status " & $d.guest.final.status & ")"
      return d.guest.final.status
    var files: seq[string] = @[]
    if d.watcher.changed(files):
      inc d.edits
      handleEdit(d, files)
      if limit > 0 and d.edits >= limit:
        d.note "done: " & $d.reloads & " reload(s), " & $d.restarts &
          " restart(s)"
        stopDevGuest d.guest
        return 0
    sleep d.opts.intervalMs
