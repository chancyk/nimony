## The safepoint a hot-reloadable program reaches.
##
## `nimony dev` (JIT.md 7.4, JIT_IMPL.md B4) rebuilds an edited module while the
## program is still running and swaps the new code in. Two things have to be
## true at the moment of the swap, and neither can be arranged from outside:
##
## * **the walk needs a synchronous seed.** nifasm's per-proc trace table gives
##   one `cfaOff` per proc and it is only valid past that proc's prologue
##   (`nativenif/src/nifasm/image/tracetable.nim`), so a stack walk cannot start
##   from a thread suspended at an arbitrary instruction -- it has to start from
##   a frame the program itself called into. `devPoll` is that call.
## * **the program has to be somewhere it does not mind being changed.** A swap
##   is deferred while a frame of a replaced proc is live; asking at the top of
##   a loop, rather than in the middle of one, is what makes the answer usually
##   "no frames, go ahead".
##
## So a program that wants to be reloadable calls `devPoll()` at the top of its
## main loop and gets back the RELOAD GENERATION: 0 before any reload, and one
## more after each one that was applied. Printing it is how a reader tells a
## reload ("the counter kept going, the message changed") from a restart ("the
## counter went back to zero").
##
## Outside `nimony dev` this is `0` and costs nothing: the external is declared
## only under `-d:nimonyDev`, which `nimony dev` passes and nothing else does,
## so an ordinary `nimony c` or `nimony n` build of the same source has no
## unresolved symbol to link and no call to make.

when defined(nimonyDev):
  proc rawDevPoll(): int {.importc: "nimony_dev_poll".}
    ## Answered by the `nimrun` loader, on THIS thread, in a frame this program
    ## called into (`src/nimony/nimrun.nim`). It is an ordinary external, which
    ## is the whole trick: on arm64 a call to one goes through a stub and a GOT
    ## slot the loader filled (`nifasm/image/hostfixup.emitA64Stub`), so there
    ## is nothing special about it for the compiler to arrange.

  proc devPoll*(): int =
    ## Reach a safepoint; return the reload generation.
    rawDevPoll()

else:
  proc devPoll*(): int =
    ## Reach a safepoint; return the reload generation. Not a `nimony dev` run,
    ## so there is nothing to reach and the generation is 0.
    result = 0
