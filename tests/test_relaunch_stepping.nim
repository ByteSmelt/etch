import std/[json, osproc]
import ../src/etch/interpreter/[regvm_serialize, regvm_debugserver]

proc getLocation(server: RegDebugServer): tuple[name: string, line: int, pc: int] =
  let stackResp = server.handleDebugRequest(%*{"seq": 999, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
  let frames = stackResp["body"]["stackFrames"].getElems()
  if frames.len > 0:
    result = (frames[0]["name"].getStr(), frames[0]["line"].getInt(), server.vm.currentFrame.pc)
  else:
    result = ("", 0, server.vm.currentFrame.pc)

# Compile the example
discard execProcess("./etch --compile examples/fn_order.etch")

# Load and create debug server
let prog = loadRegBytecode("examples/__etch__/fn_order.etcx")
let server = newRegDebugServer(prog, "examples/fn_order.etch")

echo "=== Test: Relaunch and Step Into ==="

# First launch
discard server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})
discard server.handleDebugRequest(%*{
  "seq": 2,
  "type": "request",
  "command": "launch",
  "arguments": {"stopOnEntry": true, "program": "examples/fn_order.etch"}
})

var loc = getLocation(server)
echo "\n1. First launch - Start: ", loc.name, " line ", loc.line, " (PC ", loc.pc, ")"

# Get to main
discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})
loc = getLocation(server)
echo "2. At main: ", loc.name, " line ", loc.line, " (PC ", loc.pc, ")"

# Step into test
discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
loc = getLocation(server)
echo "3. After step into: ", loc.name, " line ", loc.line, " (PC ", loc.pc, ")"
if loc.name == "test" and loc.line == 6:
  echo "   ✓ First launch: step into works"
else:
  echo "   ✗ First launch: step into FAILED"

# Now relaunch
echo "\n4. Relaunch..."
discard server.handleDebugRequest(%*{
  "seq": 6,
  "type": "request",
  "command": "launch",
  "arguments": {"stopOnEntry": true, "program": "examples/fn_order.etch"}
})
loc = getLocation(server)
echo "5. After relaunch - Start: ", loc.name, " line ", loc.line, " (PC ", loc.pc, ")"

# Get to main again
discard server.handleDebugRequest(%*{"seq": 7, "type": "request", "command": "next", "arguments": {"threadId": 1}})
discard server.handleDebugRequest(%*{"seq": 8, "type": "request", "command": "next", "arguments": {"threadId": 1}})
loc = getLocation(server)
echo "6. At main again: ", loc.name, " line ", loc.line, " (PC ", loc.pc, ")"

# Step into test again
discard server.handleDebugRequest(%*{"seq": 9, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
loc = getLocation(server)
echo "7. After second step into: ", loc.name, " line ", loc.line, " (PC ", loc.pc, ")"
if loc.name == "test" and loc.line == 6:
  echo "   ✓ After relaunch: step into works"
else:
  echo "   ✗ After relaunch: step into FAILED - got ", loc.name, " line ", loc.line
  echo "   This might be the bug!"
