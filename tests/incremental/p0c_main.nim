## Main module of the `incrementalLiveTests` fixture (JIT_IMPL.md P0c). Only
## the phases' expected output depends on what it prints, so keep it to one
## line.

import std / syncio
import p0c_mid

echo midValue(4)
