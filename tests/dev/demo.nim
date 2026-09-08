## The demo application for `nimony dev` (JIT_IMPL.md B4).
##
## It exists because the phase's gate cannot be judged without one: *"a demo
## application survives a body edit without restart, and restarts with a named
## reason on a signature edit"*. `examples/` holds one-shot tutorial scripts
## that run to completion and print a golden; none of them can be edited while
## it runs, because none of them is still running.
##
## Two constraints come from the runtime and are not negotiable:
##
## * **single-threaded.** `nifasm/image/memory.nim` refuses an image that still
##   carries a thread-local, `--dev-single-thread` is what lowers them away, and
##   the promise that makes sound is that the program never creates a thread.
##   `engine.ThreadSpawners` refuses one that could.
## * **a long-lived loop with a reloadable body.** A program that has exited
##   cannot be reloaded, and one that never reaches a safepoint cannot be asked.
##
## Three of its four procs are deliberately different cases:
##
## * `render` is called from the loop and has RETURNED by the time the loop
##   reaches its safepoint, so a body edit to it reloads.
## * `mainLoop` is on the stack AT the safepoint -- it is what called `devPoll`
##   -- so a body edit to it is deferred, forever, and `nimony dev` says so and
##   restarts. That is not a defect of the reloader; it is JIT.md 7.4's rule
##   ("a swap is deferred while a frame of the replaced proc is live") meeting a
##   frame that never goes away.
## * `pause` is a leaf over one external, and shows that a reloadable program
##   may call into libc.
##
## `{.noinline.}` on the two reloadable procs is load-bearing: an inlined proc
## has no entry to redirect, which is why JIT.md 7.4 says "safe: NON-INLINE body
## edits". Without it hexer splices `render` into `mainLoop` and the only thing
## that changed is `mainLoop`, which is live.
##
## `ticks` is a global on purpose. It is how a reader tells the two outcomes
## apart from the output alone: a reload keeps counting, a restart starts over.

import std / [syncio, devreload]
import std / posix / posix

var ticks = 0

proc pause(ms: int) =
  var req = Timespec(tv_sec: Time(ms div 1000),
                     tv_nsec: clong((ms mod 1000) * 1_000_000))
  var rem = Timespec(tv_sec: Time(0), tv_nsec: 0)
  discard nanosleep(req, rem)

proc render(n, gen: int): string {.noinline.} =
  ## The reloadable body. Edit this text and it changes without the count
  ## resetting; change its signature and the program restarts.
  result = "tick " & $n & " gen " & $gen

proc mainLoop(limit, delayMs: int) {.noinline.} =
  ## The long-lived loop. `devPoll` is the safepoint: it is where the loader
  ## gets a synchronous seed for the stack walk, and where a pending swap is
  ## applied. It answers with the reload generation, which the line below
  ## prints.
  while ticks < limit:
    let gen = devPoll()
    inc ticks
    echo render(ticks, gen)
    flushFile stdout
    pause(delayMs)

mainLoop(100_000, 60)
