
when system.fileExists(withDir(thisDir(), "nimble.paths")):
  include "nimble.paths"

when defined(staticlib) or defined(sharedlib):
  switch("threads", "off")
else:
  switch("threads", "on")

switch("panics", "on")
switch("nimcache", ".nimcache")

when defined(macosx):
  let sdkPath = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
  switch("passC", "-isysroot " & sdkPath)
  switch("passL", "-L " & sdkPath & "/usr/lib -F " & sdkPath & "/System/Library/Frameworks")

  # Handle both Apple Silicon (arm64) and Intel (x86_64) Macs
  let libffiPath = 
    when system.fileExists("/opt/homebrew/opt/libffi/lib/libffi.a"):
      "/opt/homebrew/opt/libffi"  # Apple Silicon
    else:
      "/usr/local/opt/libffi"      # Intel Mac
  switch("passC", "-I" & libffiPath & "/include")
  switch("passL", libffiPath & "/lib/libffi.a")

when defined(linux):
  # Link against system libffi
  switch("passL", "-lffi")

when defined(windows):
  # On Windows with MSYS2, use explicit paths
  # MSYS2 typically installs to C:/msys64 or in GitHub Actions under D:/a/_temp/msys64
  when system.fileExists("D:/a/_temp/msys64/mingw64/lib/libffi.a"):
    # GitHub Actions path
    switch("passC", "-ID:/a/_temp/msys64/mingw64/include")
    switch("passL", "D:/a/_temp/msys64/mingw64/lib/libffi.a")
  elif system.fileExists("C:/msys64/mingw64/lib/libffi.a"):
    # Standard MSYS2 installation
    switch("passC", "-IC:/msys64/mingw64/include")
    switch("passL", "C:/msys64/mingw64/lib/libffi.a")
  elif system.fileExists("C:/tools/msys64/mingw64/lib/libffi.a"):
    # Alternative MSYS2 installation
    switch("passC", "-IC:/tools/msys64/mingw64/include")
    switch("passL", "C:/tools/msys64/mingw64/lib/libffi.a")
  else:
    # Fall back to dynamic linking
    discard

when defined(release) or defined(deploy):
  switch("define", "danger")
  switch("define", "strip")
  switch("define", "lto")
  switch("checks", "off")

  when defined(macosx):
    switch("passC", "-O2 -fomit-frame-pointer -fvisibility=hidden -fvisibility-inlines-hidden -march=native")
    switch("passL", "-Wl,-dead_strip -Wl,-dead_strip")

when defined(debug):
  switch("panics", "on")
  switch("checks", "on")
  switch("lineDir", "on")
  switch("debugger", "native")
  switch("debuginfo")

  when defined(macosx):
    discard
    #switch("passC", "-O0 -g -fsanitize=address")
    #switch("passL", "-fsanitize=address")
    #switch("passC", "-O0 -g -fsanitize=threads")
    #switch("passL", "-fsanitize=threads")
