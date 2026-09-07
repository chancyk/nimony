# Handoff: fast-devloop, 2026-09-07

Read in this order: `SUMMARY.md` (what changed and why), `JIT_IMPL.md`
(the phases; the Status table at the end is the truth), this file,
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

- **B3e** (nativenif clone `/tmp/b3e/nativenif` branch `jit/b3e-native`, nimony clone `/tmp/b3e/nimony_clone` branch `jit/b3e` if it needed a nimony change): arkham per-proc splice. Merge by the routine below (fetch the nativenif branch into `/Users/chanc/Projects/nativenif`, re-pin `src/nativenif.commit`, rebuild, suites, boot, A/B).
- (merged) **H1**: not the incremental live set -- a deep-copy bug in `markLive`; `dceLive` 0.36 -> 0.05 s.
- (merged) **B3d** (`jit/b3d`, nativenif clone `/tmp/b3d/nativenif` branch `jit/b3d-native`): per-symbol blob validity in nifasm and per-proc asm splicing in arkham. On merge: fetch the nativenif branch into `/Users/chanc/Projects/nativenif`, re-pin `src/nativenif.commit`, run the routine, re-take the headline.
- (merged) **F2** (`jit/f2`, worktree under `.claude/worktrees/`): hexer's temp
  counters (`xelim.Pass.nextTemp`, `intramodinliner.InlinerCtx.counter`, ...)
  scoped per top-level declaration. Gate: `decl-stability`'s `tempadd`
  phase drops from 18 to 1 changed lowering-output declarations, and the
  live `sem.nim` edit changes <= 3 instead of 890 of 1794. On merge: tighten
  the `expect dTempOut <= 18` bound in `src/hastur/incrementaltests.nim`
  to 1 (the comment above it says so), re-take the headline.

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
| live edit in `sem.nim`, rebuild | 2.57 s / 3.87 s cpu / 117 MB | 1.18 s / 1.22 s / 107 MB (after H1, under load) |
| live edit that adds a proc + call | 2.29 / 3.54 / 117 | 1.14 / 1.18 / 147 |
| dead-proc edit (old headline) | 2.31 / 3.59 / 116 | 0.71 / 0.70 / 101 |
| cold | 5.61 / 14.6 / 116 | 5.37 / 13.8 / 147 |

Where the live edit goes now: nimsem 0.34, hexer 0.27, arkham 0.26 (B3e),
dceLive 0.05, dceEmit 0.05, link 0.12. nimsem is the owner's decision.

## Open decisions and follow-ups (owner's)

- Declaration-level incremental sem (the 0.44 s re-check of `sem.nim`):
  outside JIT.md's scope; not started.
- `dceLive` streaming per module (147 MB cold peak vs 122 MB linker at the
  fork point); `--threads:off` for the non-threading tools (-6 % hexer);
  hexer's one-copy-per-pass pipeline (memmove + skip ~35 % of its profile).
- B3b proper (declaration-level hexer/arkham) after F2; B4 hot reload; B5
  platforms; `std/rawthreads` nimNoLibc on macOS; the C-backend bug with a
  value-returning proc catching a ref exception (`notes/f1.md` §8.3).
