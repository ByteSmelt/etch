# test_utils.nim
# Common utilities for Etch tests

import std/[os, osproc]

proc findEtchExecutable*(): string =
  ## Find the etch executable, trying multiple locations
  ## This works whether tests are run from project root or tests directory

  # Try current directory first (when run from project root)
  if fileExists("./etch"):
    return "./etch"

  # Try parent directory (when run from tests directory)
  if fileExists("../etch"):
    return "../etch"

  # Try using nim to run directly (fallback)
  if fileExists("src/etch.nim"):
    return "nim r src/etch.nim"
  elif fileExists("../src/etch.nim"):
    return "nim r ../src/etch.nim"

  # Last resort: assume it's in PATH or current dir
  return "./etch"

proc getTestTempDir*(): string =
  ## Get a temporary directory for test files
  ## Uses a subdirectory to avoid /tmp issues mentioned in CLAUDE.md
  when defined(posix):
    # Use /private/tmp on macOS, regular temp on Linux
    let baseTemp = when defined(macosx): "/private/tmp" else: getTempDir()
    result = baseTemp / "__etch__"
  else:
    result = getTempDir() / "__etch__"

  # Create the directory if it doesn't exist
  if not dirExists(result):
    createDir(result)

proc cleanupTestTempDir*() =
  ## Clean up the test temporary directory
  let tempDir = getTestTempDir()
  if dirExists(tempDir):
    try:
      removeDir(tempDir)
    except:
      discard # Ignore errors during cleanup

proc ensureEtchBinary*(): bool =
  ## Ensure the etch binary is built and available
  ## Returns true if binary is available, false otherwise

  # First check if binary already exists
  if fileExists("./etch") or fileExists("../etch"):
    return true

  # Try to build it
  echo "Building etch binary for tests..."
  let buildCmd = if fileExists("src/etch.nim"):
    "nim c -d:danger -o:etch src/etch.nim"
  elif fileExists("../src/etch.nim"):
    "cd .. && nim c -d:danger -o:etch src/etch.nim"
  else:
    return false

  let (output, exitCode) = execCmdEx(buildCmd)
  if exitCode != 0:
    echo "Failed to build etch binary:"
    echo output
    return false

  return true
