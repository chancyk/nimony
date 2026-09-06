# A small program for the ledger's integration test: enough modules that
# every phase runs, small enough that the build stays cheap.
import std / syncio

proc greet(name: string): string =
  result = "hello, " & name

echo greet("ledger")
