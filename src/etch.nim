# etch_cli.nim
# CLI for Etch: parse, typecheck, monomorphize on call, prove safety, run VM or emit C

import std/[os, strutils]
import ./etch/[compiler, tester]
import ./etch/common/[types]
import ./etch/interpreter/[regvm_dump, regvm_debugserver]


proc usage() =
  echo "Etch - minimal language toolchain"
  echo "Usage:"
  echo "  etch [--run] [--verbose] [--release] file.etch"
  echo "  etch --test [directory]"
  echo "Options:"
  echo "  --run            Execute the program (with bytecode caching)"
  echo "  --verbose        Enable verbose debug output"
  echo "  --release        Optimize and skip debug information in bytecode"
  echo "  --debug-server   Start debug server for VSCode integration"
  echo "  --dump-bytecode  Dump bytecode instructions with debug info"
  echo "  --test           Run tests in directory (default: tests/)"
  echo "                   Tests need .pass (expected output) or .fail (expected failure)"
  quit 1


when isMainModule:
  if paramCount() < 1: usage()

  var verbose = false
  var debug = true
  var mode = ""
  var modeArg = ""
  var runVm = false
  var files: seq[string] = @[]

  var i = 1
  while i <= paramCount():
    let a = paramStr(i)

    if a == "--verbose":
      verbose = true
    elif a == "--release":
      debug = false
    elif a == "--run":
      runVm = true

    elif a == "--test":
      mode = "test"
      if i + 1 <= paramCount() and not paramStr(i + 1).startsWith("--"):
        modeArg = paramStr(i + 1)
        inc i
    elif a == "--debug-server":
      mode = "debug-server"
      if i + 1 <= paramCount():
        modeArg = paramStr(i + 1)
        inc i
    elif a == "--dump-bytecode":
      mode = "dump-bytecode"
      if i + 1 <= paramCount():
        modeArg = paramStr(i + 1)
        inc i
    elif not a.startsWith("--"):
      files.add a
    inc i

  if mode == "test":
    let testDir = if modeArg != "": modeArg else: "tests"
    quit runTests(testDir, verbose, not debug)

  if mode == "debug-server":
    if modeArg == "":
      echo "Error: --debug-server requires a file argument"
      quit 1
    let sourceFile = modeArg

    if not fileExists(sourceFile):
      echo "Error: cannot open: ", sourceFile
      quit 1

    let options = CompilerOptions(
      sourceFile: sourceFile,
      runVM: false,
      verbose: verbose,
      debug: true
    )

    try:
      let (prog, sourceHash, evaluatedGlobals) = parseAndTypecheck(options)
      let flags = CompilerFlags(verbose: verbose, debug: true)
      let regBytecode = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, sourceFile, flags)
      runRegDebugServer(regBytecode, sourceFile)
    except Exception as e:
      sendCompilationError(e.msg)
      quit 1

    quit 0

  if mode == "dump-bytecode":
    if modeArg == "":
      echo "Error: --dump-bytecode requires a file argument"
      quit 1
    let sourceFile = modeArg

    if not fileExists(sourceFile):
      echo "Error: cannot open: ", sourceFile
      quit 1

    let options = CompilerOptions(
      sourceFile: sourceFile,
      runVM: false,
      verbose: verbose,
      debug: debug
    )

    try:
      let (prog, sourceHash, evaluatedGlobals) = parseAndTypecheck(options)
      let flags = CompilerFlags(verbose: verbose, debug: debug)
      let bytecodeProgram = compileProgramWithGlobals(prog, sourceHash, evaluatedGlobals, sourceFile, flags)
      dumpBytecodeProgram(bytecodeProgram, sourceFile)
    except Exception as e:
      echo "Error: ", e.msg
      quit 1

    quit 0

  if files.len != 1: usage()

  let sourceFile = files[0]

  let options = CompilerOptions(
    sourceFile: sourceFile,
    runVM: runVm,
    verbose: verbose,
    debug: debug,
    release: not debug
  )

  let compilerResult = tryRunCachedOrCompile(options)

  if not compilerResult.success:
    echo compilerResult.error
    quit compilerResult.exitCode

  quit compilerResult.exitCode
