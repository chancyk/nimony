## Custom runner for phase B4's gate (`JIT_IMPL.md`): `nimony dev`.
##
## > **Gate**: a demo application survives a body edit without restart, and
## > restarts with a named reason on a signature edit.
##
## Both halves, on the demo next door, driven end to end: this starts a real
## `nimony dev`, edits the real source file while the real program is running,
## and reads the real stdout.
##
## Three edits, because two cannot answer the question:
##
## 1. **a body edit to `render`** -> reload. The proof is not that the text
##    changed; it is that the COUNT did not reset. `ticks` is a global in the
##    live data region, and a reload is exactly the operation that leaves that
##    region alone -- so `tick 171` followed by `TOCK 172` is a reload and
##    `TOCK 1` would have been a restart wearing its coat.
## 2. **a signature edit to `render`** -> restart, with the reason naming the
##    declaration. The proof is the counter going back to 1.
## 3. **a body edit to the RESTARTED program** -> reload again. Without this the
##    run ends the instant the restart is decided, and a restart whose new guest
##    is never seen alive has not been shown to be a restart at all.
##
## `hastur.mode = skip` for the reason `tests/nimony_r` and `tests/nativecg`
## have it: without a sibling `../nativenif` there is no arkham, no nifasm and
## no `nimrun`, so there is nothing here to test. Run it explicitly with
## `bin/hastur test tests/dev`.

import std / [os, osproc, strutils, syncio, times]
import "../../src/hastur/context"

proc arg(name: string): string =
  let prefix = "--" & name & ":"
  for p in commandLineParams():
    if p.startsWith(prefix): return p[prefix.len .. ^1]
  result = ""

if arg("bindir").len > 0: toolchainDir = arg("bindir")
if arg("cachedir").len > 0: nimcacheDir = arg("cachedir")
let testDir = if arg("dir").len > 0: arg("dir") else: "tests" / "dev"

var failures = 0

proc fail(msg: string) =
  echo "[dev] FAIL: ", msg
  inc failures

proc ok(msg: string) =
  echo "[dev] ok: ", msg

let nimony = toolExe("nimony")
if not fileExists(nimony):
  echo "[dev] no `nimony` in ", toolchainDir, "; nothing to test"
  quit 1
if not fileExists(toolExe("nimrun")) or not fileExists(toolExe("arkham")) or
   not fileExists(toolExe("nifasm")):
  echo "[dev] no nimrun/arkham/nifasm in ", toolchainDir,
       " (no ../nativenif at build time); nothing to test"
  quit 0
when not (defined(macosx) and defined(arm64)):
  echo "[dev] hot reload is macOS/arm64 only so far (JIT_IMPL.md B5); ",
       "nothing to test"
  quit 0

let scratch = nimcacheDir / "devgate"
removeDir scratch
createDir scratch
let src = scratch / "demo.nim"
let original = readFile(testDir / "demo.nim")
writeFile(src, original)

let outFile = scratch / "program.out"
let errFile = scratch / "dev.err"
writeFile(outFile, "")
writeFile(errFile, "")

# ── waiting, bounded ────────────────────────────────────────────────────────

const
  StepTimeoutMs = 120_000
    ## A whole rebuild plus a reload, with room for a loaded machine. Every wait
    ## below is bounded: a gate that hangs tells nobody anything, and this suite
    ## is meant to be runnable in CI.
  PollMs = 50

proc waitFor(file, marker: string; what: string): bool =
  ## Wait until `file` contains `marker`. False on timeout, with the file's
  ## contents in the failure, because "it did not appear" is never the whole
  ## story -- what DID appear is.
  let deadline = epochTime() + float(StepTimeoutMs) / 1000.0
  while epochTime() < deadline:
    if fileExists(file) and marker in readFile(file): return true
    sleep PollMs
  fail what & ": `" & marker & "` never appeared in " & file.extractFilename &
       "\n---\n" & (if fileExists(file): readFile(file).strip else: "(no file)") &
       "\n---"
  result = false

proc lastLineStarting(file, prefix: string): string =
  result = ""
  if not fileExists(file): return
  for line in readFile(file).splitLines:
    if line.startsWith(prefix): result = line

proc firstLineStarting(file, prefix: string): string =
  result = ""
  if not fileExists(file): return
  for line in readFile(file).splitLines:
    if line.startsWith(prefix): return line

proc tickNumber(line: string): int =
  ## `"<word> <n> gen <g>"` -> n, or -1.
  result = -1
  let f = line.splitWhitespace
  if f.len < 2: return
  try:
    result = parseInt(f[1])
  except ValueError:
    result = -1

proc edit(fromText, toText: string) =
  ## Rewrite the source the way a person would: read, change, write. The
  ## watcher is looking at modification times, so the write is the event.
  let s = readFile(src)
  if fromText notin s:
    fail "the edit `" & fromText & "` does not apply to the demo any more"
    return
  writeFile(src, s.replace(fromText, toText))

# ── the run ─────────────────────────────────────────────────────────────────

let cmd = quoteShell(nimony) & " dev --silentMake --dev-interval:" & $PollMs &
  " --dev-max-edits:3 --nimcache:" & quoteShell(scratch / "nc") & " " &
  quoteShell(src) & " > " & quoteShell(outFile) & " 2> " & quoteShell(errFile)
var driver = startProcess("/bin/sh", args = ["-c", cmd], options = {})

proc finish(code: int) {.noreturn.} =
  if driver.running: driver.terminate()
  discard driver.waitForExit()
  close driver
  if failures > 0:
    echo "[dev] ", failures, " failure(s)"
    quit 1
  echo "[dev] all checks passed"
  quit code

if not waitFor(outFile, "tick 1 gen 0", "startup"):
  finish 1
ok "the demo is running"

# ---- 1. a body edit reloads, and the count does not reset -----------------

edit("\"tick \"", "\"TOCK \"")
if not waitFor(errFile, "reloaded generation 1", "body edit"):
  finish 1
if not waitFor(outFile, "TOCK ", "body edit"):
  finish 1

let lastOld = tickNumber(lastLineStarting(outFile, "tick "))
let firstNew = tickNumber(firstLineStarting(outFile, "TOCK "))
if lastOld < 1 or firstNew < 1:
  fail "could not read the tick numbers around the reload (" & $lastOld &
       ", " & $firstNew & ")"
elif firstNew != lastOld + 1:
  fail "the count jumped across the reload: " & $lastOld & " -> " & $firstNew &
       " (a reload must not restart the program, and must not lose a tick)"
else:
  ok "a body edit reloaded at tick " & $firstNew &
     " without restarting (the global counter kept going)"

if "gen 1" notin readFile(outFile):
  fail "the program never saw generation 1"
else:
  ok "the program's `devPoll()` reports generation 1"

# ---- 2. a signature edit restarts, with a reason --------------------------

edit("proc render(n, gen: int): string", "proc render(n, gen: int; tag: string): string")
edit("result = \"TOCK \" & $n", "result = tag & $n")
edit("echo render(ticks, gen)", "echo render(ticks, gen, \"sig \")")

if not waitFor(errFile, "restart: ", "signature edit"):
  finish 1
let restartLine = firstLineStarting(errFile, "[dev] restart: ")
if "signature of render" notin restartLine:
  fail "the restart did not name the signature: " & restartLine
else:
  ok "a signature edit restarts, and says why: " & restartLine.strip

if not waitFor(outFile, "sig 1 gen 0", "restart"):
  finish 1
ok "the restarted program starts over at tick 1 (the counter reset)"

# ---- 3. the restarted program is a live, reloadable guest -----------------

edit("result = tag & $n", "result = \"[\" & tag & \"]\" & $n")
if not waitFor(errFile, "done: ", "third edit"):
  finish 1
if not waitFor(outFile, "[sig ]", "third edit"):
  finish 1
ok "the restarted program reloads too"

let tail = readFile(errFile)
if "1 reload(s)" notin tail and "2 reload(s)" notin tail:
  fail "the summary line does not report the reloads: " & tail.strip.splitLines[^1]
else:
  ok "summary: " & tail.strip.splitLines[^1]

finish 0
