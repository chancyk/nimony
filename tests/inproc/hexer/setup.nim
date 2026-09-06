## Custom runner for phase A2a-hexer (`JIT_IMPL.md`): hexer as a library.
##
## The claim under test is the one A2b depends on and the only one that
## matters: **running a hexer phase in the caller's process produces the same
## bytes as spawning `bin/hexer`.** Everything else about the refactor is
## interface; this is the invariant.
##
## Shape of the run:
##
## 1. Build two small modules with the real toolchain into ONE nimcache, so
##    two different `.s.nif` inputs (and every `.dce.nif` of their shared
##    stdlib closure) exist.
## 2. Reference: five `bin/hexer` processes — `c` on each module, `dl` over
##    the whole closure, `de` on each module.
## 3. In-process: `driver.nim` links `src/hexer/hexer` and makes the same five
##    calls through `runHexer`, with `resetHexerGlobals()` between each pair,
##    plus a sixth pass through the buffer-level `expand` overload.
## 4. Compare every artifact byte for byte.
##
## Why two modules and not one: a second run in the same process is exactly
## where stale global state shows up (`programs.prog` caches the module it
## parsed), and a single run would not exercise `resetHexerGlobals` at all.
##
## `tests/inproc/` deliberately holds no `.nim` file of its own so that the
## tree walk descends into it and finds this runner (`walk.collectTests`).

import std / [os, strutils, osproc, syncio, algorithm]
import "../../../src/hastur/context"

proc arg(name: string): string =
  let prefix = "--" & name & ":"
  for p in commandLineParams():
    if p.startsWith(prefix): return p[prefix.len .. ^1]
  result = ""

if arg("bindir").len > 0: toolchainDir = arg("bindir")
if arg("cachedir").len > 0: nimcacheDir = arg("cachedir")
let testDir = if arg("dir").len > 0: arg("dir") else: "tests" / "inproc" / "hexer"

var failures = 0

proc fail(msg: string) =
  echo "[inproc/hexer] FAIL: ", msg
  inc failures

proc expect(cond: bool; msg: string) =
  if not cond: fail msg

proc sameBytes(a, b: string; what: string) =
  ## The whole verdict of this suite: two paths, same bytes.
  if not fileExists(a):
    fail what & ": missing " & a
    return
  if not fileExists(b):
    fail what & ": missing " & b
    return
  let x = readFile(a)
  let y = readFile(b)
  if x == y:
    echo "[inproc/hexer] ok: ", what, " (", x.len, " bytes)"
  else:
    var at = 0
    while at < min(x.len, y.len) and x[at] == y[at]: inc at
    fail what & ": " & a & " and " & b &
         " differ (" & $x.len & " vs " & $y.len & " bytes, first at " & $at & ")"

proc run(cmd: string; what: string): bool =
  let (output, code) = execCmdEx(cmd)
  result = code == 0
  if not result:
    fail what & " failed (" & $code & "):\n" & cmd & "\n" & output

# ---------------------------------------------------------------------------

let nimony = toolExe("nimony")
let hexer = toolExe("hexer")
if not fileExists(nimony) or not fileExists(hexer):
  echo "[inproc/hexer] FAIL: no toolchain at ", toolchainDir
  quit 1

let scratch = nimcacheDir / "inproc_hexer"
removeDir scratch
createDir scratch

let
  src = scratch / "src"
  nc = scratch / "nc"
  refDir = scratch / "ref"      # `hexer c`, one process per module
  refCDir = scratch / "refc"    # `hexer de`, one process per module
  inDir = scratch / "inproc"    # everything the driver produced
  bufDir = scratch / "buf"      # the buffer-level `expand`
for d in [src, nc, refDir, refCDir, inDir, bufDir]: createDir d

# The `zz` prefix is not decoration: a module suffix is the first three
# characters of the module name plus a hash (`modnames.moduleSuffix`), so a
# prefix no stdlib module shares makes `nc/zz*.s.nif` name exactly our two.
writeFile(src / "zzalpha.nim", """
import std / syncio

type ZzBox*[T] = object
  value*: T

proc zzsum*(a, b: int): int = a + b
proc unwrap*[T](b: ZzBox[T]): T = b.value

let box = ZzBox[int](value: 40)
write stdout, "alpha "
write stdout, $zzsum(unwrap(box), 2)
write stdout, "\n"
""")

writeFile(src / "zzbeta.nim", """
import std / syncio

type ZzPair*[T] = object
  a*, b*: T

proc zzmul*(x, y: int): int = x * y
proc first*[T](p: ZzPair[T]): T = p.a

let p = ZzPair[int](a: 6, b: 7)
write stdout, "beta "
write stdout, $zzmul(first(p), 7)
write stdout, "\n"
""")

# ---- 1. real artifacts for two modules in one nimcache --------------------

for m in ["zzalpha", "zzbeta"]:
  if not run(quoteShell(nimony) & " c --silentMake --nimcache:" &
             quoteShell(nc) & " " & quoteShell(src / m & ".nim"),
             "building " & m):
    quit "FAILURE: " & $failures & " inproc/hexer test(s) failed"

var mains: seq[string] = @[]
for f in walkFiles(nc / "zz*.s.nif"):
  mains.add f
sort mains
expect mains.len == 2, "expected two zz*.s.nif inputs, found " & $mains.len
if mains.len != 2:
  quit "FAILURE: " & $failures & " inproc/hexer test(s) failed"

let
  sA = mains[0]
  sB = mains[1]
  sfxA = sA.extractFilename.split('.')[0]
  sfxB = sB.extractFilename.split('.')[0]
echo "[inproc/hexer] modules: ", sfxA, " ", sfxB

# ---- 2. the reference: one `bin/hexer` process per call ------------------

for s in [sA, sB]:
  discard run(quoteShell(hexer) & " c --outdir:" & quoteShell(refDir) & " " &
              quoteShell(s), "hexer c " & s)

# `dl` needs a CLOSED set of analyses: `markLive` asserts that every symbol's
# owning module is among them. The two programs' shared stdlib closure is
# `nc/*.dce.nif`; the two mains' analyses are the ones `hexer c` just wrote.
# The order is the caller's and reaches the output bytes through the table
# iteration order, so both the reference and the in-process run get the same
# list, in the same order, from this one place.
var dceFiles = @[refDir / sfxA & ".dce.nif", refDir / sfxB & ".dce.nif"]
var closure: seq[string] = @[]
for f in walkFiles(nc / "*.dce.nif"):
  closure.add f
sort closure
dceFiles.add closure
expect closure.len > 0, "the build left no .dce.nif closure behind"

let dceListFile = scratch / "dce.list"
writeFile(dceListFile, dceFiles.join("\n") & "\n")

let refLive = refDir / "reference.live.nif"
var dlArgs = ""
for f in dceFiles: dlArgs.add " " & quoteShell(f)
discard run(quoteShell(hexer) & " dl" & dlArgs & " " & quoteShell(refLive),
            "hexer dl")

for sfx in [sfxA, sfxB]:
  discard run(quoteShell(hexer) & " de --outdir:" & quoteShell(refCDir) & " " &
              quoteShell(refDir / sfx & ".x.nif") & " " & quoteShell(refLive),
              "hexer de " & sfx)

if failures > 0:
  quit "FAILURE: " & $failures & " inproc/hexer test(s) failed"

# ---- 3. the same five calls in ONE process -------------------------------

let driverBin = scratch / "driver".addFileExt(ExeExt)
let inLive = inDir / "reference.live.nif"
# `src/hexer/nim.cfg` and `src/config.nims` are what `bin/hexer` is built
# with; neither reaches a project outside `src/`, so the two flags hexer's
# sources actually need are passed by hand. `--path:src/lib` is the one
# `nifprelude`'s unqualified imports resolve through.
let driverCmd = "nim c --path:src/lib --define:nimPreviewSlimSystem" &
  " --experimental:strictDefs --warningAsError:ProveInit:off" &
  " --warningAsError:Uninit:off --hints:off" &
  " --nimcache:" & quoteShell(scratch / "drivercache") &
  " -o:" & quoteShell(driverBin) & " " &
  quoteShell(testDir / "driver.nim")
if not run(driverCmd, "compiling the in-process driver"):
  quit "FAILURE: " & $failures & " inproc/hexer test(s) failed"

var driverArgs = ""
for a in [sA, sB, inDir, bufDir, dceListFile, inLive, refLive,
          refDir / sfxA & ".x.nif", refDir / sfxB & ".x.nif"]:
  driverArgs.add " " & quoteShell(a)
discard run(quoteShell(driverBin) & driverArgs, "the in-process driver")

# ---- 4. the verdict ------------------------------------------------------

for sfx in [sfxA, sfxB]:
  sameBytes(refDir / sfx & ".x.nif", inDir / sfx & ".x.nif",
            "hexer c: " & sfx & ".x.nif")
  sameBytes(refDir / sfx & ".dce.nif", inDir / sfx & ".dce.nif",
            "hexer c: " & sfx & ".dce.nif")
  sameBytes(refCDir / sfx & ".c.nif", inDir / sfx & ".c.nif",
            "hexer de: " & sfx & ".c.nif")

sameBytes(refLive, inLive, "hexer dl: .live.nif")

sameBytes(refDir / sfxA & ".x.nif", bufDir / sfxA & ".x.nif",
          "buffer-level expand: " & sfxA & ".x.nif")
sameBytes(refDir / sfxA & ".dce.nif", bufDir / sfxA & ".dce.nif",
          "buffer-level expand: " & sfxA & ".dce.nif")

if failures > 0:
  quit "FAILURE: " & $failures & " inproc/hexer test(s) failed"
echo "[inproc/hexer] all checks passed"
