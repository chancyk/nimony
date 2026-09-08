## Custom runner: the SPELLING of a NIF symbol, checked against the grammar
## upstream enforces.
##
## `notes/f1-respell.md` is the argument; this is the instrument. F1 and F2
## give every compiler-minted symbol an owning-declaration tag, and there are
## two places to put one: in the disambiguator, after the dot, or in the
## identifier, before it. nif-spec #2457 settles it — a NIF symbol's
## disambiguator carries A NUMBER AND NOTHING ELSE — and upstream's
## `nifcore.parseDisamb` enforces it: a disambiguator that is not all digits,
## or that has a leading zero, is not a disambiguator at all, and the WHOLE
## spelling collapses into the symbol's `name` field with `disamb = NoDisamb`.
##
## When that happens nothing raises. `pool.symIsLocal` still answers correctly,
## the spelling still round-trips, every artifact on disk is still valid — and
## `pool.symBasename` quietly answers `""` for every symbol the compiler minted.
## Roughly thirty call sites that used to read `symparser.extractBasename` read
## that instead, so a scope key, an `{.importc.}` external name and a
## re-minting stem all become the empty string at once.
##
## No existing gate sees it. `decl-stability` and arkham's splice counts are
## gates for LOWERING STABILITY — whether a declaration's output moves when an
## unrelated one is edited — and a uniform rename keeps them green. This is a
## gate for IDENTIFIER PRESERVATION, which is a different property, and it is
## the only one we have.
##
## Two halves:
##
## - `nifcore.parseDisamb`/`splitSpelling` are VENDORED BELOW, verbatim, from
##   `e1da48e9:src/lib/nifcore.nim` ("nifsyms refactor", #2483) — the commit
##   that introduces them, which `fast-devloop` has not merged yet. Vendoring
##   is what lets this run BEFORE the merge, which is the whole point: the
##   spelling had to conform before upstream arrived, not after.
## - `symparser` is imported for real.
##
## AFTER the merge, delete the vendored block and import `nifcore` instead.
## The assertions do not change; they are what must keep holding.

import std / [strutils]
import "../../src/lib/symparser"

var failures = 0

template check(cond: bool; msg: string) =
  if not cond:
    echo "  FAIL: ", msg
    inc failures

# ── vendored from e1da48e9:src/lib/nifcore.nim — DO NOT EDIT ────────────────
const
  NoDisamb = -1'i32
  DisambMax = int(high(int32))

proc parseDisamb(s: string; start, len: int): int =
  ## The value of the disambiguator spelled by `s[start ..< start+len]`, or -1
  ## when that is not how NIF spells a number:
  ##
  ## * digits only -- `p.0h107` names no `p` with a disambiguator;
  ## * no leading zero -- `d.00` is a NAME, and deliberately so: no user symbol
  ##   can collide with a field the compiler injects (`typenav.DataField`);
  ## * small enough to fit the field.
  ##
  ## A spelling that fails any of these keeps its tail inside the NAME, which is
  ## what lets every symbol round-trip through the pool unchanged. The reader's
  ## split-symbol path asks this too, so the two agree about the same bytes.
  if len == 0: return -1
  if len > 1 and s[start] == '0': return -1
  result = 0
  for i in start ..< start+len:
    if s[i] notin {'0'..'9'}: return -1
    result = result * 10 + (ord(s[i]) - ord('0'))
    if result > DisambMax: return -1

type
  Spelling = object
    ## Where each part of `<name>.<disamb>[.<dedup>].<module>` sits inside the
    ## string that spells it. Private: it exists to build a `NifSymbol` and to
    ## look one up, and both are here.
    nameLen: int
    disamb: int32          ## `NoDisamb` when there is none that is a number
    dedupStart, dedupLen: int
    moduleStart, moduleLen: int

proc splitSpelling(s: string): Spelling =
  ## The module is the LAST dot-separated component -- unless it STARTS with a
  ## digit, which makes it the disambiguator and the symbol local. `p.0h107` is
  ## a local whose disambiguator an inliner minted, not a symbol from a module
  ## called `0h107`.
  ##
  ## The name/disambiguator boundary needs the digit anchor, because a name may
  ## contain dots itself (`Pool.Obj.0`, `a.b.c.23`, `..<.3`) and only the digit
  ## tells the two apart. Everything not accounted for stays in the name.
  result = Spelling(nameLen: s.len, disamb: NoDisamb,
                    dedupStart: 0, dedupLen: 0, moduleStart: 0, moduleLen: 0)
  var lastDot = -1
  for k in 0 ..< s.len:
    if s[k] == '.': lastDot = k
  var head = s.len
  if lastDot >= 0:
    if lastDot+1 < s.len and s[lastDot+1] notin {'0'..'9'}:
      result.moduleStart = lastDot+1
      result.moduleLen = s.len - (lastDot+1)
      head = lastDot
    elif lastDot == s.len-1:
      head = lastDot
  result.nameLen = head

  var i = head - 2
  while i > 0:
    if s[i] == '.' and s[i+1] in {'0'..'9'}: break
    dec i
  if i <= 0: return  # no numeric disambiguator: the head is all name

  var d = i+1
  while d < head and s[d] in {'0'..'9'}: inc d
  var disambLen = head - (i+1)
  if d < head and s[d] == '.':
    disambLen = d - (i+1)
  let v = parseDisamb(s, i+1, disambLen)
  if v < 0: return   # `p.0h107`, `d.00`: it belongs to the name
  result.nameLen = i
  result.disamb = int32(v)
  if d < head and s[d] == '.':
    result.dedupStart = d+1
    result.dedupLen = head - (d+1)

# ── end vendored block ─────────────────────────────────────────────────────

proc nifcoreName(s: string): string =
  ## `pool.symBasename` for the spelling `s`: the `name` component, or `""`
  ## when the tail after the dot is not a number (`symBasename` returns `""`
  ## whenever `disamb == NoDisamb`).
  let sl = splitSpelling(s)
  if sl.disamb == NoDisamb: "" else: substr(s, 0, sl.nameLen-1)

proc nifcoreIsLocal(s: string): bool =
  splitSpelling(s).moduleLen == 0

proc nifcoreRoundTrip(s: string): string =
  ## `symString(symRecord(s))`: what the pool would hand back.
  let sl = splitSpelling(s)
  result = substr(s, 0, sl.nameLen-1)
  if sl.disamb != NoDisamb:
    result.add '.'
    result.addInt sl.disamb
  if sl.dedupLen > 0:
    result.add '.'
    result.add substr(s, sl.dedupStart, sl.dedupStart+sl.dedupLen-1)
  if sl.moduleLen > 0:
    result.add '.'
    result.add substr(s, sl.moduleStart, sl.moduleStart+sl.moduleLen-1)

proc conforms(s, wantIdent: string) =
  ## Everything one spelling has to satisfy at once.
  check nifcoreRoundTrip(s) == s,
    s & ": does not round-trip through the pool (got " & nifcoreRoundTrip(s) & ")"
  check nifcoreName(s).len > 0,
    s & ": EMPTY BASENAME — the disambiguator is not a number, so upstream " &
    "files the whole spelling under `name` and `symBasename` answers \"\""
  var eb = s
  extractBasename(eb)
  check nifcoreName(s) == eb,
    s & ": nifcore `symBasename` (" & nifcoreName(s) & ") and " &
    "`symparser.extractBasename` (" & eb & ") disagree"
  check nifcoreIsLocal(s) == isLocalName(s),
    s & ": nifcore `symIsLocal` and `symparser.isLocalName` disagree"
  check sourceIdent(s) == wantIdent,
    s & ": sourceIdent is " & sourceIdent(s) & ", wanted " & wantIdent
  check s.len == 0 or s[0] != '.',
    s & ": a spelling whose first byte is a dot — an empty stem reached a minter"

proc spellingCase() =
  # ---- what `sembasics.makeLocalSym` mints (F1) ----------------------------
  conforms localSymName("x", 3, localNamespace("semExpr.0.mymod")), "x"
  conforms localSymName("x", 0, localNamespace("main.0.mymod")), "x"
  conforms localSymName("result", 0, localNamespace("isLe.0.m")), "result"
  conforms localSymName("x", 3, localNamespace("foo.1.Iabcdef.mymod")), "x"
  conforms localSymName("x", 3, ""), "x"              # no enclosing routine
  # an owner whose own name begins with a backtick: two separators meet
  conforms localSymName("e", 0, localNamespace("`dollar`bool.0.m")), "e"

  # ---- what `passes.TempNamer` mints (F2) ---------------------------------
  conforms localSymName("`x", 3, localNamespace("semStmt.0.mymod")), "`x"
  conforms localSymName("`err", 2, localNamespace("step6.0.mymod")), "`err"
  conforms localSymName("`setlit", 0, localNamespace("semStmt.0.mymod")) &
           ".mymod", "`setlit"
  conforms localSymName("c", 0, localNamespace("f.0.mymod")) & ".mymod", "c"

  # ---- what `intramodinliner` mints (#2457's own shape) -------------------
  # `passes.taggedName` shape, spelled out rather than imported: the pass
  # letter joins the identifier alongside the namespace, so the number after
  # the dot stays a number.
  conforms localSymName("result" & LocalNsSep & "h" & LocalNsSep &
             localNamespace("semStmt.0.m"), 5, ""), "result"
  conforms localSymName("returnLabel" & LocalNsSep & "x", 2, ""), "returnLabel"

  # ---- what `lambdalifting` mints around a closure -------------------------
  conforms "outerA`env.0.mymod", "outerA"
  conforms localSymName("a`f", 0, localNamespace("outerA.0.mymod")) &
           ".mymod", "a"

  # ---- upstream's own shapes, which must keep working ----------------------
  conforms "semExpr.0.semv1g3zm", "semExpr"
  conforms "abc.12.Ikey.mod", "abc"
  conforms "result`i.5", "result"          # upstream's inliner, #2457
  conforms "write`sys.0.mymod", "write"    # nativenif 2c30a9ef

proc collisionCase() =
  ## The uniqueness the whole scheme rests on: two declarations that mint the
  ## same identifier must not arrive at the same spelling. `hexer_context`'s
  ## `hoistedConsts` is keyed by the SymId a spelling interns to, and
  ## `pool.symId` is injective on spellings only because each carries its
  ## owner. (`notes/f1.md` section 3.)
  let inF = localSymName("c", 0, localNamespace("f.0.mymod")) & ".mymod"
  let inG = localSymName("c", 0, localNamespace("g.0.mymod")) & ".mymod"
  check inF != inG, "two owners minted the same spelling: " & inF
  check sourceIdent(inF) == sourceIdent(inG),
    "the two spellings must still name the same source identifier"

proc oldShapeCase() =
  ## The spelling this branch used to mint, kept as a NEGATIVE test: it is
  ## exactly what upstream's grammar rejects, and it is why the respelling
  ## happened. If this ever passes `conforms`, the tag has drifted back into
  ## the disambiguator.
  const old = "x.3`semExpr`0"
  check nifcoreName(old).len == 0,
    "the pre-respell spelling is supposed to FAIL upstream's grammar; " &
    "if it now parses, this test has stopped testing anything"
  check nifcoreRoundTrip(old) == old,
    "even a rejected spelling round-trips — that is why nothing raised"

spellingCase()
collisionCase()
oldShapeCase()

if failures > 0:
  echo "symspelling: ", failures, " failure(s)"
  quit 1
echo "symspelling: all checks passed"
