# Compile-time evaluation latency benchmark.
#
# Unlike the other benchmarks here, the work this file measures happens while
# it COMPILES, not while it runs. Every `const` below is an expression
# `expreval` cannot fold in-process — a call to a user proc, a loop, a `@[]`,
# a `Table`, a string built piece by piece — so each one sends `exprexec` off
# to compile and run a whole program of its own (see `semos.runEval`). The
# program you get at the end just adds the results up; the interesting number
# was spent before it existed.
#
#   bench/ctfe_latency.sh          cold, warm and forced wall time plus the
#                                  process counts, which is the measurement
#   hastur test bench              the smoke check: does it still build and
#                                  still compute the same total
#
# The consts are deliberately all DIFFERENT expressions. A sub-program is
# named after a checksum of the expression that asked for it, so two
# identical initializers would share one evaluation and this file would
# measure half of what it claims to.

import std / [syncio, tables]

const
  smoke = defined(benchSmoke)
    ## `hastur` compiles this file with `-d:benchSmoke` (see
    ## `bench/hastur.mode`). The suite is not here to time anything — it asks
    ## whether the file still builds and still computes the number it used to
    ## — so the smoke shape keeps one const of each kind and the latency
    ## script, which compiles without the define, pays for all thirteen.

proc weigh(x: int): int =
  ## A plain user proc with a loop: enough on its own to defeat in-process
  ## folding, which stops at literals, arithmetic and a magic whitelist.
  result = 0
  var i = 0
  while i <= x:
    result = result + i * i
    inc i

proc digits(x: int): int =
  result = 0
  var n = x
  while n > 0:
    result = result + n mod 10
    n = n div 10

proc counted(a, b, c: string): int =
  ## Builds a `Table` and reduces it, so the evaluation has to allocate and
  ## serialise a container rather than an integer.
  var t = initTable[string, int]()
  t[a] = a.len
  t[b] = b.len * 2
  t[c] = c.len * 3
  result = 0
  for k, v in pairs(t):
    result = result + v * k.len

proc built(n: int): int =
  ## String building, the fourth shape.
  var s = ""
  for i in 0 ..< n:
    s.add "ab"
  result = s.len

proc sum(s: seq[int]): int =
  result = 0
  for x in items(s):
    result = result + x

# --- one sub-compile per const ----------------------------------------------

const
  callA = weigh(11)
  seqA: seq[int] = @[3, 1, 4, 1, 5]
  tableA = counted("alpha", "beta", "gamma")
  textA = built(6)

when smoke:
  const rest = 0

  proc restSeqs(): int = 0
else:
  const
    callB = weigh(23)
    callC = weigh(37)
    callD = digits(123456789)
    callE = digits(24680)
    seqB: seq[int] = @[9, 2, 6, 5, 3, 5]
    seqC: seq[int] = @[8, 9, 7, 9, 3, 2, 3, 8]
    tableB = counted("delta", "epsilon", "zeta")
    tableC = counted("eta", "theta", "iota")
    textB = built(14)
    textC = built(29)
    rest = callB + callC + callD + callE + tableB + tableC + textB + textC

  proc restSeqs(): int =
    ## The const seqs are folded at compile time but reduced at RUN time: a
    ## `seq` const cannot be passed to a proc inside another const
    ## initializer, and the point of these two is the sub-compile they cost,
    ## not where they are added up.
    result = sum(seqB) + sum(seqC)

proc main() =
  let total = callA + tableA + textA + sum(seqA) + rest + restSeqs()
  echo total

main()
