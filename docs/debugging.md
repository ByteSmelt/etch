# Debugging Etch Programs

Etch provides comprehensive debugging support through the Debug Adapter Protocol (DAP), allowing you to debug Etch scripts both standalone and embedded within C/C++ applications.

## Table of Contents

- [Overview](#overview)
- [Direct Debugging Mode](#direct-debugging-mode)
- [Remote Debugging Mode](#remote-debugging-mode)
- [Compound Debugging (C++ + Etch)](#compound-debugging-c-etch)
- [Debugging Features](#debugging-features)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)

## Overview

Etch supports three debugging modes:

1. **Direct Debugging**: Debug standalone `.etch` scripts directly from VSCode
2. **Remote Debugging**: Debug Etch scripts running inside C/C++ applications
3. **Compound Debugging**: Debug both C++ host application and embedded Etch scripts simultaneously

All modes support the full DAP feature set including breakpoints, stepping, variable inspection, and call stack navigation.

## Direct Debugging Mode

Direct debugging is the simplest mode for debugging standalone Etch scripts.

### Setup

1. Open an Etch script (`.etch` file) in VSCode
2. Set breakpoints by clicking in the gutter
3. Press **F5** or select **"Launch Etch VM Program"** from the debug menu

### Launch Configuration

Add to your `.vscode/launch.json`:

```json
{
  "type": "etch",
  "request": "launch",
  "name": "Launch Etch VM Program",
  "program": "${file}",
  "stopOnEntry": true
}
```

### Features

- Breakpoints with conditions
- Step over (F10), step into (F11), step out (Shift+F11)
- Variable inspection in locals, globals, and registers
- Call stack navigation
- Debug console output

## Remote Debugging Mode

Remote debugging allows you to debug Etch scripts embedded in C/C++ applications, similar to Python's `debugpy` for embedded Python interpreters.

### How It Works

When you set the `ETCH_DEBUG_PORT` environment variable, the Etch VM automatically:
1. Starts a TCP debug server on the specified port (default: 9823)
2. Waits for a debugger connection (with configurable timeout)
3. Forwards all DAP events and commands over the TCP socket

This is completely transparent - no code changes required in your C/C++ application!

### Setup

#### 1. Create an Attach Configuration

Add to your `.vscode/launch.json`:

```json
{
  "type": "etch",
  "request": "attach",
  "name": "Attach to Etch Remote Debugger",
  "host": "127.0.0.1",
  "port": 9823,
  "timeout": 30000,
  "stopOnEntry": true
}
```

#### 2. Set Environment Variables

When launching your C/C++ application, set:

```bash
export ETCH_DEBUG_PORT=9823      # Port for debug server
export ETCH_DEBUG_TIMEOUT=30000  # Connection timeout in ms
```

#### 3. Launch Your Application

Run your C/C++ application with the environment variables set. The Etch VM will:
- Print: `DEBUG: Remote debug server listening on port 9823`
- Wait for debugger connection
- Continue execution once debugger attaches

#### 4. Attach Debugger

In VSCode, select **"Attach to Etch Remote Debugger"** and press **F5**. The debugger will connect and pause at the entry point if `stopOnEntry: true`.

### C++ Example

```cpp
#include <etch.hpp>

int main(int argc, char** argv) {
    // Create context with debugging enabled
    etch::Context ctx(false, true);  // verbose=false, debug=true

    // The ETCH_DEBUG_PORT environment variable triggers remote debugging
    ctx.compileFile("script.etch");
    ctx.execute();  // Waits for debugger if ETCH_DEBUG_PORT is set

    return 0;
}
```

Compile and run with:

```bash
export ETCH_DEBUG_PORT=9823
export ETCH_DEBUG_TIMEOUT=30000
./my_app script.etch
```

## Compound Debugging (C++ + Etch)

Compound debugging allows you to debug **both** your C++ application and the embedded Etch scripts simultaneously, switching between them seamlessly.

### Setup

Add a compound configuration to `.vscode/launch.json`:

```json
{
  "compounds": [
    {
      "name": "Debug C++ + Etch (Remote)",
      "configurations": [
        "Attach to Etch Remote Debugger",
        "Debug C++ with Embedded Etch"
      ],
      "stopAll": true,
      "presentation": {
        "hidden": false,
        "group": "Hybrid Debugging",
        "order": 1
      }
    }
  ],
  "configurations": [
    {
      "type": "etch",
      "request": "attach",
      "name": "Attach to Etch Remote Debugger",
      "host": "127.0.0.1",
      "port": 9823,
      "timeout": 30000,
      "stopOnEntry": true
    },
    {
      "type": "cppdbg",
      "request": "launch",
      "name": "Debug C++ with Embedded Etch",
      "program": "${workspaceFolder}/my_app",
      "args": ["${workspaceFolder}/script.etch"],
      "cwd": "${workspaceFolder}",
      "environment": [
        {"name": "ETCH_DEBUG_PORT", "value": "9823"},
        {"name": "ETCH_DEBUG_TIMEOUT", "value": "30000"}
      ],
      "externalConsole": false,
      "MIMode": "lldb",  // or "gdb" on Linux
      "stopAtEntry": false
    }
  ]
}
```

### Usage

1. Set breakpoints in both C++ files and `.etch` files
2. Select **"Debug C++ + Etch (Remote)"** from the debug menu
3. Press **F5** to start compound debugging

Both debuggers will start simultaneously:
- The C++ debugger launches your application
- The Etch debugger connects to the remote debug server
- You can step through C++ and Etch code independently
- Both debuggers appear in the **Call Stack** panel

### Workflow

**When debugging C++ code:**
- Step through C++ with F10/F11
- See Etch VM function calls like `etch_execute()`
- The Etch debugger remains paused at its current location

**When debugging Etch code:**
- Switch to the Etch session in the Call Stack panel
- Step through Etch code with F10/F11
- The C++ debugger remains at the `etch_execute()` call

**Switching between debuggers:**
- Click different sessions in the Call Stack panel
- Each maintains its own breakpoints and state
- Use "Continue" independently for each session

## Debugging Features

### Breakpoints

Set breakpoints in Etch source files by clicking in the gutter. Breakpoints support:

- **Regular breakpoints**: Stop execution at a specific line
- **Conditional breakpoints**: Break only when a condition is true
- **Inline breakpoint information**: Shows file, line, and call stack when hit

When stepping, the debugger will automatically skip the breakpoint at the current location to avoid getting stuck.

### Stepping

- **Step Over (F10)**: Execute the current line and stop at the next line in the same function
- **Step Into (F11)**: Step into function calls
- **Step Out (Shift+F11)**: Continue until the current function returns
- **Continue (F5)**: Resume execution until the next breakpoint

### Variable Inspection

The **Variables** panel shows:

- **Local Variables**: Variables in the current function scope
  - Shows both initialized and uninitialized variables
  - Displays type information
  - Expands arrays and tables

- **Globals**: Global variables and module-level definitions

- **Registers (Debug)**: Low-level VM register contents
  - Useful for debugging the VM itself
  - Shows register indices and values

### Call Stack

The **Call Stack** panel displays:
- Current function being executed
- Complete call chain with file names and line numbers
- Frame information for register-based stack frames
- Ability to select different frames and inspect their locals

### Debug Console

The **Debug Console** shows:
- Program output from `print()` statements
- Debug events (breakpoint hits, step completions)
- Compilation errors
- VM state information

## Architecture

### Console DAP Mode (Direct Debugging)

```
VSCode ←→ stdin/stdout ←→ regvm_debugserver.nim ←→ Etch VM
```

- Communication via standard input/output
- DAP messages sent as JSON lines
- Events echoed to stdout
- Used for direct script debugging

### Remote DAP Mode (Embedded Debugging)

```
VSCode ←→ TCP socket ←→ regvm_debugserver_remote.nim ←→ regvm_debugserver.nim ←→ Etch VM
```

- Communication via TCP socket (default port 9823)
- DAP messages framed as newline-delimited JSON
- Events forwarded over socket
- Transparent activation via environment variables
- Handles EINTR when C++ debugger pauses the process

### Component Separation

The architecture follows clean separation of concerns:

- **`regvm_debugger.nim`**: Core debugger logic (breakpoints, stepping, VM inspection)
- **`regvm_debugserver.nim`**: DAP protocol implementation (command handling, JSON responses)
- **`regvm_debugserver_remote.nim`**: TCP transport layer (socket management, connection handling)

This design allows:
- Reusable protocol logic across transports
- Easy testing and maintenance
- Support for future transport mechanisms

### Event Flow

All debugging events flow through the `onDebugEvent` handler:

1. **Console mode**: Handler echoes events to stdout
2. **Remote mode**: Handler sends events over TCP socket

This abstraction ensures consistent behavior across modes while supporting different transport layers.

## Troubleshooting

### Connection Timeout

If you see "Connection timeout" when attaching:

1. Check the C++ application is running with `ETCH_DEBUG_PORT` set
2. Verify the port number matches in both configurations
3. Increase the timeout: `"timeout": 60000` (60 seconds)
4. Check firewall settings aren't blocking localhost connections

### Debugger Stays at Same Line

If stepping doesn't move to the next line:

1. **Check for breakpoints**: Remove breakpoints at the current line and retry
2. **Verify the fix**: The `justStepped` flag should skip the current breakpoint
3. **Check debug logs**: Look for "DEBUG: next - sending stopped event" in output

### Events Not Received

If stopped events aren't triggering UI updates:

1. Check debug console logs for "DEBUG: Sending event to client"
2. Verify the event handler is properly connected
3. Look for EINTR errors (should automatically retry)

### C++ Debugger Blocks Etch Debugging

This is expected behavior! The compound configuration works sequentially:

1. **C++ debugger**: Set `stopAtEntry: false` to not pause immediately
2. **Etch debugger**: Will connect once C++ reaches `etch_execute()`
3. **When C++ is paused**: Etch debugger may experience EINTR (automatically handled)

### Multiple Etch Instances

If your C++ app executes multiple Etch scripts:

1. The debug server starts on **first execution** with `ETCH_DEBUG_PORT` set
2. Subsequent executions in the same process will **not** start new servers
3. For multiple instances, use different processes with different ports

### Performance Impact

Remote debugging has minimal performance overhead:
- TCP socket communication is fast (localhost only)
- Stepping is synchronous (blocks execution)
- No overhead when `ETCH_DEBUG_PORT` is not set

## Best Practices

### Development Workflow

1. **Start simple**: Debug Etch scripts directly first
2. **Integrate gradually**: Test remote debugging with minimal C++ host
3. **Use compound mode**: Once both work independently, combine them

### Debugging Strategy

1. **Set strategic breakpoints**: Entry points, error paths, critical logic
2. **Use step over by default**: Step into only when you need details
3. **Inspect variables**: Check state before and after operations
4. **Watch the call stack**: Understand the execution context

### Production Considerations

1. **Never ship with `ETCH_DEBUG_PORT` set**: Remove from production environment
2. **Disable debug builds**: Compile Etch library in release mode
3. **Remove debug logging**: The `verbose` flag should be false in production
4. **Security**: Debug ports should never be exposed externally

## Example Session

Here's a complete example of debugging an embedded Etch script:

**script.etch:**
```etch
fn factorial(n: int) -> int {
    if n <= 1 {
        return 1;
    }
    return n * factorial(n - 1);
}

fn main() -> void {
    let x: int = 5;
    let result: int = factorial(x);
    print(result);
}
```

**app.cpp:**
```cpp
#include <etch.hpp>
#include <iostream>

int main() {
    std::cout << "=== Starting Etch Integration ===" << std::endl;

    etch::Context ctx(false, true);  // debug enabled
    ctx.compileFile("script.etch");

    std::cout << "=== Executing Etch Script ===" << std::endl;
    ctx.execute();  // Remote debugging happens here

    std::cout << "=== Etch Complete ===" << std::endl;
    return 0;
}
```

**Debugging session:**

1. Set breakpoints in `script.etch` at lines 9 and 10
2. Export environment: `export ETCH_DEBUG_PORT=9823`
3. Start compound debugger: **F5** on "Debug C++ + Etch (Remote)"
4. C++ debugger starts the app
5. Etch debugger connects when `ctx.execute()` is called
6. Execution pauses at line 9 (entry point)
7. Press **F10** to step to line 10
8. Inspect `x` in Variables panel (should show `5`)
9. Press **F5** to continue to the next breakpoint
10. Both debuggers remain responsive throughout

This workflow gives you complete visibility into both the C++ host and the embedded Etch script!
