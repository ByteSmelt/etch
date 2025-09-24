# etch_cli.nim
# CLI for Etch: parse, typecheck, monomorphize on call, prove safety, run VM or emit C

import std/os
import ./etch/[compiler, tester, debug_server]
import ./etch/interpreter/[bytecode]


proc usage() =
  echo "Etch - minimal language toolchain"
  echo "Usage:"
  echo "  etch [--run] [--verbose] [--emit:c out.c] [--debug] file.etch"
  echo "  etch --test [directory]"
  echo "Options:"
  echo "  --run         Execute the program (with bytecode caching)"
  echo "  --verbose     Enable verbose debug output"
  echo "  --debug       Include debug information in bytecode"
  echo "  --debug-server Start debug server for VSCode integration"
  echo "  --test        Run tests in directory (default: tests/)"
  echo "                Tests need .result (expected output) or .error (expected failure)"
  quit 1


when isMainModule:
  if paramCount() < 1: usage()

  # Check for special modes first
  if paramCount() >= 1 and paramStr(1) == "--test":
    let testDir = if paramCount() >= 2: paramStr(2) else: "tests"
    quit runTests(testDir)

  # Check for debug server mode
  if paramCount() >= 2 and paramStr(1) == "--debug-server":
    let sourceFile = paramStr(2)

    # Compile with debug info enabled
    let options = CompilerOptions(
      sourceFile: sourceFile,
      runVM: false,
      verbose: false,
      debug: true
    )

    try:
      # Parse, typecheck and compile to bytecode
      let (prog, sourceHash, evaluatedGlobals) = parseAndTypecheck(options)
      let flags = CompilerFlags(verbose: false, debug: true)
      let bytecodeProgram = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, sourceFile, flags)

      # Start debug server
      runDebugServer(bytecodeProgram, sourceFile)
    except Exception as e:
      echo "Error: ", e.msg
      quit 1

    quit 0

  var runVm = false
  var verbose = false
  var debug = false
  var files: seq[string] = @[]
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--run": runVm = true
    elif a == "--verbose": verbose = true
    elif a == "--debug": debug = true
    else:
      files.add a
    inc i
  if files.len != 1: usage()

  let sourceFile = files[0]

  # Set up compiler options
  let options = CompilerOptions(
    sourceFile: sourceFile,
    runVM: runVm,
    verbose: verbose,
    debug: debug
  )

  # Use the compiler module to handle compilation and execution
  let compilerResult = tryRunCachedOrCompile(options)

  if not compilerResult.success:
    echo compilerResult.error
    quit compilerResult.exitCode

  quit compilerResult.exitCode
