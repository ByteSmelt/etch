# logging.nim
# Centralized logging utilities for the Etch language implementation

import std/[macros]
import constants


# Convenience templates for each module
macro logCompiler*(verbose: untyped, msg: untyped): untyped =
  result = quote do:
    if `verbose`:
      echo "[", MODULE_COMPILER, "] ", $`msg`

macro logProver*(verbose: untyped, msg: untyped): untyped =
  result = quote do:
    if `verbose`:
      echo "[", MODULE_PROVER, "] ", $`msg`

macro logVM*(verbose: untyped, msg: untyped): untyped =
  result = quote do:
    if `verbose`:
      echo "[", MODULE_VM, "] ", $`msg`
