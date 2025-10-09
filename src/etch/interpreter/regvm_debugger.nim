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
  ## Create a new register-based debugger instance
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
  ## Add a breakpoint at the specified file and line
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
  ## Remove breakpoint at the specified file and line
  if debugger.breakpoints.hasKey(file):
    debugger.breakpoints[file].keepItIf(it.line != line)

proc hasBreakpoint*(debugger: RegEtchDebugger, file: string, line: int): bool =
  ## Check if there's an enabled breakpoint at the specified location
  if not debugger.breakpoints.hasKey(file):
    return false

  for bp in debugger.breakpoints[file]:
    if bp.line == line and bp.enabled:
      return true
  return false

# Note: formatRegisterValue and captureRegisters are moved to regvm_exec.nim
# to avoid circular dependencies. They require access to V type internals.

proc pushStackFrame*(debugger: RegEtchDebugger, functionName: string, fileName: string,
                     line: int, isBuiltIn: bool = false) =
  ## Push a new stack frame for function call tracking
  var frame = RegDebugStackFrame(
    functionName: functionName,
    fileName: fileName,
    line: line,
    isBuiltIn: isBuiltIn,
    registers: @[],  # Will be populated by VM when needed
    varToReg: initTable[string, uint8]()
  )

  debugger.stackFrames.add(frame)

  # Only count user-defined functions for step depth tracking
  if not isBuiltIn:
    debugger.userCallDepth += 1

proc popStackFrame*(debugger: RegEtchDebugger) =
  ## Pop the top stack frame
  if debugger.stackFrames.len > 0:
    let frame = debugger.stackFrames.pop()
    if not frame.isBuiltIn:
      debugger.userCallDepth -= 1

proc getCurrentStackFrame*(debugger: RegEtchDebugger): RegDebugStackFrame =
  ## Get the current (top) stack frame
  if debugger.stackFrames.len > 0:
    return debugger.stackFrames[^1]
  else:
    # Return main frame if no frames exist
    return RegDebugStackFrame(
      functionName: MAIN_FUNCTION_NAME,
      fileName: "",
      line: 0,
      isBuiltIn: false,
      registers: @[],  # Will be populated by VM when needed
      varToReg: initTable[string, uint8]()
    )

proc updateStackFrameRegisters*(debugger: RegEtchDebugger, registers: seq[tuple[index: uint8, value: string]]) =
  ## Update register snapshot in the current stack frame
  if debugger.stackFrames.len > 0:
    debugger.stackFrames[^1].registers = registers

proc step*(debugger: RegEtchDebugger, mode: StepMode) =
  ## Set up step operation
  debugger.stepMode = mode
  debugger.stepCallDepth = debugger.userCallDepth  # Use user call depth only
  debugger.paused = false

proc continueExecution*(debugger: RegEtchDebugger) =
  ## Continue execution
  debugger.stepMode = smContinue
  debugger.paused = false

proc pause*(debugger: RegEtchDebugger) =
  ## Pause execution
  debugger.paused = true

proc shouldBreak*(debugger: RegEtchDebugger, pc: int, file: string, line: int): bool =
  ## Check if execution should break at the current position

  # Update current position
  debugger.currentPC = pc

  # Check for breakpoints
  if debugger.hasBreakpoint(file, line):
    return true

  # Check for step operations
  case debugger.stepMode
  of smContinue:
    return false

  of smStepInto:
    # Break on every NEW line (skip multiple instructions on same line)
    if line > 0 and (file != debugger.lastFile or line != debugger.lastLine):
      return true

  of smStepOver:
    # Break if we're at the same depth or shallower AND at a different line
    if debugger.userCallDepth <= debugger.stepCallDepth:
      # Debug output
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
    # Break when we return to a shallower depth
    if debugger.userCallDepth < debugger.stepCallDepth and line > 0:
      return true

  return false

proc attachToVM*(debugger: RegEtchDebugger, vm: pointer) =
  ## Attach the debugger to a register-based VM
  debugger.vm = vm

# Note: The following functions are moved to regvm_exec.nim where they have
# access to VM internals:
# - getRegisterValue
# - setRegisterValue
# - inspectRegisters
# - inspectConstants
# - inspectGlobals
# - getCurrentInstruction

# Note: formatInstruction is also moved to regvm_exec.nim where RegInstruction is defined

proc getCallStack*(debugger: RegEtchDebugger): seq[string] =
  ## Get formatted call stack for display
  result = @[]
  for frame in debugger.stackFrames:
    var line = frame.functionName
    if frame.fileName != "":
      line &= " at " & frame.fileName & ":" & $frame.line
    if frame.isBuiltIn:
      line &= " [builtin]"
    result.add(line)

# Debug event helpers
proc sendDebugEvent*(debugger: RegEtchDebugger, event: string, data: JsonNode) =
  ## Send a debug event to the debug adapter
  if debugger.onDebugEvent != nil:
    debugger.onDebugEvent(event, data)

proc sendBreakpointHit*(debugger: RegEtchDebugger, file: string, line: int) =
  ## Notify that a breakpoint was hit
  let data = %*{
    "file": file,
    "line": line,
    "pc": debugger.currentPC,
    "callStack": debugger.getCallStack()
  }
  debugger.sendDebugEvent("breakpoint", data)

proc sendStepComplete*(debugger: RegEtchDebugger, file: string, line: int) =
  ## Notify that a step operation completed
  let data = %*{
    "file": file,
    "line": line,
    "pc": debugger.currentPC,
    "callStack": debugger.getCallStack(),
    "mode": $debugger.stepMode
  }
  debugger.sendDebugEvent("step", data)