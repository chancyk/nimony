# Handoff: fast-devloop, 2026-09-07

Read in this order: `SUMMARY.md` (what changed and why), `JIT_IMPL.md`
(the phases; the Status table at the end is the truth), this file,
`BENCHMARK.md` (every command and trap for measuring), and
`bench/results/2026-09-07/progress.md` (the numbers, latest run last).

## State

- Branch `fast-devloop` at `5df66183`, pushed; the six-commit upstream merge
  chain and the F1 respelling are on it and `MERGE.md` records them commit by
  commit. Everything in the Status table marked "merged" is verified
  (795/795, `hastur boot --boot-backend:native` byte-identical, ctfe_diff 0).
- `../nativenif` (`/Users/chanc/Projects/nativenif`) is on branch
  `jit/upstream-master` at **`9d7fcf78`**, which IS `src/nativenif.commit`'s
  value. `syncNativenif` returns silently when head == pin, so a build that
  prints **no `[deps]` line about nativenif** is a build that honoured it. Do
  not move this checkout without saying so: other toolchains' `bin/` match
  where it is now.
- Fork-point toolchain for A/B: `/tmp/devloop_base` (worktree of f69b8afc,
  built, plus `arkham`/`nifasm` copied into its `bin/`). If it is gone:
  `git worktree add --detach /tmp/devloop_base f69b8afc && (cd /tmp/devloop_base
  && nim c -r src/hastur/hastur build all)` and build arkham/nifasm into its
  `bin/` from the nativenif checkout (`nim c -d:release --outdir:/tmp/devloop_base/bin
  src/{arkham/arkham,nifasm/nifasm}.nim`). **Rebuilding it changes the
  headline number**, so leave it alone.
- `/tmp/prechain` (6870790c, detached) and `/tmp/merge-u1` (95fff89d,
  `merge/u6b`) are the two sides of the merge chain's gating comparison. Keep.
- Parallel `nim c` builds share `~/.cache/nim`; every agent sets a private
  `XDG_CACHE_HOME`.

## In flight

**B4 stage 1, on `jit/b4`** (worktree `/tmp/b4/nimony`, with its nativenif
sibling worktree `/tmp/b4/nativenif` on `jit/b4-native`, still AT the pin
`9d7fcf78` -- stage 1 needed no nativenif change). `notes/b4.md` is the
write-up. Two things landed:

* **1a, the design question the staging existed to catch**, is answered and did
  not change the phase: JIT.md 7.4's trace-table walk is the SAME mechanism as
  `lib/std/stacktraces.nim` -- a synchronous walk of the guest's own stack --
  because the table's `cfaOff` is defined only past the prologue and an
  out-of-process guest cannot be reached across the boundary without the
  entitlement B0's design refuses. Corrections to the memo's sizing are in
  `notes/b4.md` §1a; the short version is that a loader-side walk needs
  nothing from arkham and a guest-side one needs THREE intrinsics, not two.
* **1b, the `nimrun` out-of-process guest**, is built and gated:
  `src/nimony/guestwire.nim`, `src/nimony/nimrun.nim`,
  `engine.runWholeProgramOutOfProcess`, `nimony r --guest:inproc|subprocess`
  (default `inproc`), `hastur build all` builds `nimrun` beside `nimony`, and
  `tests/inproc/guest` is the gate. `tests/nimony_r` gained five differential
  checks against the in-process run.

Stage 2 (layout sidecar, classifier, slot-swap policy, the walk, the watcher,
restart diagnostics, and a demo application that has to be WRITTEN) has not
started. Worktrees alive: the main tree, `/tmp/devloop_base`, `/tmp/merge-u1`,
`/tmp/prechain`, `/tmp/b4/nimony`; in nativenif, the main checkout,
`/tmp/u6/nativenif` and `/tmp/b4/nativenif`.

## How a phase is merged (the routine used throughout)

1. `git merge --no-edit jit/<phase>`; resolve (JIT_IMPL.md's table and
   `incrementaltests.nim` are the usual spots); remove the worktree
   (`git worktree unlock` then `remove --force`).
2. `XDG_CACHE_HOME=/tmp/main_cache nim c -r src/hastur/hastur build all`.
3. Focused: `bin/hastur test tests/incremental`, `bin/hastur tests/inproc`,
   `bin/hastur test tests/ctfe_diff`, `tests/nifcache`, `tests/nimony_r`,
   `tests/ctfe_engine`, `tests/ledger`; then `bin/hastur tests/nimony`
   (whole tree) and `bin/hastur boot --boot-backend:native` (stages must be
   byte-identical).
4. Measure: `bench/devloop_ab.sh /tmp/devloop_base . self.editbody 5` (the
   LIVE edit: a statement inserted into `semStmt`) and `self.cold 3`; wall,
   cpu and peak rss; append to `bench/results/<date>/progress.md`; update
   the numbers table in `SUMMARY.md` and the Status table in `JIT_IMPL.md`.

## Headline as of this handoff (interleaved, native backend)

Run 19 of `bench/results/2026-09-07/progress.md`, head = `95fff89d`
(= the `5df66183` tip's code), base = `/tmp/devloop_base` (`f69b8afc`).

| | fork point | branch |
|---|---|---|
| live edit in `sem.nim`, rebuild (`self.editbody`) | 2.577 s / 3.772 s cpu / 117 MB | **1.020 / 1.045 / 107** |
| live edit that adds a proc + call (`self.editcall`) | 2.619 / 3.803 / 117 | 1.277 / 1.298 / 146 |
| dead-proc edit (old headline, `self.editdead`) | 2.729 / 3.890 / 116 | 0.810 / 0.806 / 100 |
| nothing edited (`self.nochange`) | 0.096 / 0.093 / 4 | 0.045 / 0.044 / 7 |
| cold (`self.cold`) | 5.241 / 13.598 / 116 | 5.296 / 13.902 / 175 |

The 0.92 s that stood here before the merge chain is superseded: the chain cost
the edit loop 13.8 % cpu, all of it in two upstream commits (run 20).

Where the live edit's ~1.02 s goes: nimsem, hexer (B3b's incremental expand,
floor ~0.11 s), link 0.12, arkham 0.09, dceLive 0.05, dceEmit 0.05.

## Open decisions and follow-ups (owner's)

- Declaration-level incremental sem (the 0.44 s re-check of `sem.nim`):
  outside JIT.md's scope; not started.
- `dceLive` streaming per module (147 MB cold peak vs 122 MB linker at the
  fork point); `--threads:off` for the non-threading tools (-6 % hexer);
  hexer's one-copy-per-pass pipeline (memmove + skip ~35 % of its profile).
- B3b proper (declaration-level hexer/arkham) after F2; B4 hot reload; B5
  platforms; `std/rawthreads` nimNoLibc on macOS; the C-backend bug with a
  value-returning proc catching a ref exception (`notes/f1.md` §8.3).

## Upstream (merged 2026-09-07)

`https://github.com/nim-lang/nimony` master's six commits past the fork point
are **on the branch**: `MERGE.md` has the whole chain, one branch per commit,
plus the F1 respelling (`643569c2`) that `e1da48e9` requires and the nativenif
re-pins `3ec73fef` and `9d7fcf78`. It cost the edit loop 13.8 % cpu, all of it
in two upstream commits (`c6be04e1` 1.057 and `e1da48e9` 1.066), and none of it
ours (our F1 respelling measured 1.006). The headline against the fork point is
therefore 2.58 -> 1.02 s wall on the live edit. Nothing is pending upstream as
of this handoff; re-check before the next phase.
