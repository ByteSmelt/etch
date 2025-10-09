# test_debugger.nim
# Tests for the register VM debugger with DAP protocol

import std/[unittest, json, osproc, streams, os, strutils]

suite "Register VM Debugger":
  test "Debug server responds to DAP protocol":
    # Create a simple test program
    let testProgram = getTempDir() / "test_debug.etch"
    writeFile(testProgram, """
fn main() -> void {
    var x: int = 1;
    var y: int = 2;
    var z: int = x + y;
    print(z);
}
""")

    # Start debug server as a subprocess
    let process = startProcess("./src/etch.out", args = ["--debug-server", testProgram],
                              options = {poStdErrToStdOut})
    defer:
      process.terminate()
      process.close()
      removeFile(testProgram)

    # Helper to send request and get response
    proc sendRequest(p: Process, request: JsonNode): JsonNode =
      p.inputStream.writeLine($request)
      p.inputStream.flush()

      # Read responses until we get one matching our request
      var line: string
      for i in 0..10:  # Try up to 10 lines
        if p.outputStream.readLine(line):
          if line.len > 0:
            let response = parseJson(line)
            if response.hasKey("type") and response["type"].getStr() == "response":
              if response.hasKey("request_seq") and response["request_seq"].getInt() == request["seq"].getInt():
                return response
        else:
          break
      return %*{"error": "No response received"}

    # Test initialize request
    let initReq = %*{
      "seq": 1,
      "type": "request",
      "command": "initialize",
      "arguments": {
        "clientID": "test",
        "adapterID": "etch"
      }
    }
    let initResp = sendRequest(process, initReq)
    check initResp.hasKey("success")
    check initResp["success"].getBool() == true
    check initResp.hasKey("body")
    check initResp["body"].hasKey("supportsStepInRequest")

    # Test launch request with stopOnEntry
    let launchReq = %*{
      "seq": 2,
      "type": "request",
      "command": "launch",
      "arguments": {
        "program": testProgram,
        "stopOnEntry": true
      }
    }
    let launchResp = sendRequest(process, launchReq)
    check launchResp["success"].getBool() == true

    # Read the stopped event
    var stoppedEvent: JsonNode
    for i in 0..5:
      var line: string
      if process.outputStream.readLine(line) and line.len > 0:
        let msg = parseJson(line)
        if msg.hasKey("event") and msg["event"].getStr() == "stopped":
          stoppedEvent = msg
          break

    check stoppedEvent != nil
    check stoppedEvent["body"]["reason"].getStr() == "entry"

    # Test threads request
    let threadsReq = %*{
      "seq": 3,
      "type": "request",
      "command": "threads",
      "arguments": {}
    }
    let threadsResp = sendRequest(process, threadsReq)
    check threadsResp["success"].getBool() == true
    check threadsResp["body"]["threads"].len == 1
    check threadsResp["body"]["threads"][0]["name"].getStr() == "main"

    # Test scopes request
    let scopesReq = %*{
      "seq": 4,
      "type": "request",
      "command": "scopes",
      "arguments": {"frameId": 0}
    }
    let scopesResp = sendRequest(process, scopesReq)
    check scopesResp["success"].getBool() == true
    check scopesResp["body"]["scopes"].len >= 1
    check scopesResp["body"]["scopes"][0]["name"].getStr() == "Local Variables"

    # Test variables request
    let varsReq = %*{
      "seq": 5,
      "type": "request",
      "command": "variables",
      "arguments": {"variablesReference": 1}
    }
    let varsResp = sendRequest(process, varsReq)
    check varsResp["success"].getBool() == true
    check varsResp["body"]["variables"].len == 3  # x, y, z

    # Verify initial values (all should be 0)
    for v in varsResp["body"]["variables"]:
      check v["value"].getStr() == "0"

    # Test stepping
    let nextReq = %*{
      "seq": 6,
      "type": "request",
      "command": "next",
      "arguments": {"threadId": 1}
    }
    let nextResp = sendRequest(process, nextReq)
    check nextResp["success"].getBool() == true

    # Read stopped event after step
    for i in 0..5:
      var line: string
      if process.outputStream.readLine(line) and line.len > 0:
        let msg = parseJson(line)
        if msg.hasKey("event") and msg["event"].getStr() == "stopped":
          check msg["body"]["reason"].getStr() == "step"
          break

    # Check variables after first step (x should be 1)
    let varsReq2 = %*{
      "seq": 7,
      "type": "request",
      "command": "variables",
      "arguments": {"variablesReference": 1}
    }
    let varsResp2 = sendRequest(process, varsReq2)
    check varsResp2["success"].getBool() == true

    # Find x in the variables
    var foundX = false
    for v in varsResp2["body"]["variables"]:
      if v["name"].getStr() == "x":
        check v["value"].getStr() == "1"
        foundX = true
        break
    check foundX

    # Test disconnect
    let disconnectReq = %*{
      "seq": 8,
      "type": "request",
      "command": "disconnect",
      "arguments": {}
    }
    let disconnectResp = sendRequest(process, disconnectReq)
    check disconnectResp["success"].getBool() == true

  test "Debugger tracks line numbers correctly":
    # Create test program with known line numbers
    let testProgram = getTempDir() / "test_lines.etch"
    writeFile(testProgram, """
fn main() -> void {
    var a: int = 10;
    var b: int = 20;
    var c: int = a + b;
}
""")

    let process = startProcess("./src/etch.out", args = ["--debug-server", testProgram],
                              options = {poStdErrToStdOut})
    defer:
      process.terminate()
      process.close()
      removeFile(testProgram)

    # Initialize and launch
    process.inputStream.writeLine($ %*{
      "seq": 1,
      "type": "request",
      "command": "initialize",
      "arguments": {"clientID": "test", "adapterID": "etch"}
    })
    process.inputStream.flush()

    process.inputStream.writeLine($ %*{
      "seq": 2,
      "type": "request",
      "command": "launch",
      "arguments": {"program": testProgram, "stopOnEntry": true}
    })
    process.inputStream.flush()

    # Get stack trace to check line number
    process.inputStream.writeLine($ %*{
      "seq": 3,
      "type": "request",
      "command": "stackTrace",
      "arguments": {"threadId": 1}
    })
    process.inputStream.flush()

    # Read responses until we get stackTrace
    var stackResp: JsonNode
    for i in 0..10:
      var line: string
      if process.outputStream.readLine(line) and line.len > 0:
        let msg = parseJson(line)
        if msg.hasKey("command") and msg["command"].getStr() == "stackTrace":
          stackResp = msg
          break

    check stackResp != nil
    check stackResp["body"]["stackFrames"].len > 0
    check stackResp["body"]["stackFrames"][0]["line"].getInt() == 2  # Should start at line 2 (first line inside main)

    # Step and check line advances
    process.inputStream.writeLine($ %*{
      "seq": 4,
      "type": "request",
      "command": "next",
      "arguments": {"threadId": 1}
    })
    process.inputStream.flush()

    # Get new stack trace
    process.inputStream.writeLine($ %*{
      "seq": 5,
      "type": "request",
      "command": "stackTrace",
      "arguments": {"threadId": 1}
    })
    process.inputStream.flush()

    # Read responses until we get the second stackTrace
    for i in 0..15:
      var line: string
      if process.outputStream.readLine(line) and line.len > 0:
        let msg = parseJson(line)
        if msg.hasKey("command") and msg["command"].getStr() == "stackTrace":
          if msg.hasKey("request_seq") and msg["request_seq"].getInt() == 5:
            check msg["body"]["stackFrames"][0]["line"].getInt() == 3  # Should be at line 3 now
            break

    # Disconnect
    process.inputStream.writeLine($ %*{
      "seq": 6,
      "type": "request",
      "command": "disconnect",
      "arguments": {}
    })
    process.inputStream.flush()

  test "Breakpoint functionality":
    let testProgram = getTempDir() / "test_breakpoint.etch"
    writeFile(testProgram, """
fn main() -> void {
    var x: int = 1;
    var y: int = 2;
    var z: int = 3;
    print(x);
    print(y);
    print(z);
}
""")

    let process = startProcess("./src/etch.out", args = ["--debug-server", testProgram],
                              options = {poStdErrToStdOut})
    defer:
      process.terminate()
      process.close()
      removeFile(testProgram)

    # Initialize
    process.inputStream.writeLine($ %*{
      "seq": 1,
      "type": "request",
      "command": "initialize",
      "arguments": {"clientID": "test", "adapterID": "etch"}
    })
    process.inputStream.flush()

    # Set breakpoint at line 5 (print(x))
    process.inputStream.writeLine($ %*{
      "seq": 2,
      "type": "request",
      "command": "setBreakpoints",
      "arguments": {
        "path": testProgram,
        "lines": [5]
      }
    })
    process.inputStream.flush()

    # Read response
    var bpResp: JsonNode
    for i in 0..10:
      var line: string
      if process.outputStream.readLine(line) and line.len > 0:
        let msg = parseJson(line)
        if msg.hasKey("command") and msg["command"].getStr() == "setBreakpoints":
          bpResp = msg
          break

    check bpResp != nil
    check bpResp["success"].getBool() == true
    check bpResp["body"]["breakpoints"].len == 1
    check bpResp["body"]["breakpoints"][0]["verified"].getBool() == true

    # Launch without stopOnEntry
    process.inputStream.writeLine($ %*{
      "seq": 3,
      "type": "request",
      "command": "launch",
      "arguments": {"program": testProgram, "stopOnEntry": false}
    })
    process.inputStream.flush()

    # Continue - should hit breakpoint
    process.inputStream.writeLine($ %*{
      "seq": 4,
      "type": "request",
      "command": "continue",
      "arguments": {"threadId": 1}
    })
    process.inputStream.flush()

    # Look for stopped event with breakpoint reason
    var hitBreakpoint = false
    for i in 0..15:
      var line: string
      if process.outputStream.readLine(line) and line.len > 0:
        let msg = parseJson(line)
        if msg.hasKey("event") and msg["event"].getStr() == "stopped":
          if msg["body"]["reason"].getStr() == "breakpoint":
            hitBreakpoint = true
            break

    check hitBreakpoint

    # Disconnect
    process.inputStream.writeLine($ %*{
      "seq": 5,
      "type": "request",
      "command": "disconnect",
      "arguments": {}
    })
    process.inputStream.flush()