import std/[json, strutils, osproc, tables]
import ../src/etch/interpreter/[regvm, regvm_serialize, regvm_debugserver]

# Compile the example
echo "=== Compiling fn_order.etch ==="
discard execProcess("./etch --compile examples/fn_order.etch")

# Load and create debug server
let prog = loadRegBytecode("examples/__etch__/fn_order.etcx")
let server = newRegDebugServer(prog, "examples/fn_order.etch")

echo "\n=== Program Structure ==="
echo "Entry point: ", prog.entryPoint
echo "Functions:"
for name, info in prog.functions:
  echo "  ", name, " at PC ", info.startPos, "..", info.endPos

# Initialize
echo "\n=== Initialize Request ==="
let initReq = %*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}}
discard server.handleDebugRequest(initReq)

# Launch with stopOnEntry
echo "\n=== Launch Request ==="
let launchReq = %*{
  "seq": 2,
  "type": "request",
  "command": "launch",
  "arguments": {
    "stopOnEntry": true,
    "program": "examples/fn_order.etch"
  }
}
let launchResp = server.handleDebugRequest(launchReq)
echo "Launch success: ", launchResp["success"].getBool()

# Get initial stack trace
echo "\n=== Initial Stack Trace ==="
let stackReq1 = %*{"seq": 3, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}}
let stackResp1 = server.handleDebugRequest(stackReq1)
let frames1 = stackResp1["body"]["stackFrames"].getElems()
echo "Stack depth: ", frames1.len
for i, frame in frames1:
  echo "  [", i, "] ", frame["name"].getStr(), " at line ", frame["line"].getInt()

# Step (next)
echo "\n=== Step 1 (next) ==="
let nextReq1 = %*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}}
discard server.handleDebugRequest(nextReq1)

let stackReq2 = %*{"seq": 5, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}}
let stackResp2 = server.handleDebugRequest(stackReq2)
let frames2 = stackResp2["body"]["stackFrames"].getElems()
echo "Stack depth: ", frames2.len
for i, frame in frames2:
  echo "  [", i, "] ", frame["name"].getStr(), " at line ", frame["line"].getInt()

# Step (next) again
echo "\n=== Step 2 (next) ==="
let nextReq2 = %*{"seq": 6, "type": "request", "command": "next", "arguments": {"threadId": 1}}
discard server.handleDebugRequest(nextReq2)

let stackReq3 = %*{"seq": 7, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}}
let stackResp3 = server.handleDebugRequest(stackReq3)
let frames3 = stackResp3["body"]["stackFrames"].getElems()
echo "Stack depth: ", frames3.len
for i, frame in frames3:
  echo "  [", i, "] ", frame["name"].getStr(), " at line ", frame["line"].getInt()

# Step (next) again
echo "\n=== Step 3 (next) ==="
let nextReq3 = %*{"seq": 8, "type": "request", "command": "next", "arguments": {"threadId": 1}}
discard server.handleDebugRequest(nextReq3)

let stackReq4 = %*{"seq": 9, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}}
let stackResp4 = server.handleDebugRequest(stackReq4)
let frames4 = stackResp4["body"]["stackFrames"].getElems()
echo "Stack depth: ", frames4.len
for i, frame in frames4:
  echo "  [", i, "] ", frame["name"].getStr(), " at line ", frame["line"].getInt()

echo "\n=== Done ==="
