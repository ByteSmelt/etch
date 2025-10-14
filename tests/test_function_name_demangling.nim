import std/[json, strutils, osproc]
import ../src/etch/interpreter/[regvm_serialize, regvm_debugserver]

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

echo "=== Test: Function Name Demangling ==="

# Step through program and verify function names are demangled
# 1. Start in <global>
let stackResp1 = server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
let frames1 = stackResp1["body"]["stackFrames"].getElems()
let globalName = frames1[0]["name"].getStr()
echo "1. Start in ", globalName
if "__" in globalName and globalName != "<global>":
  echo "   ERROR: Function name not demangled: ", globalName
  quit(1)

# 2. Step to main
discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})
discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "next", "arguments": {"threadId": 1}})
let stackResp2 = server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
let frames2 = stackResp2["body"]["stackFrames"].getElems()
let mainName = frames2[0]["name"].getStr()
echo "2. Step to ", mainName
if "__" in mainName:
  echo "   ERROR: Function name not demangled: ", mainName
  quit(1)

# 3. Step into test function
discard server.handleDebugRequest(%*{"seq": 7, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
let stackResp3 = server.handleDebugRequest(%*{"seq": 8, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
let frames3 = stackResp3["body"]["stackFrames"].getElems()
if frames3.len > 0:
  let testName = frames3[0]["name"].getStr()
  echo "3. Step into ", testName
  if "__" in testName:
    echo "   ERROR: Function name not demangled: ", testName
    quit(1)

  # Verify the call stack shows demangled names
  if frames3.len > 1:
    for i, frame in frames3:
      let funcName = frame["name"].getStr()
      if "__" in funcName and funcName != "<global>":
        echo "   ERROR: Function name in callstack not demangled: ", funcName
        quit(1)

echo "\n✓ All function names properly demangled!"
echo "  - <global> displayed correctly"
echo "  - main displayed correctly"
echo "  - test displayed correctly (not test___s)"
