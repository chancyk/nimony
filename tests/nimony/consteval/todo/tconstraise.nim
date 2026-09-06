import std/strutils

# Failure mode: the evaluated expression RAISES in the sub-compile.
#
# `exprexec.executeExpr` wraps the synthesised program's body in a
# `try/except` so a `.raises` callee like `parseInt` sem-checks at all; the
# handler does not write a result, so the `.out.nif` never gets a value and
# the const has nothing to bind. What the user must see is a diagnostic at the
# const, not a silent zero — this test is the golden for that.

const bad = parseInt("x")

echo bad
