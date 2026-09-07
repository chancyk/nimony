# merge/u6 — upstream `e1da48e9` into `fast-devloop`

Step 6, the last of the chain (`MERGE.md`). Base: `0ece350b`
(= `origin/fast-devloop` after step 5). Merged: `e1da48e9` "nifsyms refactor
(#2483)" **and** the pin move to nativenif `9d7fcf78`.

Written before any edit, per `JIT_IMPL.md` "Execution rules for agents" rule 3.

## 0. Two corrections to the brief, found before merging

**It is 95 files, not 40.** `git show e1da48e9 --stat` reports 95 files,
+1594/-922. The 40 in the plan appears to count `src/nimony/` and `src/hexer/`
only; the commit also rewrites `src/lib/nifcore.nim` (+380),
`src/lib/nifreader.nim` (+269), all of `src/lengc/` including `shoggoth/`,
`src/dagon/`, `src/finalir/`, `src/nifgram/`, `src/validator/` and two
`tests/nimony/nifcore/` tests.

**The pin move is not just "step 3's pin plus the split-symbol fix".** It also
brings one upstream nativenif commit that step 3's pin did not have:

```
git merge-base --is-ancestor 2c30a9ef 3ec73fef   -> NO   (step 3's pin)
git merge-base --is-ancestor 2c30a9ef 9d7fcf78   -> yes  (this pin)
git rev-list --count e201a816..2c30a9ef          -> 1
```

`2c30a9ef` is "arkham: the role goes in the identifier, the disambiguator
stays a number (#165)", and it changes how arkham NAMES the synthesized
syscall and extern procs: `write.sys.<module>` becomes
`` write`sys.0.<module> `` via `symparser.derivedName`, citing nimony#2457.
That is a change to `.asm.nif` declaration names, which is what B3d's
`asmdecls` digests and what B3e's splice keys on. It cannot be assumed
harmless — **it is the concrete reason the splice-count gate matters on this
step and not merely as a formality.**

(It is also, incidentally, the same device F1 used: `derivedName` puts a role
tag behind a backtick inside the IDENTIFIER, and it is pre-existing shared
machinery in `src/lib/symparser.nim`, present at the fork point. F1 puts its
namespace segment after the numeric disambiguator instead
(`` x.3`semExpr`0 ``), so the two occupy different fields and compose. Note
that `e1da48e9` does **not touch `src/lib/symparser.nim` at all** — checked
with `git show e1da48e9 --stat -- src/lib/symparser.nim`, which is empty. F1's
`localNamespace`, `sourceIdent`, `LocalNsSep`, `localSymName` and
`splitLocalSymName` are therefore untouched by the refactor.)

## 1. A hard mechanical blocker, and the layout that answers it

**`hastur build all` cannot build arkham for this pin from a `/tmp` worktree
with the default sibling layout, and the failure looks nothing like its
cause.**

The chain:

- `e1da48e9` introduces `nifcore.symString` — `git show
  e1da48e9:src/lib/nifcore.nim | grep -n 'proc symString'` gives lines 550 and
  563; `git show 0ece350b:src/lib/nifcore.nim` has no such proc.
- nativenif at `9d7fcf78` CALLS it: `src/arkham/core/programs.nim:1021`,
  `:1664`, `src/arkham/core/typeutil.nim:170`, `src/ghast/translate.nim:92`.
- `nativenif/src/arkham/nim.cfg` reaches nimony's libraries by a
  SIBLING-relative path, `--path: "../../../nimony/src/lib"`. From
  `/Users/chanc/Projects/nativenif/src/arkham/` that is
  `/Users/chanc/Projects/nimony/src/lib` — **the main checkout**, which is at
  `0ece350b` and has no `symString`.
- `hastur`'s `nativeToolPrefix()` adds no `--path`, so nothing overrides it.

So building arkham would compile upstream's new arkham against the OLD nimony
libraries and fail on an undeclared `symString`, while the merge in this
worktree is perfectly fine. `NIMONY_NATIVENIF` does not help: it says WHICH
nativenif to build, not which nimony that nativenif sees.

`BENCHMARK.md` §1 already records the shape of the answer ("a clone under
`/tmp/x/nativenif` needs `/tmp/x/nimony` to be a symlink to a nimony tree").
Applied here:

```
mkdir -p /tmp/u6
ln -sfn /tmp/merge-u1 /tmp/u6/nimony
git -C /Users/chanc/Projects/nativenif worktree add --detach /tmp/u6/nativenif 9d7fcf78
export NIMONY_NATIVENIF=/tmp/u6/nativenif
```

`/tmp/u6/nativenif/src/arkham/../../../nimony/src/lib` then resolves (checked
with `os.path.realpath`) to `/private/tmp/merge-u1/src/lib` — the merged tree.

**This is a worktree-local workaround, not a change anyone needs to keep.**
Once `fast-devloop` is fast-forwarded past this merge, the main checkout has
`symString` and the ordinary sibling layout works again. It matters only
because every step of this chain has been verified from `/tmp/merge-u1`, and
step 6 is the first one where that location changes the answer.

### 1.1 The failure, reproduced on purpose

Building this pin's arkham against the UNMERGED tree gives exactly one error,
and it is the one to recognise:

```
$ nim c -d:release --outdir:/tmp/u6/probe-bin /tmp/u6/nativenif/src/arkham/arkham.nim
/private/tmp/u6/nativenif/src/arkham/core/programs.nim(1021, 14) Error: undeclared identifier: 'symString'
```

Two consequences worth stating separately:

1. **The pin and the nimony merge are atomic.** nativenif `9d7fcf78` does not
   build against a nimony without `e1da48e9`, and (per the nativenif track)
   upstream nativenif does not build against a pre-refactor nimony at all. So
   this step cannot be split into "merge the refactor" and "move the pin"
   later, and there is no bisectable point between them.
2. **This error is NOT the four-fixture signature.** If the pin fails to take
   (the `syncNativenif` branch guard from §3), the symptom is four
   `const_rodata_reloc_foreign` fixtures failing at RUN time with an
   assembler that was silently built from the wrong commit. If the *nimony
   libraries* are wrong, the symptom is this compile error at BUILD time.
   Different failure, different cause; do not treat one as evidence about the
   other.

---

# POST-MORTEM: the step-6 attempt, abandoned on the owner's decision

The merge described below was completed (all 82 hunks resolved, pin set) and
then **destroyed** before it could be built: a research subagent ran
`git merge --abort` in `/tmp/merge-u1`, having mistaken this worktree's
in-progress merge for a stray leftover of its own probe. `git reflog` shows
`0ece350b HEAD@{0}: reset: moving to HEAD`. Nothing was committed, so nothing
of the resolution survives except what is written here.

That is not the reason it was abandoned. The owner's decision — respell F1's
locals as `` x`semExpr`0.3 `` first, on a clean base — supersedes it anyway.
This section is the evidence the attempt produced, recorded so it does not
have to be paid for twice.

## A. The break, and why the gates would not have caught it

`e1da48e9` adds a rule `symparser` never had: a disambiguator is digits only,
no leading zero (`nifcore.parseDisamb`). F1's disambiguator is
`` 3`semExpr`0 ``, which fails it by construction, so `splitSpelling` files the
whole spelling into `NifSymbol.name` with `disamb = NoDisamb`, and
`symBasename` returns `""` for every F1/F2-spelled symbol.

Measured, not read — upstream's verbatim `parseDisamb`/`splitSpelling`
extracted into a standalone program:

| spelling | `symBasename` | `extractBasename` | `symIsLocal` | round-trips |
|---|---|---|---|---|
| `` x.3`semExpr`0 `` | `''` | `x` | true | yes |
| `` s.0`testMutateWhileIterating`0 `` | `''` | `s` | true | yes |
| `` x.3`foo`1`Iabcdef `` | `''` | `x` | true | yes |
| `` `x.3`semStmt`0 `` | `''` | `` `x `` | true | yes |
| `` `err.2`step6`0 `` | `''` | `` `err `` | true | yes |
| `` returnLabel.0h2``main`0 `` | `''` | `returnLabel` | true | yes |
| `` `setlit.0`semStmt`0.mymod `` | `''` | `` `setlit `` | false | yes |
| `` c.0`f`0.mymod `` | `''` | `c` | false | yes |
| `x.3` (F1, no owner) | `x` | `x` | true | yes |
| `semExpr.0.semv1g3zm` (control) | `semExpr` | `semExpr` | false | yes |
| `abc.12.Ikey.mod` (control) | `abc` | `abc` | false | yes |

**Classification is safe, identifiers are not, artifacts still round-trip.**

**Two findings the audit did not report, and they matter for the respell.**
Upstream's OWN legacy shapes fail the same rule:

| spelling | `symBasename` | `extractBasename` |
|---|---|---|
| `x.0h37` — the PRE-F1 `intramodinliner` disambiguator | `''` | `x` |
| `_exit.sys.mod` — the reserved syproc shape | `''` | `_exit.sys.mod` |

So F1/F2 are not uniquely offending: upstream shipped `e1da48e9` with two of
its own spellings broken by its own new rule, and the `intramodinliner`
rewrite *inside that same commit* is upstream fixing one of them, to
`` result`i.5 ``. nativenif `2c30a9ef` fixes the other, to
`` write`sys.0.<module> ``. **The respelling therefore has an exact upstream
precedent to copy rather than a convention to invent.**

## B. Which sites conflicted and which merged clean — the dangerous set

The question the audit could not settle by reading. Answered by counting
`symBasename|symVersionedBasename|symNameId` in `git show e1da48e9:<file>`
minus `git show 0ece350b:<file>`, split by whether the file appeared in
`git diff --name-only --diff-filter=U`. Reproducible without the merge.

**60 new accessor sites. 37 of them, in 21 files, arrive with NO conflict
marker.** All three files the audit guessed are in that set.

### Clean merge — upstream's accessor taken silently (37 sites, 21 files)

```
 4  src/nimony/semdecls.nim          2  src/nimony/indexgen.nim
 3  src/nimony/renderer.nim          2  src/nimony/sempragmas.nim
 3  src/nimony/sembasics.nim         2  src/nimony/sigconcepts.nim
 3  src/nimony/semimport.nim         1  src/hexer/arcopt.nim      <- audit guessed
 2  src/dagon/dagon.nim   <- guessed 1  src/hexer/inliner.nim
 2  src/lengc/codegen.nim            1  src/lengc/genexprs.nim    <- audit guessed
 2  src/lengc/llvmcodegen.nim        1  src/nimony/asthelpers.nim
 2  src/nimony/exprexec.nim          1  src/nimony/deps.nim
                                     1  src/nimony/idetools.nim
                                     1  src/nimony/nimony_model.nim
                                     1  src/nimony/semmagics.nim
                                     1  src/nimony/templates.nim
                                     1  src/validator/semfacts.nim
```

`sembasics.nim` (3) is the one to notice: it holds `symToIdent`, which
`notes/f1.md` §4 names as load-bearing for F1, and it merges clean.

### In a conflicted file (23 sites, 11 files) — but only 3 inside a hunk

```
 9  src/nimony/sem.nim               1  src/hexer/lengcgen.nim
 3  src/hexer/coro_transform.nim     1  src/hexer/vtables_backend.nim
 2  src/hexer/lambdalifting.nim      1  src/lengc/nifmodules.nim
 2  src/nimony/macro_plugin.nim      1  src/nimony/semmain.nim
 1  src/hexer/duplifier.nim          1  src/nimony/semos.nim
                                     1  src/nimony/semtypes.nim
```

Only **3** of the 60 (`coro_transform.localToFieldname`,
`lambdalifting.localToField`, `sem.nim`'s new private `asNimSym`) appeared
inside a conflict marker. **57 of 60 arrive without one.**

## C. What the resolution turned up that the audit did not predict

1. **The pin is not just "step 3's plus the split-symbol fix".** `9d7fcf78`
   also contains upstream `2c30a9ef` ("arkham: the role goes in the
   identifier"), which `3ec73fef` does NOT
   (`git merge-base --is-ancestor 2c30a9ef 3ec73fef` fails; against
   `9d7fcf78` it succeeds). That changes `.asm.nif` DECLARATION NAMES — the
   input B3d digests and B3e splices. It is a second, independent reason the
   splice counts must be re-measured on the redo.
2. **The pin and the merge are ATOMIC; there is no bisectable point.**
   nativenif `9d7fcf78`'s arkham calls `nifcore.symString`, which only
   `e1da48e9` introduces. Reproduced:
   `programs.nim(1021, 14) Error: undeclared identifier: 'symString'`.
3. **`hastur build all` cannot build this pin from a `/tmp` worktree.**
   `nativenif/src/arkham/nim.cfg` reaches nimony by the SIBLING path
   `../../../nimony/src`, i.e. the MAIN checkout — not the worktree being
   merged. `NIMONY_NATIVENIF` chooses which nativenif, not which nimony. The
   layout that works is `BENCHMARK.md` §1's: `/tmp/u6/nimony` a symlink to
   the worktree, a nativenif worktree at `/tmp/u6/nativenif`, and
   `NIMONY_NATIVENIF=/tmp/u6/nativenif`. Verified: the arkham path then
   resolves to `/private/tmp/merge-u1/src/lib`. Both already built and left
   in place for the redo.
4. **`sem.nim` shadowing trap.** Upstream inserts a private
   `proc asNimSym(symId): string = pool.symBasename(symId)` where our side is
   empty. Any "keep both" or "theirs" pick silently shadows
   `renderer.asNimSym` for every unqualified call in that file only — changing
   diagnostics in `sem.nim` alone. It must be actively deleted, not side-picked.
5. **`lengc/nifmodules.nim`: "ours" does not compile.** A clean auto-merge two
   lines above the conflict renamed `let splitted = splitSymName(...)` to
   `let module = c.pool.symModule(s)`. Our conflicted side still says
   `splitted.module`. The resolution is our intent (`vfsExists`, A1b) on
   upstream's variable (`module`) — a case of a clean hunk changing the
   meaning of a conflicted one.
6. **`nifmake.nim` is a 640-line pseudo-conflict.** A2b moved the build graph
   into `dag.nim`, which upstream does not have, so git cannot see past the
   deletion. Upstream's real payload is two accessor renames, which must be
   ported by hand into `dag.nim` (still `pool.syms[n.symId]` at :1081, :1118).
7. **`dce1`/`dce2` would silently lose two documented bug fixes** if upstream
   won: P0c's `sortedSymNames`/`cmpSymNames` determinism (the fix that made
   `OnlyIfChanged` hold) and P0b's `prefersOffer` main-module rule. Upstream
   rewrote the same lines with unordered iteration and a plain string compare.
8. **`pool.syms[...]` still compiles but is no longer zero-copy.** The shim
   builds a string per call. Our hot paths are on it and upstream never
   migrated them, because they are files upstream does not have:
   `decldigest.nim:135-136` (per TOKEN of every declaration — F1's digest
   loop), `dce1.nim:107`, `dce2.nim:332,472`, `dag.nim:1081,1118`,
   `passes.nim:57`. Correct, but a cold/edit-loop cost to measure after the
   respell.
9. **One golden moves, and it merges clean:** `bench/nifbench.output`,
   checksum `133797427` -> `133798294`, from upstream's side alone (the
   `NifSymbol` encoding change). No `.msgs` or `.nif` golden conflicts or is
   added.

## D. Resolution rules that worked, for the redo

Of 82 hunks, ~68 were one shape and fell to two mechanical rules:

- **Rule 1** — our side calls `namer.fresh*` / `freshCfSym` / `freshErrSym`,
  their side is a manual counter plus the accessor rename: **take ours**. F2's
  `TempNamer` subsumes the counter. (50 hunks.)
- **Rule 2** — our logic, upstream's API: take ours, then rewrite
  `pool.syms.getOrIncl(` -> `pool.symId(` and `pool.syms[x]` ->
  `pool.symString(x)` inside it. (16 hunks, all diagnostics via `asNimSym`.)
- `passes.nim`'s `freshSym`/`freshGlobalSym` move onto `pool.symId` once, and
  every F2 call site then needs no edit at all.

The remainder are items 4-7 above plus `intramodinliner` (the design
collision the respell resolves).

## E. Two silent sites that produce WRONG OUTPUT, not ugly names

A parallel call-site audit was disrupted by the same reset and is only
partial, but two of the sites it reached are verified here directly against
`git show e1da48e9:<file>`, which is stable. **Both are in the clean-merge
set — they arrive with no conflict marker.**

**1. `sembasics.newSymId` (`e1da48e9:src/nimony/sembasics.nim:419`) — F1's own
machinery.**

```nim
proc newSymId*(c: var SemContext; s: SymId; forceGlobal = false): SymId =
  let isGlobal = not pool.symIsLocal(s)
  var name = pool.symBasename(s)          # "" for every F1-spelled local
  if isGlobal or forceGlobal: c.makeGlobalSym(name)
  else:                       c.makeLocalSym(name)
  result = pool.symId(name)
```

This copies a symbol *keeping its layout* and is the template-expansion path.
With `name == ""`, the local branch mints `localSymName("", n, ns)` =
`` .3`foo`0 `` — a spelling whose FIRST CHARACTER IS A DOT. Every local copied
in the same routine also collapses onto one counter key `("", ns)`. They stay
distinct by number, so nothing crashes; the names are simply malformed and
carry no identity. `sembasics.nim` has 3 clean-merge sites.

**2. `sempragmas` importc/exportc default name
(`e1da48e9:src/nimony/sempragmas.nim:341`).**

```nim
elif crucial.sym != SymId(0):
  var name = pool.symBasename(crucial.sym)
  dest.addStrLit(name, info)
```

This is the branch taken when `{.importc.}` / `{.exportc.}` / `{.dynlib.}` is
given WITHOUT an explicit string, so the symbol's own identifier is the
external C name. `crucial.sym` comes from `semLocal`'s `delayed.s.name`, so a
`var x {.importc: ...}` written inside a routine is an F1-spelled local and
the emitted external name is the empty string. That is a miscompile, not a
rendering problem. `sempragmas.nim` has 2 clean-merge sites.

Also named by the audit, unverified here: `semdecls.buildInnerObjDecl` (the
`.Obj` split name for a `ref object` declared inside a routine),
`validator/semfacts.baseName` (empty variable names in borrow diagnostics),
`lengc/llvmcodegen.nifSymBaseName` (DWARF local/parameter names; it has an
`if result.len == 0` fallback to the full spelling, so cosmetic only).

**The structural correction the audit got right and is worth keeping:** the
reachability question is NOT "is this symbol local". `TempNamer.freshGlobalSym`
appends a module suffix to the same backtick-tailed string, so an F2 global
(`` `setlit.0`semStmt`0.mymod ``) fails `parseDisamb` exactly like a local while
`symIsLocal` answers `false`. The right question is **"did this name ever pass
through `sembasics.makeLocalSym` or through `TempNamer`"**, and neither
`symIsLocal` nor `symModule` distinguishes those from safe globals — which is
precisely what a call site's own `isGlobal` check assumes when it branches, as
`newSymId` and `buildInnerObjDecl` both do.

After the respelling, every one of these becomes correct on its own, with no
call-site edits: that is the argument for doing the respell first.
