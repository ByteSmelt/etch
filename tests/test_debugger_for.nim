import std/[json, unittest, strformat, osproc, os, strutils]

suite "For Loop Debugging":
  test "Stepping alternates between for statement and body":
    # Test that stepping through a for loop alternates between:
    # line 7 (for statement) and line 8 (loop body) for each iteration
    let cmds = getTempDir() / "for_loop_stepping_cmds.txt"
    writeFile(cmds, """{"seq":1,"type":"request","command":"initialize","arguments":{}}
{"seq":2,"type":"request","command":"launch","arguments":{}}
{"seq":3,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
{"seq":4,"type":"request","command":"next","arguments":{"threadId":1}}
{"seq":5,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
{"seq":6,"type":"request","command":"next","arguments":{"threadId":1}}
{"seq":7,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
{"seq":8,"type":"request","command":"next","arguments":{"threadId":1}}
{"seq":9,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
{"seq":10,"type":"request","command":"next","arguments":{"threadId":1}}
{"seq":11,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
{"seq":12,"type":"request","command":"next","arguments":{"threadId":1}}
{"seq":13,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
{"seq":14,"type":"request","command":"next","arguments":{"threadId":1}}
{"seq":15,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
{"seq":16,"type":"request","command":"disconnect","arguments":{}}""")
    defer: removeFile(cmds)

    let cmd = "timeout 2 ./etch --debug-server examples/for_string_test.etch < " & cmds & " 2>/dev/null"
    let (output, _) = execCmdEx(cmd)

    # Helper to extract line number from stack trace response
    proc getLineFromTrace(output: string, seq: int): int =
      for line in output.splitLines():
        if line.contains("\"request_seq\":" & $seq) and line.contains("stackTrace"):
          let parsed = parseJson(line)
          if parsed.hasKey("body") and parsed["body"].hasKey("stackFrames"):
            let frames = parsed["body"]["stackFrames"]
            if frames.len > 0:
              return frames[0]["line"].getInt()
      return -1

    # Check initial position (seq 3)
    let line1 = getLineFromTrace(output, 3)
    echo fmt"Initial position: line {line1}"
    check line1 == 3  # Should start at first line with code (var nums)

    # After first step (seq 5)
    let line2 = getLineFromTrace(output, 5)
    echo fmt"After step 1: line {line2}"
    check line2 == 5  # Should be at print("Testing...")

    # After second step (seq 7) - first time at for statement
    let line3 = getLineFromTrace(output, 7)
    echo fmt"After step 2: line {line3}"
    check line3 == 7  # Should be at for statement (1st iteration)

    # After third step (seq 9) - loop body, 1st iteration
    let line4 = getLineFromTrace(output, 9)
    echo fmt"After step 3: line {line4}"
    check line4 == 8  # Should be at print(x) in loop body

    # After fourth step (seq 11) - back to for statement, 2nd iteration
    let line5 = getLineFromTrace(output, 11)
    echo fmt"After step 4: line {line5}"
    check line5 == 7  # Should be at for statement (2nd iteration)

    # After fifth step (seq 13) - loop body, 2nd iteration
    let line6 = getLineFromTrace(output, 13)
    echo fmt"After step 5: line {line6}"
    check line6 == 8  # Should be at print(x) in loop body

    # After sixth step (seq 15) - back to for statement, 3rd iteration
    let line7 = getLineFromTrace(output, 15)
    echo fmt"After step 6: line {line7}"
    check line7 == 7  # Should be at for statement (3rd iteration)

    echo "✓ For loop correctly alternates between for statement and body"

  test "For loop executes all 7 iterations":
    # Test that verifies all 7 iterations execute
    # The string "ABCDEFG" has 7 characters, so we should see 7 outputs
    # Note: print(x) prints the ASCII value when x is a char from string indexing
    let cmds = getTempDir() / "for_loop_full_test_cmds.txt"
    writeFile(cmds, """{"seq":1,"type":"request","command":"initialize","arguments":{}}
{"seq":2,"type":"request","command":"launch","arguments":{}}
{"seq":3,"type":"request","command":"next","arguments":{"threadId":1}}
{"seq":4,"type":"request","command":"next","arguments":{"threadId":1}}
{"seq":5,"type":"request","command":"continue","arguments":{"threadId":1}}
{"seq":6,"type":"request","command":"disconnect","arguments":{}}""")
    defer: removeFile(cmds)

    # Capture stdout to verify all 7 values are printed
    let cmd = "timeout 2 ./etch --debug-server examples/for_string_test.etch < " & cmds & " 2>&1"
    let (output, _) = execCmdEx(cmd)

    # Check for ASCII values 65-71 (A-G) being printed
    # These should appear as separate lines in the output
    echo "Checking for 7 loop iterations (ASCII values 65-71)..."
    check output.contains("65")  # A
    check output.contains("66")  # B
    check output.contains("67")  # C
    check output.contains("68")  # D
    check output.contains("69")  # E
    check output.contains("70")  # F
    check output.contains("71")  # G

    # Also verify the expected start and end messages
    check output.contains("Testing for loop with string:")
    check output.contains("Done")

    echo "✓ All 7 iterations confirmed!"
