#       Nimony
# (c) Copyright 2024 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## Nimony driver program.

when defined(windows):
  when defined(gcc):
    when defined(x86):
      {.link: "../../icons/nimony.res".}
    else:
      {.link: "../../icons/nimony_icon.o".}

when defined(nimony):
  {.feature: "lenientnils".}
  {.feature: "untyped".}
import std / [parseopt, sets, strutils, os, assertions, syncio, dirs, paths]
import ".." / lib / [tooldirs, argsfinder, nimversion, vfs, artifactstore]

import ".." / gear2 / modnames
import semmain, sem, nifconfig, semos, semdata, deps, langmodes, cli
when not defined(nimony):
  # The in-process scheduler. Gated for the reason `deps.nim` states at its own
  # `import`: `hastur boot` compiles nimony with nimony, which cannot compile
  # `nifmake/dag.nim` yet. A booted nimony parses `--spawn`/`--jobs`/
  # `--inproc-k` exactly the same way -- they only ever set environment
  # variables -- and then spawns `nifmake` for every graph, which is what it
  # did before this phase.
  import phases

when defined(nimonyEngine):
  # Only the two names the cross-compile guard in `runProject` needs; a full
  # import would put arrays called `CPU`/`OS` into this module's scope.
  from ".." / lib / platform import nameToCPU, nameToOS

  # `nimony r`. Gated the same way `semos.nim` gates it: the engine links
  # arkham and nifasm out of the sibling `../nativenif` checkout, so a plain
  # clone still builds a nimony -- one that says `r` needs that checkout
  # instead of pretending to have it (`compileProgram`'s `RunProject` arm).
  import engine

  proc cExit(code: cint) {.importc: "exit", header: "<stdlib.h>", noreturn.}

  proc exitAs(status: int) {.noreturn.} =
    ## The program's status, verbatim. `quit` clamps anything at or above 128
    ## to 127 (POSIX reserves those for "killed by signal N" in a WAIT status),
    ## and reinterpreting a guest's status is exactly what `nimony r` may not
    ## do: `nimony n` + exec gives the shell 200 for `quit(200)` and so must
    ## this. Buffers flushed by hand, since libc's `exit` is reached directly.
    flushFile stdout
    flushFile stderr
    cExit status.cint

include ".." / lib / compat2

template makeDir(p: string) =
  when defined(nimony):
    onRaiseQuit createDir(path(p))
  else:
    onRaiseQuit createDir(Path(p))

const
  Usage = "Nimony Compiler. Version " & Version & """

  (c) 2024-2025 Andreas Rumpf
Usage:
  nimony [options] [command]
Command:
  c project.nim               compile the full project via C backend
  l project.nim               compile the full project via LLVM backend
  n project.nim               compile the full project via the native backend
                              (arkham + nifasm; static, libc-free executable)
  r project.nim [args...]     compile with the native backend and RUN the
                              program out of the compiler's own memory: no
                              image is written and no linker runs. Everything
                              after project.nim is the program's argv, and its
                              exit status becomes nimony's. `--out:PATH` asks
                              for the executable as well.
  check project.nim           check the full project for errors; can be
                              combined with `--usages`, `--def` for
                              editor integration
  m file.nim [project.nim]    compile a single Nim module to Hexer

Options:
  -d, --define:SYMBOL       define a symbol for conditional compilation
  -d:release                build in release mode (implies --opt:speed;
                            runtime checks stay on)
  -d:danger                 build in danger mode (implies --opt:speed and
                            turns every runtime check off)
  -p, --path:PATH           add PATH to the search path
  -f, --forcebuild          force a rebuild
  --ff                      force a full build
  -r, --run                 also run the compiled program
  --compat                  turn on compatibility mode
  --isSystem                passed module is a `system.nim` module
  --isMain                  passed module is the main module of a project
  --noSystem                do not auto-import `system.nim`
  --mm:STRATEGY             select the memory management strategy; the name
                            maps to `system/<strategy>.nim` in the stdlib.
                            Possible values: atomicArc (default), arc
  --bits:N                  `int` has N bits; possible values: 64, 32, 16
  --cpu:SYMBOL              set the target processor (cross-compilation)
  --os:SYMBOL               set the target operating system (cross-compilation)
  --silentMake              suppresses make output
  --profile                 print nifmake timing profile of executed commands
  --report                  print machine-readable per-command invocation
                            counts on stdout (one line per build graph);
                            `inproc=N` of those ran without a process
  --stats                   after build, print total LOC and module count
                            across the dep graph
  --spawn:always|auto       `auto` (default) runs a build-graph node in this
                            process when the cost ledger says a process is not
                            worth it; `always` gives every node its own, which
                            is the escape hatch and is implied by --vfs:disk
  --jobs:N                  cap the per-graph-depth fan-out at N processes;
                            --jobs:1 also runs the graph node by node
  --inproc-k:N              a phase runs in this process while its estimated
                            cost is under N spawn costs (default 3)
  --inproc-mem-budget:MB    stop running phases in this process once its peak
                            resident size plus the next node's estimated peak
                            would exceed MB; 0 turns the rule off. The default
                            is physical memory / (8 * cores), clamped to
                            [128, 1024] MB
  --no-blobcache            native backend: assemble every reachable proc from
                            scratch instead of reusing nifasm's per-symbol code
                            cache under <nimcache>/blobcache. The cache is on by
                            default and produces a byte-identical image; this is
                            the escape hatch, and `NIMONY_BLOBCACHE=off` is the
                            same switch for a whole build tree (it reaches child
                            processes, which a flag does not).
  --layout:FILE             native backend, bare-metal targets only: the BOARD
                            description (memory regions, stack slots, heap) that
                            arkham and nifasm build the image against. See
                            nativenif's doc/layout.md
  --nimcache:PATH           set the path used for generated files
  -o, --out:PATH            write the executable to PATH (overrides the
                            default `<nimcache>/<modhash>/<basename>.exe`).
                            Splits into directory + filename like Nim;
                            combine with --outdir if you want them set
                            independently.
  --outdir:DIR              put the executable in DIR (default = cwd).
                            Same semantics as Nim's --outdir.
  --boundchecks:on|off      turn bound checks on or off
  --usages:file,line,col    list usages of the symbol at the given position
  --def:file,line,col       list definition of the symbol at the given position
  --cc:C_COMPILER           set the C compiler; can be a path to the compiler's
                            executable or a name
  --linker:LINKER           set the linker
  --app:console|gui|lib|staticlib
                            set the application type (default: console)
  --opt:speed|size|none     C compiler optimization level
                            (default: -O1, opt:speed -> -O3, opt:size -> -Os,
                             opt:none -> -O0)
  --inlineframes:on|off     record which template an expansion came from, so a
                            debug build shows template calls as inlined frames
                            (default: off)
  --vfs:MODE                where build artifacts live: disk (the default; no
                            artifact store at all), memory, memory+spill, or
                            verify (memory, written through, every read
                            compared against the disk copy). The mode reaches
                            every tool of the build through the environment.
  --vfs-budget:MB           how much the artifact store may hold resident
                            before it sheds entries (default: 512)
  --vfs-spill-margin:PCT    over the budget, only spill an artifact when
                            reloading it costs less than PCT percent of
                            recomputing it (default: 50)
  --novalidate              skip running the plugin validator on plugin sources
  --verbose                 dump Final IR (and other diagnostics) on contract
                            analysis failures
  --version                 show the version
  --help                    show this help
"""

proc writeHelp() = quit(Usage, QuitSuccess)
proc writeVersion() = quit(Version & "\n", QuitSuccess)

proc processSingleModule(nimFile: string; config: sink NifConfig; moduleFlags: set[ModuleFlag];
                         commandLineArgs: string; forceRebuild: bool) =
  let nifler = demandTool("nifler")
  let name = moduleSuffix(nimFile, config.paths)
  let src = config.nifcachePath / name & ".p.nif"
  let dest = config.nifcachePath / name & ".s.nif"
  let toforceRebuild = if forceRebuild: " -f " else: ""
  exec quoteShell(nifler) & " --portablePaths p " & toforceRebuild & quoteShell(nimFile) & " " &
    quoteShell(src)
  semcheck(@[src], @[dest], ensureMove config, moduleFlags, commandLineArgs, true)

type
  Command = enum
    None, SingleModule, FullProject, CheckProject, SemCheckNif, DocProject,
    RunProject

proc dispatchBasicCommand(key: string; config: var NifConfig): Command =
  case key.normalize:
  of "m":
    SingleModule
  of "c":
    FullProject
  of "l":
    config.backend = backendLLVM
    FullProject
  of "n":
    # Native backend: Leng -> arkham -> nifasm, producing a static, libc-free
    # executable. arkham emits raw syscalls and nifasm writes a static image
    # with no dynamic linker, so the standard library must be compiled in its
    # native-allocator + libc-free configuration.
    config.backend = backendNative
    config.addDefine "nimNativeAlloc"
    config.addDefine "nimNativeIo"
    FullProject
  of "r":
    # The same backend as `n`, stopping one node earlier: every module's
    # `.asm.nif` is produced and the program is then assembled into this
    # process's own memory and called there (JIT.md 7.3). It has to set the
    # very same defines, because the program the engine runs must be the same
    # program `n` would have linked -- that is what makes `nimony r` and
    # `nimony n` + exec comparable, which is what the tests compare.
    config.backend = backendNative
    config.addDefine "nimNativeAlloc"
    config.addDefine "nimNativeIo"
    RunProject
  of "w":
    # Wasm backend: Leng -> ithaqua, producing one whole-program `.wasm`
    # module (no C compiler, no linker — the JS/wasm host resolves the fixed
    # env import set). The target is implied after CLI parsing (see the
    # backendWasm block in handleCmdLine): wasm32/standalone/32 bits.
    config.backend = backendWasm
    FullProject
  of "check":
    CheckProject
  of "s":
    SemCheckNif
  of "doc":
    DocProject
  else:
    quit "invalid command, " & key

type
  CmdMode = enum
    FromCmdLine, FromArgsFile
  CmdOptions = object
    args: seq[string]
    cmd: Command
    fullRebuild: bool
    buildFlags: set[BuildFlag]  ## ForceRebuild, SilentMake, Profile, Report
    doRun: bool
    isChild: bool
    forwardArgsToExecutable: bool
    moduleFlags: set[ModuleFlag]
    checkModes: set[CheckMode]
    config: NifConfig
    commandLineArgs: string
    commandLineArgsLengc: string
    passC: string
    passL: string
    executableArgs: string
    programArgs: seq[string]
      ## `nimony r`'s argv for the program, UNQUOTED. `executableArgs` beside it
      ## is a shell command line, which is what `-r`'s `exec` needs and exactly
      ## what an in-process call must not have: the engine hands the strings to
      ## the guest's `main` one pointer at a time, so a `quoteShell` would put
      ## the quotes into argv.

proc createCmdOptions(baseDir: sink string): CmdOptions =
  CmdOptions(
    args: @[],
    cmd: Command.None,
    fullRebuild: false,
    buildFlags: {},
    doRun: false,
    moduleFlags: {},
    config: initNifConfig(baseDir),
    commandLineArgs: "",
    commandLineArgsLengc: "",
    isChild: false,
    passC: "",
    passL: "",
    checkModes: DefaultSettings,
    forwardArgsToExecutable: false,
    executableArgs: "",
    programArgs: @[]
  )

proc parsePositiveInt(val: string): int =
  ## A digit-only parse that answers 0 for anything else, so the caller can
  ## reject with its own message. Hand-rolled rather than `parseInt` because
  ## `except ValueError` is not in nimony's language and this file is compiled
  ## by nimony in `hastur boot`; `cli.parseBudgetMB` has the same shape for
  ## the same reason.
  result = 0
  if val.len == 0: return 0
  for c in val:
    if c < '0' or c > '9': return 0
    result = result * 10 + (ord(c) - ord('0'))

proc rememberForChildren(key, val: string) =
  ## A2b's three settings travel in the environment rather than in
  ## `c.commandLineArgs`, for the reason A1b gives for `--vfs`: a forwarded
  ## flag is spliced into the `.build.nif`, and two settings would then emit
  ## different build files -- which is what the phase's byte-identity gate
  ## forbids. The environment reaches every child instead, the nested
  ## `nimony s` of a compile-time evaluation included.
  ##
  ## A nimony-built compiler has no environment API and no in-process
  ## scheduler to configure, so it parses the flags and ignores them. That is
  ## the same gap `deps.inProcessMakeAvailable` documents.
  when not defined(nimony):
    putEnv(key, val)
  else:
    discard

proc handleCmdLine(c: var CmdOptions; cmdLineArgs: seq[string]; mode: CmdMode) =
  for kind, key, val in getopt(cmdLineArgs):
    case kind
    of cmdArgument:
      if c.cmd == None:
        c.cmd = dispatchBasicCommand(key, c.config)
      else:
        if c.forwardArgsToExecutable:
          c.executableArgs.add " " & quoteShell(key)
          c.programArgs.add key
        else:
          c.args.add key
          if c.cmd == FullProject and c.doRun and c.args.len >= 1:
            c.forwardArgsToExecutable = true
          elif c.cmd == RunProject and c.args.len >= 1:
            # `nimony r prog.nim a b`: the project file is the last token this
            # compiler reads. `-r` needs the flag first because `nimony c -r`
            # and `nimony c` are the same command; `r` IS the command, so
            # there is nothing to wait for.
            c.forwardArgsToExecutable = true

    of cmdLongOption, cmdShortOption:
      if c.forwardArgsToExecutable:
        c.executableArgs.add " --" & key
        if val.len > 0:
          c.executableArgs.add ":" & quoteShell(val)
        # The unquoted twin, for a program called rather than exec'd. `getopt`
        # has already split `--k:v`/`--k=v`, so this is the one spelling both
        # forms come back as -- which is what the exec path does too.
        if val.len > 0:
          c.programArgs.add "--" & key & ":" & val
        else:
          c.programArgs.add "--" & key
      else:
        var forwardArg = true
        var forwardArgLengc = false
        # Handle special cases first, then try common parser
        let keyNorm = normalize(key)
        if keyNorm == "vfs" and normalize(val) == "disk":
          # JIT.md 6.2: "`--vfs:disk` forces today's behaviour entirely". It is
          # the EXPLICIT flag that implies it, not the resolved policy: A1b
          # left the default policy at `disk` until A2c flips it, so reading
          # the resolved value here would leave the whole in-process path dead
          # at its own default. `--spawn:` given later still wins, which is
          # what makes `--vfs:disk --spawn:auto` mean "old store, new
          # scheduler" for a bisect.
          rememberForChildren("NIMONY_SPAWN", "always")
        if keyNorm == "help":
          echo Usage
          quit(QuitSuccess)
        elif keyNorm == "path" or keyNorm == "p":
          # Special handling for --path due to FromArgsFile check
          if mode == FromArgsFile:
            quit "`--path` in `.args` file is forbidden. Use a `nimony.paths` file instead."
          c.config.paths.add val
        elif (keyNorm == "define" or keyNorm == "d") and
             (normalize(val) == "release" or normalize(val) == "danger"):
          # `-d:release` / `-d:danger`: define the symbol (so `defined(release)`
          # / `defined(danger)` work here and — via forwarding (forwardArg stays
          # true) — in nimsem and the stdlib) and apply the implied build
          # settings. Mirroring Nim, `release` only raises the optimization level
          # while keeping runtime checks; `danger` additionally turns every
          # runtime check off. Later explicit `--opt:`/`--boundchecks:` still win,
          # since options are processed left to right.
          c.config.addDefine val
          c.config.optLevel = optSpeed
          if normalize(val) == "danger":
            c.checkModes = {}
        elif parseCommonOption(key, val, c.config, c.moduleFlags, forwardArg, forwardArgLengc,
                              helpMsg = Usage, versionMsg = Version & "\n"):
          discard "handled by common CLI parser"
        else:
          # Handle nimony-specific options
          case keyNorm
          of "forcebuild", "f":
            # NOT forwarded: `-f` is an instruction about THIS build graph, not
            # about the sub-builds this compile spawns. Forwarding it put
            # `--force` on the `nimony s` of every CTFE sub-program (see
            # `semos.runEval`), where it deleted and rebuilt all 30-odd nodes
            # per const evaluation. A sub-program is content-addressed — its
            # module suffix is a checksum of the expression — so there is
            # nothing to force: the same name always means the same input.
            c.buildFlags.incl ForceRebuild
            forwardArg = false
          of "ff":
            c.fullRebuild = true
            c.buildFlags.incl ForceRebuild
            forwardArg = false
          of "run", "r":
            c.doRun = true
            if c.cmd == FullProject and c.args.len >= 1:
              c.forwardArgsToExecutable = true
            forwardArg = false
          of "boundchecks":
            forwardArg = false
            case val
            of "on": c.checkModes.incl BoundCheck
            of "off": c.checkModes.excl BoundCheck
            else: quit "invalid value for --boundchecks"
          of "silentmake":
            c.buildFlags.incl SilentMake
            forwardArg = false
          of "spawn":
            # `always` is the escape hatch of JIT.md 6.2: every DAG node gets a
            # process, and so does `nifmake` itself, so the process tree is
            # literally the one the release before A2b produced. It isolates a
            # scheduler bug from a store bug because the store stays installed.
            #
            # In the environment rather than in `c.commandLineArgs` for the
            # reason A1b gives for `--vfs`: a forwarded flag is spliced into
            # the `.build.nif`, and the two modes would then emit different
            # build files -- exactly what this phase's gate forbids the tests
            # from tolerating. The environment reaches every child, the nested
            # `nimony s` of a compile-time evaluation included.
            case normalize(val)
            of "always": rememberForChildren("NIMONY_SPAWN", "always")
            of "auto", "": rememberForChildren("NIMONY_SPAWN", "auto")
            else: quit "invalid value for --spawn; expected always or auto"
            forwardArg = false
          of "jobs":
            # The per-DAG-depth process cap. `--jobs:1` also drops the batch
            # entirely and runs the graph node by node, which is what makes a
            # build's output readable when something in it fails.
            let n = parsePositiveInt(val)
            if n < 1: quit "invalid value for --jobs; expected a process count >= 1"
            rememberForChildren("NIMONY_JOBS", $n)
            forwardArg = false
          of "inproc-k", "inprock":
            # JIT.md 6.2's `k`: a registered phase runs in-process while its
            # estimated cost is under `k` spawn costs. Exposed because the
            # right value is a property of the machine, and 3 is a measurement
            # on one of them.
            let n = parsePositiveInt(val)
            if n < 1: quit "invalid value for --inproc-k; expected a number >= 1"
            rememberForChildren("NIMONY_INPROC_K", $n)
            forwardArg = false
          of "inproc-mem-budget", "inprocmembudget":
            # M1's memory gate. In the environment beside `--spawn` and
            # `--inproc-k` for the same reason: the setting must reach the
            # nested `nimony s` of a compile-time evaluation without changing
            # a byte of any `.build.nif`.
            #
            # `0` is a value, not an absence -- it turns the rule off -- so it
            # is checked before `parsePositiveInt`'s "0 means unparseable".
            if val == "0":
              rememberForChildren("NIMONY_INPROC_MEM_BUDGET", "0")
            else:
              let mb = parsePositiveInt(val)
              if mb < 1:
                quit "invalid value for --inproc-mem-budget; expected megabytes >= 1, or 0 to disable"
              rememberForChildren("NIMONY_INPROC_MEM_BUDGET", $mb)
            forwardArg = false
          of "profile":
            c.buildFlags.incl Profile
            forwardArg = false
          of "no-blobcache", "noblobcache":
            # NOT forwarded, like `--vfs`: a `nimony s` sub-compile never
            # reaches a native link node, and the one setting that has to
            # travel -- to a child that DOES link, i.e. a `{.build.}` tool --
            # travels in the environment as `NIMONY_BLOBCACHE=off`, which is
            # already inherited.
            c.config.blobCache = false
            forwardArg = false
          of "report":
            c.buildFlags.incl Report
            forwardArg = false
          of "stats":
            c.buildFlags.incl Stats
            forwardArg = false
          of "vfs-spill-margin", "vfsspillmargin":
            # The artifact store's spill decision (JIT.md 5.2). Parsed here
            # rather than in `cli.parseCommonOption` beside `--vfs` because the
            # tools that share that parser are the ones that never see the flag
            # anyway: like the policy and the budget it travels to every child
            # in the environment, so that two settings still emit
            # byte-identical `*.build.nif` files.
            let pct = parseBudgetMB(val)
            if pct <= 0 or pct > 100:
              quit "invalid value for --vfs-spill-margin; expected a percentage"
            requestSpillMargin pct
            forwardArg = false
          of "ischild":
            # undocumented command line option, by design
            c.isChild = true
            forwardArg = false
          of "native":
            # Select the libc-free native backend (arkham + nifasm) for this build,
            # without using the `n` *command*. Used by macro-plugin compilation (the
            # `s` command), where skipping the C-compiler round-trip is the biggest
            # compile-time win. Mirrors `n`'s config in dispatchBasicCommand; the
            # defines are forwarded to nimsem by compileProgram (the backendNative
            # branch), so this flag itself need not propagate.
            c.config.backend = backendNative
            c.config.addDefine "nimNativeAlloc"
            c.config.addDefine "nimNativeIo"
            forwardArg = false
          of "passc":
            if c.passC.len > 0:
              c.passC.add " "
            c.passC.add val
            forwardArg = false
          of "passl":
            if c.passL.len > 0:
              c.passL.add " "
            c.passL.add val
            forwardArg = false
          else: writeHelp()
        if forwardArg:
          c.commandLineArgs.add " --" & key
          if val.len > 0:
            # Store the raw value: it is emitted into the `.build.nif` as
            # individual StringLits which nifmake shell-quotes exactly once.
            # Pre-quoting here would double-quote (e.g. `--usages:f,3,10`'s
            # comma triggers quoteShell, then nifmake quotes again and the
            # literal quotes reach the tool). The forwarded compiler flags are
            # shell-safe unquoted, so `selfExec`'s raw splice is fine too.
            c.commandLineArgs.add ":" & val
        if forwardArgLengc:
          c.commandLineArgsLengc.add " --" & key
          if val.len > 0:
            c.commandLineArgsLengc.add ":" & val

    of cmdEnd: assert false, "cannot happen"

proc runProject(c: var CmdOptions) =
  ## `nimony r`: build the native backend down to every module's `.asm.nif`,
  ## then assemble and call the program in this very process
  ## (`engine.runWholeProgram`). Nothing is written to disk unless `--out` /
  ## `--outdir` asked for an executable, in which case the ordinary link node
  ## runs as well and the program is STILL run from memory -- one build, two
  ## answers.
  ##
  ## The program's status becomes nimony's. That is stricter than `-r`, whose
  ## `exec` turns any non-zero result into a generic `FAILURE:` line; a command
  ## whose whole purpose is running the program has to be transparent about
  ## what the program said.
  when defined(nimonyEngine):
    if c.config.targetCPU != nameToCPU(hostCPU) or
       c.config.targetOS != nameToOS(hostOS):
      # A cross compile has no arena to run in: the image is code for another
      # machine, and `hostrun` would call it here. Refused before the build
      # rather than after it, because the build is the expensive half and
      # nothing about it could make the run possible.
      quit "nimony r runs the program in this process, so it cannot cross " &
           "compile (--cpu/--os name another target); use `nimony n`"
    makeDir(c.config.nifcachePath)
    let project = c.args[0].addFileExt(".nim")
    # Read off the config BEFORE `buildGraphForRun` consumes it. The same
    # directory the `link` node would have handed nifasm on the command line,
    # so the two native paths keep one store per nimcache rather than each
    # inventing its own place to put fragments.
    let blobDir = if blobCacheEnabled(c.config): blobCacheDir(c.config) else: ""
    let wantExe = c.config.outFile.len > 0 or c.config.outDir.len > 0
    let target = buildGraphForRun(c.config, project, c.buildFlags,
                                  c.commandLineArgs, c.commandLineArgsLengc,
                                  c.moduleFlags, c.passC, c.passL, wantExe)
    if not target.ok:
      quit "FAILURE: could not build " & project
    # argv[0] is the program's own name, the way an exec'd one sees it: the
    # executable's path when there is one, else the project file.
    var argv: seq[string] = @[]
    if target.exe.len > 0: argv.add target.exe
    else: argv.add project
    for a in c.programArgs: argv.add a
    var e = initEngine()
    let r = runWholeProgram(e, RunProgram(backendDir: target.backendDir,
                                          mainModule: target.mainModule,
                                          argv: argv,
                                          verbose: c.config.verbose,
                                          profile: Profile in c.buildFlags or
                                                   c.config.verbose,
                                          blobCacheDir: blobDir))
    case r.outcome
    of roRan:
      exitAs r.status
    of roRefused:
      # No fallback here. JIT.md 7.5's C-backend fallback is for compile-time
      # evaluation, where a refusal must not be visible to the user; for `r`
      # the honest answer is the diagnostic and the command that does work.
      quit "nimony r: cannot run this program from memory: " & r.reason &
           "\n  use `nimony n" & (if wantExe: "" else: " -r") &
           "` to link and run it instead"
  else:
    quit "nimony r needs the sibling `../nativenif` checkout at build time " &
         "(the compiler was built without `-d:nimonyEngine`); use `nimony n -r`"

proc compileProgram(c: var CmdOptions) =
  if c.config.backend == backendNative and c.config.appType notin {appConsole, appGui}:
    quit "the native backend supports executables only (no --app:lib/staticlib)"
  if c.config.backend == backendLLVM:
    if c.config.linker.len == 0:
      c.config.linker = "clang"
  elif c.config.linker.len == 0 and c.config.cc.len > 0:
    c.config.linker = c.config.cc
  if c.args.len == 0:
    quit "too few command line arguments, try --help"
  elif c.args.len > 2 - int(c.cmd in {FullProject, CheckProject, DocProject}):
    quit "too many command line arguments"

  if c.checkModes != DefaultSettings:
    let flags = genFlags(c.checkModes)
    # Emit a bare `--flags` when no checks are active (e.g. `-d:danger`): a
    # trailing `--flags:` would make parseopt swallow the following `m` command
    # as its value. Append `:value` only when there is one, matching how every
    # other forwarded option is built below.
    c.commandLineArgs.add (if flags.len > 0: " --flags:" & flags else: " --flags")
  # Forward the active check modes to the hexer code generator too (nifcgen
  # injects bound/range-check calls); without this it always used DefaultSettings.
  c.config.checkFlags = genFlags(c.checkModes)

  # The libc-free stdlib is the DEFAULT for every backend now: the native
  # allocator (`nimNativeAlloc`, a ported region allocator over mmap) and
  # raw-syscall IO (`nimNativeIo`). Opt back into the libc-backed versions with
  # `-d:useLibc` (both), `-d:useMimalloc` (allocator only) or `-d:useLibcIo` (IO
  # only). The native backend links no libc at all, so it is ALWAYS libc-free
  # regardless of those opt-outs. The `when defined(...)` gates live in nimsem,
  # which only sees defines forwarded on its command line (config.defines is the
  # cache key but not enough on its own) — so inject them the same way a user's
  # `-d:` does, and record them in config.defines so the cache key tracks them.
  if c.config.backend == backendWasm:
    # The wasm backend has exactly one target; imply it here — after CLI
    # parsing — so `nimony w x.nim` works bare. Forwarded like user flags
    # because nimsem sees only its command line (appended last, so it also
    # wins over a contradictory explicit --cpu/--os).
    #
    # `--os:standalone`, NOT `embedded`. Both are freestanding and it is easy to
    # read them as the same target, but they pick different stdlib arms and only
    # one of them is wasm's. `embedded` is BARE METAL: `syncio`'s arm writes
    # through ARM semihosting and `osalloc`'s takes the heap from nifasm's
    # `(heapstart)`/`(heapsize)` board-layout constants — neither exists here.
    # `standalone` falls into the raw-`write`/`read`/`open` arm instead, and
    # those are exactly the names ithaqua resolves to the host's import set.
    discard c.config.setTargetCPU("wasm32")
    discard c.config.setTargetOS("standalone")
    c.config.bits = 32
    c.commandLineArgs.add " --cpu:wasm32 --os:standalone --bits:32"
  let nativeBackend = c.config.backend == backendNative
  let optOutAll = c.config.isDefined("useLibc")
  if nativeBackend or not (optOutAll or c.config.isDefined("useMimalloc")):
    c.config.addDefine "nimNativeAlloc"
    c.commandLineArgs.add " --define:nimNativeAlloc"
  if nativeBackend or not (optOutAll or c.config.isDefined("useLibcIo")):
    c.config.addDefine "nimNativeIo"
    c.commandLineArgs.add " --define:nimNativeIo"
  # `nimNoLibc` marks the TRULY freestanding target — the native (arkham+nifasm)
  # backend, which links no libc at all. It is a stricter condition than
  # `nimNativeIo`: the C backend uses the raw-syscall stdlib too, but libc is still
  # linked, so stdlib code can fall back to a libc symbol where the freestanding
  # implementation is impossible (`futex` — no libc symbol of that name) or merely
  # approximate (`strtod`). Only the native backend sets it.
  if nativeBackend:
    c.config.addDefine "nimNoLibc"
    c.commandLineArgs.add " --define:nimNoLibc"

  semos.setupPaths(c.config)

  case c.cmd
  of None:
    quit "command missing"
  of SingleModule:
    if not c.isChild:
      makeDir(c.config.nifcachePath)
    processSingleModule(c.args[0].addFileExt(".nim"), c.config, c.moduleFlags,
                        c.commandLineArgs, ForceRebuild in c.buildFlags)
  of FullProject:
    makeDir(c.config.nifcachePath)
    # compile full project modules
    buildGraph c.config, c.args[0].addFileExt(".nim"), c.buildFlags,
      c.commandLineArgs, c.commandLineArgsLengc, c.moduleFlags, (if c.doRun: DoRun else: DoCompile),
      c.passC, c.passL, c.executableArgs
  of CheckProject:
    makeDir(c.config.nifcachePath)
    # check full project modules
    buildGraph c.config, c.args[0].addFileExt(".nim"), c.buildFlags,
      c.commandLineArgs, c.commandLineArgsLengc, c.moduleFlags, DoCheck, c.passC, c.passL, c.executableArgs
  of DocProject:
    makeDir(c.config.nifcachePath)
    # doc full project modules
    buildGraph c.config, c.args[0].addFileExt(".nim"), c.buildFlags,
      c.commandLineArgs, c.commandLineArgsLengc, c.moduleFlags, DoDoc, c.passC, c.passL, c.executableArgs
  of SemCheckNif:
    makeDir(c.config.nifcachePath)
    # compile full project modules
    buildGraph c.config, c.args[0], c.buildFlags,
      c.commandLineArgs, c.commandLineArgsLengc, c.moduleFlags, (if c.doRun: DoRun else: DoCompile),
      c.passC, c.passL, c.executableArgs
  of RunProject:
    runProject(c)

when isMainModule:
  var c = createCmdOptions(determineBaseDir())

  if c.config.baseDir.len > 0:
    let argsFile = findArgs(c.config.baseDir, "nimony.args")
    var args: seq[string] = @[]
    processArgsFile argsFile, args
    if args.len > 0:
      handleCmdLine(c, args, FromArgsFile)

  handleCmdLine(c, @[], FromCmdLine)
  # The store, if any, has to exist before the first artifact is touched and
  # after `--vfs` has been seen. Every child process inherits the mode through
  # the environment (`artifactstore.applyRequestedStore`).
  #
  # The nimcache goes the same way: it is where the cost ledger lives, and the
  # store reads the ledger to decide what is cheaper to reload than to
  # recompute (A1d). The driver is the only process that knows the directory
  # from a command line rather than from a path it was handed.
  requestLedgerDir(c.config.nifcachePath)
  applyRequestedStore()
  # The in-process scheduler (JIT.md 6.1-6.2). Installed here, after the
  # command line and after the store, because it reads the cost ledger out of
  # the nimcache and the nimcache is a command-line answer. `--spawn:always`
  # installs nothing, which is what makes the escape hatch exact rather than
  # approximate: no relay, so `deps.runMake` spawns `nifmake` and `nifmake`
  # spawns every node, the way it always did.
  when not defined(nimony):
    installPhaseRelay(spawnModeFromEnv(smAuto), c.config.nifcachePath,
                      inprocKFromEnv(DefaultInprocK))
  compileProgram(c)
  storeFlush()
  # The driver is the parent of every other tool process, so its own VFS time
  # is the one line the per-tool dumps cannot account for.
  dumpVfsProfile("nimony")
