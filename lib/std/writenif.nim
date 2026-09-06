# Helper routines for generating NIF code. Used by the `exprexec` module.

import std/[syncio, math, formatfloat]

var outp: File
var readsFile = ""

const ReadsExt* = ".reads"
  ## Appended to the result file's name for the dependency sidecar; kept here
  ## so `semos.runEval`, which reads it back, and this writer agree.

proc setup*(filename: string) =
  ## Starts one compile-time evaluation: `filename` is `<sfx>.out.nif`, the
  ## file the generated program serialises its result into.
  outp = open(filename, fmWrite)
  # The compiler memoizes `<sfx>.out.nif` and cannot otherwise see a file this
  # program reads while it runs — `readFile` in a `const` initializer is a
  # plain call, not a compiler magic. Record those reads so the memo can be
  # invalidated when one of them changes, the way a plugin reports its own
  # reads through `plugins.dependsOn`.
  readsFile = filename & ReadsExt
  fileReadLog.paths = ""
  fileReadLog.enabled = true

proc teardown*() =
  ## Ends the evaluation: closes the result and writes the sidecar beside it.
  ## The sidecar is plain text, one absolute-or-`sourceDir`-relative path per
  ## line, and is written LAST so its presence means "this run completed".
  fileReadLog.enabled = false
  close(outp)
  var sidecar: File
  if open(sidecar, readsFile, fmWrite):
    write(sidecar, fileReadLog.paths)
    close(sidecar)

# all atoms must start with a space, keeps the logic simple

proc writeNifFloat*(f: float) =
  case classify(f)
  of fcInf: write(outp, "(inf)")
  of fcNan: write(outp, "(nan)")
  of fcNegInf: write(outp, "(neginf)")
  of fcNegZero: write(outp, " -0.0")
  of fcNormal, fcSubnormal, fcZero:
    write(outp, " ")
    var buf = newStringOfCap(32)
    buf.addFloat f
    for i in 0 ..< buf.len:
      if buf[i] == 'e': buf[i] = 'E'
    write(outp, buf)

proc writeNifInt*(i: int) =
  write(outp, " ")
  write(outp, i)

proc writeNifUInt*(u: uint) =
  write(outp, " ")
  write(outp, u)
  write(outp, "u")

proc writeNifBool*(b: bool) =
  if b:
    write(outp, "(true)")
  else:
    write(outp, "(false)")

const
  ControlChars* = {'(', ')', '[', ']', '{', '}', '~', '#', '\'', '"', '\\', ':', '@'}

proc escape(c: char) =
  const HexChars = "0123456789ABCDEF"
  var n = int(c)
  write(outp, "\\")
  write(outp, HexChars[n shr 4 and 0xF])
  write(outp, HexChars[n and 0xF])

template needsEscape(c: char): bool = c < ' ' or c in ControlChars

proc writeNifChar*(c: char) =
  write(outp, " '")
  if c.needsEscape:
    escape c
  else:
    write(outp, c)
  write(outp, "'")

proc writeNifRaw*(s: string) =
  write(outp, s)

proc writeNifStr*(s: string) =
  write(outp, " \"")
  for c in s.items:
    if c.needsEscape:
      escape c
    else:
      write(outp, c)
  write(outp, "\"")

proc writeNifSymbol*(s: string) =
  if s.len > 0:
    let c = s[0]
    if c in {'.', '0'..'9', '+', '-', '~'} or c.needsEscape:
      escape c
    else:
      write(outp, c)
    for i in 1..<s.len:
      let c = s[i]
      # Symbols imported from C can have a space like "struct foo".
      if c == ' ' or c.needsEscape:
        escape c
      else:
        write(outp, c)

proc writeNifParLe*(tag: string) =
  write(outp, "(")
  write(outp, tag)

proc writeNifParRi*() =
  write(outp, ")")
