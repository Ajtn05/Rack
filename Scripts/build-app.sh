#!/bin/sh
#
# build-app.sh — build the SwiftPM executable and wrap it in a signed .app.
#
#   sh Scripts/build-app.sh [--release] [--universal] [--ad-hoc] [--run]
#
# We assemble the bundle by hand rather than through Xcode: the package builds
# with Command Line Tools alone.
#
# SIGNING
#
# Signing is not optional — AudioHardwareCreateProcessTap only raises its TCC
# prompt for a signed binary, and a bare SwiftPM executable is not one. The
# identity is chosen in this order:
#
#   1. $RACK_SIGN_IDENTITY, if set — a real Apple-issued certificate.
#   2. "Rack Local Signing", if Scripts/make-signing-cert.sh has been run.
#      Stable designated requirement, so the TCC grant survives rebuilds.
#   3. Ad-hoc. Works, but the audio capture prompt returns on every rebuild.
#
# Run `sh Scripts/make-signing-cert.sh` once if you are in case 3.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOCAL_IDENTITY="Rack Local Signing"
CONFIG=debug
RUN=0
UNIVERSAL=0
ADHOC=0

for arg in "$@"; do
    case "$arg" in
        --release) CONFIG=release ;;
        --universal) UNIVERSAL=1 ;;
        --ad-hoc) ADHOC=1 ;;
        --run)     RUN=1 ;;
        --help|-h)
            printf 'Usage: sh Scripts/build-app.sh [--release] [--universal] [--ad-hoc] [--run]\n'
            exit 0 ;;
        *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Identity selection
# ---------------------------------------------------------------------------
if [ "$ADHOC" -eq 1 ]; then
    IDENTITY="-"
    KIND=adhoc
elif [ -n "${RACK_SIGN_IDENTITY:-}" ]; then
    IDENTITY="$RACK_SIGN_IDENTITY"
    KIND=explicit
elif security find-identity -p codesigning 2>/dev/null | grep -q "$LOCAL_IDENTITY"; then
    IDENTITY="$LOCAL_IDENTITY"
    KIND=local
else
    IDENTITY="-"
    KIND=adhoc
fi

cd "$ROOT"

# ---------------------------------------------------------------------------
# An installed-but-unlicensed Xcode blocks every toolchain invocation, and the
# error ("You have not agreed to the Xcode license agreements") reads like a
# build failure rather than a one-command fix. Command Line Tools has no such
# gate, so fall back to it and say why. Self-clearing: once the license is
# accepted this branch stops firing.
# ---------------------------------------------------------------------------
if xcrun --show-sdk-path 2>&1 | grep -q 'license'; then
    if [ -d /Library/Developer/CommandLineTools ]; then
        printf '! Xcode is installed but its license has not been accepted.\n'
        printf '  Falling back to Command Line Tools. To fix properly:\n'
        printf '      sudo xcodebuild -license accept\n\n'
        DEVELOPER_DIR=/Library/Developer/CommandLineTools
        export DEVELOPER_DIR
    else
        printf 'Xcode license not accepted. Run: sudo xcodebuild -license accept\n' >&2
        exit 1
    fi
fi

printf '→ swift build (%s)\n' "$CONFIG"
if [ "$UNIVERSAL" -eq 1 ]; then
    # Separate scratch directories work with Command Line Tools and avoid
    # mixing architecture-specific objects or overwriting a development build.
    minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Resources/Info.plist")
    for arch in arm64 x86_64; do
        scratch="$ROOT/.build/universal/$arch"
        triple="$arch-apple-macosx$minimum"
        swift build -c "$CONFIG" --product Rack --scratch-path "$scratch" --triple "$triple"
        bin="$(swift build -c "$CONFIG" --scratch-path "$scratch" --triple "$triple" --show-bin-path)/Rack"
        [ -x "$bin" ] || { printf 'no executable at %s\n' "$bin" >&2; exit 1; }
        case "$arch" in
            arm64) ARM_BIN="$bin" ;;
            x86_64) INTEL_BIN="$bin" ;;
        esac
    done
else
    swift build -c "$CONFIG" --product Rack
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/Rack"
    [ -x "$BIN" ] || { printf 'no executable at %s\n' "$BIN" >&2; exit 1; }
fi

APP="$ROOT/.build/app/$CONFIG/Rack.app"

printf '→ assembling %s\n' "${APP#"$ROOT"/}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ "$UNIVERSAL" -eq 1 ]; then
    lipo -create "$ARM_BIN" "$INTEL_BIN" -output "$APP/Contents/MacOS/Rack"
    for arch in arm64 x86_64; do
        lipo "$APP/Contents/MacOS/Rack" -verify_arch "$arch"
    done
else
    cp "$BIN" "$APP/Contents/MacOS/Rack"
fi
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/MenuBarIcon.png" "$APP/Contents/Resources/MenuBarIcon.png"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ---------------------------------------------------------------------------
# Entitlements
#
# Re-signing the bundle discards the get-task-allow entitlement SwiftPM puts on
# the raw executable, and without it a hardened-runtime binary cannot be
# attached to by a debugger. Since Phase 1 onward is largely Core Audio
# debugging, debug builds get it added back.
# ---------------------------------------------------------------------------
ENTITLEMENTS="$ROOT/Resources/Rack.entitlements"
if [ "$CONFIG" = debug ]; then
    ENTITLEMENTS="$ROOT/.build/app/$CONFIG/Rack.debug.entitlements"
    cp "$ROOT/Resources/Rack.entitlements" "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c \
        "Add :com.apple.security.get-task-allow bool true" "$ENTITLEMENTS" \
        > /dev/null
fi

# ---------------------------------------------------------------------------
# Signing
#
# The hardened runtime is what gives the audio-input entitlement meaning, so it
# is on for anything cert-backed. Pairing it with an ad-hoc signature buys
# nothing and complicates debugging. Timestamping needs Apple's timestamp
# authority to accept the certificate, which it will not do for a self-signed
# one, so it is requested only for an explicitly supplied identity.
# ---------------------------------------------------------------------------
case "$KIND" in
    adhoc)
        printf '→ codesign (ad-hoc — TCC will re-prompt on every rebuild)\n'
        codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
        ;;
    local)
        printf '→ codesign (%s)\n' "$IDENTITY"
        codesign --force --sign "$IDENTITY" \
            --options runtime --timestamp=none \
            --entitlements "$ENTITLEMENTS" "$APP"
        ;;
    explicit)
        printf '→ codesign (%s)\n' "$IDENTITY"
        codesign --force --sign "$IDENTITY" \
            --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" "$APP"
        ;;
esac

codesign --verify --strict --verbose=1 "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated | sed 's/^/   /'

printf '✓ %s\n' "$APP"

if [ "$KIND" = adhoc ]; then
    printf '\n  Tip: sh Scripts/make-signing-cert.sh  — makes the TCC grant stick.\n'
fi

if [ "$RUN" -eq 1 ]; then
    printf '→ launching\n'
    open "$APP"
fi
