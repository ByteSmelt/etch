import std/[json, strutils, osproc]
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

echo "=== Test: Step Out from test() function ==="

# Step to main
echo "\n1. Step over global vars to reach main"
discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})
let stackResp1 = server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
let frames1 = stackResp1["body"]["stackFrames"].getElems()
echo "   At: ", frames1[0]["name"].getStr(), " line ", frames1[0]["line"].getInt()

# Step into test
echo "\n2. Step into test() function"
discard server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
let stackResp2 = server.handleDebugRequest(%*{"seq": 7, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
let frames2 = stackResp2["body"]["stackFrames"].getElems()
echo "   Stack depth: ", frames2.len
for i, frame in frames2:
  echo "   [", i, "] ", frame["name"].getStr(), " line ", frame["line"].getInt()

# Step out back to main
echo "\n3. Step out from test() back to main"
discard server.handleDebugRequest(%*{"seq": 8, "type": "request", "command": "stepOut", "arguments": {"threadId": 1}})
let stackResp3 = server.handleDebugRequest(%*{"seq": 9, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
let frames3 = stackResp3["body"]["stackFrames"].getElems()
echo "   Stack depth: ", frames3.len
for i, frame in frames3:
  echo "   [", i, "] ", frame["name"].getStr(), " line ", frame["line"].getInt()

# Verify we're back in main at line 2
if frames3.len > 0:
  let funcName = frames3[0]["name"].getStr()
  let line = frames3[0]["line"].getInt()
  if funcName == "main" and line == 2:
    echo "\n✓ SUCCESS: Stepped out to main line 2"
  else:
    echo "\n✗ FAILED: Expected main line 2, got ", funcName, " line ", line
    quit(1)
else:
  echo "\n✗ FAILED: No stack frames after step out"
  quit(1)
