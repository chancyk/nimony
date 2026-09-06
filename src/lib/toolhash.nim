#       Nif library
# (c) Copyright 2026 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## Identity of the running toolchain binary, as one opaque string.
##
## The cost ledger (`ledger.nim`, JIT.md 5.2) keys its samples by
## (phase, module, toolhash): a rebuilt tool emits different code and runs at a
## different speed, so timings taken from the previous build say nothing about
## the new one. Stamping every sample with the tool's identity lets
## `ledger.estimate` drop what a toolchain change invalidated instead of
## averaging across it.
##
## Path + size + mtime is the same stamp `deps.nim` already uses to decide that
## a tool changed (`getLastModTime(findTool "lengc")` in the object-cache key);
## hashing it keeps the value short, opaque and free of absolute paths' noise.
## The digest is computed at most once per process.

when defined(nimony):
  import std / [os, sha1]
else:
  # `std/sha1` is `{.deprecated.}` in favour of the `checksums` package, but it
  # is the only SHA-1 module guaranteed to ship with every Nim 2.x install --
  # the same reasoning (and the same digest) as `nifchecksums.nim`.
  import std / os
  {.push warning[Deprecated]: off.}
  import std / sha1
  {.pop.}

import vfs

var cachedToolhash = ""
  ## Set on the first call and never again: one `getAppFilename` plus one
  ## `stat` per process, no matter how many samples the process records.

proc fileSizeOrZero*(path: string): int64 =
  ## Size of `path` in bytes, or 0 when it cannot be determined. Non-raising in
  ## both dialects so that callers on a timing path never need a handler.
  when defined(nimony):
    try: getFileSize(path) except: 0'i64
  else:
    try: int64(getFileSize(path)) except CatchableError: 0'i64

proc appFilenameOrEmpty(): string =
  when defined(nimony):
    getAppFilename()
  else:
    try: getAppFilename() except CatchableError: ""

proc toolhash*(): string =
  ## A stable identifier of the executable running this code. Cached.
  if cachedToolhash.len == 0:
    let exe = appFilenameOrEmpty()
    let stamp = exe & "|" & $fileSizeOrZero(exe) & "|" & $vfsMtime(exe)
    var state = newSha1State()
    state.update(stamp)
    cachedToolhash = $SecureHash(state.finalize())
  result = cachedToolhash
