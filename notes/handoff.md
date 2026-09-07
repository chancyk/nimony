# Handoff: fast-devloop, 2026-09-07

Read in this order: `SUMMARY.md` (what changed and why), `JIT_IMPL.md`
(the phases; the Status table at the end is the truth), this file,
`BENCHMARK.md` (every command and trap for measuring), and
`bench/results/2026-09-07/progress.md` (the numbers, latest run last).

## State

- Branch `fast-devloop`, HEAD after the F1 follow-ups merge; everything in
  the Status table marked "merged" is on it and verified (794/794,
  `hastur boot --boot-backend:native` byte-identical, ctfe_diff 0 diffs).
- `../nativenif` (`/Users/chanc/Projects/nativenif`) must be at the commit in
  `src/nativenif.commit` (c3f27fc, branch `jit/b3c`). Its branches:
  `jit/b1` -> `jit/b3` -> `jit/b3-fixes` -> `jit/b3c` (linear). `hastur`
  checks out the pin before building; from a worktree under `/tmp` or
  `.claude/worktrees` set `NIMONY_NATIVENIF=/Users/chanc/Projects/nativenif`.
- Fork-point toolchain for A/B: `/tmp/devloop_base` (worktree of f69b8afc,
  built, plus `arkham`/`nifasm` copied into its `bin/`). If it is gone:
  `git worktree add --detach /tmp/devloop_base f69b8afc && (cd /tmp/devloop_base
  && nim c -r src/hastur/hastur build all)` and build arkham/nifasm into its
  `bin/` from the nativenif checkout (`nim c -d:release --outdir:/tmp/devloop_base/bin
  src/{arkham/arkham,nifasm/nifasm}.nim`).
- Parallel `nim c` builds share `~/.cache/nim`; every agent sets a private
  `XDG_CACHE_HOME`.

## In flight

Nothing. Paused on the owner's instruction after B3e merged (2026-09-07).
All `jit/*` branches are merged; `git worktree list` should show only the
main tree and `/tmp/devloop_base`. `../nativenif` is at pin 5f6f011
(`jit/b3e-native`).

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

| | fork point | branch |
|---|---|---|
| live edit in `sem.nim`, rebuild | 2.30 s / 3.56 s cpu / 117 MB | 0.92 s / 0.94 s / 107 MB (after B3e) |
| live edit that adds a proc + call | 2.69 / 3.87 / 117 | 1.14 / 1.15 / 147 |
| dead-proc edit (old headline) | 2.31 / 3.59 / 116 | 0.71 / 0.70 / 101 |
| cold | 5.61 / 14.6 / 116 | 5.37 / 13.8 / 147 |

Where the live edit's 0.92 s goes: nimsem 0.34 (owner's decision), hexer
0.27 (B3b's incremental expand, floor ~0.11 s), link 0.12, arkham 0.09,
dceLive 0.05, dceEmit 0.05.

## Open decisions and follow-ups (owner's)

- Declaration-level incremental sem (the 0.44 s re-check of `sem.nim`):
  outside JIT.md's scope; not started.
- `dceLive` streaming per module (147 MB cold peak vs 122 MB linker at the
  fork point); `--threads:off` for the non-threading tools (-6 % hexer);
  hexer's one-copy-per-pass pipeline (memmove + skip ~35 % of its profile).
- B3b proper (declaration-level hexer/arkham) after F2; B4 hot reload; B5
  platforms; `std/rawthreads` nimNoLibc on macOS; the C-backend bug with a
  value-returning proc catching a ref exception (`notes/f1.md` §8.3).
