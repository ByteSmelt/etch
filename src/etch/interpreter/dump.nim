# dump.nim
# Enhanced bytecode dumping utilities for Etch programs

import std/[strutils, strformat, tables, sequtils, algorithm]
import bytecode, serialize, ../frontend/ast

proc alignRight*(s: string, width: int, fillChar: char = ' '): string =
  let padding = max(0, width - s.len)
  result = repeat(fillChar, padding) & s

proc formatOpCode*(op: OpCode): string =
  case op
  of opLoadInt: "LOAD_INT"
  of opLoadFloat: "LOAD_FLOAT"
  of opLoadString: "LOAD_STRING"
  of opLoadChar: "LOAD_CHAR"
  of opLoadBool: "LOAD_BOOL"
  of opLoadVar: "LOAD_VAR"
  of opStoreVar: "STORE_VAR"
  of opAdd: "ADD"
  of opSub: "SUB"
  of opMul: "MUL"
  of opDiv: "DIV"
  of opMod: "MOD"
  of opNeg: "NEG"
  of opNot: "NOT"
  of opEq: "EQ"
  of opNe: "NE"
  of opLt: "LT"
  of opLe: "LE"
  of opGt: "GT"
  of opGe: "GE"
  of opAnd: "AND"
  of opOr: "OR"
  of opJump: "JUMP"
  of opJumpIfFalse: "JUMP_IF_FALSE"
  of opCall: "CALL"
  of opReturn: "RETURN"
  of opPop: "POP"
  of opDup: "DUP"
  of opNewRef: "NEW_REF"
  of opDeref: "DEREF"
  of opMakeArray: "MAKE_ARRAY"
  of opArrayGet: "ARRAY_GET"
  of opArraySlice: "ARRAY_SLICE"
  of opArrayLen: "ARRAY_LEN"
  of opCast: "CAST"
  of opLoadNil: "LOAD_NIL"
  of opMakeOptionSome: "MAKE_OPTION_SOME"
  of opMakeOptionNone: "MAKE_OPTION_NONE"
  of opMakeResultOk: "MAKE_RESULT_OK"
  of opMakeResultErr: "MAKE_RESULT_ERR"
  of opMatchValue: "MATCH_VALUE"
  of opExtractSome: "EXTRACT_SOME"
  of opExtractOk: "EXTRACT_OK"
  of opExtractErr: "EXTRACT_ERR"

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
      let info = if prog.functionInfo.hasKey(name):
        let finfo = prog.functionInfo[name]
        if finfo.parameterNames.len > 0:
          &"({finfo.parameterNames.join(\", \")})"
        else:
          "()"
      else:
        "(unknown signature)"
      echo &"  [{i:3}] {name}{info} @ instruction {address}"

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
    echo &"  {formatOpCode(op):20} {count:4} times"

proc dumpInstructionsDetailed*(prog: BytecodeProgram, showDebug: bool = true, maxInstructions: int = -1) =
  echo ""
  echo "=== DETAILED INSTRUCTION LISTING ==="

  let limit = if maxInstructions > 0: min(maxInstructions, prog.instructions.len) else: prog.instructions.len

  for i in 0..<limit:
    let instr = prog.instructions[i]
    let indexStr = ($i).alignRight(4)
    let opStr = formatOpCode(instr.op).alignLeft(16)
    let argStr = formatArgument(instr)
    let debugStr = if showDebug: " " & formatDebugInfo(instr.debug, showDetails = true) else: ""

    echo &"{indexStr}: {opStr}{argStr}{debugStr}"

  if maxInstructions > 0 and prog.instructions.len > maxInstructions:
    echo &"... ({prog.instructions.len - maxInstructions} more instructions)"

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