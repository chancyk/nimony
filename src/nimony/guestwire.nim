#       Nimony
# (c) Copyright 2026 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## The wire between a compiler and an out-of-process guest loader (`nimrun`),
## JIT.md 7.3's *"out-of-process guest for whole programs (`nimrun` loader over
## a pipe: crash isolation, trivial TLS and exit)"*.
##
## Why there is a second way to run a program at all
## -------------------------------------------------
##
## `engine.runWholeProgram` maps an arena in the COMPILER's process and calls
## the guest's `main` on a thread of its own. Two properties of that are fine
## for `nimony r`, which runs one program and exits, and are fatal for
## `nimony dev`, which runs many without a fresh compiler process:
##
## * **`exit` parks a thread forever.** `nifasm/hostrun.guestExit` cannot
##   return into the guest's frame -- the three ways out are `longjmp`,
##   unwinding and not leaving -- so it records the status, wakes the host and
##   sleeps. Every guest that exits leaks a thread and its 8 MB stack.
## * **the arena is never released**, because that parked thread's frames are
##   in it (`notes/b1-nimony.md`, "Not done").
##
## A process boundary answers both at once, and answers a third thing nothing
## else can: a guest that faults takes only its own process down.
##
## The protocol
## ------------
##
## One `AF_UNIX` `socketpair`, duplicated onto a fixed descriptor in the child
## (`GuestControlFd`), which is told about it with `--control-fd:`. A
## socketpair rather than two pipes because the channel is bidirectional and
## one descriptor is one thing to inherit, to close and to get wrong.
##
## **fd 0, 1 and 2 are NOT ours.** They are inherited untouched, so the guest's
## stdout IS the user's stdout -- no copying, no interleaving decision, and no
## deadlock from a full pipe nobody is draining. That is also what makes the
## out-of-process run byte-identical to the in-process one for free.
##
## Records are length-framed and binary-safe, because an argument may contain
## anything a shell can pass:
##
## ```
##   <fieldCount>\n
##   <byteLen>\n<bytes>          -- fieldCount times, no separator after
## ```
##
## Decimal counts and a newline are enough: nothing here is hot (one record
## each way per program), and a framing a person can read in `xxd` is worth
## more during a phase that is bringing a new process into the toolchain than
## a compact one would be.
##
## Three record shapes, distinguished by field 0:
##
## * `hello`   loader -> host, once, at start: `["hello", <version>]`. It is
##             the handshake AND the liveness proof -- a `nimrun` from an older
##             toolchain is diagnosed here rather than by a reply that does not
##             parse.
## * `run`     host -> loader: what to assemble and run.
## * `ran` / `refused`  loader -> host: `RunResult`, flattened.
##
## Nothing in this module knows what a `RunProgram` is: `engine` maps its
## records onto these fields and `nimrun` maps them back, so the assembler and
## the arena stay on one side of the boundary and the compiler's build graph on
## the other.

import std / [os, posix, strutils]

const
  GuestProtocolVersion* = 1
    ## Bumped when a field changes meaning. The host refuses a `nimrun` that
    ## answers with a different one, because the alternative is a run that
    ## silently ignored a flag.
  GuestControlFd* = 3.cint
    ## Where the socketpair lands in the child. 3 is the first descriptor
    ## POSIX leaves to the application, and a FIXED number rather than a
    ## negotiated one because the negotiation would need a channel.
  MaxFieldBytes = 64 * 1024 * 1024
    ## A field longer than this is a desynchronized stream, not an argument.
    ## Refusing it is what keeps a garbled length from becoming a 2 GB
    ## allocation in the compiler.

type
  GuestChannel* = object
    ## One end of the control socket, plus the bytes read ahead of what has
    ## been asked for. `recv` on a stream socket returns what it has, not what
    ## was asked for, so a reader that did not buffer would lose the head of
    ## the next record.
    fd*: cint
    buf: string
    pos: int
    broken*: bool   ## the peer closed or errored; every later call is a no-op

  GuestLaunch* = object
    ## A spawned loader: the process and the channel to it. One object because
    ## neither is usable without the other and both have to be released.
    pid*: Pid
    chan*: GuestChannel
    alive*: bool

  GuestExitKind* = enum
    gxExited      ## ran to completion; `code` is its exit status
    gxSignalled   ## killed by `signal` -- a guest fault, which is now ONLY
                  ## the loader's process
    gxUnknown     ## `waitpid` failed or reported something else

  GuestExit* = object
    kind*: GuestExitKind
    code*: int
    signal*: int

proc guestTermSignal*(): int {.inline.} =
  ## What `nimony dev` sends a guest it is replacing. A proc rather than a
  ## `const` because `SIGTERM` is an imported C macro and has no compile-time
  ## value here.
  int(SIGTERM)

# ── framing ─────────────────────────────────────────────────────────────────

proc openChannel*(fd: cint): GuestChannel =
  result = GuestChannel(fd: fd, buf: "", pos: 0, broken: false)

proc writeAll(fd: cint; s: string): bool =
  ## `write(2)` until the whole buffer is gone. A short write on a socket is
  ## ordinary, not an error, and `EINTR` is not one either.
  var off = 0
  while off < s.len:
    let n = posix.write(fd, addr s[off], s.len - off)
    if n > 0:
      off += n.int
    elif n < 0 and errno == EINTR:
      continue
    else:
      return false
  result = true

proc fill(c: var GuestChannel): bool =
  ## One `read(2)` appended to the buffer. False at end of stream.
  var tmp = newString(8192)
  while true:
    let n = posix.read(c.fd, addr tmp[0], tmp.len)
    if n > 0:
      # Drop what has already been consumed while we are here: the buffer is
      # otherwise append-only for the life of the channel.
      if c.pos > 0:
        c.buf = c.buf[c.pos .. ^1]
        c.pos = 0
      c.buf.add tmp[0 ..< n.int]
      return true
    elif n == 0:
      c.broken = true
      return false
    elif errno == EINTR:
      continue
    else:
      c.broken = true
      return false

proc readLine(c: var GuestChannel; dest: var string): bool =
  ## One newline-terminated header line. The line itself is never long: it is a
  ## decimal count.
  dest.setLen 0
  while true:
    while c.pos < c.buf.len:
      let ch = c.buf[c.pos]
      inc c.pos
      if ch == '\n': return true
      dest.add ch
      if dest.len > 32:
        c.broken = true
        return false
    if not c.fill(): return false

proc readExactly(c: var GuestChannel; n: int; dest: var string): bool =
  dest.setLen 0
  while dest.len < n:
    if c.pos >= c.buf.len:
      if not c.fill(): return false
    let take = min(n - dest.len, c.buf.len - c.pos)
    dest.add c.buf[c.pos ..< c.pos + take]
    c.pos += take
  result = true

proc parseCount(s: string; dest: var int): bool =
  ## Digits by hand rather than `parseInt`: a desynchronized stream must be a
  ## refusal, never an exception raised out of the middle of a build.
  if s.len == 0 or s.len > 12: return false
  var v = 0
  for ch in s:
    if ch notin {'0' .. '9'}: return false
    v = v * 10 + (ord(ch) - ord('0'))
  dest = v
  result = true

proc sendFields*(c: var GuestChannel; fields: openArray[string]): bool =
  ## One record, one `write`. Assembled into a single string first so that a
  ## reader on the other side never sees a half-written header -- and so that
  ## the record is one syscall rather than 2n+1.
  if c.broken: return false
  var out0 = $fields.len & "\n"
  for f in fields:
    out0.add $f.len
    out0.add '\n'
    out0.add f
  result = writeAll(c.fd, out0)
  if not result: c.broken = true

proc hasPending*(c: var GuestChannel): bool =
  ## Is a record already readable? Asked at a safepoint, where the guest is
  ## parked inside an intercept and must not be held there while nothing is
  ## happening -- so the question has to be answerable without blocking.
  ##
  ## `poll` with a zero timeout, and buffered bytes count too: `recvFields` may
  ## have left the head of the next record in the buffer, and a reader that only
  ## asked the kernel would wait forever for bytes it already has.
  if c.broken: return false
  if c.pos < c.buf.len: return true
  var fds: TPollfd
  fds.fd = c.fd
  fds.events = POLLIN
  fds.revents = 0
  let n = poll(addr fds, 1, 0)
  result = n > 0 and (fds.revents and (POLLIN or POLLHUP)) != 0

proc recvFields*(c: var GuestChannel; dest: var seq[string]): bool =
  ## One record. False means the peer is gone or the stream is not a record
  ## stream any more; the caller reports that, it never retries.
  dest.setLen 0
  if c.broken: return false
  var head = ""
  if not c.readLine(head): return false
  var count = 0
  if not parseCount(head, count) or count > 4096:
    c.broken = true
    return false
  for i in 0 ..< count:
    if not c.readLine(head): return false
    var n = 0
    if not parseCount(head, n) or n > MaxFieldBytes:
      c.broken = true
      return false
    var field = ""
    if not c.readExactly(n, field): return false
    dest.add field
  result = true

# ── spawning ────────────────────────────────────────────────────────────────

proc closeFd(fd: cint) {.inline.} =
  if fd >= 0: discard close(fd)

proc spawnGuest*(exe: string; extraArgs: openArray[string];
                 launch: var GuestLaunch): string =
  ## Start `exe` with the control socket on `GuestControlFd`; "" on success,
  ## a diagnostic otherwise.
  ##
  ## `posix_spawn` rather than `fork` + `execv`: everything between a `fork`
  ## and its `exec` must be async-signal-safe, and this process has a garbage
  ## collector, buffered streams and (under `nimony c`) worker threads. The
  ## file actions say exactly one thing -- move our end of the socketpair onto
  ## descriptor 3 -- and stdin, stdout and stderr are left alone on purpose:
  ## they are the user's, and the guest is supposed to have them.
  launch = GuestLaunch(pid: 0, chan: openChannel(-1), alive: false)
  var sv: array[0 .. 1, cint]
  if socketpair(AF_UNIX.cint, SOCK_STREAM.cint, 0, sv) != 0:
    return "could not create the control socket for " & exe

  var actions: Tposix_spawn_file_actions
  var attr: Tposix_spawnattr
  if posix_spawn_file_actions_init(actions) != 0:
    closeFd sv[0]; closeFd sv[1]
    return "posix_spawn_file_actions_init failed"
  if posix_spawnattr_init(attr) != 0:
    discard posix_spawn_file_actions_destroy(actions)
    closeFd sv[0]; closeFd sv[1]
    return "posix_spawnattr_init failed"
  # The child's end becomes descriptor 3. `adddup2` also clears FD_CLOEXEC on
  # the result, which is what makes it survive the `exec`.
  discard posix_spawn_file_actions_adddup2(actions, sv[1], GuestControlFd)

  var argv: seq[string] = @[exe, "--control-fd:" & $GuestControlFd.int]
  for a in extraArgs: argv.add a
  var envv: seq[string] = @[]
  for key, val in envPairs(): envv.add key & "=" & val

  let cArgv = allocCStringArray(argv)
  let cEnvv = allocCStringArray(envv)
  var pid: Pid = 0
  let rc = posix_spawn(pid, exe.cstring, actions, attr, cArgv, cEnvv)
  deallocCStringArray cArgv
  deallocCStringArray cEnvv
  discard posix_spawn_file_actions_destroy(actions)
  discard posix_spawnattr_destroy(attr)
  closeFd sv[1]                    # the child's end is the child's now
  if rc != 0:
    closeFd sv[0]
    return "could not start " & exe & " (posix_spawn: " & $strerror(rc.cint) & ")"
  launch = GuestLaunch(pid: pid, chan: openChannel(sv[0]), alive: true)
  result = ""

proc closeChannel*(launch: var GuestLaunch) =
  ## Close our end. The loader's `recvFields` then fails, which is how a
  ## compiler that gives up tells a loader that is still waiting for work.
  if launch.chan.fd >= 0:
    closeFd launch.chan.fd
    launch.chan.fd = -1
    launch.chan.broken = true

proc signalGuest*(launch: var GuestLaunch; sig: int): bool =
  ## Send `sig` to the loader. The way `nimony dev` restarts a program: there is
  ## no way to stop a guest THREAD from outside, and this is the whole reason
  ## the guest is a process at all.
  if not launch.alive or launch.pid <= 0: return false
  result = posix.kill(launch.pid, sig.cint) == 0

proc reapGuest*(launch: var GuestLaunch): GuestExit =
  ## Wait for the loader and say how it ended. A guest that faulted is a
  ## `gxSignalled` here and nothing at all in this process, which is the whole
  ## point of the boundary.
  result = GuestExit(kind: gxUnknown, code: 0, signal: 0)
  if not launch.alive: return
  var status: cint = 0
  while true:
    let w = waitpid(launch.pid, status, 0)
    if w == launch.pid: break
    if w < 0 and errno == EINTR: continue
    launch.alive = false
    return
  launch.alive = false
  if WIFEXITED(status):
    result = GuestExit(kind: gxExited, code: WEXITSTATUS(status).int, signal: 0)
  elif WIFSIGNALED(status):
    result = GuestExit(kind: gxSignalled, code: 0,
                       signal: WTERMSIG(status).int)

proc reraiseAsGuestDid*(signal: int) =
  ## Reproduce a guest's death in THIS process, so that the shell sees what it
  ## would have seen from a linked executable.
  ##
  ## `nimony r` in-process is transparent about the status by construction: the
  ## guest's `cAbort` does `kill(getpid(), SIGABRT)` and that IS the compiler's
  ## pid, so the shell reports 134. Out of process the signal lands on the
  ## loader, and reporting `128 + n` as an ordinary exit code would be a
  ## different thing that merely prints the same number -- `$?` agrees, `wait`
  ## does not, and a `set -e` script or a test harness reading the wait status
  ## can tell. So the handler is put back to the default and the signal is
  ## raised here.
  var sa: Sigaction
  if sigemptyset(sa.sa_mask) == 0:
    sa.sa_flags = 0
    sa.sa_handler = SIG_DFL
    discard sigaction(signal.cint, sa, nil)
  discard posix.kill(getpid(), signal.cint)
