#
#
#           Hexer Compiler
#        (c) Copyright 2026 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.
#

## The file boundary of hexer's phases (JIT_IMPL.md phase A2a).
##
## `lengcgen.expand`, `dce2.computeLiveSet` and `dce2.dceEmit` each have a
## buffer-level entry point that never names a file, and a path-based wrapper
## that is "read -> overload -> write". The wrappers call the four helpers
## below rather than `nifpools.parseFromFile` / `nifpools.writeFile`, for one
## reason: those two roll load+parse and serialize+write into a single call,
## and the cost ledger's `PhaseTimer` (`src/lib/ledger.nim`) has a bucket for
## each of the four steps. Splitting them here is what turns A1a's "the whole
## phase is `produce`" into a real per-step breakdown, and it is also the
## seam A2b/A2c hand a buffer to instead of a path.
##
## `loadAndParse` is `nifpools.parseFromFile` with the reader open and the
## token build separated; `serializeModule` + `writeSerialized` are
## `nifpools.writeFile` with the renderer and the (`OnlyIfChanged`) write
## separated. Both pairs are deliberate copies of those two procs, so the
## bytes they produce are the bytes the old path produced. The wanted shared
## change -- `nifpools` exposing the halves itself -- is recorded in
## `notes/a2a-hexer.md`; A2a-hexer may not edit `src/lib`.

include ".." / lib / nifprelude
include ".." / lib / compat2

from ".." / lib / nifcoreparse import nil
import ".." / lib / [vfs, ledger]

proc loadAndParse*(filename: string; t: var PhaseTimer; sizeHint = 100): TokenBuf =
  ## `nifpools.parseFromFile` with the two halves timed apart: opening the
  ## reader (an mmap through the VFS relay) is `load`, building the tokens is
  ## `parse`. `t.mark` is *not* called first -- the caller decides where the
  ## measured region starts.
  result = createTokenBuf(sizeHint)
  var r = nifreader.open(filename)
  discard nifreader.processDirectives(r)
  t.noteLoad()
  nifcoreparse.parse(r, result, denseLineInfo = true)
  nifreader.close(r)
  t.noteParse()

proc serializeModule*(b: var TokenBuf; filename: string): string =
  ## The renderer half of `nifpools.writeFile`. The dotted suffix is derived
  ## from the *output* file name, exactly as `writeFile` does it.
  result = nifcoreparse.toModuleString(b, "." & nifreader.extractModuleSuffix(filename))

proc writeSerialized*(content: string; filename: string;
                      mode: FileWriteMode = AlwaysWrite) {.canRaise.} =
  ## The write half of `nifpools.writeFile`, `OnlyIfChanged` included.
  if mode == OnlyIfChanged:
    let existingContent = try: vfsRead(filename) except: ""
    if existingContent == content: return
  vfsWrite(filename, content)
