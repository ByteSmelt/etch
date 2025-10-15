# logging.nim
# Centralized logging utilities for the Etch language implementation

import types
import constants


# Verbose logging function
proc verboseLog*(verbose: bool, module: string, msg: string) =
  if verbose:
    echo "[", module, "] ", msg


# Convenience templates for each module
template logCompiler*(flags: CompilerFlags, msg: string) =
  verboseLog(flags.verbose, MODULE_COMPILER, msg)

template logProver*(flags: CompilerFlags, msg: string) =
  verboseLog(flags.verbose, MODULE_PROVER, msg)

template logVM*(flags: CompilerFlags, msg: string) =
  verboseLog(flags.verbose, MODULE_VM, msg)
