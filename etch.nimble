# Package
version       = "0.1.0"
author        = "kunitoki"
description   = "Define once, Etch forever."
license       = "MIT"
srcDir        = "src"
bin           = @["etch"]

# Dependencies
requires "nim >= 2.2.4"

# Tasks
task test, "Run all tests":
  echo "===== Running debugger tests ====="
  exec "nim c -r tests/test_debug_basic.nim"
  exec "nim c -r tests/test_debugger_integration.nim"
  echo "\n===== Running example tests ====="
  exec "nim r src/etch.nim --test examples/"

task build, "Build the etch compiler":
  exec "nim c -d:release src/etch.nim"

task build_debug, "Build the etch compiler with debug info":
  exec "nim c src/etch.nim"

task clean, "Clean build artifacts":
  exec "rm -f src/etch src/etch.out"
  exec "find . -name '*.etcx' -delete"
  echo "Cleaned build artifacts"
