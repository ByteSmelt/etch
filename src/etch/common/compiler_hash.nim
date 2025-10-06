# compiler_hash.nim
# Provides compiler version hash for bytecode cache invalidation

import std/[macros, hashes]

# Generate a compile-time hash based on compilation timestamp and source files
# This will change whenever the code is recompiled
const COMPILE_TIME* = CompileDate & " " & CompileTime

# We can also include specific source file modification times if available
macro generateCompilerHash(): string =
  # At compile time, generate a unique hash for this compiler build
  let timestamp = COMPILE_TIME

  # Include Nim version for additional safety
  let nimVersion = NimVersion

  # Combine all version information
  let versionInfo = timestamp & "|" & nimVersion

  # Generate hash
  let hash = $hash(versionInfo)
  result = newLit(hash)

# The compiler version hash is computed at compile time
const COMPILER_VERSION_HASH* = generateCompilerHash()

proc getCompilerVersionHash*(): string =
  ## Get the compiler version hash embedded at compile time
  ## This changes whenever the compiler is rebuilt
  return COMPILER_VERSION_HASH