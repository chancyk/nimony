# merge/u6b — upstream `e1da48e9` onto the respelled base

Step 6 of the chain (`MERGE.md`), second attempt. Base: `643569c2`
(`fast-devloop` after the F1 respelling). Merged: `e1da48e9` "nifsyms
refactor (#2483)" together with the nativenif pin `3ec73fef` -> `9d7fcf78`.

The first attempt (`notes/merge-u6.md`) is the evidence for WHY the respelling
had to come first. This file is what a B4 agent needs from the result.

## 1. What the respelling bought, measured

The first attempt found 60 upstream call sites migrated onto
`pool.symBasename`, of which **57 arrived with no conflict marker** — silently
correct-looking and wrong, because F1's disambiguator failed
`nifcore.parseDisamb` and `symBasename` answered `""`.

On the respelled base the same merge produces **46 conflicted files instead of
30**. That is the mechanism working: a site where both sides now touch the
line conflicts and is read, instead of being taken silently. The clean-merge
set that the audit called dangerous largely stopped existing.

## 2. The one that still got through, and why it is the shape to remember

`sembasics.symToIdent` merged **clean** and came out wrong anyway:

```nim
  var name = pool.symString(s)     # ours
  extractBasename name             # ours
  stripLocalNs name                # ours
  ...
  result = pool.symNameId(s)       # UPSTREAM'S — throws all of that away
```

git took our body and upstream's `result =` line. Both sides present, every
line individually correct, the computed value discarded. Nim does not warn
about the unused `name`.

It broke every `{.untyped.}` generic in the stdlib — `arithmetics.\`+=\`` failed
with `undeclared identifier: x` — because a parameter's scope key became the
owner-tagged `` x`+=`0 `` instead of `x`. **`tests/incremental` caught it in
about ninety seconds.**

The lesson for a later merge in this area: **`symBasename`/`symNameId` return
the OWNER-TAGGED identifier, not the source one.** The respelling made them
*parse* correctly; it did not make them mean "what the user wrote". Anything
matching a source identifier — a scope key, a named argument, an `{.importc.}`
external name, a diagnostic — needs `extractBasename` **and** `stripLocalNs`,
which is what `symparser.sourceIdent` does in one call. There are 25 files
with a `stripLocalNs` site; the count per file is the invariant to check after
any merge here (`git grep -c stripLocalNs`), and it held everywhere except the
proc above, where the extraction survived and the RESULT did not.

## 3. Three more resolutions that only compile by luck otherwise

Each is a conflicted hunk whose "ours" side stopped compiling because a
CLEAN-merged line above it changed the surrounding scope. Taking either side
whole is wrong; the resolution is our intent on upstream's binding:

| file | what happened | resolution |
|---|---|---|
| `lengc/nifmodules.nim` | `let splitted = splitSymName(...)` became `let module = c.pool.symModule(s)` two lines above | our `vfsExists` (A1b) on upstream's `module` |
| `lengc/genexprs.nim` | `var x = c.m.pool.syms[s]` was dropped by upstream's rewrite | re-bind `x`, keep our two-step extraction |
| `hexer/dce2.nim` | `offerName` was dropped when the loop head moved to `pool.symWithoutModule` | P0b's `prefersOffer` asking for the spelling directly |
| `dagon/dagon.nim` | `basename` changed signature `string` -> `SymId` | upstream's signature, our two-step body |

## 4. Numbers, and an honest regression

Interleaved, one run, two branches — `bench/devloop_ab.sh
/private/tmp/f1-respell . self.editbody 5` (see the new trap in
`BENCHMARK.md` §1 for why it must be done this way):

| | wall | cpu | peak RSS |
|---|---|---|---|
| A = `643569c2` | 0.971 | 0.980 | 107 MB |
| B = this merge | 1.041 | 1.053 | 107 MB |
| **B/A** | | **1.074** | 1.00 |

**A ~7 % cpu regression on the edit loop, consistent across all five rounds.**
It decomposes, by swapping only the assembler:

| B toolchain | B/A cpu |
|---|---|
| merged nimony + OLD arkham/nifasm (`3ec73fef`) | **1.047** |
| merged nimony + NEW arkham/nifasm (`9d7fcf78`) | **1.070** |

so roughly **+4.7 % from `e1da48e9` itself** and **+2.3 % from the pin move**.
Both are upstream's own changes, not the resolution: the refactor makes every
symbol spelling a BUILT string where `pool.syms[id]` used to lend one, and the
newer nifasm links slower (`--stats` `link` 212 -> 383 ms).

**A hypothesis tested and rejected, so nobody re-tests it:** `decldigest`
reads a spelling once per SYMBOL TOKEN, which looked like the obvious cause.
Memoizing it per `SymId` for the length of one walk — bytes mixed identically,
digests bit-for-bit unchanged — moved the ratio from 1.074 to 1.070, i.e.
nothing. It was reverted rather than carried, because an unmeasured
optimisation does not belong in a merge commit. The cost is spread across
every accessor call, not concentrated in that loop.

This is the first phase in the chain to make the loop slower. It is a
correctness merge with no performance claim, and B4 should treat ~7 % as the
new baseline rather than a bug to hunt — but the `--stats` `link` line is
where the largest single number sits.

## 5. What a B4 agent needs

- **The pin and the merge are atomic.** nativenif `9d7fcf78`'s arkham calls
  `nifcore.symString`, which only `e1da48e9` introduces; there is no commit
  between them that builds. If you bisect this range, bisect both repos
  together.
- **Building from a worktree needs the `/tmp/u6` layout.**
  `nativenif/src/arkham/nim.cfg` reaches nimony by the SIBLING path
  `../../../nimony/src`, i.e. the MAIN checkout — not the worktree you are
  building. `NIMONY_NATIVENIF` says which nativenif, not which nimony. The
  layout: a directory holding a `nimony` symlink to your worktree and a
  `nativenif` checkout at the pin, with `NIMONY_NATIVENIF` pointing at the
  latter. `BENCHMARK.md` §1 records the rule; this is the first step that
  needed it.
- **`hastur`'s `syncNativenif` will not move a checkout that sits on a
  BRANCH** — it warns and builds what is there. The evidence that the pin was
  honoured is that `build all` prints **no `[deps]` line at all**.
- **`tests/symspelling` is now on the real `nifcore`.** The vendored copy of
  `parseDisamb`/`splitSpelling` is gone; the sixteen shapes and the negative
  case are unchanged and assert against the pool itself. It is the only gate
  for identifier preservation — `decl-stability` and the splice counts are
  gates for lowering stability and go green through an identifier break, which
  is exactly how the first attempt got as far as it did.
- **`tests/nativecg` is `hastur.mode = skip`** and must be checked by hand
  after any arkham move. This pin moved it (see `MERGE.md` §6).
