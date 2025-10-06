# values.nim
# Common value types used across FFI and interpreter

type
  ValueKind* = enum
    vkInt, vkFloat, vkString, vkBool, vkVoid, vkRef, vkOption, vkResult

  Value* = object
    case kind*: ValueKind
    of vkInt:
      intVal*: int64
    of vkFloat:
      floatVal*: float64
    of vkString:
      stringVal*: string
    of vkBool:
      boolVal*: bool
    of vkVoid:
      discard
    of vkRef:
      refId*: int
    of vkOption:
      hasValue*: bool
      optionVal*: ref Value
    of vkResult:
      isOk*: bool
      resultVal*: ref Value

# Value constructors
proc vInt*(val: int64): Value =
  Value(kind: vkInt, intVal: val)

proc vFloat*(val: float64): Value =
  Value(kind: vkFloat, floatVal: val)

proc vString*(val: string): Value =
  Value(kind: vkString, stringVal: val)

proc vBool*(val: bool): Value =
  Value(kind: vkBool, boolVal: val)

proc vVoid*(): Value =
  Value(kind: vkVoid)

proc vRef*(id: int): Value =
  Value(kind: vkRef, refId: id)