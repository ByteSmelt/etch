# Etch Language Implementation - Just commands

# Test compiling and running all examples
examples:
    nim r src/etch.nim --test examples/

# Run a specific example file
go file:
    nim r src/etch.nim --run {{file}}

# Build the project
build:
    nim c src/etch.nim

# Clean build artifacts
clean:
    rm -f src/etch
    find . -name "*.exe" -delete
    find . -name "nimcache" -type d -exec rm -rf {} + 2>/dev/null || true

# Deal with VSCode extension packaging and installation
[working-directory: 'vscode']
syntax:
    rm -f *.vsix
    -code --uninstall-extension kunitoki.etchlang
    vsce package --allow-missing-repository
    code --install-extension etchlang-*.vsix
