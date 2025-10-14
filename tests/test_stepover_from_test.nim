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

echo "=== Test: Step OVER from inside test() ==="

# Get to main
echo "\n1. Get to main line 2"
discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})

# Step into test
echo "\n2. Step into test() to get to line 6"
discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "stepIn", "arguments": {"threadId": 1}})
let stackResp1 = server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
let frames1 = stackResp1["body"]["stackFrames"].getElems()
echo "   At: ", frames1[0]["name"].getStr(), " line ", frames1[0]["line"].getInt(), " (PC ", server.vm.currentFrame.pc, ")"

# NOW step OVER from inside test
echo "\n3. Step OVER from test line 6 (should skip line 2 and continue to completion)"
let stepResp = server.handleDebugRequest(%*{"seq": 7, "type": "request", "command": "next", "arguments": {"threadId": 1}})

# Check if the step command indicates program completion (running becomes false)
if not server.running:
  echo "   Result: Program completed execution"
  echo "\n✓ SUCCESS: Step over from test skipped line 2 and completed program"
else:
  # Check where we stopped
  let stackResp2 = server.handleDebugRequest(%*{"seq": 8, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
  let frames2 = stackResp2["body"]["stackFrames"].getElems()

  if frames2.len == 0:
    echo "   Result: No stack frames (program completed)"
    echo "\n✓ SUCCESS: Step over from test completed execution past line 2"
  else:
    echo "   Result: ", frames2[0]["name"].getStr(), " line ", frames2[0]["line"].getInt()
    # Should NOT be at line 2
    if frames2[0]["line"].getInt() == 2:
      echo "\n✗ FAILED: Still at line 2 after step over - should have skipped it!"
      quit(1)
    else:
      echo "\n✓ SUCCESS: Stepped past line 2 to line ", frames2[0]["line"].getInt()
