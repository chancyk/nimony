# BENCHMARK.md — how the fast-devloop changes are measured

Everything here is what a new agent needs to reproduce, extend, or re-check a
number in `SUMMARY.md`. The design's measurement protocol is `JIT.md` 12; the
merge routine is `notes/handoff.md`; the results log is
`bench/results/<date>/progress.md` (latest run last, raw runs kept).

## 0. The verdict scenario, and why

The number that decides whether a change helped is **the compiler compiling
itself, on the native backend, after a live edit**: a statement inserted into
the body of `semStmt` in `src/nimony/sem.nim` (7k lines, the largest module).
Everything else (hello world, the CTFE modules, the stdlib-wide build) is
attribution, not the verdict. Two edit shapes exist because they exercise
different phases:

| scenario | what the edit is | what it exercises |
|---|---|---|
| `self.editbody` | `if isNewScope: discard N` inserted into `semStmt` | nimsem, hexer, arkham, link; NOT `dceLive` after the first round (the `.dce.nif` is byte-identical when no symbol or use-edge changes) |
| `self.editcall` | a new private proc AND a call to it from `semStmt` | the same plus `dceLive` every round (the call graph changes) |
| `self.editdead` | a private, never-called proc appended | only nimsem and hexer: DCE deletes it, so arkham and the link cost 0 — the pre-2026-09-07 headline, kept for continuity, do not quote it as the loop |

Read cpu-sum first, wall second, peak RSS beside them. Wall on this machine
drifts up to 3x with background load; cpu-sum is robust; interleaved A/B
ratios are robust to slow drift but not to a build starting halfway.

## 1. Prerequisites (one-time)

```sh
# the branch's toolchain (../nativenif must be at src/nativenif.commit)
XDG_CACHE_HOME=/tmp/main_cache nim c -r src/hastur/hastur build all

# the fork-point toolchain, for A/B (f69b8afc = master at the fork)
git worktree add --detach /tmp/devloop_base f69b8afc
(cd /tmp/devloop_base && nim c -r src/hastur/hastur build all)
# it has no ../nativenif; give it arkham/nifasm (their CLI output is gated
# byte-identical across the refactor, so the current checkout's are faithful)
(cd /Users/chanc/Projects/nativenif && for t in arkham nifasm; do
   nim c -d:release --hints:off --warningAsError:ProveInit:off \
     --warningAsError:Uninit:off --outdir:/tmp/devloop_base/bin src/$t/$t.nim; done)
```

Notes that cost hours to learn:

- Parallel `nim c` builds share `~/.cache/nim` and corrupt each other's
  links. Every agent sets a private `XDG_CACHE_HOME`.
- From a worktree under `/tmp` or `.claude/worktrees/`, `../nativenif` does
  not resolve; set `NIMONY_NATIVENIF=/Users/chanc/Projects/nativenif` (or a
  private clone) or the engine is silently not compiled into nimsem and
  `tests/ctfe_engine` reports "nothing to test".
- nativenif's `nim.cfg` reaches nimony's sources by the sibling-relative path
  `../../../nimony/src`; a clone under `/tmp/x/nativenif` needs
  `/tmp/x/nimony` to be a symlink to a nimony tree.
- `tools/refactor_gate.sh` and `tests/tester.nim` in nativenif rebuild
  `bin/nifasm` in DEBUG unless `SKIP_BUILD=1`. A debug nifasm links the
  compiler in 9 s instead of 0.9 s; copying it into a toolchain `bin/` looks
  exactly like a catastrophic regression.
- A cold build whose `--out` binary is named `nimony` and sits in the cwd
  used to fail (the CTFE sub-compile resolved the tool name to it); fixed on
  the branch, still true at the fork point: keep `--out` outside the source dir.
- **`devloop_ab` interleaves within a run, not across runs — so two branches
  must be compared in ONE invocation, never by comparing two invocations'
  ratios.** The script alternates A B A B so drift hits both sides equally,
  and that is exactly why a B/A ratio is only meaningful against the A side it
  was measured beside. Comparing a ratio from one run with a ratio from
  another silently reintroduces the drift the interleaving removed.

  What it looks like when you get it wrong: measured against the fork point
  the way `SUMMARY.md` describes, the F1-respell branch read B/A cpu **0.281**
  against an earlier **0.260-0.261** — an apparent 8 % regression that does not
  exist. `0ece350b` measured the same way in the same session read **0.257**,
  and the two *B* sides were 0.994 and 0.995 cpu — identical. What had moved
  was the **A** side, the FIXED fork-point toolchain: 3.536 s in one
  invocation, 3.879 s in another. Nothing about A changed; the machine did.

  Asked as a two-branch question — `bench/devloop_ab.sh <old-branch>
  <new-branch> self.editbody 5`, both arms in one interleaved run — the answer
  was **0.990 wall / 1.001 cpu, RSS 1.00**: no change, which is the truth.

  The rule: the fork-point comparison is for the HEADLINE ("how far have we
  come"), and it is only quotable as an absolute pair taken in one run. To ask
  "did this change move the loop", interleave the two branches being compared
  and read that run's ratio alone.

## 2. The A/B script (the one that produces the verdict)

```sh
bench/devloop_ab.sh <toolchain-A> <toolchain-B> [scenario] [rounds]
# scenarios: self.editbody | self.editcall | self.editdead | self.cold | self.run
#            | stdlib.forced | stdlib.cold | hello.forced | ctfe.forced
# e.g. the headline, fork point vs branch, 5 rounds:
bench/devloop_ab.sh /tmp/devloop_base /Users/chanc/Projects/nimony self.editbody 5
bench/devloop_ab.sh /tmp/devloop_base /Users/chanc/Projects/nimony self.editcall 5
bench/devloop_ab.sh /tmp/devloop_base /Users/chanc/Projects/nimony self.cold 3
```

A B A B ... interleaved, so drift hits both sides. Prints per-round wall,
cpu, peak RSS, then medians and B/A ratios. `self.*` copies the fork-point
sources (`/tmp/devloop_base/src`, or `SELF_SRC=<dir>`) per side so both
toolchains compile identical inputs; `--out` goes to a scratch dir.
`BACKEND=c` measures the C path (the default is `n`, the native backend).

## 3. The table script (attribution across every scenario)

```sh
bench/devloop_bench.sh <toolchain-root> <label> [runs]      # root must be ABSOLUTE
bench/devloop_bench.sh /tmp/devloop_base base 3
bench/devloop_bench.sh /Users/chanc/Projects/nimony head 3
EXTRA=--ctfe:subprocess bench/devloop_bench.sh /Users/chanc/Projects/nimony head-sub 3
```

Rows: `hello.forced/nochange/edit/nrun/run`, `ctfe.cold/warm/edit/forced`
(a 5-const module), `bench.cold/edit` (`bench/ctfe_bench.nim`, 14 consts),
`stdlib.cold/forced/edit` (`tests/nimony/stdlib/tall.nim`, C backend until
`std/rawthreads` has a nimNoLibc arm on macOS), `self.cold/nochange/
editbody/editdead/edit/forced/nrun/run`. Each row: median wall, cpu, peak
RSS of the largest process, with raw runs. Runs each toolchain as one block,
so it is fine for 2x signals and useless for 5 % ones — use the A/B for those.

## 4. Where the time goes (per-stage attribution)

```sh
# per phase of a build (nifmake's profile; in-process nodes shown separately)
bin/nimony n --profile --silentMake --nimcache:<nc> --out:<out> src/nimony/nimony.nim
NIMONY_PROFILE_NODES=1 bin/nimony n --profile ...     # one line per DAG node: inproc|spawn, phase, module, seconds, ready=n

# the cost ledger every tool writes (JIT.md 5.2): produce/serialize/write/load/parse/spawn/peak MB per phase
bin/nimony n --stats --silentMake --nimcache:<nc> src/nimony/nimony.nim

# hexer's passes on one module (StageTimer, B3b)
NIMONY_PASS_TIMING=1 bin/hexer c --bits:64 --cpu:le --os:MacOSX --native --flags:br <nc>/<mod>.s.nif

# nifasm's stages and blob-cache hits/stale/recorded on a link
NIFASM_PROFILE=1 bin/nifasm --blobcache:<nc>/blobcache -o:<out> <nc>/<main>.asm.nif   # argv: see the (cmd :link ...) in <nc>/<main>.final.build.nif

# the CTFE engine's per-evaluation line
bin/nimony c --verbose --nimcache:<nc> tests/nimony/consteval/tmyops.nim | grep ctfe-engine
# nimony r's assemble/lay/bind/run line
bin/nimony r --verbose --nimcache:<nc> prog.nim

# a sampling profile of one tool (macOS): sample the TOOL's pid, not a wrapper
( exec bin/nimsem <argv from the (cmd :nimsem ...) template in <nc>/<main>.build.nif> ) & sample $! 3 1 -mayDie -file out.txt
```

The build-file templates under `<nc>/*.build.nif` are the source of truth
for any tool's argv (`(cmd :nimsem ...)`, `(cmd :hexer ...)`,
`(cmd :link ...)`); `--base:src/nimony` is relative to the cwd the build ran in.

## 5. Correctness gates that accompany every measurement

```sh
bin/hastur boot --boot-backend:native      # stages 1 == 2 == 3 byte-identical (the compiler compiled by itself, natively)
bin/hastur boot                            # the C backend, stages 2 == 3
bin/hastur tests/nimony                    # the whole tree (794); `hastur test <dir>` is a flat dir only
bin/hastur test tests/ctfe_diff            # every compile-time result and the caller's .s.nif byte-compared across mode pairs
bin/hastur test tests/incremental          # rebuild counts per scenario (all --vfs/--spawn modes), incl. decl-stability
bin/hastur tests/inproc                    # two runs in one process == two processes, per tool
bin/hastur test tests/nifcache             # --vfs:disk vs --vfs:verify artifact identity
bin/hastur test tests/nimony_r tests/ctfe_engine tests/ledger tests/vfs   # one at a time
(cd ../nativenif && tools/refactor_gate.sh out.sums && diff <baseline>.sums out.sums)   # CLI byte identity, 2583 artifacts
(cd ../nativenif && nim r tests/tester.nim)   # incl. blob-cache and memory-image byte-identity self-tests
```

`decl-stability` (in `tests/incremental`) prints how many of a module's
declarations change for an in-place edit, an inserted proc, an added
statement and an added temp — the numbers F1/F2 are gated on (1/1/1/1).

## 6. Escape hatches (each restores the fork-point behaviour of one mechanism)

| flag / env | restores |
|---|---|
| `--ctfe:subprocess`, `NIMONY_CTFE_ENGINE=off` | CTFE through a linked binary |
| `--spawn:always` (`NIMONY_SPAWN=always`) | every phase a process, nifmake spawned |
| `--vfs:disk` (default), `--vfs:verify` | no artifact store; verify = compare every memory read to disk |
| `--no-blobcache`, `NIMONY_BLOBCACHE=off` | nifasm from scratch |
| `NIMONY_CCACHE=off` | no shared `.c.nif` for CTFE's stdlib closure |
| `--inproc-mem-budget:0` | scheduler ignores memory |
| `NIMONY_INCHEXER=off` (reserved), `--blobcache-hash` (strict blob validity) | see notes |

## 7. Reading the results log

`bench/results/2026-09-06/progress.md` runs 1–8, `2026-09-07/progress.md`
runs 9–17. Each run states its head commit, load, method and raw runs.
Run 13 corrected the headline edit (the dead-proc edit measured 0 s of
arkham and link); run 17 is the latest. Per-phase files (`p0a.txt`,
`a2b.txt`, `b1r.txt`, `b3n.txt`, `f1.txt`, `f2.txt`, `b3d.txt`, `h1.txt`, ...)
hold each phase's own before/after with its stage tables.

## 8. What to measure next, if continuing

- After B3e (arkham per-proc splice): re-take `self.editbody`/`self.editcall`
  and the per-stage table; arkham should read ~0.1 s.
- The floor then is nimsem re-checking the edited module (~0.34 s on
  `sem.nim`); only declaration-level incremental sem moves it (owner's call).
- Cold self-compilation: `dceLive` holds 147 MB (per-module resolve subsets,
  P0c) — stream them out; `--threads:off` for hexer/lengc/nifler/nimony is
  -6 % on hexer; hexer copies the module tree once per pass (memmove + skip
  ~35 % of its profile, run 14).
