import std/strutils

# Failure mode: the evaluated expression RAISES in the sub-compile.
#
# `exprexec.executeExpr` wraps the synthesised program's body in a
# `try/except` so a `.raises` callee like `parseInt` sem-checks at all; the
# handler does not write a result, so the `.out.nif` never gets a value and
# the const has nothing to bind. What the user must see is a diagnostic at the
# const, not a silent zero.
#
# TODO: what the user sees instead is `[Error] cannot open:
# nimcache/tco<sha1>.out.nif` — and that text cannot be pinned as a `.msgs`
# golden either, because hastur reads the expected exit code out of the keyword
# `Error:` and `[Error]` is not it. See README.md here.

const bad = parseInt("x")

echo bad
