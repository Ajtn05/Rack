#!/bin/sh
#
# check-boundaries.sh — mechanical enforcement of the module rules in
# ARCHITECTURE.md. Run by BoundaryCheckPlugin on every `swift build`, and
# standalone in CI:
#
#   sh Scripts/check-boundaries.sh [package-root]
#
# Exits non-zero with a description of every violation found. It reads only
# .swift files under Sources/, so it is safe to run from a build sandbox.

set -eu

ROOT="${1:-}"
if [ -z "$ROOT" ]; then
    ROOT=$(cd "$(dirname "$0")/.." && pwd)
fi

SRC="$ROOT/Sources"
THEMES="$SRC/DesignSystem/Themes"
violations=0

# Patterns are assembled from character classes so this file does not itself
# contain the literal shapes it bans.
HEX='#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]'
RGB='Color\(red:'

note() { printf '  ✗ %s\n' "$1" >&2; }

# print_hits <grep-output> — one indented, root-relative line per match.
print_hits() {
    printf '%s\n' "$1" | while IFS= read -r line; do
        [ -n "$line" ] && note "${line#"$ROOT"/}"
    done
}

# forbid_import <target-dir> <module-alternation> <why>
#   Catches `import Foo`, `@preconcurrency import Foo`, `import Foo.Bar`.
forbid_import() {
    dir="$SRC/$1"
    [ -d "$dir" ] || return 0
    pattern="^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+($2)([[:space:]]*\$|\.)"
    hits=$(find "$dir" -type f -name '*.swift' \
        -exec grep -HnE "$pattern" {} + 2>/dev/null || true)
    if [ -n "$hits" ]; then
        print_hits "$hits"
        note "$1 must not import $2 — $3"
        violations=$((violations + 1))
    fi
}

printf 'Checking module boundaries…\n'

# ---------------------------------------------------------------------------
# 1. AudioCore is UI-free. The realtime engine must be buildable, testable and
#    reasonable about without a window server anywhere in the picture.
# ---------------------------------------------------------------------------
forbid_import AudioCore 'SwiftUI|AppKit' \
    'the audio engine must stay free of UI frameworks'

# ---------------------------------------------------------------------------
# 2. DesignSystem is audio-free and sits below AppCore. A skin must be
#    swappable without recompiling a single line of DSP.
# ---------------------------------------------------------------------------
forbid_import DesignSystem 'AudioCore' \
    'components take plain data and callbacks, never audio types'
forbid_import DesignSystem 'AppCore|App' \
    'dependency arrows point downward only'

# ---------------------------------------------------------------------------
# 3. AudioCore sits below AppCore too.
# ---------------------------------------------------------------------------
forbid_import AudioCore 'AppCore|DesignSystem|App' \
    'dependency arrows point downward only'

# ---------------------------------------------------------------------------
# 4. App talks to AppCore and nothing else.
#
#    Added after the Phase 2 screen quietly reached past AppCore for EQBank
#    and DSPParameters. It built, and it looked harmless, and it meant a
#    Core Audio type was named in a view — which is exactly the coupling the
#    layout exists to prevent. AppCore restates what a screen needs.
# ---------------------------------------------------------------------------
forbid_import App 'AudioCore|RackRealtime' \
    'reach only as far as AppCore; it restates what a screen needs'

# ---------------------------------------------------------------------------
# 5. No appearance literals outside Sources/DesignSystem/Themes/.
#    Every other file reads its colors from the injected theme.
# ---------------------------------------------------------------------------
if [ -d "$SRC" ]; then
    literals=$(find "$SRC" -type f -name '*.swift' -not -path "$THEMES/*" \
        -exec grep -HnE -e "$HEX" -e "$RGB" {} + 2>/dev/null || true)
    if [ -n "$literals" ]; then
        print_hits "$literals"
        note 'appearance literals belong in Sources/DesignSystem/Themes/ only'
        violations=$((violations + 1))
    fi
fi

# ---------------------------------------------------------------------------
# 6. No named appearance values outside Themes/ either.
#
#    Rule 5 catches hex strings, which is what the brief asked for, but it is
#    not the only way a skin decision escapes. `Color.teal` and `.font(.title)`
#    are just as hardcoded — arguably worse, because they look principled.
#    Added when Phase 6 gave the codebase real components to get this wrong in.
#
#    `Color.clear` is deliberately absent from the list: it means "draw
#    nothing", which is a layout decision rather than an appearance one.
# ---------------------------------------------------------------------------
NAMED='red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown'
NAMED="$NAMED|white|black|gray|grey|primary|secondary|tertiary|quaternary"
FONTS='system|largeTitle|title|title2|title3|headline|subheadline|body'
FONTS="$FONTS|callout|footnote|caption|caption2"

COLOR_LITERAL="Color\.($NAMED|accentColor)[^A-Za-z]"
STYLE_LITERAL="\.(foregroundStyle|foregroundColor|fill|tint|stroke|background)\(\.($NAMED)\)"
FONT_LITERAL="\.font\(\.($FONTS)[^A-Za-z]"

if [ -d "$SRC" ]; then
    named=$(find "$SRC" -type f -name '*.swift' -not -path "$THEMES/*" \
        -exec grep -HnE -e "$COLOR_LITERAL" -e "$STYLE_LITERAL" -e "$FONT_LITERAL" {} + \
        2>/dev/null || true)
    if [ -n "$named" ]; then
        print_hits "$named"
        note 'named colours and system fonts are theme decisions — use a token'
        violations=$((violations + 1))
    fi
fi

# ---------------------------------------------------------------------------

if [ "$violations" -ne 0 ]; then
    printf '\nBoundary check failed: %s violation(s). See ARCHITECTURE.md.\n' \
        "$violations" >&2
    exit 1
fi

printf 'Boundary check passed.\n'
