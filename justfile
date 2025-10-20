# Etch Language Implementation - Just commands

default:
    @just -l

[working-directory: 'examples/clib']
libs:
    make

# Test compiling and running all examples + debugger tests
tests:
    @just libs
    nim r src/etch.nim --test examples/
    nimble test

# Test compiling and running a specific example file
test file:
    @just libs
    nim r src/etch.nim --test {{file}}

# Test compiling and running all examples + debugger tests (c)
tests-c:
    @just libs
    nim r src/etch.nim --test-c examples/
    #nimble test

# Test compiling and running a specific example file (c)
test-c file:
    @just libs
    nim r src/etch.nim --test-c {{file}}

# Run a specific example file
go file:
    @just libs
    nim r src/etch.nim --verbose --run {{file}}

# Build the project
build:
    nim c -d:danger -o:etch src/etch.nim

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

# Deal with VSCode extension packaging and installation
[working-directory: 'vscode']
vscode:
    rm -f *.vsix
    -code --uninstall-extension kunitoki.etchlang
    tsc -p ./
    vsce package --allow-missing-repository
    code --install-extension etchlang-*.vsix
