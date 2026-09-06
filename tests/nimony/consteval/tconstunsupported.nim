import std/syncio

# Failure mode: a const whose RESULT TYPE cannot cross the sub-compile
# boundary. `exprexec.unravel`'s dispatch has an explicit unsupported bucket
# (ref, ptr, proc types, cstring reached through a field walk, …); it sets
# `errorMsg` rather than emitting a serializer, and `forwardToExecute`
# reports it under the const. This is the golden for that path — the one
# failure mode that reaches the user as a proper diagnostic today.

type Node = ref object
  value: int

proc mk(v: int): Node = Node(value: v)

const n = mk(3)

echo n.value
