# Etch Language Implementation - Just commands

default:
    @just -l

[working-directory: 'examples/clib']
libs:
    make

[working-directory: 'examples/capi']
capi:
    make

# Test compiling and running all examples + debugger tests
tests:
    @just libs
    nim r src/etch.nim --test examples/
    nimble test

# Test compiling and running a specific example file
test file OPTS="":
    @just libs
    nim r src/etch.nim --test {{file}} {{OPTS}}

# Test compiling and running all examples + debugger tests (c)
tests-c OPTS="":
    @just libs
    nim r src/etch.nim --test-c examples/ {{OPTS}}
    #nimble test

# Test compiling and running a specific example file (c)
test-c file OPTS="":
    @just libs
    nim r src/etch.nim --test-c {{file}} {{OPTS}}

# Run a specific example file
go file:
    @just libs
    nim r src/etch.nim --verbose --run {{file}}

# Build the project
build:
    nim c -d:danger -o:etch src/etch.nim

# Build shared library
build-lib:
    mkdir -p lib
    nim c --app:lib --noMain -d:release -o:lib/libetch.so src/etch_lib.nim

# Build static library
build-lib-static:
    mkdir -p lib
    nim c --app:staticlib --noMain -d:release -o:lib/libetch.a src/etch_lib.nim

# Build both shared and static libraries
build-libs:
    @just build-lib
    @just build-lib-static

# Handle performance
perf:
    @just build
    nimble perf

# Clean build artifacts
clean:
    find . -name "*.etcx" -delete
    find . -name "*.exe" -delete
    find examples -name "*.c" -depth 0 -type f -exec rm -f {} + 2>/dev/null || true
    find examples -name "*_c" -depth 0 -type f -exec rm -f {} + 2>/dev/null || true
    find . -name "nimcache" -type d -exec rm -rf {} + 2>/dev/null || true
    rm -rf lib

# Deal with VSCode extension packaging and installation
[working-directory: 'vscode']
vscode:
    rm -f *.vsix
    -code --uninstall-extension kunitoki.etchlang
    tsc -p ./
    vsce package --allow-missing-repository
    code --install-extension etchlang-*.vsix
