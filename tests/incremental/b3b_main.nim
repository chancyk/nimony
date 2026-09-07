## Driver for the B3b declaration-stability fixture. Kept to one call so the
## edits the scenario makes to `b3b_lib` are the only thing that moves.

import std/syncio
import b3b_lib

echo total(3)
