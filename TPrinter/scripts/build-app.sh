#!/usr/bin/env bash
# Builds TPrinter in release mode and wraps it in a signed .app bundle.
# Usage: ./scripts/build-app.sh [--run]
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="TPrinter"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

# The Command Line Tools' macOS 27 SDK needs the SwiftUIMacros plugin (only shipped with Xcode)
# for @State, so build against the 26.x SDK unless the caller overrides SDKROOT.
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}"

# --- Signing -------------------------------------------------------------------
# macOS remembers the Bluetooth permission per code identity. An ad-hoc signature's
# identity is the binary hash, which changes on every build and silently revokes the
# permission ("Bluetooth not authorized"). A self-signed certificate kept in a
# project-local keychain gives a stable identity instead.
SIGNING_DIR="$PWD/.signing"
KEYCHAIN="$SIGNING_DIR/tprinter.keychain-db"
KEYCHAIN_PASSWORD="tprinter"
CERT_NAME="TPrinter Local Signing"

create_signing_identity() {
    echo "Creating local code-signing certificate in ${SIGNING_DIR}..."
    mkdir -p "$SIGNING_DIR"
    local tmp
    tmp="$(mktemp -d)"
    cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$CERT_NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$tmp/key.pem" -out "$SIGNING_DIR/cert.pem" -config "$tmp/cert.cnf" 2>/dev/null
    local legacy=""
    openssl version | grep -q "^OpenSSL 3" && legacy="-legacy"
    openssl pkcs12 -export $legacy -inkey "$tmp/key.pem" -in "$SIGNING_DIR/cert.pem" \
        -out "$tmp/identity.p12" -passout "pass:$KEYCHAIN_PASSWORD"
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN" # no auto-lock timeout
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security import "$tmp/identity.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
    rm -rf "$tmp"
}

sign_app() {
    if ! command -v openssl >/dev/null; then
        echo "warning: openssl not found, falling back to ad-hoc signing (Bluetooth permission resets each build)" >&2
        codesign --force --sign - --timestamp=none "$APP"
        return
    fi
    [[ -f "$KEYCHAIN" && -f "$SIGNING_DIR/cert.pem" ]] || create_signing_identity

    local hash original
    hash="$(openssl x509 -in "$SIGNING_DIR/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

    # codesign only finds identities in keychains on the user search list: add ours
    # temporarily and always restore the original list.
    original="$(security list-keychains -d user | tr -d '"' | xargs)"
    trap "security list-keychains -d user -s $original" EXIT
    security list-keychains -d user -s $original "$KEYCHAIN"
    codesign --force --sign "$hash" --keychain "$KEYCHAIN" --timestamp=none "$APP"
    security list-keychains -d user -s $original
    trap - EXIT
}

# --- Build & bundle ------------------------------------------------------------
# Separate scratch path: sharing .build with `swift test` debug builds leaves it stale
# ("plugin for module 'TestingMacros' not found").
SCRATCH=".build-app"
swift build -c release --scratch-path "$SCRATCH"

BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

sign_app
codesign --verify "$APP"

echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
    open "$APP"
fi
