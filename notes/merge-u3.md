# merge/u3 — upstream `b7c7daa6` into `fast-devloop`

Step 3 of the six-commit upstream merge chain (`MERGE.md`). Base: `615acc9e`
(= `merge/u2`). Merged: `b7c7daa6` "newest nativenif (#2478)", a one-line pin
bump `d0781a48` -> `e201a816`.

## 1. The conflict and the resolution

The only conflict in the chain so far. `src/nativenif.commit` is one line and
both sides rewrote it; ours was `5f6f011e` (B3e), upstream's `e201a816`.

Resolved to **neither**: `3ec73fef7bcf335f1077d0de67c574ddbd7e71ac 2026-09-07`,
the tip of the local branch `jit/upstream-e201a816` in
`/Users/chanc/Projects/nativenif` — our 32-commit B1 -> B3e chain replayed
onto upstream's `e201a816` by the parallel nativenif agent. Ancestry checked
rather than assumed:

```
git merge-base --is-ancestor e201a816 3ec73fef   # yes
git merge-base --is-ancestor d0781a48 3ec73fef   # yes
git merge-base --is-ancestor 5f6f011e 3ec73fef   # NO -- rebased, not merged
git rev-list --count e201a816..3ec73fef          # 32
```

Format byte-checked against the previous pin with `od -c`: 40 hex, one space,
`YYYY-MM-DD`, one `\n`.

## 2. The trap this step contains, and why it is not automatic

`hastur`'s `syncNativenif` (`src/hastur/deps.nim`) will NOT check a pin out
over a sibling checkout that sits on a BRANCH — it warns and builds whatever
is there (the guard exists so someone's working tree is not clobbered). The
checkout was on `jit/b3e-native` at the OLD pin `5f6f011e`, so `build all`
would have built the OLD arkham/nifasm under the NEW pin and every test would
still have passed, three times slower on the edit loop, with nothing naming
the loss.

So the checkout was moved by hand: `git switch jit/upstream-e201a816` — a
local branch whose tip IS `3ec73fef`, which makes `syncNativenif` return on
its FIRST check (`head == pin`) rather than reach the branch guard. `build
all` then prints no `[deps]` line at all, and that absence is the evidence
that the pin was honoured. **Check for it on every future pin bump.**

Where the checkout is left: `/Users/chanc/Projects/nativenif` on branch
`jit/upstream-e201a816` at `3ec73fef`, clean. It is no longer on
`jit/b3e-native`; that branch still exists and still points at `5f6f011e`.

## 3. What is deliberately NOT on this pin

The nativenif agent's rebase raised zero git conflicts but broke 4 of 2592
fixtures, fixed in nativenif `82ca1f38`. That fix is on `jit/upstream-master`
and is **deliberately absent from `3ec73fef`**, because the cause does not
exist before the nifsyms refactor: `parse` turns on split-symbol mode on a
module's SHARED reader, so a module read once through `getDecl` leaves its
reader split, and B3c's hand-copied `readDeclHead` then walks out of a tree it
has already opened. `e201a816` predates that.

**Step 6 is where this arrives.** The nifsyms refactor (`e1da48e9`) brings the
cause on the nimony side and `83ced299` (`jit/upstream-master`) brings the
compensating fix on the nativenif side; they have to land together. An agent
that takes step 6 and pins something without `82ca1f38` will see exactly those
four fixtures fail.

## 4. Correction to the chain table (carried into `MERGE.md`)

Upstream's step-6 pin `f9af5b24` does not exist in `nim-lang/nativenif`; it is
`2c30a9ef` rebased away. So **step 6 pins `83ced299`** (`jit/upstream-master`),
not `f9af5b24`. That also fixes the ORDER: `e201a816` builds against a nimony
either side of the refactor, `2c30a9ef` only after it — which is why step 3
takes `3ec73fef` and not the later tip.

## 5. Verification

Full set, env `XDG_CACHE_HOME=/tmp/cache-u1`,
`NIMONY_NATIVENIF=/Users/chanc/Projects/nativenif`.

| command | result |
|---|---|
| `nim c -r src/hastur/hastur build all` | exit 0, no `[deps]` line |
| `bin/hastur test tests/incremental` | all green; `decl-stability: 4 / 4`, digest counts unchanged from `merge/u2` |
| `bin/hastur tests/inproc` | `3 / 3 tests successful in 27.72s` |
| `bin/hastur test tests/ctfe_diff` | `19 file(s), 50 artifact(s), 79 .s.nif, 0 difference(s)` |
| `bin/hastur test tests/nifcache` | `nifcache: all checks passed` |
| `bin/hastur test tests/nimony_r` | `nimony_r: all checks passed` — includes the cached-vs-scratch byte-identical link and the run-from-memory check, i.e. the two that actually exercise the new nifasm |
| `bin/hastur test tests/ctfe_engine` | `ctfe_engine: all checks passed` |
| `bin/hastur test tests/ledger` | `[ledger] all ledger tests passed` |
| `bin/hastur tests/nimony` | `795 / 795` (unchanged; this commit adds no test) |
| `bin/hastur boot --boot-backend:native` | `stages 1 and 2 are byte-identical`, `stages 2 and 3 are byte-identical` |

Splice counts on the live edit (`/tmp/u3-self`, fork-point sources, cold build
then `self.editbody`, `ARKHAM_CACHE_STATS=1`):

```
[arkham cache] spliced 8 lowered 1 stale 1
[arkham cache] spliced 76 lowered 2 stale 2
[arkham cache] spliced 523 lowered 3 stale 3
0.85s user 0.10s system 101% cpu 0.935 total
```

Identical to `bench/results/2026-09-07/b3e.txt`, line for line.

A/B, interleaved, 5 rounds:

```
self.editbody: A wall median 2.276 | cpu median 3.533 | peak rss 117 MB
self.editbody: B wall median 0.904 | cpu median 0.921 | peak rss 107 MB
B/A cpu (median): 0.261   B/A cpu (min): 0.259   B/A peak rss: 0.91
```

Both sides land on their logged values (A 3.56 cpu, B 0.94 cpu), so the
machine was quiet and these are absolute, not merely ratios. The new
assembler did not move the loop. This also settles §1's caveat: that run's
inflated absolutes were machine load, and the 0.92 s headline stands.
