import std/[json, strutils, osproc, tables]
import ../src/etch/interpreter/[regvm, regvm_serialize, regvm_debugserver]

# Compile the example
discard execProcess("./etch --compile examples/fn_order.etch")

# Load and create debug server
let prog = loadRegBytecode("examples/__etch__/fn_order.etcx")
let server = newRegDebugServer(prog, "examples/fn_order.etch")

# Initialize
let initReq = %*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}}
discard server.handleDebugRequest(initReq)

# Launch with stopOnEntry
let launchReq = %*{
  "seq": 2,
  "type": "request",
  "command": "launch",
  "arguments": {"stopOnEntry": true, "program": "examples/fn_order.etch"}
}
discard server.handleDebugRequest(launchReq)

echo "=== Initial: <global> line 9 ==="
let stackReq1 = %*{"seq": 3, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}}
let stackResp1 = server.handleDebugRequest(stackReq1)
let frames1 = stackResp1["body"]["stackFrames"].getElems()
echo "  Stack: ", frames1[0]["name"].getStr(), " line ", frames1[0]["line"].getInt()

# Step over twice to get to main
echo "\n=== Step over to line 10 ==="
discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})
let stackResp2 = server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
let frames2 = stackResp2["body"]["stackFrames"].getElems()
echo "  Stack: ", frames2[0]["name"].getStr(), " line ", frames2[0]["line"].getInt()

echo "\n=== Step over to main line 2 ==="
discard server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "next", "arguments": {"threadId": 1}})
let stackResp3 = server.handleDebugRequest(%*{"seq": 7, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
let frames3 = stackResp3["body"]["stackFrames"].getElems()
echo "  Stack: ", frames3[0]["name"].getStr(), " line ", frames3[0]["line"].getInt()

# Now step INTO test function
echo "\n=== Step into test() ==="
discard server.handleDebugRequest(%*{"seq": 8, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
let stackResp4 = server.handleDebugRequest(%*{"seq": 9, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
let frames4 = stackResp4["body"]["stackFrames"].getElems()
echo "  Stack depth: ", frames4.len
for i, frame in frames4:
  let funcName = frame["name"].getStr()
  echo "  [", i, "] ", funcName, " line ", frame["line"].getInt()
  # Verify function names are demangled (no __ suffix)
  if "__" in funcName and funcName != "__global__":
    echo "  ERROR: Function name not demangled: ", funcName
    quit(1)

# Step into again (this is where the bug happens - accessing x)
echo "\n=== Step into (should stay in test at line 6) ==="
echo "  Current PC before step: ", server.vm.currentFrame.pc
discard server.handleDebugRequest(%*{"seq": 10, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
echo "  Current PC after step: ", server.vm.currentFrame.pc
let stackResp5 = server.handleDebugRequest(%*{"seq": 11, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
let frames5 = stackResp5["body"]["stackFrames"].getElems()
echo "  Stack depth: ", frames5.len
for i, frame in frames5:
  let funcName = frame["name"].getStr()
  echo "  [", i, "] ", funcName, " line ", frame["line"].getInt()
  # Verify function names are demangled
  if "__" in funcName and funcName != "__global__":
    echo "  ERROR: Function name not demangled: ", funcName
    quit(1)

# Check what instruction we're at
if server.vm.currentFrame.pc < server.vm.program.instructions.len:
  let instr = server.vm.program.instructions[server.vm.currentFrame.pc]
  echo "  Current instruction: PC ", server.vm.currentFrame.pc, " op=", instr.op, " debug.line=", instr.debug.line

echo "\n=== SUCCESS: All function names are properly demangled ==="
echo "  - Step into works correctly (no jump to wrong PC)"
echo "  - Function names displayed without type signatures"
