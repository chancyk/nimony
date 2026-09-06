#
#
#           Leng Compiler
#        (c) Copyright 2024 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.
#

## Leng driver program.

import std / [parseopt, strutils, os, osproc, tables, assertions, syncio,
  dirs, paths]
import codegen, llvmcodegen          # nifcore backends (local to shoggoth/)
import nifmodules                    # readSource/parseSource: the load|parse seam
import noptions
import ".." / lib / symparser
import ".." / lib / [vfs, artifactstore]
import ".." / lib / ledger
import ".." / lib / nimversion

include ".." / lib / compat2

template makeDir(p: string) =
  when defined(nimony):
    onRaiseQuit createDir(path(p))
  else:
    onRaiseQuit createDir(Path(p))

const
  Usage = "Leng Compiler. Version " & Version & """

  (c) 2024 Andreas Rumpf
Usage:
  lengc [options] [command] [arguments]
Command:
  c|cpp|llvm file.nif [file2.nif]    convert NIF files to C|C++|LLVM IR

Options:
  -r, --run                 run the makefile and the compiled program
  --compileOnly             compile only, do not run the makefile and the compiled program
  --isMain                  mark the file as the main program
  --cc:SYMBOL               specify the C compiler
  --opt:none|speed|size     optimize not at all or for speed|size
  --lineDir:on|off          generation of #line directive on|off
  --bits:N                  `(i -1)` has N bits; possible values: 64, 32, 16
  --nimcache:PATH           set the path used for generated files
  --app:console|gui|lib|staticlib
                            set the application type (default: console)
  --version                 show the version
  --help                    show this help
"""

proc fail(msg: string): int =
  ## What `quit msg` writes, minus the process exit: `system.quit(errormsg)` is
  ## `cstderr.rawWrite(msg)`, a newline, and `QuitFailure`. `runLengc` returns
  ## this so the CLI keeps its exact bytes and exit codes while the driver is
  ## callable as a library (JIT_IMPL.md A2a).
  stderr.write msg
  stderr.write "\n"
  result = QuitFailure

proc writeHelp(): int =
  stderr.write Usage
  stderr.write "\n"
  result = QuitSuccess

proc writeVersion(): int =
  stderr.write Version & "\n"
  stderr.write "\n"
  result = QuitSuccess

proc resetLengcGlobals*() =
  ## Put lengc back into its start-of-process state, so a second `runLengc` in
  ## the same process produces what a second process would (JIT.md 6.1,
  ## JIT_IMPL.md A2a). Called before every in-process lengc node.
  ##
  ## The complete list of module-level `var`s under `src/lengc/`
  ## (`grep -rnE '^var( |$)' src/lengc/`), and what each needs:
  ##
  ## - `shoggoth/tracer_tmp.nim:33 wantedSubstr` — a debug tracer's own
  ##   program; not in this binary's import graph, and its `main` reassigns it.
  ## - `shoggoth/optfuzz.nim:72-74 totalPasses/totalCrashes/totalMalformed` —
  ##   the fuzzer's own program; likewise not reachable from here.
  ## - `shoggoth/cse.nim:146-149`, the ten `g*` counters behind
  ##   `-d:cseSummaryStats` — shoggoth's optimizer, a separate binary.
  ##
  ## That is the whole list: nothing on lengc's own path holds state between
  ## runs. Every counter that looks global (`CurrentProc.nextTemp`, the LLVM
  ## label and string-literal counters, the token `BiTable`, `generatedTypes`,
  ## `requestedSyms`, `includedHeaders`, `fileIds`) is a field of an object
  ## `initGeneratedCode`/`initLLVMCode` builds fresh per call, `mangler.nim` is
  ## pure, and `createLengTagPool()` mints a new pool every time. So this proc
  ## has nothing to assign today, and it exists to keep that fact reviewable:
  ## a new global under `src/lengc/` has to show up here as a diff.
  ##
  ## What lengc does depend on, and does NOT reset:
  ##
  ## - `nifpools.pool`, `nifpools.globalTags`, `nifcore.fallbackPool` /
  ##   `fallbackTags` — A2a-front's `resetFrontendGlobals()`. A process that
  ##   runs the front end and lengc calls both.
  ## - `artifactstore.store` and the `vfs` relays — process-wide policy and the
  ##   cross-phase cache the in-process scheduler exists to exploit. Their
  ##   teardown is `uninstallArtifactStore()`, at the end of the process, not
  ##   between two phases.
  discard "nothing to reset; see the doc comment"

proc generateTimed(s: var State; inp, outp: string; flags: set[GenFlag]) =
  ## `generateCode` split into the five steps the cost ledger has buckets for
  ## (JIT.md 5.2). A1a could only record the whole call as `produce`, because
  ## lengc loaded, translated and wrote inside it; A2a's buffer-level entry
  ## points are what make the boundaries measurable.
  var timer = initPhaseTimer(outp.parentDir, "lengc", splitModulePath(inp).name)
  let content = readSource(inp)
  timer.noteLoad()
  var m = parseSource(content, inp)
  timer.noteParse()
  var t = default(Translation)
  translate s, m, flags, t
  timer.noteProduce()
  let generated = serialize(t)
  timer.noteSerialize()
  writeGenerated generated, outp
  timer.noteWrite()
  timer.noteOutput(outp)
  timer.finish()

proc generateBackend(s: var State; action: Action; files: seq[string];
                     flags: set[GenFlag]): int =
  assert action in {atC, atCpp}
  if files.len == 0:
    return fail("command takes a filename")
  s.config.backend = if action == atC: backendC else: backendCpp
  let destExt = if action == atC: ".c" else: ".cpp"
  for i in 0..<files.len-1:
    let inp = files[i]
    let outp = s.config.nifcacheDir / splitModulePath(inp).name & destExt
    generateTimed s, inp, outp, {}
  let inp = files[^1]
  let outp = s.config.nifcacheDir / splitModulePath(inp).name & destExt
  generateTimed s, inp, outp, flags
  result = QuitSuccess

proc generateLLVMBackend(s: var State; files: seq[string];
                         flags: set[LLVMGenFlag]): int =
  if files.len == 0:
    return fail("command takes a filename")
  for i in 0..<files.len-1:
    let inp = files[i]
    let outp = s.config.nifcacheDir / splitModulePath(inp).name & ".ll"
    generateLLVMCode s, inp, outp, {}
  let inp = files[^1]
  let outp = s.config.nifcacheDir / splitModulePath(inp).name & ".ll"
  generateLLVMCode s, inp, outp, flags
  result = QuitSuccess

proc runLengc*(args: seq[string]): int =
  ## The whole `lengc` command line as a proc: `args` is what
  ## `commandLineParams()` would have returned, and the result is the exit code
  ## the process would have had. Every diagnostic writes exactly the bytes
  ## `quit msg` wrote, on stderr, and comes back as `QuitFailure` instead of
  ## ending the process — which is what lets lengc be one phase of a build that
  ## runs in a single process (JIT.md 6.1, JIT_IMPL.md A2a).
  ##
  ## Call `resetLengcGlobals()` between two runs in one process.
  var toRun = false
  var compileOnly = false
  var isMain = false
  var currentAction = atNone

  var actionTable = initActionTable()

  var s = State(config: ConfigRef(), bits: sizeof(int)*8)
  when defined(macos): # TODO: switches to default config for platforms
    s.config.cCompiler = ccCLang
  else:
    s.config.cCompiler = ccGcc
  s.config.nifcacheDir = "nimcache"
  s.config.appType = appConsole # console is the default

  # `initOptParser(@[])` falls back to the *process's* command line, which is
  # exactly wrong for a library entry point; no arguments is the same thing as
  # no action anyway, and that is `writeHelp` either way.
  if args.len == 0:
    return writeHelp()
  var p = initOptParser(args)
  for kind, key, val in getopt(p):
    case kind
    of cmdArgument:
      case key.normalize:
      of "c":
        currentAction = atC
        if not hasKey(actionTable, atC):
          actionTable[atC] = @[]
      of "cpp":
        currentAction = atCpp
        if not hasKey(actionTable, atCpp):
          actionTable[atCpp] = @[]
      of "n":
        currentAction = atNative
        if not hasKey(actionTable, atNative):
          actionTable[atNative] = @[]
      of "llvm":
        currentAction = atLLVM
        if not hasKey(actionTable, atLLVM):
          actionTable[atLLVM] = @[]
      else:
        case currentAction
        of atC:
          getOrQuit(actionTable, atC).add key
        of atCpp:
          getOrQuit(actionTable, atCpp).add key
        of atNative:
          getOrQuit(actionTable, atNative).add key
        of atLLVM:
          getOrQuit(actionTable, atLLVM).add key
        of atNone:
          return fail("invalid command: " & key)
    of cmdLongOption, cmdShortOption:
      case normalize(key)
      of "bits":
        case val
        of "64": s.bits = 64
        of "32": s.bits = 32
        of "16": s.bits = 16
        else: return fail("invalid value for --bits")
      of "help", "h": return writeHelp()
      of "version", "v": return writeVersion()
      of "run", "r": toRun = true
      of "compileonly": compileOnly = true
      of "ismain": isMain = true
      of "cc":
        case val.normalize
        of "gcc":
          s.config.cCompiler = ccGcc
        of "clang":
          s.config.cCompiler = ccCLang
        else:
          return fail("unknown C compiler: '" & val & "'. Available options are: gcc, clang")
      of "opt":
        case val.normalize
        of "speed":
          s.config.optimizeLevel = Speed
        of "size":
          s.config.optimizeLevel = Size
        of "none":
          s.config.optimizeLevel = None
        else:
          return fail("'none', 'speed' or 'size' expected, but '" & val & "' found")
      of "linedir":
        case val.normalize
        of "", "on":
          s.config.options.incl optLineDir
        of "off":
          s.config.options.excl optLineDir
        else:
          return fail("'on', 'off' expected, but '" & val & "' found")
      of "nimcache":
        s.config.nifcacheDir = val
      of "out", "o":
        s.config.outputFile = val
      of "app":
        case normalize(val)
        of "console":
          s.config.appType = appConsole
        of "gui":
          s.config.appType = appGui
        of "lib":
          s.config.appType = appLib
        of "staticlib":
          s.config.appType = appStaticLib
        else:
          return fail("invalid value for --app; expected console, gui, lib, or staticlib")
      of "vfs":
        if not requestStorePolicy(val):
          return fail("invalid value for --vfs; expected disk, memory, memory+spill or verify")
      of "vfs-budget", "vfsbudget":
        let mb = parseBudgetMB(val)
        if mb <= 0: return fail("invalid value for --vfs-budget; expected a size in megabytes")
        requestStoreBudgetMB mb
      else: return writeHelp()
    of cmdEnd: assert false, "cannot happen"

  applyRequestedStore()
  makeDir(s.config.nifcacheDir)
  if actionTable.len != 0:
    for action in actionTable.keys:
      case action
      of atC, atCpp:
        let isLast = (if compileOnly: isMain else: currentAction == action)
        let flags = if isLast: {codegen.gfMainModule} else: {}
        let code = generateBackend(s, action, getOrQuit(actionTable, action), flags)
        if code != QuitSuccess: return code
      of atNative:
        let nativeFiles = getOrQuit(actionTable, action)
        if nativeFiles.len == 0:
          return fail("command takes a filename")
        else:
          when defined(enableAsm):
            for inp in items nativeFiles:
              let outp = changeFileExt(inp, ".S")
              generateAsm inp, s.config.nifcacheDir / outp
          else:
            return fail("wasn't built with native target support")
      of atLLVM:
        let isLast = (if compileOnly: isMain else: currentAction == action)
        let llvmFlags = if isLast: {llvmcodegen.gfMainModule} else: {}
        let code = generateLLVMBackend(s, getOrQuit(actionTable, action), llvmFlags)
        if code != QuitSuccess: return code
      of atNone:
        return fail("targets are not specified")

    let appName = getOrQuit(actionTable, currentAction)[^1].splitModulePath.name
    if s.config.outputFile == "":
      s.config.outputFile = appName
    result = QuitSuccess

  else:
    result = writeHelp()

proc handleCmdLine() =
  ## The process shell over `runLengc`. `storeFlush`/`dumpVfsProfile` are the
  ## end-of-process epilogue, so they stay here rather than in the library proc:
  ## the in-process scheduler flushes once for the whole build, not once per
  ## phase. They run on success only, which is where `quit` used to leave them.
  let code = runLengc(commandLineParams())
  if code == QuitSuccess:
    storeFlush()
    dumpVfsProfile("lengc")
  quit code

when isMainModule:
  handleCmdLine()
