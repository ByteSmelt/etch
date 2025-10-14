import std/[json, osproc]
import ../src/etch/interpreter/[regvm_serialize, regvm_debugserver]

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

echo "=== Test: Stepping inside test() function ==="

# Get to main
discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})

# Step into test
echo "\n1. Step into test() - now at test line 6"
discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
var stackResp = server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
var frames = stackResp["body"]["stackFrames"].getElems()
echo "   PC: ", server.vm.currentFrame.pc
echo "   Stack: ", frames[0]["name"].getStr(), " line ", frames[0]["line"].getInt()

# Now try to step over (should complete the return statement and go back to main line 2)
echo "\n2. Step over from test() line 6 (executing return x + y)"
echo "   Before step - PC: ", server.vm.currentFrame.pc
discard server.handleDebugRequest(%*{"seq": 7, "type": "request", "command": "next", "arguments": {"threadId": 1}})
echo "   After step - PC: ", server.vm.currentFrame.pc

stackResp = server.handleDebugRequest(%*{"seq": 8, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
frames = stackResp["body"]["stackFrames"].getElems()
echo "   Stack: ", frames[0]["name"].getStr(), " line ", frames[0]["line"].getInt()

if frames[0]["name"].getStr() == "main" and frames[0]["line"].getInt() == 2:
  echo "\n✓ SUCCESS: Returned to main line 2"
else:
  echo "\n✗ FAILED: Expected main line 2, got ", frames[0]["name"].getStr(), " line ", frames[0]["line"].getInt()

# Now try step into when ALREADY inside test
echo "\n3. Test step into when already inside test() at line 6"
# First get into test
discard server.handleDebugRequest(%*{"seq": 15, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
stackResp = server.handleDebugRequest(%*{"seq": 16, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
frames = stackResp["body"]["stackFrames"].getElems()
echo "   In test at: ", frames[0]["name"].getStr(), " line ", frames[0]["line"].getInt()
echo "   Before step into - PC: ", server.vm.currentFrame.pc

# Now step into again (should execute through return and go back to main)
discard server.handleDebugRequest(%*{"seq": 17, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
echo "   After step into - PC: ", server.vm.currentFrame.pc

stackResp = server.handleDebugRequest(%*{"seq": 18, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
frames = stackResp["body"]["stackFrames"].getElems()
echo "   Stack: ", frames[0]["name"].getStr(), " line ", frames[0]["line"].getInt()

if frames[0]["name"].getStr() == "main" and frames[0]["line"].getInt() == 2:
  echo "\n✓ SUCCESS: Returned to main line 2 after step into from test"
else:
  echo "\n✗ FAILED: Expected main line 2, got ", frames[0]["name"].getStr(), " line ", frames[0]["line"].getInt()
