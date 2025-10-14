import std/[json, osproc, tables]
import ../src/etch/interpreter/[regvm_serialize, regvm_debugserver]

# Compile the example
discard execProcess("./etch --compile examples/float_test.etch")

# Load and create debug server
let prog = loadRegBytecode("examples/__etch__/float_test.etcx")
let server = newRegDebugServer(prog, "examples/float_test.etch")

echo "=== Test: Variables Display ==="

# Initialize and launch
discard server.handleDebugRequest(%*{"seq": 1, "type": "request", "command": "initialize", "arguments": {}})
discard server.handleDebugRequest(%*{
  "seq": 2,
  "type": "request",
  "command": "launch",
  "arguments": {"stopOnEntry": true, "program": "examples/float_test.etch"}
})

# Step to main and then to first variable declaration
echo "\n1. Get to main and step to first variable"
discard server.handleDebugRequest(%*{"seq": 3, "type": "request", "command": "next", "arguments": {"threadId": 1}})
discard server.handleDebugRequest(%*{"seq": 4, "type": "request", "command": "next", "arguments": {"threadId": 1}})
discard server.handleDebugRequest(%*{"seq": 5, "type": "request", "command": "next", "arguments": {"threadId": 1}})

# Get stack trace to see where we are
let stackResp = server.handleDebugRequest(%*{"seq": 6, "type": "request", "command": "stackTrace", "arguments": {"threadId": 1}})
let frames = stackResp["body"]["stackFrames"].getElems()
echo "   Current position: ", frames[0]["name"].getStr(), " line ", frames[0]["line"].getInt()

# Get scopes
echo "\n2. Get scopes"
let scopesResp = server.handleDebugRequest(%*{"seq": 7, "type": "request", "command": "scopes", "arguments": {"frameId": 0}})
let scopes = scopesResp["body"]["scopes"].getElems()
echo "   Available scopes:"
for scope in scopes:
  echo "     - ", scope["name"].getStr(), " (ref=", scope["variablesReference"].getInt(), ")"

# Get local variables
echo "\n3. Get local variables (reference=1)"
let varsResp = server.handleDebugRequest(%*{"seq": 8, "type": "request", "command": "variables", "arguments": {"variablesReference": 1}})
let variables = varsResp["body"]["variables"].getElems()
echo "   Local variables count: ", variables.len
for variable in variables:
  echo "     - ", variable["name"].getStr(), " = ", variable["value"].getStr(), " (", variable["type"].getStr(), ")"

# Get global variables
echo "\n4. Get global variables (reference=2)"
let globalsResp = server.handleDebugRequest(%*{"seq": 9, "type": "request", "command": "variables", "arguments": {"variablesReference": 2}})
let globals = globalsResp["body"]["variables"].getElems()
echo "   Global variables count: ", globals.len
for global in globals:
  echo "     - ", global["name"].getStr(), " = ", global["value"].getStr(), " (", global["type"].getStr(), ")"
