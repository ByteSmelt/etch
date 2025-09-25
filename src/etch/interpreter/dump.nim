# dump.nim
# Enhanced bytecode dumping utilities for Etch programs

import std/[strutils, strformat, tables, sequtils, algorithm]
import bytecode, serialize, ../frontend/ast

proc alignRight*(s: string, width: int, fillChar: char = ' '): string =
  let padding = max(0, width - s.len)
  result = repeat(fillChar, padding) & s

proc alignLeft*(s: string, width: int, fillChar: char = ' '): string =
  let padding = max(0, width - s.len)
  result = s & repeat(fillChar, padding)

proc formatArgument*(instr: Instruction): string =
  if instr.sarg.len > 0:
    return &" \"{instr.sarg}\""
  elif instr.arg != 0:
    return &" {instr.arg}"
  else:
    return ""

proc formatDebugInfo*(debug: DebugInfo, showDetails: bool = true): string =
  if debug.line > 0:
    result = &"[{debug.sourceFile}:{debug.line}:{debug.col}]"
    if showDetails and debug.functionName.len > 0:
      result &= &" in {debug.functionName}()"
    if showDetails and debug.localVars.len > 0:
      result &= &" locals: {debug.localVars.join(\", \")}"
  else:
    result = ""

proc dumpConstants*(prog: BytecodeProgram) =
  echo ""
  echo "=== CONSTANTS TABLE ==="
  if prog.constants.len == 0:
    echo "  (no constants)"
  else:
    for i, constant in prog.constants:
      echo &"  [{i:3}] \"{constant}\""

proc dumpGlobals*(prog: BytecodeProgram) =
  echo ""
  echo "=== GLOBAL VARIABLES ==="
  if prog.globals.len == 0:
    echo "  (no globals)"
  else:
    for i, globalName in prog.globals:
      let value = if prog.globalValues.hasKey(globalName):
        let gval = prog.globalValues[globalName]
        case gval.kind
        of tkInt: $gval.ival
        of tkFloat: $gval.fval
        of tkBool: $gval.bval
        of tkString: &"\"{gval.sval}\""
        of tkChar: &"'{gval.cval}'"
        else: "(unknown)"
      else:
        "(undefined)"
      echo &"  [{i:3}] {globalName} = {value}"

proc dumpFunctions*(prog: BytecodeProgram) =
  echo ""
  echo "=== FUNCTIONS TABLE ==="
  if prog.functions.len == 0:
    echo "  (no functions)"
  else:
    type FuncEntry = tuple[name: string, address: int]
    var funcList: seq[FuncEntry] = @[]
    for name, address in prog.functions:
      funcList.add((name, address))
    funcList.sort(proc(a, b: FuncEntry): int = cmp(a.address, b.address))

    for i, funcTuple in funcList:
      let (name, address) = funcTuple
      let demangledName = demangleFunctionSignature(name)
      echo &"  [{i:3}] {demangledName} @ instruction {address}"

proc dumpLineMapping*(prog: BytecodeProgram) =
  echo ""
  echo "=== LINE TO INSTRUCTION MAPPING ==="
  if prog.lineToInstructionMap.len == 0:
    echo "  (no debug info)"
  else:
    var lines = toSeq(prog.lineToInstructionMap.keys)
    lines.sort()
    for line in lines:
      let instructions = prog.lineToInstructionMap[line]
      echo &"  Line {line:3}: instructions {instructions.join(\", \")}"

proc dumpInstructionsSummary*(prog: BytecodeProgram) =
  echo ""
  echo "=== INSTRUCTIONS SUMMARY ==="
  var opCounts = initTable[OpCode, int]()

  for instr in prog.instructions:
    if opCounts.hasKey(instr.op):
      opCounts[instr.op] += 1
    else:
      opCounts[instr.op] = 1

  var sortedOps: seq[tuple[op: OpCode, count: int]] = @[]
  for op, count in opCounts:
    sortedOps.add((op, count))
  sortedOps.sort(proc(a, b: tuple[op: OpCode, count: int]): int = cmp(b.count, a.count))

  for (op, count) in sortedOps:
    echo &"  {op} {count:4} times"

proc dumpInstructionsByFunctions*(prog: BytecodeProgram, showDebug: bool = true, maxInstructions: int = -1) =
  echo ""
  echo "=== BYTECODE INSTRUCTIONS BY FUNCTION ==="

  # Create a list of functions sorted by their address
  type FuncEntry = tuple[name: string, address: int]
  var funcList: seq[FuncEntry] = @[]
  for name, address in prog.functions:
    funcList.add((name, address))
  funcList.sort(proc(a, b: FuncEntry): int = cmp(a.address, b.address))

  # Add a synthetic entry for instructions after the last function (if any)
  let totalInstructions = prog.instructions.len
  let limit = if maxInstructions > 0: min(maxInstructions, totalInstructions) else: totalInstructions

  var currentIdx = 0
  for funcIdx, funcEntry in funcList:
    let (funcName, funcAddress) = funcEntry

    # Skip if we've reached the instruction limit
    if currentIdx >= limit:
      break

    # Print function header
    echo ""
    let demangledName = demangleFunctionSignature(funcName)
    echo &"--- Function: {demangledName} (starts at instruction {funcAddress}) ---"

    # Determine the end address for this function
    let nextFuncAddress = if funcIdx + 1 < funcList.len:
      funcList[funcIdx + 1].address
    else:
      totalInstructions

    # Print instructions for this function
    let funcStart = max(funcAddress, currentIdx)
    let funcEnd = min(nextFuncAddress, limit)

    if funcStart < funcEnd:
      for i in funcStart..<funcEnd:
        let instr = prog.instructions[i]
        let indexStr = ($i).alignRight(4)
        let opAndArg = $instr.op & formatArgument(instr)
        let opAndArgPadded = opAndArg.alignLeft(24)  # Left-align operands and args

        let debugStr = if showDebug:
          let debug = instr.debug
          if debug.line > 0:
            let fileInfo = &"[{debug.sourceFile}:{debug.line}:{debug.col}]"
            let localVarsInfo = if debug.localVars.len > 0:
              &" locals: {debug.localVars.join(\", \")}"
            else:
              ""
            fileInfo & localVarsInfo
          else:
            ""
        else:
          ""

        echo &"{indexStr}: {opAndArgPadded} {debugStr}"

    currentIdx = funcEnd

  # Handle any remaining instructions that don't belong to a function
  if currentIdx < limit:
    echo ""
    echo "--- Instructions outside functions ---"
    for i in currentIdx..<limit:
      let instr = prog.instructions[i]
      let indexStr = ($i).alignRight(4)
      let opAndArg = $instr.op & formatArgument(instr)
      let opAndArgPadded = opAndArg.alignLeft(24)

      let debugStr = if showDebug:
        let debug = instr.debug
        if debug.line > 0:
          let fileInfo = &"[{debug.sourceFile}:{debug.line}:{debug.col}]"
          let localVarsInfo = if debug.localVars.len > 0:
            &" locals: {debug.localVars.join(\", \")}"
          else:
            ""
          fileInfo & localVarsInfo
        else:
          ""
      else:
        ""

      echo &"{indexStr}: {opAndArgPadded} {debugStr}"

  if maxInstructions > 0 and totalInstructions > maxInstructions:
    echo &"... ({totalInstructions - maxInstructions} more instructions)"

proc dumpInstructionsDetailed*(prog: BytecodeProgram, showDebug: bool = true, maxInstructions: int = -1) =
  # Use the new function-grouped format
  dumpInstructionsByFunctions(prog, showDebug, maxInstructions)

proc dumpControlFlow*(prog: BytecodeProgram) =
  echo ""
  echo "=== CONTROL FLOW ANALYSIS ==="

  var jumpTargets = initTable[int, seq[int]]()

  for i, instr in prog.instructions:
    case instr.op
    of opJump, opJumpIfFalse:
      let target = int(instr.arg)
      if not jumpTargets.hasKey(target):
        jumpTargets[target] = @[]
      jumpTargets[target].add(i)
    of opCall:
      if prog.functions.hasKey(instr.sarg):
        let funcAddr = prog.functions[instr.sarg]
        if not jumpTargets.hasKey(funcAddr):
          jumpTargets[funcAddr] = @[]
        jumpTargets[funcAddr].add(i)
    else:
      discard

  if jumpTargets.len == 0:
    echo "  (no jumps or calls detected)"
  else:
    var targets = toSeq(jumpTargets.keys)
    targets.sort()
    for target in targets:
      let sources = jumpTargets[target]
      echo &"  Instruction {target:3} <- from {sources.join(\", \")}"

proc dumpBytecodeProgram*(prog: BytecodeProgram, sourceFile: string = "",
                         showConstants: bool = true, showGlobals: bool = true,
                         showFunctions: bool = true, showLineMapping: bool = true,
                         showSummary: bool = true, showDetailed: bool = true,
                         showControlFlow: bool = true, showDebug: bool = true,
                         maxInstructions: int = -1) =
  let fileName = if sourceFile.len > 0: sourceFile else: prog.sourceFile
  echo &"=== BYTECODE DUMP FOR: {fileName} ==="
  echo &"Instructions: {prog.instructions.len}"
  echo &"Constants: {prog.constants.len}"
  echo &"Functions: {prog.functions.len}"
  echo &"Globals: {prog.globals.len}"
  echo &"Source Hash: {prog.sourceHash}"
  echo &"Compiler Flags: verbose={prog.compilerFlags.verbose}, debug={prog.compilerFlags.debug}"

  if showConstants:
    dumpConstants(prog)

  if showGlobals:
    dumpGlobals(prog)

  if showFunctions:
    dumpFunctions(prog)

  if showLineMapping and prog.compilerFlags.debug:
    dumpLineMapping(prog)

  if showSummary:
    dumpInstructionsSummary(prog)

  if showControlFlow:
    dumpControlFlow(prog)

  if showDetailed:
    dumpInstructionsDetailed(prog, showDebug, maxInstructions)