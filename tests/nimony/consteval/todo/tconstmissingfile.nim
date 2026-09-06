import std/syncio

const gone = readFile("no_such_file_here.txt")

echo gone.len
