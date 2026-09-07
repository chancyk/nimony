# merge/u5 — upstream `38f67463` into `fast-devloop`

Step 5 of the six-commit upstream merge chain (`MERGE.md`). Base: `450a0831`
(= `origin/fast-devloop` after step 4). Merged: `38f67463` "std/http: thread
the tag space instead of keeping one per process (#2484)".

The easiest of the six, and the notes are short because the interesting part is
a question that had to be *asked*, not a conflict that had to be resolved.

## 1. What upstream `38f67463` does

11 files, +241/-176. The count in the chain plan was slightly off, and the
correction matters only because it is what the `A`-vs-`M` check is for:
**one doc, FOUR library files and SIX tests** — `doc/internals/http.md`,
`lib/std/http/{httpconn,httpmsg,httpparse,httpwire}.nim`, and
`tests/nimony/http/{tchunked,tconn,tmsg,tparse,tresponse,twire}.nim`.
`httpmsg.nim` is the one that carries the change (104 lines).

`std/http` kept its tag space — the `TagPool` interning known header names,
methods, header values and structural tags — in one process-global
`gHttpTags`, filled during init. It becomes an `HttpTags` value that an
application makes with `newHttpTags()` and passes to `initHttpMsg` /
`initHttpConn`; from there `HttpMsg.tags` carries it, so the parser and the
wire writer need no tag parameter of their own. `registerHeader` takes the
space as its first argument. The argument in the doc is that a `TagId` only
means something against the space it was written against, and threading puts
that in the signatures instead of leaving it a promise the process has to keep.

The doc also drops a stale reference: it named
`tests/nimony/http/httptags.nim` as "the one place that registers", and that
file has never existed in this repository (`git log --all --
tests/nimony/http/httptags.nim` is empty).

## 2. How it met fast-devloop

Zero overlap and zero conflict, and for once that can be stated at full
strength. `git diff --stat f69b8afc..450a0831 -- doc/internals/http.md
lib/std/http tests/nimony/http` is **empty** — this branch has never touched
any of the 11 files. Our only `lib/std` changes anywhere are P0a's
`syncio.nim` read log and `writenif.nim`'s `.out.nif.reads` sidecar.

So the check that has carried the previous four steps returns the strongest
possible answer here: every one of the 11 merged files is **byte-identical**
to `git show 38f67463:<path>`, not merely "differs by our hunks".

```
for f in <the 11 paths>; do
  git show 38f67463:$f > /tmp/u5_up.tmp
  diff -q /tmp/u5_up.tmp $f
done          # 11 x "identical to upstream"
```

## 3. The question this step was told to ask

`38f67463` is `c6be04e1`'s pattern one layer out — process-global state
becoming a threaded parameter — so: **does anything in our reset or snapshot
machinery know about a per-process http tag space?**

**No, and it structurally cannot.** Checked against step 4's inventory
(`notes/merge-u4.md` §2), which is the full list of what we reset:

```
semmain.resetFrontendGlobals()  -> nifpools.resetPools()       pool, globalTags
                                -> programs.resetProgram()     prog
                                -> identstyle.resetStyleTables()
                                -> filelinecache.resetFileLineCache()
hexer.resetHexerGlobals()       -> resetProgram + resetPools + resetInlinerStats
lengc.resetLengcGlobals()       -> documented no-op
semos.takeFrontendState() / restoreFrontendState()  pool, globalTags, prog, style
```

Every entry is a global of a **compiler** process. `gHttpTags` was a global of
a program the compiler *produces*: `std/http` is library code, the compiler
does not import it (`grep -rn 'std/http' src/` is empty), and no compiler
source mentions `HttpTags`/`gHttpTags` (also empty). A2c's `FrontendSnapshot`
moves `pool`/`globalTags`/`prog` aside for an in-process sub-build; the http
tag space was never in that address space to begin with.

### 3.1 Where the analogy does land — worth writing down

The bug upstream fixed is nonetheless the same *class* as A2a's, and it landed
in a place this branch cares about: **joined tests**. `tests/nimony/http/` is a
joined group, so its six tests run in one process, and the doc says exactly
what happened — "the tag pool is process-global while a joined group is one
process, so each test registering for itself made the first member's init
decide what ids the rest saw". That is the same failure shape A2a exists to
prevent (state that is per-process when the unit of work is smaller than a
process), reached from the other direction: A2b/A2c made the compiler run
several phases in one process; `AGENTS.md`'s joined tests make several tests
run in one process. Upstream removed the coupling at the root by threading, so
"a joined group behaves like six separate processes again".

Nothing for us to do. But it is a second confirmed instance of the pattern,
and if a future phase makes more of the suite share a process, this is the
class of bug to look for first.

## 4. Test count

`git status` after the merge shows all 11 files as **`M`**, none as `A`: no
test file was added, so the total does not move. `bin/hastur tests/nimony/http`
is `6 / 6 tests successful`, and the full tree is `795 / 795`, the same
baseline as steps 2, 3 and 4. (Precedent for checking rather than assuming:
step 2, where the plan said three tests were added and they were modified.)

## 5. Verification

Env `XDG_CACHE_HOME=/tmp/cache-u1`,
`NIMONY_NATIVENIF=/Users/chanc/Projects/nativenif`. Pin unchanged at
`3ec73fef`; `../nativenif` on `jit/upstream-e201a816`, whose tip IS the pin,
so `build all` printed **zero `[deps]` lines** — the step-3 evidence rule.

| command | result |
|---|---|
| `nim c -r src/hastur/hastur build all` | exit 0, 0 `[deps]` lines |
| `bin/hastur tests/nimony/http` | `6 / 6 tests successful in 3.09s` |
| `bin/hastur test tests/incremental` | all green; `decl-stability: 4 / 4`, digest counts unchanged |
| `bin/hastur tests/inproc` | `3 / 3`; `nimsem: 6 output files byte-identical to two processes` |
| `bin/hastur test tests/ctfe_diff` | `19 file(s), 50 artifact(s), 79 .s.nif, 0 difference(s)` |
| `bin/hastur test tests/nifcache` | `nifcache: all checks passed` |
| `bin/hastur test tests/nimony_r` | `nimony_r: all checks passed` |
| `bin/hastur test tests/ctfe_engine` | `ctfe_engine: all checks passed` |
| `bin/hastur test tests/ledger` | `[ledger] all ledger tests passed` |
| `bin/hastur tests/nimony` | `795 / 795` |
| `bin/hastur boot --boot-backend:native` | stages 1 == 2 == 3 byte-identical |

No benchmark: the commit touches only `lib/std/http`, which no compiler phase
imports, so it cannot reach the loop. Step 4's 0.260/0.261 against step 3's
0.261 is the live reference.

## 6. Note for step 6

`jit/upstream-master` in `../nativenif` has moved on since step 3's write-up:
its tip is now **`9d7fcf78`**, and the chain table has been corrected from
`83ced299` to it. The two new commits are notes-only —
`git diff --stat 83ced299 9d7fcf78 -- . ':(exclude)notes'` is empty — so the
code either would build is identical; `9d7fcf78` is simply the current tip and
carries `notes/nativenif-rebase.md`. `82ca1f38` (the split-symbol reader fix
that step 3's pin deliberately lacks) is an ancestor of both.
