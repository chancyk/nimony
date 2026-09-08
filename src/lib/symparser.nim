#       Nif library
# (c) Copyright 2024 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## Parses NIF symbols into their components.

proc extractBasename*(s: string; isGlobal: var bool): string =
  # From "abc.12.Mod132a3bc" extract "abc".
  # From "abc.12" extract "abc".
  # From "a.b.c.23" extract "a.b.c".
  var i = s.len - 2
  while i > 0:
    if s[i] == '.':
      if s[i+1] in {'0'..'9'}:
        return substr(s, 0, i-1)
      isGlobal = true # we skipped one dot so it's a global name
    dec i
  return ""

proc extractBasename*(s: var string) =
  var i = s.len - 2
  while i > 0:
    if s[i] == '.':
      if s[i+1] in {'0'..'9'}:
        s.setLen i
        return
    dec i

proc genericTypeName*(key, modname: string): string =
  result = "`t.0.I" & key & "." & modname

proc extractModule*(s: string): string =
  # From "abc.12.Mod132a3bc" extract "Mod132a3bc".
  # From "abc.12" extract "".
  var i = s.len - 2
  while i > 0:
    if s[i] == '.':
      if s[i+1] in {'0'..'9'}:
        return ""
      else:
        return substr(s, i+1)
    dec i
  return ""

type
  SplittedSymName* = object
    name*: string
    module*: string

proc splitSymName*(s: string): SplittedSymName =
  var i = s.len - 2
  while i > 0:
    if s[i] == '.':
      if s[i+1] in {'0'..'9'}:
        return SplittedSymName(name: s, module: "")
      else:
        return SplittedSymName(name: substr(s, 0, i-1), module: substr(s, i+1))
    dec i
  return SplittedSymName(name: s, module: "")

proc `$`*(s: SplittedSymName): string =
  if s.module.len > 0:
    result = s.name & "." & s.module
  else:
    result = s.name

proc extractVersionedBasename*(s: string): string =
  # From "abc.12.Mod132a3bc" extract "abc.12".
  var i = s.len - 2
  while i > 0:
    if s[i] == '.':
      if s[i+1] in {'0'..'9'}:
        var j = i+1
        while j < s.len and s[j] in {'0'..'9'}: inc j
        return substr(s, 0, j-1)
    dec i
  return ""

proc derivedName*(stem, tag: string): string =
  ## The `identifier.<number>` half of a symbol the compiler mints ALONGSIDE
  ## another one — a closure's environment type, a class's vtable, a coroutine's
  ## frame. `stem` is the originating symbol minus its module suffix, and the
  ## caller appends the module it wants the result to live in:
  ##
  ##   derivedName("outer.0", "env")        == "outer`env.0"
  ##   derivedName("gen.12.Iaaaa", "coro")  == "gen.12.Iaaaa`coro.0"
  ##
  ## The tag goes INTO the identifier rather than becoming a dotted segment of
  ## its own, because the two shapes say different things. nif-spec.md gives a
  ## global symbol as `<ident>.<disamb>.<moduleSuffix>` OR
  ## `<ident>.<disamb>.<key>.<moduleSuffix>`, "where `key` usually is the result
  ## from a generic instantiation". The `key` slot answers WHICH instantiation of
  ## `<ident>.<disamb>` this is — and because every module needing that
  ## instantiation derives the same key independently, `<ident>.<disamb>.<key>` is
  ## meaningful across module boundaries. That is exactly what lets a backend
  ## collapse the copies each importing module emits: DCE's
  ## `resolveSymbolConflicts`, `lengcgen`'s content-hashed
  ## `strlit.0.I<hash>.<mod>`, and nifasm's COMDAT merge all key on it.
  ##
  ## `env`, `coro`, `vt` are not keys — they name a ROLE, and the entity they name
  ## is private to one module. Put in the key slot they promise a cross-module
  ## identity they do not have, and two modules that each close over a variable in
  ## a proc named `outer` both claim `outer.0.env`. That is not a hypothetical:
  ## one module's closure read its captures out of the other's layout — see
  ## tests/nimony/closures/tenv_name_clash.nim.
  ##
  ## The backtick keeps the result out of the Nim-spellable namespace, matching
  ## the `` `f `` of a lifted local. It is inserted before the trailing version so
  ## the disambiguation number keeps its place; a stem that does not end in one
  ## (a keyed stem ends in its key) gets a fresh `.0` instead, which keeps both
  ## distinguishing parts — stem and tag — inside the identifier where they
  ## belong.
  ##
  ## Only a version at the very END counts, and that restriction is the whole
  ## point rather than an implementation detail: the result must be an UNKEYED
  ## global symbol. Scanning back past a later segment to find a number would
  ## leave that segment sitting in the key slot — `("gen.12.Iaaaa", "coro")` would
  ## come back as `gen`coro.12.Iaaaa`, a keyed name again, and one that has
  ## silently adopted the ORIGINAL symbol's key as its own cross-module identity.
  var i = stem.len - 1
  while i > 0 and stem[i] in {'0'..'9'}: dec i
  if i > 0 and i < stem.len - 1 and stem[i] == '.':
    result = substr(stem, 0, i-1) & "`" & tag & substr(stem, i)
  else:
    result = stem & "`" & tag & ".0"

proc isInstantiation*(s: string): bool =
  # abc.12.Iabcdefghi.mod2
  var i = s.len - 2
  var dots = 3
  while i > 0:
    if s[i] == '.':
      dec dots
      if s[i+1] in {'0'..'9'}:
        return dots == 0
      elif dots == 1 and s[i+1] != 'I':
        return false
    dec i
  result = false

proc isLocalName*(s: string): bool =
  var dots = 0
  for c in s:
    if c == '.': inc dots
  result = dots <= 1

const LocalNsSep* = '`'
  ## Joins an identifier to the NAMESPACE segment that says which routine the
  ## symbol belongs to: `` x`semExpr`0.3 `` is the local `x`, third of its name
  ## inside the routine `semExpr.0`. The owner's own dots are written as this
  ## character too, so the whole spelling keeps exactly one dot and stays a
  ## local name by `isLocalName`.
  ##
  ## The namespace rides in the IDENTIFIER, ahead of the dot, never in the
  ## disambiguator: nif-spec #2457 settles that a NIF symbol's disambiguator
  ## carries a number and nothing else, and upstream's own `derivedName`
  ## (`` outer`env.0 ``) and inliner (`` result`i.5 ``) put their tags in the
  ## identifier for the same reason. `notes/f1-respell.md` records the move.
  ##
  ## A backtick for the same reason `derivedName` uses one: it is legal
  ## unescaped anywhere after a symbol's first byte, it is not part of the dot
  ## grammar every scanner in this file walks, and it keeps the result out of
  ## the Nim-spellable namespace.

proc localNsStart(s: string): int =
  ## Where the namespace segment begins inside an identifier, or -1.
  ##
  ## The first `LocalNsSep` at index >= 1: index 0 is skipped because a
  ## compiler-minted identifier may LEAD with a backtick (`` `err ``, `` `x ``,
  ## `` `setlit ``) and that one is part of the name, not a separator. Every
  ## identifier a namespace is ever appended to is a source identifier or one
  ## of those literals, so no interior backtick reaches here except the ones
  ## this module put there.
  result = -1
  for i in 1 ..< s.len:
    if s[i] == LocalNsSep: return i

proc stripLocalNs*(s: var string) =
  ## Drop the namespace segment from an identifier, in place, leaving the name
  ## it was built from. The inverse of what `localSymName` appends, and the
  ## operation `extractBasename` performed before the respelling moved the
  ## namespace to this side of the dot.
  let i = localNsStart(s)
  if i >= 0: s.setLen i

proc sourceIdentLen*(s: string): int =
  ## How many bytes of `s` the SOURCE identifier occupies — `sourceIdent(s).len`
  ## without building the string, for the scanners that need it per symbol.
  ##
  ## The identifier ends at the first `.` (disambiguator or module suffix) or at
  ## the first `LocalNsSep` at index >= 1 (the owning routine's namespace),
  ## whichever comes first. `idetools` matches a tracked source column against
  ## this, so it is the length of the token the USER typed and nothing more.
  result = s.len
  for i in 0 ..< s.len:
    if s[i] == '.' or (i >= 1 and s[i] == LocalNsSep):
      return i

proc localNamespaceOfName*(s: string): string =
  ## The namespace segment carried by the identifier `s`, or "".
  let i = localNsStart(s)
  result = if i >= 0: substr(s, i+1) else: ""

proc localSymName*(basename: string; disamb: int; ns: string): string =
  ## The one place that assembles a local symbol out of its three parts. `ns`
  ## empty means "no enclosing routine" and reproduces the plain
  ## `identifier.<number>` spelling exactly.
  result = basename
  if ns.len > 0:
    result.add LocalNsSep
    result.add ns
  result.add '.'
  result.addInt disamb

proc sourceIdent*(s: string): string =
  ## The identifier a symbol was SPELLED with in the source: the one rendering
  ## every user-facing diagnostic uses when it names a symbol.
  ##
  ##   "s`testMutateWhileIterating`0.0" -> "s"
  ##   "Foo.0.tge70svym"                -> "Foo"
  ##   "T"                              -> "T"
  ##
  ## Everything after the identifier is compiler bookkeeping — a disambiguating
  ## count, the owning routine's namespace (`LocalNsSep`), a module suffix — and
  ## none of it is anything the user wrote. A message that must tell two
  ## same-named symbols apart does it with the file/line/column it already
  ## carries, not with that bookkeeping: `a.6` and `a.9` said nothing about WHICH
  ## `a`, and the numbers moved whenever an unrelated declaration was edited.
  ##
  ## A name with no `.<digit>` in it — a plain identifier that never went through
  ## `makeGlobalSym`/`makeLocalSym` — is returned unchanged, which is why this
  ## wraps the in-place `extractBasename` rather than the one that answers `""`.
  ##
  ## Two steps, because the bookkeeping sits on both sides of the identifier
  ## since the respelling (`notes/f1-respell.md`): `extractBasename` drops the
  ## disambiguator and the module suffix off the END, `stripLocalNs` drops the
  ## owning routine's namespace off the identifier itself.
  result = s
  extractBasename(result)
  stripLocalNs(result)

proc splitLocalSymName*(s: string; basename: var string;
                        disamb: var int): bool =
  ## Splits a local symbol into its identifier and its disambiguator:
  ## `tmp.14` -> (`tmp`, 14) and `` tmp`f`0.14 `` -> (`` tmp`f`0 ``, 14).
  ## False for anything that is not a local symbol: more than one dot, no dot,
  ## no digit right after it, or anything but digits from there to the end.
  ##
  ## The namespace a local carries is part of the IDENTIFIER since the
  ## respelling, so it comes back inside `basename` and this overload — the
  ## only one — splits every local the compiler mints. `stripLocalNs` takes
  ## the namespace back off when the bare name is what is wanted.
  basename = ""
  disamb = 0
  var dot = -1
  for i in 0 ..< s.len:
    if s[i] == '.':
      if dot >= 0: return false
      dot = i
  if dot <= 0 or dot == s.len - 1:
    return false
  var value = 0
  var j = dot + 1
  while j < s.len and s[j] in {'0'..'9'}:
    let digit = ord(s[j]) - ord('0')
    if value > (high(int) - digit) div 10:
      return false
    value = value * 10 + digit
    inc j
  if j == dot + 1:
    return false
  if j != s.len:
    # Anything after the number is not a disambiguator (#2457): a NIF symbol
    # carries a number there and nothing else.
    return false
  basename = substr(s, 0, dot - 1)
  disamb = value
  result = true

proc removeModule*(s: string): string =
  # From "abc.12.Mod132a3bc" extract "abc.12".
  # From "abc.12" extract "abc.12".
  var i = s.len - 2
  while i > 0:
    if s[i] == '.':
      if s[i+1] in {'0'..'9'}:
        return s
      else:
        return substr(s, 0, i-1)
    dec i
  return s

proc localNamespace*(routineName: string): string =
  ## The namespace segment for the locals of the routine spelled `routineName`:
  ## its module-less name with the dots written as `LocalNsSep`, so that a local
  ## built from it keeps exactly ONE dot and stays a local name (`isLocalName`).
  ##
  ##   "semExpr.0.mymod"        -> "semExpr`0"
  ##   "foo.1.Iabcdef.mymod"    -> "foo`1`Iabcdef"
  ##
  ## Every counter that mints a symbol inside a routine — sem's locals, the
  ## exception lowering's `` `err ``, the control-flow graph's `` `cf `` — keys
  ## itself on this so that an edit to one declaration cannot renumber another's
  ## temporaries. See `notes/f1.md`.
  result = removeModule(routineName)
  for i in 0 ..< result.len:
    if result[i] == '.': result[i] = LocalNsSep

type
  SplittedModulePath* = object
    dir*: string
    name*: string
    ext*: string

proc splitModulePath*(s: string): SplittedModulePath =
  # We diverge from `splitFile` here in that we consider the `.2.nif` part the extension, not just the `.nif` part.
  var i = s.len - 2
  while i >= 0 and s[i] notin {'/', '\\'}:
    dec i
  var d = i + 1 # find first dot (i can be -1 here!)
  while d < s.len and s[d] != '.':
    inc d
  result = SplittedModulePath(dir: substr(s, 0, i-1), name: substr(s, i+1, d-1), ext: substr(s, d))

proc changeModuleExt*(s, ext: string): string =
  let mp = splitModulePath(s)
  result = mp.dir
  if result.len > 0: result.add "/"
  result.add mp.name
  if ext.len > 0 and ext[0] != '.':
    result.add "." & ext
  else:
    result.add ext

proc `$`*(s: SplittedModulePath): string =
  result = s.dir
  if result.len > 0: result.add "/"
  result.add s.name
  result.add s.ext

when isMainModule:
  import std/[assertions]
  assert extractVersionedBasename("abc.12.Mod132a3bc") == "abc.12"
  assert extractVersionedBasename("abc.Mod132a3bc") == ""

  let sn = splitSymName("abc.12.Mod132a3bc")
  assert sn.name == "abc.12"
  assert sn.module == "Mod132a3bc"

  assert derivedName("outer.0", "env") == "outer`env.0"
  assert derivedName("abc.12", "vt") == "abc`vt.12"
  # An instantiation stem ends in its key, not in a version: the tag and a fresh
  # number are appended so the key stays inside the identifier.
  assert derivedName("gen.12.Iaaaa", "coro") == "gen.12.Iaaaa`coro.0"
  # Whatever a caller appends its module to, the result must NOT read back as an
  # instantiation — that is the whole point of the exercise.
  assert not isInstantiation(derivedName("outer.0", "env") & ".mymod")
  assert not isInstantiation(derivedName("gen.12.Iaaaa", "coro") & ".mymod")
  assert isInstantiation("gen.12.Iaaaa.mymod")
  # ...and the module suffix must still be recoverable.
  assert extractModule(derivedName("gen.12.Iaaaa", "coro") & ".mymod") == "mymod"
  assert extractModule(derivedName("outer.0", "env") & ".mymod") == "mymod"

  let mp = splitModulePath("abc/def.2.nif")
  assert mp.dir == "abc"
  assert mp.name == "def"
  assert mp.ext == ".2.nif"

  let mp2 = splitModulePath("def.2.nif")
  assert mp2.dir == "", mp2.dir
  assert mp2.name == "def", mp2.name
  assert mp2.ext == ".2.nif"

  let mp3 = splitModulePath("def")
  assert mp3.dir == "", mp3.dir
  assert mp3.name == "def", mp3.name
  assert mp3.ext == ""

  var basename = ""
  var disamb = 0
  assert splitLocalSymName("tmp.14", basename, disamb)
  assert basename == "tmp"
  assert disamb == 14
  assert not splitLocalSymName("tmp.14.mod", basename, disamb)
  assert not splitLocalSymName("tmp.part.14", basename, disamb)

  # A namespaced local splits through the SAME overload: its namespace is part
  # of the identifier, and the disambiguator is a number and nothing else.
  assert splitLocalSymName("tmp`f`0.14", basename, disamb)
  assert basename == "tmp`f`0"
  assert disamb == 14
  assert not splitLocalSymName("tmp.14`f`0", basename, disamb)  # the old shape
  assert localSymName("tmp", 14, "f`0") == "tmp`f`0.14"
  assert localSymName("tmp", 14, "") == "tmp.14"

  # The namespace comes back off the identifier the way it went on.
  var ident = "tmp`f`0"
  stripLocalNs(ident)
  assert ident == "tmp"
  ident = "`err`step6`0"
  stripLocalNs(ident)
  assert ident == "`err"          # a LEADING backtick is part of the name
  ident = "plain"
  stripLocalNs(ident)
  assert ident == "plain"
  assert localNamespaceOfName("tmp`f`0") == "f`0"
  assert localNamespaceOfName("`err`step6`0") == "step6`0"
  assert localNamespaceOfName("plain") == ""

  var isGlobal = false
  # The user-facing rendering of all three symbol shapes, plus the identifier
  # that never got a number at all.
  assert sourceIdent("s`testMutateWhileIterating`0.0") == "s"
  assert sourceIdent("Foo.0.tge70svym") == "Foo"
  assert sourceIdent("`err`step6`0.2") == "`err"
  assert sourceIdent("T") == "T"

  # ── The local spelling, and every classifier that reads one ──────────────
  # `notes/f1-respell.md`: one dot, the byte after it a digit, and from there
  # to the end nothing but digits (#2457).
  assert localSymName("x", 3, localNamespace("semExpr.0.mymod")) == "x`semExpr`0.3"
  assert isLocalName("x`semExpr`0.3")
  assert extractBasename("x`semExpr`0.3", isGlobal) == "x`semExpr`0"
  assert not isGlobal
  assert extractModule("x`semExpr`0.3") == ""
  assert not isInstantiation("x`semExpr`0.3")
  assert removeModule("x`semExpr`0.3") == "x`semExpr`0.3"
  assert extractVersionedBasename("x`semExpr`0.3") == "x`semExpr`0.3"
  assert splitSymName("x`semExpr`0.3").module == ""
  assert sourceIdent("x`semExpr`0.3") == "x"

  # The GLOBAL layout hexer mints keeps the module suffix last, so it is still
  # two dots and still reads back as a module-qualified name.
  let g = localSymName("`setlit", 0, localNamespace("semStmt.0.mymod")) & ".mymod"
  assert g == "`setlit`semStmt`0.0.mymod"
  assert not isLocalName(g)
  assert extractModule(g) == "mymod"
  assert extractBasename(g, isGlobal) == "`setlit`semStmt`0"
  assert not isInstantiation(g)
  assert sourceIdent(g) == "`setlit"

  # The namespace segment every per-routine counter keys on.
  assert localNamespace("semExpr.0.mymod") == "semExpr`0"
  assert localNamespace("foo.1.Iabcdef.mymod") == "foo`1`Iabcdef"
  assert isLocalName(localSymName("`err", 2, localNamespace("step6.0.mymod")))
