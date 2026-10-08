#!/bin/sh
#
# check-test-registration.sh — a new Tests/RackTests file that compiles but
# was never added to main.swift's call list used to silently never run. This
# is the same class of problem check-boundaries.sh solves for import rules,
# solved the same way: fail the build instead of trusting a hand-maintained
# list to stay complete.
#
#   sh Scripts/check-test-registration.sh [package-root]

set -eu

ROOT="${1:-}"
if [ -z "$ROOT" ]; then
    ROOT=$(cd "$(dirname "$0")/.." && pwd)
fi

TESTS="$ROOT/Tests/RackTests"
MAIN="$TESTS/main.swift"

[ -d "$TESTS" ] || exit 0

printf 'Checking test registration…\n'

missing=0
declared=$(find "$TESTS" -maxdepth 1 -type f -name '*.swift' ! -name 'main.swift' \
    -exec grep -hoE '^func run[A-Za-z0-9_]*Tests\(\)' {} + 2>/dev/null \
    | sed -E 's/^func (run[A-Za-z0-9_]*Tests)\(\)/\1/' \
    | sort -u || true)

for name in $declared; do
    if ! grep -qE "^[[:space:]]*${name}\(\)" "$MAIN" 2>/dev/null; then
        printf '  ✗ %s() is declared but never called from main.swift\n' "$name" >&2
        missing=$((missing + 1))
    fi
done

if [ "$missing" -ne 0 ]; then
    printf '\nTest registration check failed: %s suite(s) declared but not run.\n' \
        "$missing" >&2
    printf 'Add the call to Tests/RackTests/main.swift.\n' >&2
    exit 1
fi

printf 'Test registration check passed.\n'
