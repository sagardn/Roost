#!/bin/bash
#
# Installs the latest Roost release.
#
# Why this exists: Roost is signed ad hoc rather than with a paid Apple
# Developer ID, so macOS refuses to open it when it arrives through a browser
# -- and since macOS 15 the old right-click-Open escape hatch is gone, leaving
# a dialog whose only buttons are "Move to Trash" and "Done".
#
# Quarantine is attached by the program that downloads a file, not by the file
# itself. curl does not attach it, so fetching the DMG this way skips Gatekeeper
# entirely. Nothing here disables a security feature system-wide: the xattr call
# only clears the flag on this one app, and only if one is present.
#
#   curl -fsSL https://raw.githubusercontent.com/sagardn/Roost/main/Tools/install.sh | bash
#
set -euo pipefail

DMG_URL="https://github.com/sagardn/Roost/releases/latest/download/Roost.dmg"
DMG="$(mktemp -t Roost).dmg"
MOUNT="/Volumes/Roost"

cleanup() {
    [ -d "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet || true
    rm -f "$DMG"
}
trap cleanup EXIT

echo "==> downloading Roost"
curl -fsSL "$DMG_URL" -o "$DMG"

echo "==> verifying the disk image"
# A truncated or half-served download fails here rather than half-installing.
hdiutil verify "$DMG" >/dev/null

echo "==> mounting"
[ -d "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet || true
hdiutil attach "$DMG" -nobrowse -quiet

if pgrep -f "/Applications/Roost.app/Contents/MacOS/Roost" >/dev/null; then
    echo "==> quitting the running copy"
    pkill -f "/Applications/Roost.app/Contents/MacOS/Roost" || true
    sleep 2
fi

# Roost was called Perch until 1.0.19. Its settings come across on the
# first launch; the old bundle would only be a second copy holding the same
# hotkeys.
if [ -d /Applications/Perch.app ]; then
    echo "==> removing Perch.app, Roost's old name"
    pkill -x Perch 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Perch.app
fi

echo "==> installing to /Applications"
rm -rf /Applications/Roost.app
cp -R "$MOUNT/Roost.app" /Applications/
xattr -dr com.apple.quarantine /Applications/Roost.app 2>/dev/null || true

echo "==> launching"
open /Applications/Roost.app

cat <<'NOTE'

Roost is running in your menu bar.

It needs Accessibility to move and minimise windows:
  System Settings > Privacy & Security > Accessibility > enable Roost

NOTE
