# vm.nim
# Simple AST interpreter acting as Etch VM (used both at runtime and for comptime eval)

import std/[tables, strformat, strutils, random, json]
import ../frontend/ast, bytecode, debugger
import ../common/[constants, errors, types, builtins, cffi, values]


type
  # Forward declaration for jump table
  VM* = ref VMObj

  # Instruction handler function type - returns false to halt execution
  InstructionHandler = proc(vm: VM, instr: Instruction): bool {.nimcall.}

  # Fast builtin function handler type
  BuiltinHandler = proc(vm: VM, argCount: int): bool {.nimcall.}

  V* = object
    kind*: TypeKind
    ival*: int64
    fval*: float64
    bval*: bool
    sval*: string
    cval*: char
    # Ref represented as reference to heap slot
    refId*: int
    # Array represented as sequence of values
    aval*: seq[V]
    # Option/Result represented as wrapped value with presence flag
    hasValue*: bool        # true for Some/Ok, false for None/Err
    wrappedVal*: ref V     # the actual value for Some/Ok, or error msg for Err
    # Object represented as field name -> value mapping
    oval*: Table[string, V]

  HeapCell = ref object
    alive: bool
    val: V

  Frame* = ref object
    vars*: Table[string, V]
    returnAddress*: int  # For bytecode execution
    # Fast slots for commonly accessed local variables (optimization)
    fastVars*: array[VM_FAST_SLOTS_COUNT, V]
    fastVarNames*: array[VM_FAST_SLOTS_COUNT, string]
    fastVarCount*: int  # Number of fast slots currently used

  VMObj* = object
    # AST interpreter state
    heap*: seq[HeapCell]
    funs*: Table[string, FunDecl]
    injectedStmts*: seq[Stmt]  # Queue for statements to inject from comptime

    # Bytecode interpreter state
    stack*: seq[V]
    callStack*: seq[Frame]
    program*: BytecodeProgram
    pc*: int  # Program counter
    globals*: Table[string, V]

    # Jump table for fast instruction dispatch - initialized once per VM
    jumpTable*: array[OpCode, InstructionHandler]
    # Fast builtin function dispatch
    builtinTable*: array[BuiltinFuncId, BuiltinHandler]

    # Debugger support (optional - zero cost when nil)
    debugger*: EtchDebugger

# Pre-allocated common values to reduce allocation overhead
let
  vIntZero* = V(kind: tkInt, ival: 0)
  vIntOne* = V(kind: tkInt, ival: 1)
  vFloatZero* = V(kind: tkFloat, fval: 0.0)
  vFloatOne* = V(kind: tkFloat, fval: 1.0)
  vBoolTrue* = V(kind: tkBool, bval: true)
  vBoolFalse* = V(kind: tkBool, bval: false)
  vEmptyString* = V(kind: tkString, sval: "")
  vNilRef* = V(kind: tkRef, refId: -1)
  vVoidValue* = V(kind: tkVoid)

# Optimized value constructors with inline pragma for performance
proc vInt(x: int64): V {.inline.} = V(kind: tkInt, ival: x)
proc vFloat(x: float64): V {.inline.} = V(kind: tkFloat, fval: x)
proc vString(x: string): V {.inline.} = V(kind: tkString, sval: x)
proc vChar(x: char): V {.inline.} = V(kind: tkChar, cval: x)
proc vBool(x: bool): V {.inline.} = V(kind: tkBool, bval: x)
proc vRef(id: int): V {.inline.} = V(kind: tkRef, refId: id)
proc vArray(elements: seq[V]): V {.inline.} = V(kind: tkArray, aval: elements)
proc vObject(fields: Table[string, V]): V {.inline.} = V(kind: tkObject, oval: fields)

# Fast constructors that use pre-allocated values when beneficial
proc vIntFast*(x: int64): V {.inline.} =
  case x:
  of 0: vIntZero
  of 1: vIntOne
  else: V(kind: tkInt, ival: x)

proc vFloatFast*(x: float64): V {.inline.} =
  if x == 0.0: vFloatZero
  elif x == 1.0: vFloatOne
  else: V(kind: tkFloat, fval: x)

proc vBoolFast*(x: bool): V {.inline.} =
  if x: vBoolTrue else: vBoolFalse

proc vStringFast*(x: string): V {.inline.} =
  if x.len == 0: vEmptyString
  else: V(kind: tkString, sval: x)

proc vOptionSome(val: V): V {.inline.} =
  var refVal = new(V)
  refVal[] = val
  V(kind: tkOption, hasValue: true, wrappedVal: refVal)

proc vOptionNone(): V {.inline.} =
  V(kind: tkOption, hasValue: false)

proc vResultOk(val: V): V {.inline.}  =
  var refVal = new(V)
  refVal[] = val
  V(kind: tkResult, hasValue: true, wrappedVal: refVal)

proc vResultErr(err: V): V {.inline.}  =
  var refVal = new(V)
  refVal[] = err
  V(kind: tkResult, hasValue: false, wrappedVal: refVal)

proc alloc(vm: VM; v: V): V {.inline.}  =
  vm.heap.add HeapCell(alive: true, val: v)
  vRef(vm.heap.high)

proc truthy(v: V): bool {.inline.} =
  case v.kind
  of tkBool: v.bval
  of tkInt: v.ival != 0
  of tkFloat: v.fval != 0.0
  else: false

proc getCurrentPos(vm: VM): Pos =
  ## Get current source position from the executing instruction
  if vm.pc > 0 and vm.pc <= vm.program.instructions.len:
    let instr = vm.program.instructions[vm.pc - 1]
    return Pos(
      line: instr.debug.line,
      col: instr.debug.col,
      filename: instr.debug.sourceFile
    )
  else:
    return Pos()

proc raiseRuntimeError(vm: VM, msg: string) =
  ## Raise a runtime error with current position information
  raise newRuntimeError(vm.getCurrentPos(), msg)

# Optimized bytecode VM functionality with inlined operations
proc push(vm: VM; val: V) {.inline.} =
  # Trust compiler safety verification - no bounds checking needed
  vm.stack.add(val)

proc pop(vm: VM): V {.inline.} =
  # Fast stack pop - trust compiler verification, no underflow checks
  let lastIndex = vm.stack.len - 1
  result = vm.stack[lastIndex]
  vm.stack.setLen(lastIndex)

proc peek(vm: VM): V {.inline.} =
  # Fast peek - trust compiler verification
  vm.stack[^1]

# Optimized variable access with fast slot caching
proc getVar(vm: VM, name: string): V =
  # Check current frame first
  if vm.callStack.len > 0:
    let frame = vm.callStack[^1]

    # Fast path: check cached slots first
    for i in 0..<frame.fastVarCount:
      if frame.fastVarNames[i] == name:
        return frame.fastVars[i]

    # Slower path: check full table
    if frame.vars.hasKey(name):
      return frame.vars[name]

  # Check globals
  if vm.globals.hasKey(name):
    return vm.globals[name]

  vm.raiseRuntimeError(&"Unknown variable: {name}")

proc setVar(vm: VM, name: string, value: V) =
  # Set in current frame if we're in a function, otherwise global
  if vm.callStack.len > 0:
    let frame = vm.callStack[^1]

    # Fast path: try to update cached slots first
    for i in 0..<frame.fastVarCount:
      if frame.fastVarNames[i] == name:
        frame.fastVars[i] = value
        frame.vars[name] = value  # Keep table in sync
        return

    # If we have room in fast slots, add new variable there
    if frame.fastVarCount < VM_FAST_SLOTS_COUNT:
      let slot = frame.fastVarCount
      frame.fastVarNames[slot] = name
      frame.fastVars[slot] = value
      frame.fastVarCount += 1

    frame.vars[name] = value
  else:
    vm.globals[name] = value

# Optimized individual operation functions for jump table dispatch
# All functions return bool: true to continue execution, false to halt
proc opLoadIntImpl(vm: VM, instr: Instruction): bool =
  vm.push(vIntFast(instr.arg))
  return true

proc opLoadFloatImpl(vm: VM, instr: Instruction): bool =
  vm.push(vFloatFast(parseFloat(vm.program.constants[instr.arg])))
  return true

proc opLoadStringImpl(vm: VM, instr: Instruction): bool =
  vm.push(vStringFast(vm.program.constants[instr.arg]))
  return true

proc opLoadCharImpl(vm: VM, instr: Instruction): bool =
  vm.push(vChar(vm.program.constants[instr.arg][0]))
  return true

proc opLoadBoolImpl(vm: VM, instr: Instruction): bool =
  vm.push(vBoolFast(instr.arg != 0))
  return true

proc opLoadVarImpl(vm: VM, instr: Instruction): bool =
  vm.push(vm.getVar(instr.sarg))
  return true

proc opStoreVarImpl(vm: VM, instr: Instruction): bool =
  vm.setVar(instr.sarg, vm.pop())
  return true

proc opLoadNilImpl(vm: VM, instr: Instruction): bool =
  vm.push(vNilRef)
  return true

proc opPopImpl(vm: VM, instr: Instruction): bool =
  discard vm.pop()
  return true

proc opDupImpl(vm: VM, instr: Instruction): bool =
  vm.push(vm.peek())
  return true

proc opAddImpl(vm: VM, instr: Instruction): bool =
  # Unboxed arithmetic optimization - avoid V object field access when possible
  let b = vm.pop()
  let a = vm.pop()

  # Fast path for integer addition (most common case in benchmarks)
  if likely(a.kind == tkInt and b.kind == tkInt):
    # Direct unboxed computation - no V object manipulation during calculation
    let computedResult = V(kind: tkInt, ival: a.ival + b.ival)
    vm.stack.add(computedResult)
    return true

  # Fast path for float addition
  if a.kind == tkFloat and b.kind == tkFloat:
    let computedResult = V(kind: tkFloat, fval: a.fval + b.fval)
    vm.stack.add(computedResult)
    return true

  # Slower paths for other types (string concat, array concat)
  case a.kind:
  of tkString:
    vm.push(vString(a.sval & b.sval))
  of tkArray:
    vm.push(vArray(a.aval & b.aval))
  else:
    vm.raiseRuntimeError("Unsupported types in addition")
  return true

proc opSubImpl(vm: VM, instr: Instruction): bool =
  let b = vm.pop()
  let a = vm.pop()

  # Fast unboxed integer subtraction
  if likely(a.kind == tkInt and b.kind == tkInt):
    let computedResult = V(kind: tkInt, ival: a.ival - b.ival)
    vm.stack.add(computedResult)
    return true

  # Fast unboxed float subtraction
  if a.kind == tkFloat and b.kind == tkFloat:
    let computedResult = V(kind: tkFloat, fval: a.fval - b.fval)
    vm.stack.add(computedResult)
    return true

  vm.raiseRuntimeError("Subtraction requires numeric types")
  return true

proc opMulImpl(vm: VM, instr: Instruction): bool =
  let b = vm.pop()
  let a = vm.pop()

  # Fast unboxed integer multiplication
  if likely(a.kind == tkInt and b.kind == tkInt):
    let computedResult = V(kind: tkInt, ival: a.ival * b.ival)
    vm.stack.add(computedResult)
    return true

  # Fast unboxed float multiplication
  if a.kind == tkFloat and b.kind == tkFloat:
    let computedResult = V(kind: tkFloat, fval: a.fval * b.fval)
    vm.stack.add(computedResult)
    return true

  vm.raiseRuntimeError("Multiplication requires numeric types")
  return true

proc opDivImpl(vm: VM, instr: Instruction): bool =
  let b = vm.pop()
  let a = vm.pop()

  # Fast unboxed integer division
  if likely(a.kind == tkInt and b.kind == tkInt):
    let computedResult = V(kind: tkInt, ival: a.ival div b.ival)
    vm.stack.add(computedResult)
    return true

  # Fast unboxed float division
  if a.kind == tkFloat and b.kind == tkFloat:
    let computedResult = V(kind: tkFloat, fval: a.fval / b.fval)
    vm.stack.add(computedResult)
    return true

  vm.raiseRuntimeError("Division requires numeric types")
  return true

proc opModImpl(vm: VM, instr: Instruction): bool =
  let b = vm.pop()
  let a = vm.pop()

  # Fast unboxed integer modulo
  if likely(a.kind == tkInt and b.kind == tkInt):
    let computedResult = V(kind: tkInt, ival: a.ival mod b.ival)
    vm.stack.add(computedResult)
    return true

  vm.raiseRuntimeError("Modulo requires integer types")
  return true

proc opNegImpl(vm: VM, instr: Instruction): bool =
  let a = vm.pop()

  case a.kind:
  of tkInt:
    vm.push(vInt(-a.ival))
  of tkFloat:
    vm.push(vFloat(-a.fval))
  else:
    vm.raiseRuntimeError("Negation requires numeric type")
  return true

proc opEqImpl(vm: VM, instr: Instruction): bool =
  let b = vm.pop()
  let a = vm.pop()

  # Fast unboxed integer comparison (most common in loops)
  if likely(a.kind == tkInt and b.kind == tkInt):
    let computedResult = V(kind: tkBool, bval: a.ival == b.ival)
    vm.stack.add(computedResult)
    return true

  # Fast unboxed float comparison
  if a.kind == tkFloat and b.kind == tkFloat:
    let computedResult = V(kind: tkBool, bval: a.fval == b.fval)
    vm.stack.add(computedResult)
    return true

  # Slower paths for other types
  let compareResult = case a.kind:
  of tkString: a.sval == b.sval
  of tkChar: a.cval == b.cval
  of tkBool: a.bval == b.bval
  of tkRef: a.refId == b.refId
  else: false

  vm.push(vBool(compareResult))
  return true

proc opNeImpl(vm: VM, instr: Instruction): bool =
  let b = vm.pop()
  let a = vm.pop()

  let compareResult = case a.kind:
  of tkInt: a.ival != b.ival
  of tkFloat: a.fval != b.fval
  of tkString: a.sval != b.sval
  of tkChar: a.cval != b.cval
  of tkBool: a.bval != b.bval
  of tkRef: a.refId != b.refId
  else: true

  vm.push(vBool(compareResult))
  return true

proc opLtImpl(vm: VM, instr: Instruction): bool =
  let b = vm.pop()
  let a = vm.pop()

  # Fast unboxed integer less-than (critical for loop conditions)
  if likely(a.kind == tkInt and b.kind == tkInt):
    let computedResult = V(kind: tkBool, bval: a.ival < b.ival)
    vm.stack.add(computedResult)
    return true

  # Fast unboxed float less-than
  if a.kind == tkFloat and b.kind == tkFloat:
    let computedResult = V(kind: tkBool, bval: a.fval < b.fval)
    vm.stack.add(computedResult)
    return true

  # Fallback for unsupported types
  vm.push(vBoolFalse)
  return true

proc opLeImpl(vm: VM, instr: Instruction): bool =
  let b = vm.pop()
  let a = vm.pop()

  let compareResult = case a.kind:
  of tkInt: a.ival <= b.ival
  of tkFloat: a.fval <= b.fval
  else: false

  vm.push(vBool(compareResult))
  return true

proc opGtImpl(vm: VM, instr: Instruction): bool =
  let b = vm.pop()
  let a = vm.pop()

  let compareResult = case a.kind:
  of tkInt: a.ival > b.ival
  of tkFloat: a.fval > b.fval
  else: false

  vm.push(vBool(compareResult))
  return true

proc opGeImpl(vm: VM, instr: Instruction): bool =
  let b = vm.pop()
  let a = vm.pop()

  let compareResult = case a.kind:
  of tkInt: a.ival >= b.ival
  of tkFloat: a.fval >= b.fval
  else: false

  vm.push(vBool(compareResult))
  return true

proc opAndImpl(vm: VM, instr: Instruction): bool =
  let b = vm.pop()
  let a = vm.pop()
  vm.push(vBool(a.bval and b.bval))
  return true

proc opOrImpl(vm: VM, instr: Instruction): bool =
  let b = vm.pop()
  let a = vm.pop()
  vm.push(vBool(a.bval or b.bval))
  return true

proc opNotImpl(vm: VM, instr: Instruction): bool =
  let a = vm.pop()
  if a.kind != tkBool:
    vm.raiseRuntimeError("Logical NOT requires bool")
  vm.push(vBool(not a.bval))
  return true

proc opNewRefImpl(vm: VM, instr: Instruction): bool =
  let value = vm.pop()
  vm.push(vm.alloc(value))
  return true

proc opDerefImpl(vm: VM, instr: Instruction): bool =
  let refVal = vm.pop()
  if refVal.kind != tkRef:
    vm.raiseRuntimeError("Deref expects reference")
  if refVal.refId < 0 or refVal.refId >= vm.heap.len:
    vm.raiseRuntimeError("Invalid reference")
  let cell = vm.heap[refVal.refId]
  if not cell.alive:
    vm.raiseRuntimeError("Dereferencing dead reference")
  vm.push(cell.val)
  return true

proc opMakeArrayImpl(vm: VM, instr: Instruction): bool =
  let count = instr.arg
  # Optimize: pre-allocate array and fill in reverse order to avoid inserts
  var elements: seq[V] = newSeq[V](count)
  for i in countdown(count-1, 0):
    elements[i] = vm.pop()
  vm.push(vArray(elements))
  return true

proc opArrayGetImpl(vm: VM, instr: Instruction): bool =
  let index = vm.pop()
  let array = vm.pop()

  # Fast unboxed array access (critical for array benchmarks)
  if likely(array.kind == tkArray and index.kind == tkInt):
    # Direct stack push - avoid function call overhead
    vm.stack.add(array.aval[index.ival])
    return true

  # Fast unboxed string indexing
  if array.kind == tkString and index.kind == tkInt:
    let computedResult = V(kind: tkChar, cval: array.sval[index.ival])
    vm.stack.add(computedResult)
    return true

  vm.raiseRuntimeError("Indexing requires array or string type")
  return true

proc opArraySliceImpl(vm: VM, instr: Instruction): bool =
  let endVal = vm.pop()
  let startVal = vm.pop()
  let array = vm.pop()
  let startIdx = if startVal.kind == tkInt and startVal.ival != -1: startVal.ival else: 0
  case array.kind
  of tkArray:
    let endIdx = if endVal.kind == tkInt and endVal.ival != -1: endVal.ival else: array.aval.len
    let actualStart = max(0, min(startIdx, array.aval.len))
    let actualEnd = max(actualStart, min(endIdx, array.aval.len))
    if actualStart >= actualEnd:
      vm.push(vArray(@[]))
    else:
      vm.push(vArray(array.aval[actualStart..<actualEnd]))
  of tkString:
    let endIdx = if endVal.kind == tkInt and endVal.ival != -1: endVal.ival else: array.sval.len
    let actualStart = max(0, min(startIdx, array.sval.len))
    let actualEnd = max(actualStart, min(endIdx, array.sval.len))
    if actualStart >= actualEnd:
      vm.push(vEmptyString)
    else:
      vm.push(vStringFast(array.sval[actualStart..<actualEnd]))
  else:
    vm.raiseRuntimeError("Slicing requires array or string type")
  return true

proc opArrayLenImpl(vm: VM, instr: Instruction): bool =
  let array = vm.pop()
  case array.kind
  of tkArray:
    vm.push(vIntFast(array.aval.len.int64))
  of tkString:
    vm.push(vIntFast(array.sval.len.int64))
  else:
    vm.raiseRuntimeError("Length operator requires array or string type")
  return true

proc opCastImpl(vm: VM, instr: Instruction): bool =
  let source = vm.pop()
  case instr.arg:
  of 1:
    case source.kind:
    of tkFloat: vm.push(vInt(source.fval.int64))
    of tkInt: vm.push(source)
    else: vm.raiseRuntimeError("invalid cast to int")
  of 2:
    case source.kind:
    of tkInt: vm.push(vFloat(source.ival.float64))
    of tkFloat: vm.push(source)
    else: vm.raiseRuntimeError("invalid cast to float")
  of 3:
    case source.kind:
    of tkInt: vm.push(vStringFast($source.ival))
    of tkFloat: vm.push(vStringFast($source.fval))
    else: vm.raiseRuntimeError("invalid cast to string")
  else:
    vm.raiseRuntimeError("unsupported cast type")
  return true

proc opMakeOptionSomeImpl(vm: VM, instr: Instruction): bool =
  let value = vm.pop()
  vm.push(vOptionSome(value))
  return true

proc opMakeOptionNoneImpl(vm: VM, instr: Instruction): bool =
  vm.push(vOptionNone())
  return true

proc opMakeResultOkImpl(vm: VM, instr: Instruction): bool =
  let value = vm.pop()
  vm.push(vResultOk(value))
  return true

proc opMakeResultErrImpl(vm: VM, instr: Instruction): bool =
  let errValue = vm.pop()
  vm.push(vResultErr(errValue))
  return true

proc opMatchValueImpl(vm: VM, instr: Instruction): bool =
  let value = vm.peek() # Don't pop yet, just peek
  case instr.arg:
  of 0: # check for None
    if value.kind == tkOption and not value.hasValue:
      vm.push(vBool(true))
    else:
      vm.push(vBool(false))
  of 1: # check for Some
    if value.kind == tkOption and value.hasValue:
      vm.push(vBool(true))
    else:
      vm.push(vBool(false))
  of 2: # check for Ok
    if value.kind == tkResult and value.hasValue:
      vm.push(vBool(true))
    else:
      vm.push(vBool(false))
  of 3: # check for Err
    if value.kind == tkResult and not value.hasValue:
      vm.push(vBool(true))
    else:
      vm.push(vBool(false))
  else:
    vm.push(vBool(false))
  return true

proc opExtractSomeImpl(vm: VM, instr: Instruction): bool =
  let option = vm.pop()
  if option.kind == tkOption and option.hasValue and option.wrappedVal != nil:
    vm.push(option.wrappedVal[])
  else:
    vm.raiseRuntimeError("extractSome: not a Some value")
  return true

proc opExtractOkImpl(vm: VM, instr: Instruction): bool =
  let resultValue = vm.pop()
  if resultValue.kind == tkResult and resultValue.hasValue and resultValue.wrappedVal != nil:
    vm.push(resultValue.wrappedVal[])
  else:
    vm.raiseRuntimeError("extractOk: not an Ok value")
  return true

proc opExtractErrImpl(vm: VM, instr: Instruction): bool =
  let resultValue = vm.pop()
  if resultValue.kind == tkResult and not resultValue.hasValue and resultValue.wrappedVal != nil:
    vm.push(resultValue.wrappedVal[])
  else:
    vm.raiseRuntimeError("extractErr: not an Err value")
  return true

proc opMakeObjectImpl(vm: VM, instr: Instruction): bool =
  # arg contains number of field pairs on stack
  # Stack format: value1, "field1", value2, "field2", ... (top of stack has last pair)
  let numFields = int(instr.arg)
  var fields = initTable[string, V](numFields)  # Pre-allocate table capacity

  # Pop field-value pairs from stack (in reverse order)
  for i in 0..<numFields:
    let fieldName = vm.pop().sval  # Field name
    let fieldValue = vm.pop()      # Field value
    fields[fieldName] = fieldValue

  vm.push(vObject(fields))
  return true

proc opObjectGetImpl(vm: VM, instr: Instruction): bool =
  let fieldName = instr.sarg  # Field name is stored in instruction
  let obj = vm.pop()          # Object to access

  # Handle automatic dereferencing for reference types
  var actualObj = obj
  if obj.kind == tkRef:
    if obj.refId < 0 or obj.refId >= vm.heap.len:
      vm.raiseRuntimeError("invalid reference")
    let cell = vm.heap[obj.refId]
    if cell.isNil or not cell.alive:
      vm.raiseRuntimeError("attempted to access field on null reference")
    actualObj = cell.val

  if actualObj.kind != tkObject:
    vm.raiseRuntimeError(&"field access requires object type, got '{actualObj.kind}'")

  if not actualObj.oval.hasKey(fieldName):
    vm.raiseRuntimeError(&"object has no field '{fieldName}'")

  vm.push(actualObj.oval[fieldName])
  return true

proc opObjectSetImpl(vm: VM, instr: Instruction): bool =
  let fieldName = instr.sarg  # Field name is stored in instruction
  let value = vm.pop()        # Value to set
  let obj = vm.pop()          # Object to modify

  # Handle automatic dereferencing for reference types
  var actualObj: V
  var objRef: int = -1
  if obj.kind == tkRef:
    objRef = obj.refId
    if objRef < 0 or objRef >= vm.heap.len:
      vm.raiseRuntimeError("invalid reference")
    let cell = vm.heap[objRef]
    if cell.isNil or not cell.alive:
      vm.raiseRuntimeError("attempted to set field on null reference")
    actualObj = cell.val
  else:
    actualObj = obj

  if actualObj.kind != tkObject:
    vm.raiseRuntimeError(&"field assignment requires object type, got '{actualObj.kind}'")

  # Create a new object with the updated field
  var newFields = actualObj.oval
  newFields[fieldName] = value

  # Update the object (either on heap or in variable)
  if objRef >= 0:
    # Update the heap-allocated object
    vm.heap[objRef].val = vObject(newFields)
  else:
    # For stack-allocated objects, we need to store the modified object
    # This is handled by the calling code (e.g., in a variable assignment)
    vm.push(vObject(newFields))

  return true

# Fast builtin function implementations
proc builtinPrint(vm: VM, argCount: int): bool =
  let arg = vm.pop()
  let output = case arg.kind:
    of tkString: arg.sval
    of tkChar: $arg.cval
    of tkInt: $arg.ival
    of tkFloat: $arg.fval
    of tkBool:
      if arg.bval: "true" else: "false"
    else: "<ref>"

  if vm.debugger != nil:
    stderr.writeLine(output)
    stderr.flushFile()
  else:
    echo output

  vm.push(vVoidValue)
  return true

proc builtinNew(vm: VM, argCount: int): bool =
  let arg = vm.pop()
  vm.push(vm.alloc(arg))
  return true

proc builtinDeref(vm: VM, argCount: int): bool =
  let refVal = vm.pop()
  if refVal.kind != tkRef:
    vm.raiseRuntimeError("deref on non-ref")
  let cell = vm.heap[refVal.refId]
  if cell.isNil or not cell.alive:
    vm.raiseRuntimeError("nil ref")
  vm.push(cell.val)
  return true

proc builtinRand(vm: VM, argCount: int): bool =
  if argCount == 1:
    let maxVal = vm.pop()
    if maxVal.kind == tkInt and maxVal.ival > 0:
      let res = rand(int(maxVal.ival))
      vm.push(vIntFast(int64(res)))
    else:
      vm.push(vIntZero)
  elif argCount == 2:
    let maxVal = vm.pop()
    let minVal = vm.pop()
    if maxVal.kind == tkInt and minVal.kind == tkInt and maxVal.ival >= minVal.ival:
      let res = rand(int(maxVal.ival - minVal.ival)) + int(minVal.ival)
      vm.push(vIntFast(int64(res)))
    else:
      vm.push(vIntZero)
  return true

proc builtinSeed(vm: VM, argCount: int): bool =
  if argCount == 1:
    let seedVal = vm.pop()
    if seedVal.kind == tkInt:
      randomize(int(seedVal.ival))
  elif argCount == 0:
    randomize()
  vm.push(vVoidValue)
  return true

proc builtinReadFile(vm: VM, argCount: int): bool =
  if argCount == 1:
    let pathArg = vm.pop()
    if pathArg.kind == tkString:
      try:
        let content = readFile(pathArg.sval)
        vm.push(vStringFast(content))
      except:
        vm.push(vEmptyString)
    else:
      vm.push(vEmptyString)
  return true

proc builtinParseInt(vm: VM, argCount: int): bool =
  if argCount == 1:
    let strArg = vm.pop()
    if strArg.kind == tkString:
      try:
        let parsed = parseInt(strArg.sval)
        vm.push(vOptionSome(vInt(parsed)))
      except:
        vm.push(vOptionNone())
    else:
      vm.push(vOptionNone())
  return true

proc builtinParseFloat(vm: VM, argCount: int): bool =
  if argCount == 1:
    let strArg = vm.pop()
    if strArg.kind == tkString:
      try:
        let parsed = parseFloat(strArg.sval)
        vm.push(vOptionSome(vFloat(parsed)))
      except:
        vm.push(vOptionNone())
    else:
      vm.push(vOptionNone())
  return true

proc builtinParseBool(vm: VM, argCount: int): bool =
  if argCount == 1:
    let strArg = vm.pop()
    if strArg.kind == tkString:
      case strArg.sval.toLower()
      of "true", "1", "yes", "on":
        vm.push(vOptionSome(vBool(true)))
      of "false", "0", "no", "off":
        vm.push(vOptionSome(vBool(false)))
      else:
        vm.push(vOptionNone())
    else:
      vm.push(vOptionNone())
  return true

proc builtinToString(vm: VM, argCount: int): bool =
  if argCount == 1:
    let arg = vm.pop()
    case arg.kind
    of tkInt:
      vm.push(vStringFast($arg.ival))
    of tkFloat:
      vm.push(vStringFast($arg.fval))
    of tkBool:
      vm.push(vStringFast($arg.bval))
    of tkChar:
      vm.push(vStringFast($arg.cval))
    else:
      vm.push(vEmptyString)
  return true

proc builtinIsSome(vm: VM, argCount: int): bool =
  if argCount == 1:
    let arg = vm.pop()
    if arg.kind == tkOption:
      vm.push(vBool(arg.hasValue))
    else:
      vm.push(vBool(false))
  return true

proc builtinIsNone(vm: VM, argCount: int): bool =
  if argCount == 1:
    let arg = vm.pop()
    if arg.kind == tkOption:
      vm.push(vBool(not arg.hasValue))
    else:
      vm.push(vBool(false))
  return true

proc builtinIsOk(vm: VM, argCount: int): bool =
  if argCount == 1:
    let arg = vm.pop()
    if arg.kind == tkResult:
      vm.push(vBool(arg.hasValue))
    else:
      vm.push(vBool(false))
  return true

proc builtinIsErr(vm: VM, argCount: int): bool =
  if argCount == 1:
    let arg = vm.pop()
    if arg.kind == tkResult:
      vm.push(vBool(not arg.hasValue))
    else:
      vm.push(vBool(false))
  return true

# Fused instruction implementations for performance optimization
proc opLoadVarArrayGetImpl(vm: VM, instr: Instruction): bool =
  ## Fused: LoadVar(array), LoadVar(index), ArrayGet
  ## arg contains array var name offset, sarg contains index var name
  let arrayVar = vm.getVar(vm.program.constants[instr.arg])
  let indexVar = vm.getVar(instr.sarg)

  # Fast unboxed array access without intermediate stack operations
  if likely(arrayVar.kind == tkArray and indexVar.kind == tkInt):
    vm.stack.add(arrayVar.aval[indexVar.ival])
    return true

  vm.raiseRuntimeError("Fused array access requires array and int types")
  return true

proc opLoadIntAddVarImpl(vm: VM, instr: Instruction): bool =
  ## Fused: LoadInt, LoadVar, Add
  ## arg contains the int constant, sarg contains var name
  let intVal = instr.arg
  let varVal = vm.getVar(instr.sarg)

  # Fast unboxed integer addition
  if likely(varVal.kind == tkInt):
    let computedResult = V(kind: tkInt, ival: intVal + varVal.ival)
    vm.stack.add(computedResult)
    return true

  vm.raiseRuntimeError("Fused int+var requires int variable")
  return true

proc opLoadVarIntLtImpl(vm: VM, instr: Instruction): bool =
  ## Fused: LoadVar, LoadInt, Lt
  ## sarg contains var name, arg contains int constant
  let varVal = vm.getVar(instr.sarg)
  let intVal = instr.arg

  # Fast unboxed integer comparison
  if likely(varVal.kind == tkInt):
    let computedResult = V(kind: tkBool, bval: varVal.ival < intVal)
    vm.stack.add(computedResult)
    return true

  vm.raiseRuntimeError("Fused var<int requires int variable")
  return true

proc opCallBuiltinImpl(vm: VM, instr: Instruction): bool =
  ## Ultra-fast builtin dispatch using direct builtin ID
  ## arg contains: (builtinId << 16) | argCount for compact encoding
  let packed = instr.arg
  let builtinId = BuiltinFuncId(packed shr 16)
  let argCount = int(packed and 0xFFFF)
  let handler = vm.builtinTable[builtinId]
  return handler(vm, argCount)

proc opCallCFFIImpl(vm: VM, instr: Instruction): bool =
  ## Handle CFFI function calls
  let argCount = int(instr.arg)
  let funcName = instr.sarg

  # Collect arguments from stack
  var args: seq[Value] = @[]
  for i in 0 ..< argCount:
    let arg = vm.pop()
    # Convert VM value to CFFI Value
    var cffiVal: Value
    case arg.kind
    of tkInt:
      cffiVal = Value(kind: vkInt, intVal: arg.ival)
    of tkFloat:
      cffiVal = Value(kind: vkFloat, floatVal: arg.fval)
    of tkString:
      cffiVal = Value(kind: vkString, stringVal: arg.sval)
    of tkBool:
      cffiVal = Value(kind: vkBool, boolVal: arg.bval)
    of tkChar:
      # Convert char to string for CFFI
      cffiVal = Value(kind: vkString, stringVal: $arg.cval)
    else:
      cffiVal = Value(kind: vkVoid)
    args.insert(cffiVal, 0)  # Reverse order since we popped from stack

  try:
    # Call the CFFI function
    let cffiResult = globalCFFIRegistry.callFunction(funcName, args)

    # Convert result back to VM value
    case cffiResult.kind
    of vkInt:
      vm.push(vInt(cffiResult.intVal))
    of vkFloat:
      vm.push(vFloat(cffiResult.floatVal))
    of vkString:
      vm.push(vString(cffiResult.stringVal))
    of vkBool:
      vm.push(vBool(cffiResult.boolVal))
    of vkVoid:
      vm.push(vNilRef)
    else:
      vm.push(vNilRef)
  except Exception as e:
    # CFFI call failed - push nil and continue (or could raise error)
    echo "CFFI call failed: ", e.msg
    vm.push(vNilRef)

  return true

proc opJumpImpl(vm: VM, instr: Instruction): bool =
  vm.pc = int(instr.arg)
  return true

proc opJumpIfFalseImpl(vm: VM, instr: Instruction): bool =
  let condition = vm.pop()
  if not truthy(condition):
    vm.pc = int(instr.arg)
  return true

proc opReturnImpl(vm: VM, instr: Instruction): bool =
  if vm.callStack.len == 0:
    return false
  let frame = vm.callStack.pop()
  vm.pc = frame.returnAddress
  return true

proc opCallImpl(vm: VM, instr: Instruction): bool =
  let funcName = instr.sarg
  let argCount = int(instr.arg)

  # User-defined function call - fast hash lookup
  if vm.program.functions.hasKey(funcName):
    # Create new frame with fast slots initialization
    let newFrame = Frame(
      vars: initTable[string, V](),
      returnAddress: vm.pc,
      fastVarCount: 0
    )

    # Pop arguments and collect them (they come off stack in reverse order due to forward push)
    # Optimize: pre-allocate args array to avoid repeated allocations
    var args: seq[V] = newSeq[V](argCount)
    for i in 0..<argCount:
      args[argCount-1-i] = vm.pop()
    # Arguments are now in correct parameter order

    # Get parameter names from function debug info
    if vm.program.functionInfo.hasKey(funcName):
      let debugInfo = vm.program.functionInfo[funcName]
      for i in 0..<min(args.len, debugInfo.parameterNames.len):
        newFrame.vars[debugInfo.parameterNames[i]] = args[i]
    else:
      # Fallback: use generic parameter names if debug info is not available
      for i in 0..<args.len:
        newFrame.vars["param" & $i] = args[i]

    vm.callStack.add(newFrame)
    vm.pc = vm.program.functions[funcName]
    return true

  # Function not found
  vm.raiseRuntimeError("Unknown function: " & funcName)

proc vmValueToDisplayString(value: V, maxArrayElements: int = 10): string =
  ## Convert a VM value to a display string for debugger
  case value.kind
  of tkInt: return $value.ival
  of tkFloat: return $value.fval
  of tkString: return "\"" & value.sval & "\""
  of tkChar: return "'" & $value.cval & "'"
  of tkBool: return if value.bval: "true" else: "false"
  of tkVoid: return "(void)"
  of tkArray:
    if value.aval.len == 0:
      return "[]"
    var res = "["
    let elementsToShow = min(value.aval.len, maxArrayElements)
    for i in 0..<elementsToShow:
      if i > 0: res.add(", ")
      res.add(vmValueToDisplayString(value.aval[i], maxArrayElements))
    if value.aval.len > maxArrayElements:
      res.add(", ...")
    res.add("]")
    return res & " (length: " & $value.aval.len & ")"
  of tkOption:
    if value.hasValue:
      if value.wrappedVal != nil:
        return "Some(" & vmValueToDisplayString(value.wrappedVal[], maxArrayElements) & ")"
      else:
        return "Some(<invalid>)"
    else:
      return "None"
  of tkResult:
    if value.hasValue:
      if value.wrappedVal != nil:
        return "Ok(" & vmValueToDisplayString(value.wrappedVal[], maxArrayElements) & ")"
      else:
        return "Ok(<invalid>)"
    else:
      if value.wrappedVal != nil:
        return "Err(" & vmValueToDisplayString(value.wrappedVal[], maxArrayElements) & ")"
      else:
        return "Err(<invalid>)"
  of tkRef:
    if value.refId == -1:
      return "nil"
    else:
      return "ref#" & $value.refId
  else: return "<" & $value.kind & ">"

proc vmGetCurrentVariables*(vm: VM): Table[string, string] =
  ## Get current variables in scope for debugger display
  var variables = initTable[string, string]()

  # Get variables from current call frame (if any)
  if vm.callStack.len > 0:
    let currentFrame = vm.callStack[^1]
    for name, value in currentFrame.vars:
      variables[name] = vmValueToDisplayString(value)

  # Get global variables
  for name, value in vm.globals:
    # Only show globals if they're not shadowed by locals
    if not variables.hasKey(name):
      variables[name] = vmValueToDisplayString(value)

  return variables

proc vmGetVariableValue*(vm: VM, name: string): V =
  ## Get a variable value by name for debugger inspection
  # Check current call frame first
  if vm.callStack.len > 0:
    let currentFrame = vm.callStack[^1]
    if currentFrame.vars.hasKey(name):
      return currentFrame.vars[name]

  # Check globals
  if vm.globals.hasKey(name):
    return vm.globals[name]

  vm.raiseRuntimeError(&"Variable '{name}' not found")

proc vmInspectArrayElement*(vm: VM, arrayName: string, index: int): string =
  ## Inspect a specific array element for debugger
  try:
    let arrayValue = vmGetVariableValue(vm, arrayName)
    case arrayValue.kind:
    of tkArray:
      if index < 0 or index >= arrayValue.aval.len:
        return &"Index {index} out of bounds (array length: {arrayValue.aval.len})"
      return &"{arrayName}[{index}] = " & vmValueToDisplayString(arrayValue.aval[index])
    of tkString:
      if index < 0 or index >= arrayValue.sval.len:
        return &"Index {index} out of bounds (string length: {arrayValue.sval.len})"
      return &"{arrayName}[{index}] = '" & $arrayValue.sval[index] & "'"
    else:
      return &"Variable '{arrayName}' is not an array or string (type: {arrayValue.kind})"
  except Exception as e:
    return &"Error inspecting {arrayName}[{index}]: {e.msg}"

proc vmInspectArraySlice*(vm: VM, arrayName: string, startIdx, endIdx: int): string =
  ## Inspect a slice of an array for debugger
  try:
    let arrayValue = vmGetVariableValue(vm, arrayName)
    case arrayValue.kind:
    of tkArray:
      let actualStart = max(0, min(startIdx, arrayValue.aval.len))
      let actualEnd = max(actualStart, min(endIdx, arrayValue.aval.len))
      if actualStart >= actualEnd:
        return &"{arrayName}[{startIdx}..{endIdx}] = [] (empty slice)"
      let slice = arrayValue.aval[actualStart..<actualEnd]
      let sliceArray = V(kind: tkArray, aval: slice)
      return &"{arrayName}[{startIdx}..{endIdx}] = " & vmValueToDisplayString(sliceArray)
    of tkString:
      let actualStart = max(0, min(startIdx, arrayValue.sval.len))
      let actualEnd = max(actualStart, min(endIdx, arrayValue.sval.len))
      if actualStart >= actualEnd:
        return &"{arrayName}[{startIdx}..{endIdx}] = \"\" (empty slice)"
      let slice = arrayValue.sval[actualStart..<actualEnd]
      return &"{arrayName}[{startIdx}..{endIdx}] = \"" & slice & "\""
    else:
      return &"Variable '{arrayName}' is not an array or string (type: {arrayValue.kind})"
  except Exception as e:
    return &"Error inspecting {arrayName}[{startIdx}..{endIdx}]: {e.msg}"

proc vmGetArrayInfo*(vm: VM, arrayName: string): string =
  ## Get comprehensive array information for debugger
  try:
    let arrayValue = vmGetVariableValue(vm, arrayName)
    case arrayValue.kind:
    of tkArray:
      var info = &"Array '{arrayName}': length={arrayValue.aval.len}, type=array"
      if arrayValue.aval.len > 0:
        info.add(&", elements:")
        let maxShow = min(20, arrayValue.aval.len)  # Show more elements in detailed view
        for i in 0..<maxShow:
          info.add(&"\n  [{i}] = " & vmValueToDisplayString(arrayValue.aval[i]))
        if arrayValue.aval.len > maxShow:
          info.add(&"\n  ... and {arrayValue.aval.len - maxShow} more elements")
      return info
    of tkString:
      var info = &"String '{arrayName}': length={arrayValue.sval.len}, type=string"
      if arrayValue.sval.len > 0:
        info.add(&", characters:")
        let maxShow = min(50, arrayValue.sval.len)  # Show more chars for strings
        for i in 0..<maxShow:
          info.add(&"\n  [{i}] = '" & $arrayValue.sval[i] & "'")
        if arrayValue.sval.len > maxShow:
          info.add(&"\n  ... and {arrayValue.sval.len - maxShow} more characters")
      return info
    else:
      return &"Variable '{arrayName}' is not an array or string (type: {arrayValue.kind})"
  except Exception as e:
    return &"Error getting array info for '{arrayName}': {e.msg}"

# Debugger implementation functions
proc vmDebuggerBeforeInstruction*(vm: VM) =
  ## Called before each instruction execution
  if vm.pc < vm.program.instructions.len:
    let instr = vm.program.instructions[vm.pc]  # Current instruction about to execute

    # Update stack frame tracking for step operations
    case instr.op:
    of opCall:
      let funcName = instr.sarg
      let currentFile = if instr.debug.sourceFile.len > 0: instr.debug.sourceFile else: MAIN_FUNCTION_NAME
      let isBuiltIn = not vm.program.functions.hasKey(funcName)
      vm.debugger.pushStackFrame(funcName, currentFile, instr.debug.line, isBuiltIn)
    of opReturn:
      vm.debugger.popStackFrame()
    else:
      discard

proc vmDebuggerAfterInstruction*(vm: VM) =
  ## Called after instruction execution for debugging
  if vm.debugger != nil and vm.pc > 0:
    let instr = vm.program.instructions[vm.pc - 1]  # Instruction just executed

    # For built-in function calls, pop stack frame immediately since they don't use opReturn
    if instr.op == opCall:
      let funcName = instr.sarg
      # Check if this is a built-in function (not a user-defined function)
      if not vm.program.functions.hasKey(funcName):
        vm.debugger.popStackFrame()

proc vmDebuggerShouldBreak*(vm: VM): bool =
  ## Check if execution should break at current instruction
  if vm.debugger.paused:
    return true

  if vm.pc < vm.program.instructions.len:
    let instr = vm.program.instructions[vm.pc]  # Current instruction about to execute
    let currentFile = instr.debug.sourceFile
    let currentLine = instr.debug.line

    # Skip breaking on internal control flow instructions
    if instr.op == opJump or instr.op == opJumpIfFalse:
      return false

    # Check breakpoints
    if vm.debugger.hasBreakpoint(currentFile, currentLine):
      return true

    # Check step modes
    case vm.debugger.stepMode:
    of smContinue:
      return false
    of smStepInto:
      # Break on any instruction (but not on the same line we just stepped from)
      let shouldBreak = currentLine != vm.debugger.lastLine or currentFile != vm.debugger.lastFile
      if shouldBreak and currentLine > 0:  # Only log for valid lines
        stderr.writeLine("DEBUG: StepInto - breaking at line " & $currentLine &
                        " (last was " & $vm.debugger.lastLine & ")")
        stderr.flushFile()
      return shouldBreak
    of smStepOver:
      # Break if we're at the same user call depth or returned, and on a different line
      let shouldBreak = vm.debugger.userCallDepth <= vm.debugger.stepCallDepth and
                        (currentLine != vm.debugger.lastLine or currentFile != vm.debugger.lastFile) and
                        currentLine > 0  # Only break on valid lines
      if currentLine > 0:  # Only log for valid lines
        stderr.writeLine("DEBUG: StepOver - line " & $currentLine &
                        " (last was " & $vm.debugger.lastLine & "), userDepth=" &
                        $vm.debugger.userCallDepth & "/" & $vm.debugger.stepCallDepth &
                        ", shouldBreak=" & $shouldBreak)
        stderr.flushFile()
      return shouldBreak
    of smStepOut:
      # Break if we've returned from current user function
      return vm.debugger.userCallDepth < vm.debugger.stepCallDepth

  return false

proc vmDebuggerOnBreak*(vm: VM) =
  ## Called when execution breaks
  vm.debugger.paused = true
  vm.debugger.stepMode = smContinue

  if vm.pc < vm.program.instructions.len:
    let instr = vm.program.instructions[vm.pc]  # Current instruction where we stopped
    vm.debugger.lastFile = instr.debug.sourceFile
    vm.debugger.lastLine = instr.debug.line

  # Send stopped event to debug adapter if callback is set
  if vm.debugger.onDebugEvent != nil:
    let event = %*{
      "reason": "breakpoint",
      "threadId": 1,
      "file": vm.debugger.lastFile,
      "line": vm.debugger.lastLine
    }
    vm.debugger.onDebugEvent("stopped", event)

proc executeInstruction*(vm: VM): bool =
  ## Execute a single bytecode instruction using jump table dispatch. Returns false when program should halt.
  if vm.pc >= vm.program.instructions.len:
    return false

  # Zero-cost debug hook - optimized away when debugger is nil
  if vm.debugger != nil:
    vmDebuggerBeforeInstruction(vm)
    if vmDebuggerShouldBreak(vm):
      vmDebuggerOnBreak(vm)

  let instr = vm.program.instructions[vm.pc]
  vm.pc += 1

  # Fast jump table dispatch - single array lookup instead of case statement
  let handler = vm.jumpTable[instr.op]
  let continueExecution = handler(vm, instr)

  # Call debugger after instruction hook
  if vm.debugger != nil:
    vmDebuggerAfterInstruction(vm)

  return continueExecution

proc runBytecode*(vm: VM): int =
  ## Run the bytecode program. Returns exit code.
  try:
    # Initialize globals with stored values
    for globalName in vm.program.globals:
      if vm.program.globalValues.hasKey(globalName):
        let gv = vm.program.globalValues[globalName]
        case gv.kind
        of tkInt:
          vm.globals[globalName] = V(kind: tkInt, ival: gv.ival)
        of tkFloat:
          vm.globals[globalName] = V(kind: tkFloat, fval: gv.fval)
        of tkBool:
          vm.globals[globalName] = V(kind: tkBool, bval: gv.bval)
        of tkString:
          vm.globals[globalName] = V(kind: tkString, sval: gv.sval)
        of tkChar:
          vm.globals[globalName] = V(kind: tkChar, cval: gv.cval)
        else:
          vm.globals[globalName] = vInt(0)  # Default for unsupported types
      else:
        # For globals without pre-computed values, initialize with default
        # The runtime initialization code will set the correct values
        vm.globals[globalName] = vInt(0)  # Default initialization

    # Execute global initialization function if it exists
    if vm.program.functions.hasKey(GLOBAL_INIT_FUNC_NAME):
      vm.pc = vm.program.functions[GLOBAL_INIT_FUNC_NAME]
      while vm.executeInstruction():
        discard

    # Start execution from main function if it exists
    if vm.program.functions.hasKey(MAIN_FUNCTION_NAME):
      vm.pc = vm.program.functions[MAIN_FUNCTION_NAME]
    else:
      echo "No main function found"
      return 1

    # Execute main function
    while vm.executeInstruction():
      discard

    return 0
  except Exception as e:
    echo "Runtime error: ", e.msg
    if vm.program.sourceFile.len > 0 and vm.pc > 0 and vm.pc <= vm.program.instructions.len:
      let instr = vm.program.instructions[vm.pc - 1]
      if instr.debug.line > 0:
        echo "  at line ", instr.debug.line, " in ", instr.debug.sourceFile
    return 1

# Initialize the builtin function tables
proc initBuiltinTable(): array[BuiltinFuncId, BuiltinHandler] =
  ## Initialize fast builtin dispatch table
  result[bfPrint] = builtinPrint
  result[bfNew] = builtinNew
  result[bfDeref] = builtinDeref
  result[bfRand] = builtinRand
  result[bfSeed] = builtinSeed
  result[bfReadFile] = builtinReadFile
  result[bfParseInt] = builtinParseInt
  result[bfParseFloat] = builtinParseFloat
  result[bfParseBool] = builtinParseBool
  result[bfToString] = builtinToString
  result[bfIsSome] = builtinIsSome
  result[bfIsNone] = builtinIsNone
  result[bfIsOk] = builtinIsOk
  result[bfIsErr] = builtinIsErr

# Initialize the jump table with instruction handlers
proc initJumpTable(): array[OpCode, InstructionHandler] =
  ## Initialize the jump table for fast instruction dispatch
  result[opLoadInt] = opLoadIntImpl
  result[opLoadFloat] = opLoadFloatImpl
  result[opLoadString] = opLoadStringImpl
  result[opLoadChar] = opLoadCharImpl
  result[opLoadBool] = opLoadBoolImpl
  result[opLoadVar] = opLoadVarImpl
  result[opStoreVar] = opStoreVarImpl
  result[opLoadNil] = opLoadNilImpl
  result[opPop] = opPopImpl
  result[opDup] = opDupImpl
  result[opAdd] = opAddImpl
  result[opSub] = opSubImpl
  result[opMul] = opMulImpl
  result[opDiv] = opDivImpl
  result[opMod] = opModImpl
  result[opNeg] = opNegImpl
  result[opEq] = opEqImpl
  result[opNe] = opNeImpl
  result[opLt] = opLtImpl
  result[opLe] = opLeImpl
  result[opGt] = opGtImpl
  result[opGe] = opGeImpl
  result[opAnd] = opAndImpl
  result[opOr] = opOrImpl
  result[opNot] = opNotImpl
  result[opNewRef] = opNewRefImpl
  result[opDeref] = opDerefImpl
  result[opMakeArray] = opMakeArrayImpl
  result[opArrayGet] = opArrayGetImpl
  result[opArraySlice] = opArraySliceImpl
  result[opArrayLen] = opArrayLenImpl
  result[opCast] = opCastImpl
  result[opMakeOptionSome] = opMakeOptionSomeImpl
  result[opMakeOptionNone] = opMakeOptionNoneImpl
  result[opMakeResultOk] = opMakeResultOkImpl
  result[opMakeResultErr] = opMakeResultErrImpl
  result[opMatchValue] = opMatchValueImpl
  result[opExtractSome] = opExtractSomeImpl
  result[opExtractOk] = opExtractOkImpl
  result[opExtractErr] = opExtractErrImpl
  result[opMakeObject] = opMakeObjectImpl
  result[opObjectGet] = opObjectGetImpl
  result[opObjectSet] = opObjectSetImpl
  result[opJump] = opJumpImpl
  result[opJumpIfFalse] = opJumpIfFalseImpl
  result[opCall] = opCallImpl
  result[opReturn] = opReturnImpl
  # Fused instructions
  result[opLoadVarArrayGet] = opLoadVarArrayGetImpl
  result[opLoadIntAddVar] = opLoadIntAddVarImpl
  result[opLoadVarIntLt] = opLoadVarIntLtImpl
  result[opCallBuiltin] = opCallBuiltinImpl
  result[opCallCFFI] = opCallCFFIImpl

proc newBytecodeVM*(program: BytecodeProgram): VM =
  ## Create a new bytecode VM instance with initialized jump table and pre-allocated stacks
  VM(
    stack: newSeqOfCap[V](1024),      # Pre-allocate stack capacity for better performance
    heap: newSeqOfCap[HeapCell](256), # Pre-allocate heap capacity
    callStack: newSeqOfCap[Frame](64), # Pre-allocate call stack capacity
    program: program,
    pc: 0,
    globals: initTable[string, V](),
    jumpTable: initJumpTable(),       # Initialize jump table once at VM creation
    builtinTable: initBuiltinTable(), # Initialize builtin dispatch table
    debugger: nil  # No debugger by default - zero cost
  )

proc newBytecodeVMWithDebugger*(program: BytecodeProgram, debugger: EtchDebugger): VM =
  ## Create a new bytecode VM instance with debugger attached and pre-allocated stacks
  VM(
    stack: newSeqOfCap[V](1024),      # Pre-allocate stack capacity for better performance
    heap: newSeqOfCap[HeapCell](256), # Pre-allocate heap capacity
    callStack: newSeqOfCap[Frame](64), # Pre-allocate call stack capacity
    program: program,
    pc: 0,
    globals: initTable[string, V](),
    jumpTable: initJumpTable(),       # Initialize jump table once at VM creation
    debugger: debugger
  )

proc convertVMValueToGlobalValue*(val: V): GlobalValue =
  ## Convert a VM value to a GlobalValue for bytecode storage
  case val.kind
  of tkInt:
    GlobalValue(kind: tkInt, ival: val.ival)
  of tkFloat:
    GlobalValue(kind: tkFloat, fval: val.fval)
  of tkBool:
    GlobalValue(kind: tkBool, bval: val.bval)
  of tkString:
    GlobalValue(kind: tkString, sval: val.sval)
  of tkChar:
    GlobalValue(kind: tkChar, cval: val.cval)
  else:
    # Default for unsupported types
    GlobalValue(kind: tkInt, ival: 0)

proc evalExprWithBytecode*(prog: Program, expr: Expr, globals: Table[string, V] = initTable[string, V]()): V =
  ## Evaluate an expression using bytecode compilation and execution
  ## This reduces code duplication by using the same execution path as regular programs

  # Create a temporary bytecode program for expression evaluation
  var bytecodeProgram = BytecodeProgram(
    instructions: @[],
    constants: @[],
    functions: initTable[string, int](),
    globals: @[],
    globalValues: initTable[string, GlobalValue](),
    sourceFile: "",
    compilerFlags: CompilerFlags(),
    sourceHash: "",
    lineToInstructionMap: initTable[int, seq[int]](),
    functionInfo: initTable[string, FunctionInfo]()
  )

  # Add globals to the program
  for name, value in globals:
    if name notin bytecodeProgram.globals:
      bytecodeProgram.globals.add(name)
      bytecodeProgram.globalValues[name] = convertVMValueToGlobalValue(value)

  # Create compilation context
  var ctx = CompilationContext(
    currentFunction: "",
    localVars: @[],
    sourceFile: "",
    astProgram: prog
  )

  # First, compile all functions from the program so they're available for calls
  for name, funDecl in pairs(prog.funInstances):
    ctx.currentFunction = funDecl.name
    ctx.localVars = @[]

    # Add function parameters to local vars
    for param in funDecl.params:
      ctx.localVars.add(param.name)

    let startAddr = bytecodeProgram.instructions.len
    bytecodeProgram.functions[funDecl.name] = startAddr

    # Store function debug info for parameter handling
    var paramNames: seq[string] = @[]
    for param in funDecl.params:
      paramNames.add(param.name)
    bytecodeProgram.functionInfo[funDecl.name] = FunctionInfo(
      parameterNames: paramNames
    )

    # Compile function body
    for stmt in funDecl.body:
      compileStmt(bytecodeProgram, stmt, ctx)

    # Functions should end with opReturn, but make sure
    if bytecodeProgram.instructions.len == 0 or bytecodeProgram.instructions[^1].op != opReturn:
      # For void functions, push a dummy value
      if funDecl.ret.kind == tkVoid:
        emit(bytecodeProgram, opLoadInt, 0, ctx = ctx)
      emit(bytecodeProgram, opReturn, ctx = ctx)

  # Now compile the expression as a separate function
  ctx.currentFunction = "__eval_expr__"
  let exprAddr = bytecodeProgram.instructions.len
  bytecodeProgram.functions["__eval_expr__"] = exprAddr

  # Compile the expression
  compileExpr(bytecodeProgram, expr, ctx)

  # Add return instruction to get the result
  emit(bytecodeProgram, opReturn, ctx = ctx)

  # Create VM and execute
  var vm = newBytecodeVM(bytecodeProgram)

  # Set up globals in VM
  for name, value in globals:
    vm.globals[name] = value

  # Execute the expression function
  vm.pc = exprAddr
  try:
    while vm.executeInstruction():
      discard

    # Return the top stack value as result
    if vm.stack.len > 0:
      return vm.stack[^1]
    else:
      return vInt(0)  # Default value if no result
  except: # Exception as e:
    # Error in global evaluation - return default value silently
    # The actual error will be caught by the compiler's type checker
    return vInt(0)  # Default value on error
