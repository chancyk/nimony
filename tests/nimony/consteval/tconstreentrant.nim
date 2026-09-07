import std / [syncio, assertions]
import imports / reentrantprov

# The cross-module form of `tconstchain.nim`: a `const` here whose initializer
# reads a `const` from an IMPORTED module that needed a sub-compile of its own.
#
# What that exercises is the compile-time-evaluation path running twice in one
# process at two different points of one frontend graph -- once while
# `reentrantprov` is being semchecked, once while this module is -- and, in
# between, this module reading the imported module's `.s.nif`. If the nested
# build left anything of its own in `prog`, in the pool or in the identifier
# tables, the symbols this module resolves out of that `.s.nif` are the first
# thing to go wrong.
#
# Generics, templates and ordinary procs are declared after each `const` in
# both modules on purpose: they are semchecked from the symbol table the nested
# build ran across.

const Steps = ProviderSteps
assert Steps == 111

const Doubled = twice(ProviderSteps)
assert Doubled == 222

proc combine(a: int; b: string): string =
  result = b
  result.add "/"
  result.add $a

const Combined = combine(Steps, ProviderLabel)
  ## A sub-compile in THIS module whose arguments are both values that came
  ## back from a sub-compile of the imported one.
assert Combined == "steps=111/111"

const Paired = pairUp(Steps)
  ## A generic of the IMPORTED module, instantiated here and evaluated by a
  ## third sub-compile. Its instance is minted from the imported module's
  ## symbol table as this module read it back out of a `.s.nif` written on the
  ## other side of a nested build.
assert Paired[0] == 111
assert Paired[1] == 111

announce()
echo Steps, " ", Doubled
echo Combined
echo Paired[0] + Paired[1]
