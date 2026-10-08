#!/bin/sh
#
# make-signing-cert.sh — create the local code-signing identity Rack builds with.
#
#   sh Scripts/make-signing-cert.sh            create (idempotent)
#   sh Scripts/make-signing-cert.sh --remove   tear down completely
#
# WHY THIS EXISTS
#
# Rack cannot be developed with an ad-hoc signature. AudioHardwareCreateProcessTap
# raises a TCC prompt, and TCC remembers the answer against the binary's
# *designated requirement*. Those two forms differ in exactly the way that
# matters:
#
#   ad-hoc      designated => cdhash H"bb72…"
#   this cert   designated => identifier "dev.rack.Rack" and certificate root H"de89…"
#
# The ad-hoc requirement names the code hash, so every rebuild is a different
# program as far as TCC is concerned and the prompt comes back. The certificate
# requirement names the bundle ID and the certificate, neither of which a
# rebuild touches — grant it once and it holds.
#
# Apple-issued certificates need Xcode to provision, so this generates a
# self-signed one instead. macOS reports it as CSSMERR_TP_NOT_TRUSTED and
# `security find-identity -v` will not list it; that is expected and does not
# matter. Chain trust governs Gatekeeper, which does not apply to a locally
# built app, and codesign signs with it regardless. It is not a distribution
# certificate and must never be used as one.
#
# The identity lives in its own keychain rather than the login keychain so that
# --remove is a clean, complete undo and nothing here can disturb the user's
# own credentials. The keychain password below is not a secret: it protects a
# throwaway local dev key and is checked into the repository on purpose, so
# that setup needs no interactive prompt.

set -eu

IDENTITY="Rack Local Signing"
KEYCHAIN_NAME="rack-signing.keychain"
KEYCHAIN_PATH="$HOME/Library/Keychains/${KEYCHAIN_NAME}-db"
PASSWORD="rack-local-signing"
VALID_DAYS=3650

# LibreSSL at /usr/bin, not whatever Homebrew put on PATH: OpenSSL 3 writes
# PKCS#12 with AES/PBKDF2 by default, which Security.framework refuses to
# import.
OPENSSL=/usr/bin/openssl

# search_list_without_ours — current user keychain search list, minus ours,
# one path per line.
search_list_without_ours() {
    security list-keychains -d user | while IFS= read -r line; do
        path=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
        [ -z "$path" ] && continue
        [ "$path" = "$KEYCHAIN_PATH" ] && continue
        printf '%s\n' "$path"
    done
}

# set_search_list <paths…> — replace the user search list.
set_search_list() {
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$@"
}

remove() {
    printf '→ removing %s from the keychain search list\n' "$KEYCHAIN_NAME"
    set --
    while IFS= read -r path; do
        [ -n "$path" ] && set -- "$@" "$path"
    done <<EOF
$(search_list_without_ours)
EOF
    [ "$#" -gt 0 ] && set_search_list "$@"

    if [ -f "$KEYCHAIN_PATH" ]; then
        printf '→ deleting %s\n' "$KEYCHAIN_PATH"
        security delete-keychain "$KEYCHAIN_NAME"
    fi

    printf '✓ removed. Builds fall back to ad-hoc signing.\n'
    printf '  macOS will still hold a TCC grant for the old certificate;\n'
    printf '  clear it with:  tccutil reset All dev.rack.Rack\n'
}

create() {
    if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
        printf '✓ identity "%s" already exists — nothing to do.\n' "$IDENTITY"
        show_fingerprint
        return 0
    fi

    work=$(mktemp -d)
    # The private key exists on disk only between here and the import.
    trap 'rm -rf "$work"' EXIT INT TERM

    printf '→ generating a self-signed code-signing certificate\n'
    cat > "$work/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = Rack Local Signing
O  = Rack

[v3]
basicConstraints     = critical,CA:FALSE
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
EOF

    "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days "$VALID_DAYS" \
        -config "$work/openssl.cnf" \
        -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null

    "$OPENSSL" pkcs12 -export \
        -inkey "$work/key.pem" -in "$work/cert.pem" \
        -out "$work/identity.p12" -passout "pass:$PASSWORD" \
        -name "$IDENTITY"

    printf '→ creating keychain %s\n' "$KEYCHAIN_NAME"
    if [ ! -f "$KEYCHAIN_PATH" ]; then
        security create-keychain -p "$PASSWORD" "$KEYCHAIN_NAME"
    fi
    # No idle timeout and no lock on sleep, so builds never stall on a prompt.
    security set-keychain-settings "$KEYCHAIN_NAME"
    security unlock-keychain -p "$PASSWORD" "$KEYCHAIN_NAME"

    printf '→ importing the identity\n'
    security import "$work/identity.p12" \
        -k "$KEYCHAIN_NAME" -P "$PASSWORD" \
        -A -T /usr/bin/codesign

    # Without this, the first codesign run raises a GUI keychain-access dialog.
    security set-key-partition-list \
        -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN_NAME" \
        > /dev/null 2>&1

    printf '→ adding to the keychain search list\n'
    set --
    while IFS= read -r path; do
        [ -n "$path" ] && set -- "$@" "$path"
    done <<EOF
$(search_list_without_ours)
EOF
    set_search_list "$@" "$KEYCHAIN_PATH"

    if ! security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
        printf '✗ identity did not appear in the search list\n' >&2
        exit 1
    fi

    printf '✓ created "%s"\n' "$IDENTITY"
    show_fingerprint
    printf '\n  Builds pick this up automatically. The audio capture prompt in\n'
    printf '  Phase 1 now needs answering once, not once per build.\n'
}

show_fingerprint() {
    security find-identity -p codesigning 2>/dev/null \
        | grep "$IDENTITY" \
        | sed 's/^/  /'
}

case "${1:-}" in
    --remove) remove ;;
    "")       create ;;
    *)        printf 'usage: %s [--remove]\n' "$0" >&2; exit 2 ;;
esac
