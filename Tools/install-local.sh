#!/bin/bash
#
# Builds Roost from this checkout and installs it to /Applications, signed
# with a local self-signed identity.
#
# Why: macOS keys the Accessibility grant to the app's designated
# requirement. An unsigned or ad-hoc build has a requirement made of its own
# code hash, which changes with every build -- so every local install used to
# come up with window control silently revoked. Signed by a certificate,
# the requirement becomes `identifier "com.sagar.roost" and certificate leaf
# = H"…"`, which is the same build after build, and the grant survives.
#
# The identity is any self-signed code-signing certificate in the login
# keychain; free, local, and nothing to do with Apple's paid Developer ID.
# Create one once in Keychain Access ▸ Certificate Assistant ▸ Create a
# Certificate…, type "Code Signing", and name it "Roost Dev" (or set
# ROOST_SIGN_IDENTITY to the name you chose). Without one this falls back to
# an ad-hoc signature and says so.
#
# Releases are unaffected: CI still builds and signs ad hoc.
#
#   Tools/install-local.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."
IDENTITY="${ROOST_SIGN_IDENTITY:-Roost Dev}"
# A certificate made before the rename is called "Perch Dev". The name is only
# a label in the keychain; it is the certificate that the grant is keyed to.
if [ -z "${ROOST_SIGN_IDENTITY:-}" ] \
   && ! security find-identity -v -p codesigning | grep -q "\"$IDENTITY\"" \
   && security find-identity -v -p codesigning | grep -q '"Perch Dev"'; then
    IDENTITY="Perch Dev"
fi
DERIVED=build/local
APP="$DERIVED/Build/Products/Release/Roost.app"

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "==> building, signed as \"$IDENTITY\""
    SIGNING=(CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""
             OTHER_CODE_SIGN_FLAGS="--timestamp=none")
else
    echo "==> no \"$IDENTITY\" identity in the keychain; building ad hoc"
    echo "    (Accessibility will need granting again after this install)"
    SIGNING=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="")
fi

# The bundle, not the derived data: an incremental build leaves the previous
# Roost.app in place and updates it, and a resource that changed outside the
# compiler's view -- a .lproj rewritten between builds -- then fails
# `codesign --verify` with "a sealed resource is missing or invalid", which
# reads as a signing problem and is a staleness problem. Removing the bundle
# costs a re-link and a re-sign; the compiled objects are kept.
rm -rf "$APP"

xcodebuild -project Roost.xcodeproj -scheme Roost -configuration Release \
    -derivedDataPath "$DERIVED" "${SIGNING[@]}" build -quiet

codesign --verify --deep --strict "$APP"
echo "==> $(codesign -dr - "$APP" 2>&1 | tail -1)"

if pgrep -f "/Applications/Roost.app/Contents/MacOS/Roost" >/dev/null; then
    echo "==> quitting the running copy"
    osascript -e 'quit app "Roost"' 2>/dev/null || true
    sleep 2
    pkill -f "/Applications/Roost.app/Contents/MacOS/Roost" || true
fi

# The app before it was renamed. Roost brings its settings across on first
# launch; the old bundle left beside it would be a second copy holding the
# same hotkeys.
if [ -d /Applications/Perch.app ]; then
    echo "==> removing Perch.app, the app's old name"
    osascript -e 'quit app "Perch"' 2>/dev/null || true
    sleep 1
    pkill -x Perch 2>/dev/null || true
    rm -rf /Applications/Perch.app
fi

echo "==> installing to /Applications"
rm -rf /Applications/Roost.app
ditto "$APP" /Applications/Roost.app
open /Applications/Roost.app
echo "==> done"
