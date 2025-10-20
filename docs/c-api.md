# Etch C/C++ Library API

## Overview

Etch can now be compiled as a shared/static library and embedded into C and C++ applications as a scripting engine. This enables using Etch as a safe, statically-typed scripting language with compile-time verification and runtime safety checks.

## Features

### Core Capabilities
- **Compile-time type checking** - Catch errors before runtime
- **Memory safety** - No buffer overflows or use-after-free bugs
- **Clean C API** - Simple, well-documented C interface
- **Modern C++ wrapper** - RAII, exceptions, and type-safe interfaces
- **Host function registration** - Expose C/C++ functions to Etch scripts
- **Bidirectional value passing** - Easy conversion between native and Etch types
- **Global variable access** - Read/write globals from host code

### API Design

#### C API (`include/etch.h`)
- Minimal, portable C interface
- Opaque handles for contexts and values
- Traditional return-code error handling
- Compatible with any C/C++ compiler

#### C++ Wrapper (`include/etch.hpp`)
- Modern C++11+ interface
- RAII for automatic resource management
- Exception-based error handling
- Move semantics for efficient value passing
- Type-safe value operations

## Building

### Build the Library

From the project root:

```bash
# Build shared library (libetch.so / libetch.dylib)
just build-lib

# Build static library (libetch.a)
just build-lib-static

# Build both
just build-libs
```

The library will be created in the `lib/` directory.

### Build the Examples

```bash
cd examples/c_api
make all
```

This builds three examples:
- `simple_example` - Basic C API usage
- `host_functions_example` - Registering C functions
- `cpp_example` - C++ wrapper demonstration

## Quick Start

### C API Example

```c
#include "etch.h"

int main(void) {
    // Create context
    EtchContext* ctx = etch_context_new();

    // Compile Etch code
    const char* code =
        "fn main(): int {\n"
        "    print(\"Hello from Etch!\")\n"
        "    return 0\n"
        "}\n";

    if (etch_compile_string(ctx, code, "hello.etch") != 0) {
        printf("Error: %s\n", etch_get_error(ctx));
        etch_context_free(ctx);
        return 1;
    }

    // Execute
    etch_execute(ctx);

    // Clean up
    etch_context_free(ctx);
    return 0;
}
```

### C++ API Example

```cpp
#include "etch.hpp"

int main() {
    try {
        // Create context (RAII)
        etch::Context ctx;

        // Compile and execute
        ctx.compileString(
            "fn main(): int {\n"
            "    print(\"Hello from Etch!\")\n"
            "    return 0\n"
            "}\n"
        );
        ctx.execute();

    } catch (const etch::Exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
```

## API Reference

### Context Management

```c
// C API
EtchContext* etch_context_new(void);
void etch_context_free(EtchContext* ctx);
void etch_context_set_verbose(EtchContext* ctx, int verbose);
```

```cpp
// C++ API
etch::Context ctx;  // Automatically cleaned up via RAII
ctx.setVerbose(true);
```

### Compilation

```c
// C API - Compile from string or file
int etch_compile_string(EtchContext* ctx, const char* source, const char* filename);
int etch_compile_file(EtchContext* ctx, const char* path);
```

```cpp
// C++ API
ctx.compileString(source, filename);
ctx.compileFile(path);
```

### Execution

```c
// C API
int etch_execute(EtchContext* ctx);
EtchValue* etch_call_function(EtchContext* ctx, const char* name,
                               EtchValue** args, int numArgs);
```

```cpp
// C++ API
ctx.execute();
etch::Value result = ctx.callFunction(name, args);
```

### Value Creation

```c
// C API
EtchValue* etch_value_new_int(int64_t v);
EtchValue* etch_value_new_float(double v);
EtchValue* etch_value_new_bool(int v);
EtchValue* etch_value_new_string(const char* v);
EtchValue* etch_value_new_char(char v);
EtchValue* etch_value_new_nil(void);
```

```cpp
// C++ API
etch::Value intVal(42);
etch::Value floatVal(3.14);
etch::Value boolVal(true);
etch::Value stringVal("hello");
etch::Value charVal('x');
etch::Value nilVal;  // Default constructor creates nil
```

### Value Inspection & Extraction

```c
// C API
int etch_value_is_int(EtchValue* v);
int etch_value_to_int(EtchValue* v, int64_t* out);
const char* etch_value_to_string(EtchValue* v);
void etch_value_free(EtchValue* v);
```

```cpp
// C++ API
if (val.isInt()) {
    int64_t i = val.toInt();
}
std::string s = val.toString();
// Automatic cleanup via RAII
```

### Global Variables

```c
// C API
void etch_set_global(EtchContext* ctx, const char* name, EtchValue* value);
EtchValue* etch_get_global(EtchContext* ctx, const char* name);
```

```cpp
// C++ API
ctx.setGlobal("counter", etch::Value(42));
etch::Value counter = ctx.getGlobal("counter");
```

### Host Functions

```c
// C API - Register a C function callable from Etch
typedef EtchValue* (*EtchHostFunction)(EtchContext ctx, EtchValue** args,
                                       int numArgs, void* userData);

int etch_register_function(EtchContext* ctx, const char* name,
                           EtchHostFunction callback, void* userData);

// Example:
EtchValue* my_add(EtchContext ctx, EtchValue** args, int numArgs, void* userData) {
    int64_t a, b;
    etch_value_to_int(args[0], &a);
    etch_value_to_int(args[1], &b);
    return etch_value_new_int(a + b);
}

etch_register_function(ctx, "my_add", my_add, NULL);
```

### Error Handling

```c
// C API
const char* etch_get_error(EtchContext* ctx);
void etch_clear_error(EtchContext* ctx);
```

```cpp
// C++ API - Uses exceptions
try {
    ctx.compileFile("script.etch");
} catch (const etch::Exception& e) {
    std::cerr << e.what() << std::endl;
}
```

## Value Types

| Etch Type | C Type | C++ Type | Notes |
|-----------|--------|----------|-------|
| `int` | `int64_t` | `int64_t` | 64-bit signed integer |
| `float` | `double` | `double` | Double-precision float |
| `bool` | `int` | `bool` | Boolean (0/1 in C) |
| `char` | `char` | `char` | Single character |
| `string` | `const char*` | `std::string` | UTF-8 string |
| `nil` | - | - | Null/nil value |

## Memory Management

### C API
- **Contexts**: Create with `etch_context_new()`, free with `etch_context_free()`
- **Values**: Create with `etch_value_new_*()`, free with `etch_value_free()`
- **Strings**: Returned strings are owned by the value/context, don't free them
- **Error messages**: Owned by context, don't free them

### C++ API
- **Everything is automatic** via RAII
- Values and contexts clean up when they go out of scope
- Use move semantics for efficient transfers

## Linking

### Linux
```bash
gcc -o myapp myapp.c -I/path/to/etch/include -L/path/to/etch/lib -letch -lm
```

### macOS
```bash
clang -o myapp myapp.c -I/path/to/etch/include -L/path/to/etch/lib -letch -lm
```

### Runtime Library Path
Set `LD_LIBRARY_PATH` (Linux) or `DYLD_LIBRARY_PATH` (macOS):
```bash
export LD_LIBRARY_PATH=/path/to/etch/lib:$LD_LIBRARY_PATH
```

Or use rpath flags (see `examples/c_api/Makefile` for examples).

## Use Cases

1. **Game Scripting** - Safe, fast scripting for game logic
2. **Application Plugins** - Allow users to extend functionality
3. **Configuration DSLs** - More powerful than JSON, safer than Lua
4. **Data Processing** - Type-safe scripts for data transformation
5. **Testing** - Script-driven test scenarios
6. **Embedded Systems** - Lightweight scripting with safety guarantees

## Thread Safety

The current API is **not thread-safe**. Each thread should have its own `EtchContext`.

## Performance

- Register-based bytecode VM for fast interpretation
- Aggressive optimizations in bytecode compiler
- C backend available for maximum performance
- Typically 2-5x slower than native C (VM mode)
- C backend can match native C performance

## Future Enhancements

### In Progress
- [ ] Full integration of host functions with Etch type system
- [ ] Array and table manipulation from C/C++
- [ ] Option/Result type support in C API

### Planned
- [ ] Async/await for host functions
- [ ] Debugging API (breakpoints, stepping)
- [ ] Bytecode serialization/deserialization
- [ ] JIT compilation
- [ ] Multi-threading support

## Implementation Details

### File Structure
```
include/
  etch.h          # C API header
  etch.hpp        # C++ wrapper
src/
  etch/
    c_api.nim     # C API implementation
  etch_lib.nim    # Library entry point
examples/
  c_api/
    simple_example.c
    host_functions_example.c
    cpp_example.cpp
    Makefile
    README.md
lib/
  libetch.so      # Built shared library
```

### How It Works

1. **Compilation**: Etch source → AST → Typechecked AST → Bytecode
2. **Execution**: Bytecode → Register VM execution
3. **C API**: Nim functions exported with `{.exportc, cdecl, dynlib.}` pragmas
4. **Memory**: Nim's memory management handles internals, C code manages API objects

### Limitations (Current)

1. **Host functions**: Can be registered and called from C, but not yet integrated with Etch's type system for calling from Etch code
2. **Thread safety**: Not thread-safe (planned for future)
3. **Arrays/tables**: Limited C API support (being expanded)
4. **Debugging**: No debugging API yet (planned)

## Examples

See `examples/c_api/` for complete working examples:
- **simple_example.c** - Basic compilation, execution, and global variables
- **host_functions_example.c** - Registering C functions
- **cpp_example.cpp** - Modern C++ interface with RAII

## Documentation

- This document: C API overview
- `examples/c_api/README.md`: Detailed examples and usage
- `include/etch.h`: C API documentation (comments)
- `include/etch.hpp`: C++ API documentation (comments)

## Support

For questions, issues, or contributions:
- Open an issue on GitHub
- See main Etch documentation for language features
- Check examples for common usage patterns
