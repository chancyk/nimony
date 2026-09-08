# F1 respell — the owner tag moves into the identifier

Research and implementation notes per `JIT_IMPL.md`'s "Execution rules for
agents" rule 3. Branch `f1/respell`, forked from `fast-devloop` (`0ece350b`,
i.e. merge steps 1–5: everything through upstream `38f67463`). nativenif is
the pinned clone at `/Users/chanc/Projects/nativenif`, `3ec73fef`, untouched.

The phase is one sentence: **F1 and F2 put the owning declaration's name in
the DISAMBIGUATOR; nif-spec #2457 says a disambiguator carries a number and
nothing else, so it moves into the IDENTIFIER.**

```
    before   x.3`semExpr`0        `setlit.0`semStmt`0.mymod
    after    x`semExpr`0.3        `setlit`semStmt`0.0.mymod
```

Nothing else changes: the same owner, the same per-(identifier, owner)
counter, the same module-lifetime table, the same one dot for a local and two
for a global. Only the side of the dot the tag sits on.

---

## 1. Why this had to happen before the merge, not inside it

Upstream `e1da48e9` ("nifsyms refactor", #2483) stops storing a symbol as one
interned string and stores a taken-apart record instead —
`NifSymbol(name, disamb, dedup, module)` — parsed once, at intern time, by
`nifcore.splitSpelling`. Every question the compiler used to ask
`symparser` it now asks the pool: `symBasename`, `symModule`, `symIsLocal`,
`symWithoutModule`. The commit migrates about thirty call sites accordingly.

The parse has a rule `symparser` never had. `nifcore.parseDisamb`
(`e1da48e9:src/lib/nifcore.nim:573-591`) accepts the disambiguator only if it
is **digits only, with no leading zero**; anything else is not a disambiguator
at all, and `splitSpelling` folds the whole spelling back into `name` with
`disamb = NoDisamb`. `symBasename` then returns `""` — by construction:

```nim
proc symBasename*(p: Pool; id: SymId): string =
  let s = p.symbols[id]
  if s.disamb == NoDisamb: "" else: p.strings[s.name]
```

F1's disambiguator is `` 3`semExpr`0 ``. It fails that rule for every local
the compiler mints, and F2's global-layout names fail it too — the module
suffix parses off correctly, so `symIsLocal` answers `false` as it should,
and then the backtick-tailed head fails `parseDisamb` exactly as a local's
does. **"Is this symbol local" is the wrong question about this population;
"did it pass through `makeLocalSym` or `TempNamer`" is the right one.**

Nothing raises when it happens. The spelling still round-trips, the artifacts
on disk stay valid, `symIsLocal` keeps answering correctly, and about thirty
call sites quietly start reading `""` — a scope key, an `{.importc.}`
external name, and a stem another name is minted from, all at once. Two of
them miscompile rather than merely rename:

* `sembasics.newSymId`, F1's own template-expansion copy path, mints
  `` .3`foo`0 `` — a spelling whose first byte is a dot;
* `sempragmas`'s `{.importc.}`/`{.exportc.}`-without-a-string branch, where
  the identifier IS the external C name, emits the empty string.

Doing the respelling first means the collision does not exist when
`e1da48e9` arrives: upstream's migrated `symBasename` sites are simply
correct for us, and the merge is mechanical. It also keeps the two
independently verifiable, instead of one commit in which a failure could be
either.

## 2. Why the identifier, and not a third option

Three shapes were on the table.

* **Keep the tag in the disambiguator and teach `parseDisamb` a tail.** One
  change in one place, and `symparser.splitLocalSymName` already had the
  four-argument `tail` form F1 added for it. Rejected: it contradicts #2457
  and would have to be argued upstream, not merged locally.
* **A second separator character**, so an F1 tag and a `derivedName` tag are
  told apart by shape. Rejected: it re-opens exactly the criticism
  `SUMMARY.md` row 11 carries — "argued legal from the scanners rather than
  from nifspec's text" — which this change exists to close.
* **The identifier.** What upstream itself does, twice, in the same breath as
  the refactor: `e1da48e9` rewrites `intramodinliner`'s own mint from
  `base.0i<n>` to `` result`i.5 `` with the comment *"The pass letter goes
  INTO the identifier, which is what keeps it out of the DISAMBIGUATOR, where
  a NIF symbol is specified to carry a number and nothing else (#2457)"*, and
  nativenif `2c30a9ef` fixes `_exit.sys.mod` to `` write`sys.0.<module> ``.
  `symparser.derivedName` has always spelled a sibling declaration
  `` outer`env.0 `` the same way.

So the shape is not invented here. It is the one the toolchain already had,
applied to the population F1 and F2 introduced.

`notes/f1.md` §4 rejected this shape, for a reason that is still true: it
makes `extractBasename` answer `` x`semExpr`0 `` where the source wrote `x`,
so `symToIdent` would put a declaration into scope under a name no lookup can
find. The answer is not to avoid the shape but to pay for it — §3.

## 3. What it cost: `sourceIdent`'s job moves onto the lookup path

`symparser` gains one primitive and one length helper:

* `stripLocalNs(s: var string)` — drop the namespace from an identifier,
  truncating at the first `LocalNsSep` at index **>= 1**. Index 0 is skipped
  because a compiler-minted identifier may LEAD with a backtick (`` `err ``,
  `` `x ``, `` `setlit ``) and that one is part of the name. Every identifier a
  namespace is appended to is a source identifier or one of those literals, so
  no interior backtick reaches it except the ones this module put there.
* `sourceIdentLen(s)` — `sourceIdent(s).len` without building the string, for
  the one scanner that needs it per symbol.

`sourceIdent` is now the two steps: `extractBasename` off the end,
`stripLocalNs` off the identifier.

`extractBasename` itself is UNCHANGED, deliberately. Making it strip would
have been a two-line diff instead of twenty-eight, and it would have silently
changed what a `derivedName` name answers at every call site — `outer`env`
becoming `outer` in the module index, in the iface, and in overload
resolution's candidate lists. `extractBasename` keeps meaning what
upstream's `symBasename` means, and the sites that want the SOURCE identifier
say so.

Twenty-eight sites say so. They divide into four jobs:

| job | sites |
|---|---|
| an identifier that goes back into SCOPE, or is compared against one | `sem.fetchSym`, `sem.sameIdent` (×2), `semdecls` (inject-to-scope), `templates` (params), `sembasics.symToIdent`, `nimony_model.symNameId`, `asthelpers.getIdent` |
| a stem another name is MINTED from (tag stacking) | `sembasics.newSymId`, `semdecls.buildInnerObjDecl`, `lengcgen.makeLocalDeclName`, `lambdalifting.localToField`, `coro_transform.localToFieldname`, `intramodinliner.freshSym`, `inliner` |
| an EXTERNAL name — C, asm, LLVM debug | `sempragmas` (importc/exportc), `lengc/codegen` (×2), `lengc/llvmcodegen` (×2), `lengc/genexprs`, `lengc/nifmodules`, `lengc/llvmdebug` |
| something a HUMAN or a tool reads | `renderer` (×3), `idetools`, `macro_plugin` (×2), `exprexec` (×2), `semmagics`, `semfacts`, `dagon` (×2) |

The sites left alone are the ones that only ever see module-level symbols —
the index, the iface, imports, fields, hooks — where no namespace exists and
where a `derivedName` tag must survive.

Two of the twenty-eight were found by the test suite rather than by reading,
and both are worth recording because neither is where one would look:

* **`asthelpers.getIdent`** is what `sigmatch.buildParamsInfo` keys
  `params.names` with AND what `orderArgs` looks a named argument up by. A
  parameter is a local. Unstripped, `weak = true` stopped matching the
  parameter `weak` and every named argument in the standard library failed
  with "named argument not found".
* **`idetools`'s symbol scan** computed the tracked token's length by counting
  bytes to the first dot. That is the source identifier only while the
  namespace sits after the dot; afterwards it claimed an eight-byte column
  span for a one-byte `x` and matched the wrong symbol. It is one of the
  ad-hoc dot-counting classifiers that bypass `symparser` entirely; it now
  calls `sourceIdentLen`.

`nimony_model.symNameId` is the subtlest of the twenty-eight: its only
consumer is `sameTreesButIgnoreSymIds`, which matches a forward declaration's
parameters against the implementation's. Those are locals in two different
routines, so without the strip their namespaces differ and every forward
declaration in the tree stops matching its body.

### The plugin gensym protocol got simpler

`splitLocalSymName`'s four-argument `tail` overload is **gone**, and so is
`plugins.unusedNameTail`. The namespace is part of the identifier now, so a
local is `<identifier>.<number>` with nothing after the number — the pre-F1
shape, structurally — and the three-argument overload splits every local the
compiler mints. It also gained an assertion it could not make before: nothing
may follow the digits (#2457).

## 4. Verified against upstream's parser, not against an argument

`tests/symspelling/setup.nim` is the instrument and it runs in
`hastur test all`. It **vendors `nifcore.parseDisamb` and `splitSpelling`
verbatim** from `e1da48e9:src/lib/nifcore.nim`, with provenance, so it can run
BEFORE the merge — which is the point: the spelling had to conform before
upstream arrived. After the merge, delete the vendored block and import
`nifcore`; the assertions do not change.

For every spelling the compiler mints it asserts four things at once: the
spelling round-trips through the pool; `symBasename` is NON-EMPTY;
`symBasename` agrees with `symparser.extractBasename`; `symIsLocal` agrees
with `symparser.isLocalName`; `sourceIdent` is the identifier the source
wrote; and the first byte is not a dot. Measured, on the sixteen shapes:

| spelling | `symBasename` before | after |
|---|---|---|
| `` x`semExpr`0.3 `` (was `` x.3`semExpr`0 ``) | `""` | `` x`semExpr`0 `` |
| `` `x`semStmt`0.3 `` | `""` | `` `x`semStmt`0 `` |
| `` `setlit`semStmt`0.0.mymod `` | `""` | `` `setlit`semStmt`0 `` |
| `` c`f`0.0.mymod `` (a hoisted const) | `""` | `` c`f`0 `` |
| `` result`h`semStmt`0.5 `` (was `result.0h5`) | `""` | `` result`h`semStmt`0 `` |
| `` a`f`outerA`0.0.mymod `` (an env field) | `""` | `` a`f`outerA`0 `` |

plus a NEGATIVE case: the pre-respell spelling must still FAIL the grammar. If
that ever starts passing, the tag has drifted back into the disambiguator and
the test has stopped testing anything.

### The two hazard sites, checked directly

Both were checked against real output, not by implication.

* **A spelling whose first byte is a dot.** Over the whole 127-module
  self-compile: **zero**. The `.s.nif`/`.x.nif` files do contain 126
  first-byte-escaped symbols (`:\2E…`) and every one of them is the slice
  operator family — `..`, `..<`, `..^` — which has been spelled that way
  since long before this branch. Zero of them carry a namespace.
* **`lambdalifting.envTypeForProc` collapsing distinct procs onto one
  `SymId`.** That site derives its name from `extractVersionedBasename` and
  has NO counter, so an empty stem would give every closure in a module the
  same environment type. The compiler's own sources mint no closure
  environments at all, so this needed a corpus of its own
  (three procs, five captured locals). Result: three distinct environment
  types (`` outerA`env.0 ``, `` outerB`env.0 ``, `` outerC`env.0 ``) and five
  distinct fields (`` a`f`outerA`0.0 ``, `` b`f`outerA`0.0 ``,
  `` c`f`outerB`0.0 ``, `` d`f`outerC`0.0 ``, `` e`f`outerC`0.0 ``) — each
  carrying both its source identifier and its owning routine. No collapse.

### Why no existing gate would have caught any of this

Worth stating, because it is the reason `tests/symspelling` exists.
`decl-stability` and arkham's splice counts are gates for **lowering
stability** — whether a declaration's output moves when an unrelated
declaration is edited. A uniform rename keeps them both green: the namespace
still scopes the counter, so every declaration's temps are still a function of
that declaration alone, whatever the names are. They were never gates for
**identifier preservation**, which is a different property and the one that
breaks here. Both numbers below are green, and they would have been green if
this had gone wrong.

## 5. Results

Every gate, on this machine, `NIMONY_NATIVENIF=/Users/chanc/Projects/nativenif`
at `3ec73fef` (`build all` prints no `[deps]` line, which is how the pin
reports that it took).

| gate | value | reference |
|---|---|---|
| `tests/symspelling` | all checks passed | new |
| `symparser` self-test | passes | — |
| `hastur tests/nimony` | **795 / 795** | 795 |
| `decl-stability` sem-input | **1/0/1/1** | 1/0/1/1 |
| `decl-stability` lowering-output | **1/-/1/1** | 1/-/1/1 |
| arkham splice, 2nd edit | **11/1, 83/1, 527/1** | 8/1, 76/2, 523/3 |
| `hastur boot --boot-backend:native` | stages 1 == 2 == 3 | same |
| `tests/incremental` (16 phases + inproc, membudget, tool-shadow, live, ctfe-ocache) | all green | — |
| `tests/ctfe_diff` | 0 differences | 0 |
| `tests/nifcache`, `vfs`, `ledger`, `nimony_r`, `ctfe_engine` | all passed | — |
| `devloop_ab` self.editbody, B/A cpu | **0.990** median, 1.001 min | — |

The splice totals differ from `notes/b3e.md`'s because the corpus does: that
measurement was taken on the fork point's sources and this one on this
branch's, which has two more procs in `sem.nim` and six more in its largest
neighbour. What matters is the second column of each pair — **1 lowered per
module**, the floor, 527 of 528 procs spliced.

### The benchmark, and a trap in it

The headline first: **B/A cpu 0.990 median, 1.001 min, peak RSS 1.00**, from
`bench/devloop_ab.sh /tmp/rs-base . self.editbody 5` where `/tmp/rs-base` is a
build of `0ece350b` with no working-tree changes. The respelling is at the
noise floor.

Getting there took one wrong turn worth recording. Run against the FORK POINT
the way `SUMMARY.md` states the number, this branch reads B/A cpu **0.281**
against a 0.260–0.261 reference — an apparent 8 % regression. It is not one.
The same command run against `0ece350b` reads 0.257, and the B sides of the
two runs are `cpu median 0.994` and `0.995` — identical. What moved was the A
side, the fixed fork-point toolchain, between one invocation and the next:
`3.536` in one run and `3.879` in the other, 9 % of drift in the reference
itself. `devloop_ab` interleaves A and B so that drift hits both sides
equally, and it does — WITHIN a run. A ratio is not comparable ACROSS runs,
and a 5 %-scale question about two branches has to be asked by interleaving
those two branches, not by comparing each to a third.

### Goldens

Two commits, so that each diff can be read for what it is.

**`ab750716` — `tests/nativecg/tinlinecond.arm64.asm.nif`, 46 insertions /
54 deletions, no symbol names.** This golden was ALREADY stale at `0ece350b`,
from merge step 3's nativenif re-pin (`7b838ec` -> `3ec73fef`): arkham's
register allocator makes different choices in the new pin — one callee-saved
pair fewer in the prologue (`stp x21, x22`), `x9` -> `x11` throughout, and the
`(.indexat …)` offset that follows. The suite is `hastur.mode = skip`, so
`hastur tests/nimony` never ran it and nothing noticed. Verified by building
`0ece350b` with an empty working tree and regenerating there, which is where
this commit's contents come from.

**The respelling commit — 17 files, 317 insertions / 317 deletions, every
line a symbol name.** Line-for-line, insertion count equal to deletion count
in every file, which is what a pure rename looks like:

| file | ± | what changed |
|---|---|---|
| `tests/nimony/nosystem/*.nif` (14 files) | 201 / 201 | `.s.nif` goldens: `` e.0`dollar``bool`0 `` -> `` e`dollar``bool`0.0 ``, and 200 more of the same |
| `tests/nimony/track/tvar.msgs` | 4 / 4 | `` x.0`main`0 `` -> `` x`main`0.0 `` |
| `tests/nimony/track/tfield_def1.msgs` | 2 / 2 | `` foo.0`main`0 `` -> `` foo`main`0.0 `` |
| `tests/nativecg/tinlinecond.arm64.asm.nif` | 116 / 116 | `` returnLabel.0h2``main`0 `` -> `` returnLabel`h``main`0.2 ``, `returnLabel.0x2` -> `` returnLabel`x.2 ``, `` result.0`isLe`0 `` -> `` result`isLe`0.0 `` |

The two `track/*.msgs` files print the FULL symbol on purpose and still do:
`idetools.foundSymbol` is nimsuggest's machine protocol, whose symbol column
is the symbol's identity (`notes/f1.md` §8.1). Every other golden that names a
symbol renders `sourceIdent` and did not move — which is the check that the
respelling did not leak into a diagnostic.

No golden changed for any reason other than the rename. In particular the
`.nif` goldens' token counts and dot-count histograms are unchanged, which is
what says nothing was reclassified between local and global.

## 6. What is left

* **`pool.syms[…]` is no longer zero-copy after the merge.** It survives as a
  compatibility view whose `[]` builds a string via `symString`. Our hot paths
  sit on it — `decldigest.hashTree` reads it once per TOKEN of every
  declaration (`decldigest.nim:135-136`), and `passes.localNamespaceOf` reads
  it per declaration. That is a post-merge measurement, not a correctness
  issue, and it is the first thing to look at if the benchmark drifts after
  the merge rather than before it. Both have a structured accessor available
  to move to: `symWithoutModule` for the namespace, `symNameId` for the digest.
* **`extractBasename` and `pool.symBasename` are the same function after the
  merge** and one of them should go. Thirty-odd call sites currently read the
  `symparser` one; upstream migrated them to the pool one. Doing that
  conversion is mechanical NOW — that is the whole benefit of landing this
  first — but it is the merge's work, not this branch's.
* **`tests/nativecg/tinlinecond.x64.asm.nif` is still stale** and this branch
  still cannot fix it: it is regenerable only on x64, and `notes/f2.md` §6
  already recorded that it predates both B3c's inliner and F1. Whoever next
  runs the suite on x64 regenerates it, and the diff will be larger than this
  branch's.
* **The `Dl.<dynlib>` family carries a dot in its identifier**, so a name
  minted from it has three dots and `symparser.isLocalName` calls it global
  while `nifcore.splitSpelling` calls it local. That disagreement is
  pre-existing — the same is true of `x.Obj` inner-object names, before and
  after this change — and it is one to settle when `symparser`'s dot-counting
  classifiers are retired in favour of the pool's.
