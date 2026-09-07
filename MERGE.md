# MERGE.md — upstream commits merged into `fast-devloop`

One entry per upstream commit, in merge order. `fast-devloop` forked from
`nim-lang/nimony` master at **f69b8afc** ("Fix/closure typeclass hasmore",
#2477); these are the six commits master gained after that, merged one at a
time so each conflict is resolved against a known-good base.

Read with `SUMMARY.md` (what this branch changed and why), `JIT_IMPL.md` (the
phase log and Status table), `BENCHMARK.md` (how every number is taken) and
`notes/handoff.md` (the merge routine and the upstream-drift analysis that
this file supersedes as it is filled in).

## The chain

| # | commit | subject | branch | status |
|---|---|---|---|---|
| 1 | `4aa797d5` | sem: `import` is not a shadowing boundary (#2479) | `merge/u1` | pending |
| 2 | `c6db98b6` | sem: sum type constructor over a `ref object` produces the `ref` (#2481) | `merge/u2` | pending |
| 3 | `b7c7daa6` | newest nativenif (#2478) — pin `d0781a48` -> `e201a816` | `merge/u3` | pending |
| 4 | `c6be04e1` | no globals in nifcore (#2482) | `merge/u4` | pending |
| 5 | `38f67463` | std/http: thread the tag space instead of keeping one per process (#2484) | `merge/u5` | pending |
| 6 | `e1da48e9` | nifsyms refactor (#2483) — pin `e201a816` -> `f9af5b24` | `merge/u6` | pending |

Plus a parallel track in `../nativenif`: rebase our `jit/b1 .. jit/b3e-native`
chain (fork point `d0781a48`) onto upstream nativenif master, which steps 3
and 6 need. See "nativenif track" at the end.

## Entry template

Each agent appends its section below, in chain order, using this shape:

```
## N. `<sha>` — <subject>

**What upstream changed.** Two or three sentences: the intent, not the diff.

**How it collided with us.** Every conflicted file, and for each one the
fast-devloop change it collided with (name the phase: P0*, A1*, A2*, B*, F1,
F2, M1, H1).

**What we did.** The resolution per file. Say explicitly where upstream's
version won, where ours won, and where the two had to be combined.

**Was anything of ours made redundant?** Code we could now delete, or a
follow-up to delete it.

**Was anything of ours broken?** Behaviour we had to restore by other means.

**Evidence.** The commands run and their verbatim tails: `hastur build all`,
`hastur tests/nimony`, `hastur boot --boot-backend:native` (stages 1 == 2 == 3),
`tests/incremental`, `tests/inproc`, `tests/ctfe_diff`, `tests/nimony_r`,
`tests/ctfe_engine`, `tests/ledger`, `tests/nifcache`, and the
`decl-stability` scenario. Note anything skipped and why.

**Numbers.** Only if the merge could plausibly move them: `bench/devloop_ab.sh
/tmp/devloop_base . self.editbody 5` cpu-sum first, per `BENCHMARK.md`.
```

---
