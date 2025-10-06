# values.nim
# Common value types used across FFI and interpreter

type
  ValueKind* = enum
    vkInt, vkFloat, vkString, vkBool, vkVoid, vkRef, vkOption, vkResult, vkUnion

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
    of vkUnion:
      unionTypeIndex*: int     # Index indicating which type in the union is active (0-based)
      unionVal*: ref Value     # The actual value

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

proc vUnion*(typeIndex: int, val: Value): Value =
  Value(kind: vkUnion, unionTypeIndex: typeIndex, unionVal: new(Value))

proc initUnion*(typeIndex: int, val: Value): Value =
  result = Value(kind: vkUnion, unionTypeIndex: typeIndex)
  new(result.unionVal)
  result.unionVal[] = val
