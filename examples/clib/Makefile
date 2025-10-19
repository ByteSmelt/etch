# Makefile for building C libraries for Etch FFI testing

CC = clang
LDFLAGS =

# Platform-specific settings
# Detect Windows via OS environment variable (set on Windows)
ifeq ($(OS),Windows_NT)
    # Windows - no -fPIC needed for DLLs
    CFLAGS = -shared -O2
    XFLAGS =
    LIBEXT = .dll
else
    # Unix-like systems (macOS, Linux)
    UNAME_S := $(shell uname -s)
    CFLAGS = -shared -fPIC -O2

    ifeq ($(UNAME_S),Darwin)
        XFLAGS = -isysroot $(shell xcrun --show-sdk-path)
        LIBEXT = .dylib
    else ifeq ($(UNAME_S),Linux)
        XFLAGS =
        LIBEXT = .so
    else
        # Fallback for other Unix-like systems
        XFLAGS =
        LIBEXT = .so
    endif
endif

all: libmathlib$(LIBEXT)

libmathlib$(LIBEXT): mathlib.c
	$(CC) $(CFLAGS) $(XFLAGS) -o $@ $< $(LDFLAGS)

clean:
ifeq ($(OS),Windows_NT)
	del /Q libmathlib$(LIBEXT) 2>nul || exit 0
else
	rm -f libmathlib$(LIBEXT)
endif

.PHONY: all clean
