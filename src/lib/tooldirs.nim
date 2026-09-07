## This module provides functions to find tools in the Nimony bin directory.

# `syncio` is here for `quit` alone: this module is compiled by the
# self-hosted compiler during a boot, and nimony's `quit` lives there rather
# than in `system`.
import std / [os, strutils, syncio]

proc binDir*(): string =
  ## The directory tools live in. `bin*` is matched (not just `bin`) so the
  ## boot bootstrap can stage parallel toolchains under sibling directories
  ## like `bin0`, `bin1`, `bin2` without each stage's nimony falling back to
  ## looking in `bin*/bin`.
  let appDir = getAppDir()
  let (_, tail) = splitPath(appDir)
  if tail.startsWith("bin"):
    result = appDir
  else:
    result = appDir / "bin"

proc toolDir*(f: string): string =
  result = binDir() / f

proc findTool*(name: string): string =
  ## The path of one of OUR tools: next to the running executable and nowhere
  ## else. An absolute name is already a decision and passes through.
  ##
  ## Two candidates this deliberately does not have:
  ##
  ## * the current directory. `fileExists(name)` used to be tried first, so a
  ##   build whose `--out` binary is called `nimony` and sits in the directory
  ##   the build runs from made `findTool("nimony")` answer with that file.
  ## * a bare name. The old fallback returned `name` unchanged, which a shell
  ##   then resolves through `PATH` — so the cwd hit above did not even run
  ##   the file it had found: it produced `nimony`, and `/bin/sh` answered
  ##   `nimony: command not found` from the middle of a CTFE sub-compile.
  ##
  ## The path is returned whether or not the file exists: `semos.requiresTool`
  ## and `deps.wantTool` build a missing tool on demand and test for
  ## themselves. A caller with no such fallback uses `demandTool`.
  if name.len == 0:
    result = name
  elif name.isAbsolute:
    result = name.addFileExt(ExeExt)
  else:
    result = toolDir(name.addFileExt(ExeExt))

proc missingToolMsg*(name: string): string =
  ## Names the one directory `findTool` searches, because "not found" without
  ## it sends the reader looking at `PATH`, which is not consulted.
  result = "FAILURE: tool '" & name & "' not found in " & binDir() &
           "; build it with `hastur build all`"

proc demandTool*(name: string): string =
  ## `findTool` for a caller that has no way to recover. Failing here, with
  ## the directory named, beats handing a path that does not exist to a shell
  ## two processes down and reading its guess at what went wrong.
  result = findTool(name)
  if not fileExists(result):
    quit missingToolMsg(name)
