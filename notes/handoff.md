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

**B4 is complete on `jit/b4` and its gate is met**, worktree `/tmp/b4/nimony`
with its nativenif sibling `/tmp/b4/nativenif` on `jit/b4-native`.
`notes/b4.md` is the write-up (stage 1 first, then stage 2).

**`src/nativenif.commit` now pins `ad886112`, which is on `jit/b4-native` and
is NOT PUSHED.** That branch has to reach the owner's fork before anything
depends on the pin: nativenif's `origin` is nim-lang upstream and `fork` is the
owner's, and pushing is the owner's action. The commit is two three-line
additions -- `AsmSession.wantTraceTable` and `MemImage.traceTable` -- and
nothing else in nativenif moved.

What B4 built, in one list:

* `src/nimony/guestwire.nim`, `src/nimony/nimrun.nim`,
  `engine.runWholeProgramOutOfProcess` -- the out-of-process guest, and
  `nimony r --guest:inproc|subprocess` (default `inproc`, so no measured
  number moved).
* `src/nimony/devwalk.nim` -- the trace-table stack walk, run by the LOADER on
  the guest's thread inside the safepoint intercept. Needs nothing from arkham.
* `src/nimony/devclassify.nim` -- reload or restart, with a reason. No layout
  sidecar; `notes/b4.md` argues why one is not needed for soundness.
* `src/nimony/devhost.nim` -- the swap: re-assemble, relay the code into free
  arena space against the LIVE data region, walk, patch entries through slots.
* `src/nimony/devdriver.nim` + `nimony dev` -- the loop, the watcher
  (`--dev-interval`), `--dev-max-edits`, and the restart diagnostics.
* `lib/std/devreload.nim` -- `devPoll()`, the safepoint. In `tall.nim`.
* `tests/dev/` -- the demo application and the gate; `tests/inproc/guest/` --
  stage 1's gate.

Two things a next session should know before touching it:

* **JIT.md 7.3's build-time slot indirection does not exist in either tool**,
  and B4 does not build it (`notes/b4.md` §2 has the citations). The reload
  installs the same indirection at the first reload instead. Building the
  `extproc` route later would make a reload assemble ONE module instead of the
  whole program -- 0.02 s against 0.09 s, an optimization.
* **A define set with `config.addDefine` does not reach the child that sems the
  program.** It has to go into `c.commandLineArgs` too. Cost an hour; the
  symptom looks exactly like a broken reloader.

Nothing else is in flight. Worktrees alive: the main tree, `/tmp/devloop_base`,
`/tmp/merge-u1`, `/tmp/prechain`, `/tmp/b4/nimony`; in nativenif, the main
checkout, `/tmp/u6/nativenif` and `/tmp/b4/nativenif`.

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
