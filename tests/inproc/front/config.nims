# The nifler driver compiles nifler, which parses Nim with the HOST compiler's
# parser — and nifler swaps in the pinned checkout of Nim's own `parser.nim`
# (see `src/nifler/config.nims` for the whole story). This mirrors that
# `patchFile` so the in-process nifler is the SAME parser as `bin/nifler`;
# without it the two would agree on ordinary code and disagree the moment a
# test input used syntax only `devel` parses.
#
# `patchFile` is a lookup override keyed by (package, module), so it is inert
# for every project here that does not import `compiler / parser` — the runner
# and the nimsem driver are unaffected. The path is relative to this file;
# `fileExists` is relative to the current directory, hence `thisDir()`.
if fileExists(thisDir() & "/../../../src/nifler/nimparser/parser.nim"):
  patchFile("compiler", "parser", "../../../src/nifler/nimparser/parser")
