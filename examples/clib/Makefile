# Makefile for building C libraries for Etch FFI testing

CC = clang
CFLAGS = -shared -fPIC -O2
LDFLAGS =

# Platform-specific settings
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    XFLAGS = -isysroot $(shell xcrun --show-sdk-path)
    LIBEXT = .dylib
else ifeq ($(UNAME_S),Linux)
    XFLAGS =
    LIBEXT = .so
else
    XFLAGS =
    LIBEXT = .dll
endif

all: libmathlib$(LIBEXT)

libmathlib$(LIBEXT): mathlib.c
	$(CC) $(CFLAGS) $(XFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f libmathlib$(LIBEXT)

.PHONY: all clean
