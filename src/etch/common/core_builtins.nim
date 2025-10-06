# core_builtins.nim
# True builtin operations that are part of the core language
# These are NOT host functions but fundamental language operations

import ../frontend/ast
import ../common/[types, errors]

type
  CoreBuiltin* = enum
    # Memory operations (true builtins)
    cbNew = 0      # Allocate on heap: new(value) -> ref[T]
    cbDeref        # Dereference pointer: deref(ref) -> T

    # These will be removed from builtins and become FFI imports:
    # print, rand, seed, readFile, parseInt, parseFloat, parseBool, toString
    # isSome, isNone, isOk, isErr

const CORE_BUILTIN_NAMES*: array[CoreBuiltin, string] = [
  cbNew: "new",
  cbDeref: "deref"
]

proc isCoreBuiltin*(name: string): bool =
  ## Check if a name is a core builtin (not an FFI function)
  case name
  of "new", "deref":
    return true
  else:
    return false

proc getCoreBuiltinId*(name: string): CoreBuiltin =
  ## Get the core builtin ID for a name
  for id, builtin in CORE_BUILTIN_NAMES:
    if builtin == name:
      return id
  raise newException(ValueError, "Not a core builtin: " & name)

proc checkCoreBuiltin*(name: string, argTypes: seq[EtchType], pos: Pos): EtchType =
  ## Type check a core builtin call
  case name
  of "new":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "new expects 1 argument")
    return tRef(argTypes[0])

  of "deref":
    if argTypes.len != 1:
      raise newTypecheckError(pos, "deref expects 1 argument")
    if argTypes[0].kind != tkRef:
      raise newTypecheckError(pos, "deref expects ref[T]")
    return argTypes[0].inner

  else:
    raise newTypecheckError(pos, "Unknown core builtin: " & name)