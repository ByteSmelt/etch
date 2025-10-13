# regvm_debugger.nim
# Debugger implementation for register-based VM

import std/[tables, json, options, sequtils]
import ../common/constants

type
  StepMode* = enum
    smContinue,     # Continue execution
    smStepInto,     # Step into function calls
    smStepOver,     # Step over function calls
    smStepOut       # Step out of current function

  Breakpoint* = object
    file*: string
    line*: int
    enabled*: bool
    condition*: Option[string]

  # Register-based debug stack frame
  RegDebugStackFrame* = object
    functionName*: string
    fileName*: string
    line*: int
    isBuiltIn*: bool
    # Register snapshot for this frame
    registers*: seq[tuple[index: uint8, value: string]]  # Only non-nil registers
    # Local variable mapping (name -> register index)
    varToReg*: Table[string, uint8]

  RegEtchDebugger* = ref object
    # Breakpoint management
    breakpoints*: Table[string, seq[Breakpoint]]  # file -> breakpoints

    # Stack frame tracking for register frames
    stackFrames*: seq[RegDebugStackFrame]

    # Execution control
    stepMode*: StepMode
    stepTarget*: int        # Target instruction for step operations
    userCallDepth*: int     # Depth of user-defined function calls only
    stepCallDepth*: int     # User call depth when step was initiated

    # State
    paused*: bool
    lastFile*: string
    lastLine*: int
    currentPC*: int         # Current program counter

    # Event callback for communication with debug adapter
    onDebugEvent*: proc(event: string, data: JsonNode) {.gcsafe.}

    # Reference to the VM for inspection (kept as pointer to avoid circular deps)
    vm*: pointer  # Will be cast to RegisterVM* in regvm_exec

proc newRegEtchDebugger*(): RegEtchDebugger =
  RegEtchDebugger(
    breakpoints: initTable[string, seq[Breakpoint]](),
    stackFrames: @[],
    stepMode: smContinue,
    stepTarget: -1,
    userCallDepth: 0,
    stepCallDepth: 0,
    paused: false,
    lastFile: "",
    lastLine: 0,
    currentPC: 0,
    onDebugEvent: nil,
    vm: nil
  )

proc addBreakpoint*(debugger: RegEtchDebugger, file: string, line: int, condition: Option[string] = none(string)) =
  let breakpoint = Breakpoint(
    file: file,
    line: line,
    enabled: true,
    condition: condition
  )

  if not debugger.breakpoints.hasKey(file):
    debugger.breakpoints[file] = @[]
  debugger.breakpoints[file].add(breakpoint)

proc removeBreakpoint*(debugger: RegEtchDebugger, file: string, line: int) =
  if debugger.breakpoints.hasKey(file):
    debugger.breakpoints[file].keepItIf(it.line != line)

proc hasBreakpoint*(debugger: RegEtchDebugger, file: string, line: int): bool =
  if not debugger.breakpoints.hasKey(file):
    return false
  for bp in debugger.breakpoints[file]:
    if bp.line == line and bp.enabled:
      return true
  return false

proc pushStackFrame*(debugger: RegEtchDebugger, functionName: string, fileName: string,
                     line: int, isBuiltIn: bool = false) =
  var frame = RegDebugStackFrame(
    functionName: functionName,
    fileName: fileName,
    line: line,
    isBuiltIn: isBuiltIn,
    registers: @[],
    varToReg: initTable[string, uint8]()
  )

  debugger.stackFrames.add(frame)

  if not isBuiltIn:
    debugger.userCallDepth += 1

proc popStackFrame*(debugger: RegEtchDebugger) =
  if debugger.stackFrames.len > 0:
    let frame = debugger.stackFrames.pop()
    if not frame.isBuiltIn:
      debugger.userCallDepth -= 1

proc getCurrentStackFrame*(debugger: RegEtchDebugger): RegDebugStackFrame =
  if debugger.stackFrames.len > 0:
    return debugger.stackFrames[^1]
  else:
    return RegDebugStackFrame(
      functionName: MAIN_FUNCTION_NAME,
      fileName: "",
      line: 0,
      isBuiltIn: false,
      registers: @[],
      varToReg: initTable[string, uint8]()
    )

proc updateStackFrameRegisters*(debugger: RegEtchDebugger, registers: seq[tuple[index: uint8, value: string]]) =
  if debugger.stackFrames.len > 0:
    debugger.stackFrames[^1].registers = registers

proc step*(debugger: RegEtchDebugger, mode: StepMode) =
  debugger.stepMode = mode
  debugger.stepCallDepth = debugger.userCallDepth
  debugger.paused = false

proc continueExecution*(debugger: RegEtchDebugger) =
  debugger.stepMode = smContinue
  debugger.paused = false

proc pause*(debugger: RegEtchDebugger) =
  debugger.paused = true

proc shouldBreak*(debugger: RegEtchDebugger, pc: int, file: string, line: int): bool =
  debugger.currentPC = pc
  if debugger.hasBreakpoint(file, line):
    return true

  case debugger.stepMode
  of smContinue:
    return false

  of smStepInto:
    if line > 0 and (file != debugger.lastFile or line != debugger.lastLine):
      return true

  of smStepOver:
    if debugger.userCallDepth <= debugger.stepCallDepth:
      stderr.writeLine("DEBUG shouldBreak StepOver: depth=" & $debugger.userCallDepth &
                       " stepDepth=" & $debugger.stepCallDepth &
                       " file=" & file & " line=" & $line &
                       " lastFile=" & debugger.lastFile & " lastLine=" & $debugger.lastLine)
      stderr.flushFile()

      if line > 0 and (file != debugger.lastFile or line != debugger.lastLine):
        stderr.writeLine("DEBUG shouldBreak: BREAKING at line " & $line)
        stderr.flushFile()
        return true

  of smStepOut:
    if debugger.userCallDepth < debugger.stepCallDepth and line > 0:
      return true

  return false

proc attachToVM*(debugger: RegEtchDebugger, vm: pointer) =
  debugger.vm = vm

proc getCallStack*(debugger: RegEtchDebugger): seq[string] =
  result = @[]
  for frame in debugger.stackFrames:
    var line = frame.functionName
    if frame.fileName != "":
      line &= " at " & frame.fileName & ":" & $frame.line
    if frame.isBuiltIn:
      line &= " [builtin]"
    result.add(line)

proc sendDebugEvent*(debugger: RegEtchDebugger, event: string, data: JsonNode) =
  if debugger.onDebugEvent != nil:
    debugger.onDebugEvent(event, data)

proc sendBreakpointHit*(debugger: RegEtchDebugger, file: string, line: int) =
  let data = %*{
    "file": file,
    "line": line,
    "pc": debugger.currentPC,
    "callStack": debugger.getCallStack()
  }
  debugger.sendDebugEvent("breakpoint", data)

proc sendStepComplete*(debugger: RegEtchDebugger, file: string, line: int) =
  let data = %*{
    "file": file,
    "line": line,
    "pc": debugger.currentPC,
    "callStack": debugger.getCallStack(),
    "mode": $debugger.stepMode
  }
  debugger.sendDebugEvent("step", data)
