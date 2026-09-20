import std/[assertions, memfiles]


when not defined(windows):
  # TODO: enable it on windows
  block:
    try:
      var f = memfiles.open("tests/nimony/stdlib/file_for_reading_test.txt")
      let s = cast[cstring](f.mem).borrowCStringUnsafe(f.size)
      assert s == "Test text\n"
      f.close
    except:
      assert false

  # The failures carry the OS's code on every backend: `open` reports through
  # `pcall`, `mmap` through `mmapErrno`.
  block:
    var code = Success
    try:
      var f = memfiles.open("tests/nimony/stdlib/no_such_file.txt")
      f.close
    except ErrorCode as e:
      code = e
    assert code == NameNotFound

  block:
    # A zero-length mapping is EINVAL.
    var code = Success
    try:
      var f = memfiles.open("tests/nimony/stdlib/file_for_reading_test.txt",
                            mappedSize = 0)
      f.close
    except ErrorCode as e:
      code = e
    assert code == ValueError
