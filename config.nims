
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

  let libffiPath =
    if system.fileExists("/opt/homebrew/opt/libffi/lib/libffi.a"):
      "/opt/homebrew/opt/libffi"
    else:
      "/usr/local/opt/libffi"
  switch("passC", "-I" & libffiPath & "/include")
  switch("passL", libffiPath & "/lib/libffi.a")

when defined(linux):
  switch("passC", "-I/usr/include")
  switch("passL", "-L/usr/lib -lffi")

when defined(windows):
  let libffiPath =
    if system.fileExists("D:/a/_temp/msys64/mingw64/lib/libffi.a"):
      "D:/a/_temp/msys64/mingw64"
    elif system.fileExists("C:/msys64/mingw64/lib/libffi.a"):
      "C:/msys64/mingw64"
    elif system.fileExists("C:/tools/msys64/mingw64/lib/libffi.a"):
      "C:/tools/msys64/mingw64"
    else:
      ""
  if libffiPath == "":
    quit("libffi.a not found on system; please install libffi development files")
  switch("passC", "-I" & libffiPath & "/include")
  switch("passL", libffiPath & "/lib/libffi.a")

when defined(release) or defined(deploy):
  switch("opt", "speed")
  switch("checks", "off")

  when defined(deploy):
    switch("define", "danger")
    switch("define", "strip")
    switch("define", "lto")

  when defined(macosx):
    switch("passC", "-O3 -march=native -fomit-frame-pointer -fvisibility=hidden -fvisibility-inlines-hidden")
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
