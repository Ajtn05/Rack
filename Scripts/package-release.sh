#!/bin/sh
# Build a universal release archive. Preview builds use an ad-hoc signature;
# public distribution can opt into Developer ID signing and notarization.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOTARIZE=0
case "${1:-}" in
    "") ;;
    --notarize) NOTARIZE=1 ;;
    --help|-h)
        printf 'Usage: sh Scripts/package-release.sh [--notarize]\n'
        exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { printf 'Too many arguments.\n' >&2; exit 2; }

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")
MINIMUM=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Resources/Info.plist")
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
    printf 'Bundle version must have the form 0.0.1.\n' >&2; exit 1;
}
NOTES="$ROOT/Resources/ReleaseNotes/$VERSION.txt"
if [ ! -f "$NOTES" ]; then
    # Older locally prepared previews kept their notes with ignored docs.
    NOTES="$ROOT/agents/docs/releases/$VERSION.md"
fi
[ -f "$NOTES" ] || {
    printf 'Add Resources/ReleaseNotes/%s.txt before packaging.\n' "$VERSION" >&2; exit 1;
}

if [ "$NOTARIZE" -eq 1 ]; then
    case "${RACK_SIGN_IDENTITY:-}" in
        'Developer ID Application:'*) ;;
        *) printf 'Set RACK_SIGN_IDENTITY to a Developer ID Application identity.\n' >&2; exit 1 ;;
    esac
    : "${RACK_NOTARY_PROFILE:?Set RACK_NOTARY_PROFILE to a notarytool keychain profile}"
fi

cd "$ROOT"
# Each invocation owns a new directory. Previously prepared packages remain
# intact even when a newer build fails.
OUT="${RACK_PACKAGE_OUTPUT:-$ROOT/dist/packages/$VERSION/$(date -u '+%Y%m%dT%H%M%SZ')-$$}"
LABEL="${RACK_PACKAGE_LABEL:-}"
case "$LABEL" in
    *[!A-Za-z0-9.-]*) printf 'Invalid package label.\n' >&2; exit 2 ;;
esac
[ ! -e "$OUT" ] || { printf 'Output already exists: %s\n' "$OUT" >&2; exit 1; }
mkdir -p "$OUT"
STAGING=$(mktemp -d "$OUT/.package.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM

if [ -n "${RACK_SIGN_IDENTITY:-}" ]; then
    sh Scripts/build-app.sh --release --universal
    SIGNING=certificate
else
    # Never ship a local development certificate by accident.
    sh Scripts/build-app.sh --release --universal --ad-hoc
    SIGNING=ad-hoc
fi

APP="$ROOT/.build/app/release/Rack.app"
codesign --verify --strict --verbose=2 "$APP"
for arch in arm64 x86_64; do
    lipo "$APP/Contents/MacOS/Rack" -verify_arch "$arch"
done
codesign -d --entitlements :- "$APP" > "$STAGING/entitlements.plist" 2>/dev/null
if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$STAGING/entitlements.plist")" != true ]; then
    printf 'Release app is missing the audio-input entitlement.\n' >&2
    exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$STAGING/entitlements.plist" 2>/dev/null | grep -q true; then
    printf 'Release app must not include the debugger entitlement.\n' >&2
    exit 1
fi
ditto "$APP" "$STAGING/Rack.app"

NOTARIZED=false
SUFFIX=-preview
if [ "$NOTARIZE" -eq 1 ]; then
    ditto -c -k --sequesterRsrc --keepParent "$STAGING/Rack.app" "$STAGING/notarization.zip"
    xcrun notarytool submit "$STAGING/notarization.zip" \
        --keychain-profile "$RACK_NOTARY_PROFILE" --wait --output-format plist \
        > "$STAGING/notarization.plist"
    STATUS=$(/usr/libexec/PlistBuddy -c 'Print :status' "$STAGING/notarization.plist")
    if [ "$STATUS" != Accepted ]; then
        cat "$STAGING/notarization.plist" >&2
        printf 'Notarization failed. No distributable archive was produced.\n' >&2
        exit 1
    fi
    xcrun stapler staple "$STAGING/Rack.app"
    xcrun stapler validate "$STAGING/Rack.app"
    spctl --assess --type execute --verbose=2 "$STAGING/Rack.app"
    NOTARIZED=true
    SUFFIX=
fi

NAME="Rack-$VERSION${LABEL:+-$LABEL}-macOS-universal$SUFFIX.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGING/Rack.app" "$STAGING/$NAME"
unzip -tq "$STAGING/$NAME"
shasum -a 256 "$STAGING/$NAME" | awk -v name="$NAME" '{ print $1 "  " name }' > "$STAGING/SHA256SUMS"
SHA=$(awk '{ print $1 }' "$STAGING/SHA256SUMS")
COMMIT=$(git -c core.fsmonitor=false rev-parse --verify HEAD 2>/dev/null || printf uncommitted)
DIRTY=false
if [ -n "$(git -c core.fsmonitor=false status --porcelain 2>/dev/null)" ]; then DIRTY=true; fi
cat > "$STAGING/release-info.json" <<EOF
{
  "version": "$VERSION",
  "build": "$BUILD",
  "minimumMacOS": "$MINIMUM",
  "architectures": ["arm64", "x86_64"],
  "signing": "$SIGNING",
  "notarized": $NOTARIZED,
  "sourceCommit": "$COMMIT",
  "sourceHasChanges": $DIRTY,
  "builtAtUTC": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "archive": "$NAME",
  "sha256": "$SHA"
}
EOF

# Publish files into the new package directory only after all checks pass.
mv "$STAGING/$NAME" "$STAGING/SHA256SUMS" "$STAGING/release-info.json" "$OUT/"
cp "$NOTES" "$OUT/release-notes.md"
printf '\nPrepared %s\n' "$OUT/$NAME"
if [ "$NOTARIZED" = false ]; then
    printf 'Preview only: this app is not notarized; macOS Gatekeeper may block it.\n'
fi
