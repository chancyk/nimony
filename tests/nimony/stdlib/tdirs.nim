import std/[assertions, dirs, os, syncio]

proc main =
  block:
    # issue #2159
    let testdir = getTempDir() / "nimony_test_dir"
    try:
      createDir(path(testdir))
    except:
      quit "createDir test failed"

  block:
    # The error codes, on the libc-free runtime too: a raw syscall sets no errno.
    let d = path(getTempDir() / "nimony_test_dir_codes")
    discard tryRemoveFinalDir(d)
    assert tryCreateFinalDir(d) == Success
    assert tryCreateFinalDir(d) == NameExists
    assert tryRemoveFinalDir(d) == Success
    assert tryRemoveFinalDir(d) == NameNotFound
    assert tryRemoveFile(d) == NameNotFound
    # A walker that never opened: no crash, and not `PermissionDenied`.
    var w = tryOpenDir(d)
    assert tryCloseDir(w) == BadDescriptor

main()
