import std/syncio

# TODO: a `const` reading a missing file has no usable diagnostic. The compile
# does fail, but with `[Error] cannot open: nimcache/tco<sha1>.out.nif` — no
# source location, no cause — and that text cannot even be pinned as a `.msgs`
# golden, because hastur reads the expected exit code out of the keyword
# `Error:` and `[Error]` is not it. See README.md here.

const gone = readFile("no_such_file_here.txt")

echo gone.len
