#       Nimony
# (c) Copyright 2026 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## `nimrun` -- the out-of-process guest loader, JIT.md 7.3's *"`nimrun` loader
## over a pipe: crash isolation, trivial TLS and exit"*.
##
## It is the sibling of nativenif's `tools/nifrun`, and the difference is the
## whole reason it exists: `nifrun` is a CLI a person types, so it takes a file
## name and prints; `nimrun` is spoken to by a compiler over
## `guestwire.GuestControlFd` and answers with a record. What it DOES between
## those two is not its own code at all -- it calls
## `engine.runWholeProgram`, the same proc `nimony r` calls in its own process.
##
## That is deliberate and it is the design's main claim: running a program out
## of process is not a second implementation of running a program. The
## assembler, the arena, the symbol resolution, the thread-spawner refusal, the
## blob cache and the `--verbose` line are one body of code that has moved to
## the other side of a `posix_spawn`, so "byte-identical to `nimony r`" is a
## property of the arrangement rather than a thing to keep two copies in step
## about.
##
## What the boundary buys, exactly
## -------------------------------
##
## * **`exit` costs nothing.** `hostrun.guestExit` parks the calling thread
##   forever because there is no way back out of a guest frame. Here that
##   thread, its 8 MB stack and the 256 MB arena are all reclaimed by the
##   kernel a moment later, when this process ends. In the compiler they were
##   permanent -- which is why `notes/b1-nimony.md` says a `nimony dev`
##   "would have to, and cannot" release the arena.
## * **a fault is contained.** A guest that dereferences null kills `nimrun`.
##   The compiler sees `gxSignalled` from `waitpid` and re-raises the same
##   signal on itself only if it wants the shell to see it
##   (`guestwire.reraiseAsGuestDid`), which is what `nimony r` does and what
##   `nimony dev` will not.
## * **many programs, one compiler.** Each program gets a `nimrun` of its own.
##   That is not a limitation worked around; it is the point. One loader
##   process runs exactly one image, so nothing accumulates anywhere and there
##   is never a second guest for `runImage` to refuse.
##
## Descriptors 0, 1 and 2 are inherited untouched -- the program's stdin, stdout
## and stderr are the user's, with no copying in between.

import std / [os, posix, strutils]
import guestwire
import engine
import devhost

import nifasm / hostrun
import nifasm / image / memory

const
  Version = "0.1.0"
  Usage = "nimrun - run a nimony native program in a process of its own " &
    Version & """

Usage:
  nimrun --control-fd:N

`nimrun` is not meant to be typed. A compiler spawns it with one end of an
AF_UNIX socketpair on descriptor N (`src/nimony/guestwire.nim`), sends it a
`run` record naming a backend directory full of `.asm.nif` modules, and reads
back the program's outcome. `nimony r --guest:subprocess` is the command that
does that; `bin/nifasm`'s `nifrun` is the equivalent for a bare `.asm.nif`.

Options:
  --control-fd:N   speak the guest protocol on descriptor N
  --help, -h       show this help
  --version, -v    show version
"""

type
  Loader = object
    ## Everything one `nimrun` process is: the channel it was spawned with and
    ## the request it read off it. An object rather than three locals because
    ## the failure paths all need to answer on the same channel.
    chan: GuestChannel
    haveChannel: bool

  DevState = object
    ## What the safepoint intercept needs, and the ONE thing in this file that
    ## has to be a module-level `var`.
    ##
    ## The same argument `nifasm/hostrun` makes for `gGuest` and `engine` makes
    ## for `gIo`: an intercept is reached through a C function pointer the GUEST
    ## holds, so it can carry no context but a global. It is sound for the same
    ## reason -- one guest runs at a time in one process, and this process runs
    ## exactly one guest -- and it is only ever touched on the guest's thread,
    ## inside a call the guest made, while the loader's main thread is parked in
    ## `waitForGuest`.
    active: bool
    session: DevSession
    chan: ptr GuestChannel
    backendDir, mainModule, blobCacheDir: string
    verbose: bool
    trace: bool
      ## `NIMONY_DEV_TRACE=1`: say what the reload session decided, on stderr.
      ## An environment variable rather than a flag because the interesting
      ## moment is inside a process the user did not type a command line for --
      ## the same reason `NIFASM_PROFILE` is one.
    polls: int
      ## How many safepoints the guest has reached. Reported with the final
      ## record, because "the program never polled" and "the program polled and
      ## nothing was pending" are different failures and look the same from
      ## outside.

var gDev: DevState

proc failOut(msg: string) {.noreturn.} =
  ## A refusal that could not be reported on the channel. stderr, because
  ## stdout is the program's.
  stderr.writeLine "nimrun: " & msg
  flushFile stderr
  quit 1

proc decodeRun(fields: openArray[string]; p: var RunProgram): string =
  ## `run` record -> `RunProgram`; "" on success, a diagnostic otherwise.
  ##
  ## Positional, and the positions are the ones `engine.encodeRunRequest`
  ## writes. A field count that does not match is a version skew the handshake
  ## should already have caught, so it is reported rather than tolerated.
  if fields.len < 6:
    return "a `run` record with " & $fields.len & " fields (want at least 6)"
  p.backendDir = fields[1]
  p.mainModule = fields[2]
  p.blobCacheDir = fields[3]
  p.verbose = 'v' in fields[4]
  p.profile = 'p' in fields[4]
  p.dev = 'd' in fields[4]
  var argc = 0
  for ch in fields[5]:
    if ch notin {'0' .. '9'}: return "a malformed argument count: " & fields[5]
    argc = argc * 10 + (ord(ch) - ord('0'))
  if fields.len != 6 + argc:
    return "a `run` record promising " & $argc & " arguments and carrying " &
      $(fields.len - 6)
  p.argv = @[]
  for i in 0 ..< argc: p.argv.add fields[6 + i]
  result = ""

proc devPollIntercept(): int {.cdecl.} =
  ## `nimony_dev_poll` (`lib/std/devreload.nim`), answered here.
  ##
  ## Three things are true at this instant and all three are what make hot
  ## reload possible at all:
  ##
  ## * we are on the GUEST's thread, in a frame the guest called into, so a
  ##   stack walk has the synchronous seed the trace table needs
  ##   (`notes/b4.md` 1a);
  ## * the guest is not running any of its own code, so patching a proc entry
  ##   races with nothing (the guest is single-threaded by construction:
  ##   `image/memory.nim` refuses an image with a thread-local, and
  ##   `engine.ThreadSpawners` refuses one that can create a thread);
  ## * the loader's main thread is parked in `waitForGuest` and touches neither
  ##   `gDev` nor the channel, so both are ours alone.
  ##
  ## Returns the reload generation, which is what the program sees.
  inc gDev.polls
  if not gDev.active:
    # The image was loaded but the reload session refused (`devLoaded` said
    # why, on stderr). The program still runs; it just never reloads, and the
    # generation it sees stays 0.
    return 0
  # Non-blocking: a program that polls every iteration must not be held up by a
  # compiler that has nothing to say.
  while gDev.chan[].hasPending():
    var fields: seq[string] = @[]
    if not gDev.chan[].recvFields(fields): break
    if fields.len == 0 or fields[0] != "swap":
      discard gDev.chan[].sendFields(["failed", "0",
        "the loader expected a `swap` record at a safepoint"])
      break
    # ["swap", backendDir, mainModule, blobCacheDir, <n>, name...]
    if fields.len < 5:
      discard gDev.chan[].sendFields(["failed", "0", "a short `swap` record"])
      break
    var changed: seq[string] = @[]
    for i in 5 ..< fields.len: changed.add fields[i]
    var res: SwapResult
    gDev.session.swap(fields[1], fields[2], fields[3], changed, res)
    case res.outcome
    of swSwapped:
      if gDev.trace:
        stderr.writeLine "[nimrun] swapped to generation " & $res.generation &
          " at poll " & $gDev.polls & "; stack: " & res.stack
        flushFile stderr
      discard gDev.chan[].sendFields(["swapped", $res.generation, "", res.stack])
    of swDeferred:
      # NOT consumed: the compiler is told to ask again, and the state the swap
      # needs is all in the record it will send again.
      discard gDev.chan[].sendFields(["deferred", $res.generation, res.reason,
                                      res.stack])
    of swRefused:
      discard gDev.chan[].sendFields(["failed", $res.generation, res.reason,
                                      res.stack])
  result = gDev.session.generation

proc devLoaded(ctx: pointer; arena: Arena; img: MemImage): string {.nimcall.} =
  ## `engine.LoadedHook`: the image is laid out, bound and executable, and the
  ## guest has not started. Build the reload session now, because the guest may
  ## reach its first safepoint before anything else runs.
  ##
  ## `ctx` is unused -- the state this fills in is `gDev`, which the intercept
  ## has to reach through a global anyway, so a second handle on it would be a
  ## second thing to keep in step.
  result = initDevSession(arena, img, gDev.session)
  if gDev.trace:
    stderr.writeLine "[nimrun] dev session: " &
      (if result.len == 0: "ready" else: "refused -- " & result)
    flushFile stderr
  if result.len == 0: gDev.active = true

proc encodeResult(r: RunResult): seq[string] =
  ## `RunResult` -> a reply record. The timings go out as `key=value` pairs
  ## rather than as fixed positions: a column added to `EngineTimings` must not
  ## be able to make an older host misread the ones it does know.
  result = @[(if r.outcome == roRan: "ran" else: "refused"), $r.status, r.reason]
  result.add "assembleMs=" & $r.timings.assembleMs
  result.add "emitRootsMs=" & $r.timings.emitRootsMs
  result.add "layMs=" & $r.timings.layMs
  result.add "bindMs=" & $r.timings.bindMs
  result.add "runMs=" & $r.timings.runMs
  result.add "totalMs=" & $r.timings.totalMs
  result.add "codeLen=" & $r.timings.codeLen
  result.add "dataLen=" & $r.timings.dataLen
  result.add "externals=" & $r.timings.externals
  result.add "blobCache=" & (if r.timings.blobCache: "1" else: "0")
  result.add "blobHits=" & $r.timings.blobHits
  result.add "blobStale=" & $r.timings.blobStale
  result.add "blobRecorded=" & $r.timings.blobRecorded

proc main() =
  var controlFd = -1
  var i = 1
  while i <= paramCount():
    let p = paramStr(i)
    let eq = p.find(':')
    let key = (if eq >= 0: p[0 ..< eq] else: p).normalize
    let val = if eq >= 0: p[eq+1 .. ^1] else: ""
    case key
    of "--controlfd", "--control-fd":
      try:
        controlFd = parseInt(val)
      except ValueError:
        failOut "--control-fd wants a descriptor number, got '" & val & "'"
    of "--help", "-h": quit(Usage, QuitSuccess)
    of "--version", "-v": quit(Version, QuitSuccess)
    else: failOut "unknown option " & p
    inc i
  if controlFd < 0:
    failOut "no --control-fd; `nimrun` is spawned by the compiler, not typed " &
      "(see --help)"

  var loader = Loader(chan: openChannel(controlFd.cint), haveChannel: true)

  # The handshake first, so that a version skew is a diagnostic from the host
  # rather than a reply it cannot parse. It is also the liveness proof: a host
  # that reads this knows `posix_spawn` found a real `nimrun`.
  if not loader.chan.sendFields(["hello", $GuestProtocolVersion]):
    failOut "the control channel closed before the handshake"

  var fields: seq[string] = @[]
  if not loader.chan.recvFields(fields):
    failOut "the compiler closed the control channel before sending a request"
  if fields.len == 0:
    failOut "an empty control record"
  if fields[0] != "run":
    failOut "an unknown control verb '" & fields[0] & "'"

  var p = RunProgram(backendDir: "", mainModule: "", argv: @[],
                     verbose: false, profile: false, blobCacheDir: "",
                     dev: false)
  let bad = decodeRun(fields, p)
  if bad.len > 0:
    discard loader.chan.sendFields(["refused", "0", "nimrun received " & bad])
    failOut "received " & bad

  var e = initEngine()
  var r: RunResult
  if p.dev:
    # `nimony dev`: answer the guest's safepoint, and take the arena and the
    # image at the moment they become final.
    gDev.chan = addr loader.chan
    gDev.backendDir = p.backendDir
    gDev.mainModule = p.mainModule
    gDev.blobCacheDir = p.blobCacheDir
    gDev.verbose = p.verbose
    gDev.trace = getEnv("NIMONY_DEV_TRACE").len > 0
    r = runWholeProgram(e, p,
      [HostIntercept(name: "nimony_dev_poll",
                     fn: cast[pointer](devPollIntercept))],
      devLoaded, nil)
  else:
    r = runWholeProgram(e, p)

  # The reply goes out BEFORE this process ends, and it is the only thing that
  # does: everything the program wrote went straight to the inherited
  # descriptors while it ran.
  flushFile stdout
  flushFile stderr
  discard loader.chan.sendFields(encodeResult(r))

  # `_exit`, not `quit`: `runWholeProgram` leaves a parked guest thread and an
  # arena that is deliberately not released (`engine.nim`'s `finally` says
  # why), and running Nim's exit machinery over that is work whose only
  # possible outcomes are "the same" and "a crash in a process the compiler is
  # already reading a reply from". The status is the guest's so that a `nimrun`
  # inspected by hand still reports something true; the compiler reads the
  # record, not this.
  discard posix.close(loader.chan.fd)
  exitnow(if r.outcome == roRan: r.status.cint else: 1.cint)

when isMainModule:
  main()
