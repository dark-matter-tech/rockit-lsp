#!/bin/bash
# build.sh — Build the Rockit LSP from modular .rok sources
# Concatenates stdlib + compiler + LSP modules, compiles to native binary.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ── Find compiler source ────────────────────────────────────────────────

if [ -n "$ROCKIT_COMPILER_DIR" ]; then
    COMPILER_DIR="$ROCKIT_COMPILER_DIR"
elif [ -d "../moon/RockitCompiler/self-hosted-rockit" ]; then
    COMPILER_DIR="../moon/RockitCompiler"
elif [ -d "../rockit-compiler/src" ]; then
    COMPILER_DIR="../rockit-compiler"
else
    echo "Error: Cannot find compiler source."
    echo "Set ROCKIT_COMPILER_DIR or place rockit-compiler alongside this repo."
    exit 1
fi

# Support both monorepo (self-hosted-rockit/) and polyrepo (src/) layouts
if [ -d "$COMPILER_DIR/self-hosted-rockit" ]; then
    COMPILER_SRC="$COMPILER_DIR/self-hosted-rockit"
elif [ -d "$COMPILER_DIR/src" ]; then
    COMPILER_SRC="$COMPILER_DIR/src"
else
    echo "Error: Cannot find compiler source in $COMPILER_DIR"
    exit 1
fi

# Find stdlib: self-hosted-rockit/stdlib/ or launchpad/
if [ -d "$COMPILER_SRC/stdlib" ]; then
    STDLIB="$COMPILER_SRC/stdlib"
elif [ -d "$COMPILER_DIR/launchpad" ]; then
    STDLIB="$COMPILER_DIR/launchpad"
else
    echo "Error: Cannot find stdlib"
    exit 1
fi

echo "Using compiler source: $COMPILER_SRC"

# ── Find runtime ────────────────────────────────────────────────────────

if [ -n "$ROCKIT_RUNTIME" ]; then
    RUNTIME="$ROCKIT_RUNTIME"
elif [ -f "$COMPILER_DIR/runtime/rockit_runtime.o" ]; then
    RUNTIME="$COMPILER_DIR/runtime/rockit_runtime.o"
elif [ -f "$COMPILER_DIR/runtime/rockit/rockit_runtime.o" ]; then
    RUNTIME="$COMPILER_DIR/runtime/rockit/rockit_runtime.o"
else
    echo "Error: Cannot find rockit_runtime.o"
    exit 1
fi

echo "Using runtime: $RUNTIME"

# ── Find Stage 1 compiler ──────────────────────────────────────────────

COMMAND="$COMPILER_SRC/command"
if [ ! -f "$COMMAND" ]; then
    COMMAND="$(which rockit 2>/dev/null || true)"
    if [ -z "$COMMAND" ]; then
        echo "Error: Stage 1 compiler not found"
        exit 1
    fi
fi

echo "Using compiler: $COMMAND"

# ── Strip main() from a module ──────────────────────────────────────────

strip_main() {
    awk '
    /^fun main\(\)/ { in_main=1; brace=0 }
    in_main && /{/ { brace++ }
    in_main && /}/ { brace--; if (brace<=0) { in_main=0; next } }
    !in_main { print }
    ' "$1"
}

# ── Concatenate modules ────────────────────────────────────────────────

OUTPUT="$SCRIPT_DIR/lsp_combined.rok"
rm -f "$OUTPUT"

echo "Concatenating modules..."

# 0. Polyfills (only what json.rok needs)
cat >> "$OUTPUT" << 'POLYFILL'
// === polyfills ===
fun stringContains(s: String, sub: String): Bool {
    if (stringIndexOf(s, sub) >= 0) { return true }
    return false
}
fun stringSubstring(s: String, start: Int, end: Int): String {
    return substring(s, start, end)
}
fun intToString(value: Int): String {
    return toString(value)
}
POLYFILL

# 1. Stdlib modules
echo "// === stdlib: encoding/json ===" >> "$OUTPUT"
strip_main "$STDLIB/rockit/encoding/json.rok" >> "$OUTPUT"

# 2. Compiler modules (for inline analysis)
echo "// === compiler: lexer ===" >> "$OUTPUT"
strip_main "$COMPILER_SRC/lexer.rok" >> "$OUTPUT"

echo "// === compiler: parser ===" >> "$OUTPUT"
strip_main "$COMPILER_SRC/parser.rok" >> "$OUTPUT"

echo "// === compiler: typechecker ===" >> "$OUTPUT"
strip_main "$COMPILER_SRC/typechecker.rok" >> "$OUTPUT"

# 3. LSP modules (strip main from all except lsp.rok)
echo "// === lsp: jsonrpc ===" >> "$OUTPUT"
strip_main "src/jsonrpc.rok" >> "$OUTPUT"

echo "// === lsp: document ===" >> "$OUTPUT"
strip_main "src/document.rok" >> "$OUTPUT"

echo "// === lsp: navigator ===" >> "$OUTPUT"
strip_main "src/navigator.rok" >> "$OUTPUT"

echo "// === lsp: analysis ===" >> "$OUTPUT"
strip_main "src/analysis.rok" >> "$OUTPUT"

echo "// === lsp: providers ===" >> "$OUTPUT"
strip_main "src/providers.rok" >> "$OUTPUT"

# 4. Main module (KEEP main)
echo "// === lsp: main ===" >> "$OUTPUT"
cat "src/lsp.rok" >> "$OUTPUT"

LINES=$(wc -l < "$OUTPUT" | tr -d ' ')
echo "Concatenated → lsp_combined.rok ($LINES lines)"

# ── Compile ─────────────────────────────────────────────────────────────

echo "Compiling..."
# Compile LSP I/O helpers (C wrappers for stdin/stdout)
EXTRA_OBJ="$SCRIPT_DIR/lsp_io.o"
cat > /tmp/lsp_io.c << 'LSPIO'
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
typedef struct { int64_t refCount; int64_t length; char* chars; void* base; int64_t capacity; char data[]; } RockitString;
extern RockitString* rockit_string_new(const char* s);
RockitString* rpcReadLine(void) {
    char buf[4096];
    if (fgets(buf, sizeof(buf), stdin)) {
        size_t len = strlen(buf);
        if (len > 0 && buf[len - 1] == '\n') buf[len - 1] = '\0';
        return rockit_string_new(buf);
    }
    return rockit_string_new("");
}
int64_t rpcReadBody(int64_t count) {
    char* buf = malloc(count + 1);
    size_t total = fread(buf, 1, count, stdin);
    buf[total] = '\0';
    RockitString* s = rockit_string_new(buf);
    free(buf);
    return (int64_t)s;
}
LSPIO
clang -c -O2 /tmp/lsp_io.c -o "$EXTRA_OBJ" 2>&1
echo "Built LSP I/O helpers"

# Compile with Stage 0 (rockit) — generates correct LLVM IR for large programs
export ROCKIT_RUNTIME_DIR="$(dirname "$RUNTIME")"
echo "Using ROCKIT_RUNTIME_DIR=$ROCKIT_RUNTIME_DIR"

ROCKIT_BIN="$(which rockit 2>/dev/null || true)"
if [ -n "$ROCKIT_BIN" ]; then
    echo "Compiling with Stage 0..."
    "$ROCKIT_BIN" build-native "$OUTPUT" -o rockit-lsp 2>&1
    # Stage 0 outputs to name without -o in some cases
    if [ -f "lsp_combined" ] && [ ! -f "rockit-lsp" ]; then
        mv lsp_combined rockit-lsp
    fi
else
    echo "Compiling with Stage 1..."
    "$COMMAND" build-native "$OUTPUT" --runtime-path "$RUNTIME" -o rockit-lsp 2>&1
fi

echo "Built: rockit-lsp"
ls -la rockit-lsp
