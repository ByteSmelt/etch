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

# Initialize and launch
discard server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})
discard server.handleDebugRequest(%*{
  "seq": 2,
  "type": "request",
  "command": "launch",
  "arguments": {"stopOnEntry": true, "program": "examples/fn_order.etch"}
})

echo "=== Comprehensive Stepping Test ==="

var loc = getLocation(server)
echo "\n1. Start: ", loc.name, " line ", loc.line, " (PC ", loc.pc, ")"

# Step to main
discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})
loc = getLocation(server)
echo "2. After stepping through globals: ", loc.name, " line ", loc.line, " (PC ", loc.pc, ")"

# Step into test
echo "\n3. Step INTO from main line 2 (should enter test)"
discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
loc = getLocation(server)
echo "   Result: ", loc.name, " line ", loc.line, " (PC ", loc.pc, ")"
if loc.name != "test" or loc.line != 6:
  echo "   ✗ FAILED: Expected test line 6"
  quit(1)

# NOW - step OVER from inside test (user's scenario)
echo "\n4. Step OVER from test line 6 (should return to main line 2)"
discard server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "next", "arguments": {"threadId": 1}})
loc = getLocation(server)
echo "   Result: ", loc.name, " line ", loc.line, " (PC ", loc.pc, ")"
if loc.name != "main" or loc.line != 2:
  echo "   ✗ FAILED: Expected main line 2, got ", loc.name, " line ", loc.line
  echo "   This is the bug the user reported!"
  quit(1)
else:
  echo "   ✓ PASS: Correctly returned to main line 2"

# Reset for next test
echo "\n5. Reset and test step INTO from inside test"
discard server.handleDebugRequest(%*{
  "seq": 7,
  "type": "request",
  "command": "launch",
  "arguments": {"stopOnEntry": true, "program": "examples/fn_order.etch"}
})
discard server.handleDebugRequest(%*{"seq": 8, "type": "request", "command": "next", "arguments": {"threadId": 1}})
discard server.handleDebugRequest(%*{"seq": 9, "type": "request", "command": "next", "arguments": {"threadId": 1}})
discard server.handleDebugRequest(%*{"seq": 10, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
loc = getLocation(server)
echo "   Now in: ", loc.name, " line ", loc.line, " (PC ", loc.pc, ")"

echo "   Step INTO from test line 6 (should return to main line 2)"
discard server.handleDebugRequest(%*{"seq": 11, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
loc = getLocation(server)
echo "   Result: ", loc.name, " line ", loc.line, " (PC ", loc.pc, ")"
if loc.name != "main" or loc.line != 2:
  echo "   ✗ FAILED: Expected main line 2, got ", loc.name, " line ", loc.line
  quit(1)
else:
  echo "   ✓ PASS: Correctly returned to main line 2"

# Reset for step out test
echo "\n6. Reset and test step OUT from inside test"
discard server.handleDebugRequest(%*{
  "seq": 12,
  "type": "request",
  "command": "launch",
  "arguments": {"stopOnEntry": true, "program": "examples/fn_order.etch"}
})
discard server.handleDebugRequest(%*{"seq": 13, "type": "request", "command": "next", "arguments": {"threadId": 1}})
discard server.handleDebugRequest(%*{"seq": 14, "type": "request", "command": "next", "arguments": {"threadId": 1}})
discard server.handleDebugRequest(%*{"seq": 15, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
loc = getLocation(server)
echo "   Now in: ", loc.name, " line ", loc.line, " (PC ", loc.pc, ")"

echo "   Step OUT from test line 6 (should return to main line 2)"
discard server.handleDebugRequest(%*{"seq": 16, "type": "request", "command": "stepOut", "arguments": {"threadId": 1}})
loc = getLocation(server)
echo "   Result: ", loc.name, " line ", loc.line, " (PC ", loc.pc, ")"
if loc.name != "main" or loc.line != 2:
  echo "   ✗ FAILED: Expected main line 2, got ", loc.name, " line ", loc.line
  quit(1)
else:
  echo "   ✓ PASS: Correctly returned to main line 2"

echo "\n✓ ALL TESTS PASSED!"
echo "  - Step over from test returns to main line 2"
echo "  - Step into from test returns to main line 2"
echo "  - Step out from test returns to main line 2"
