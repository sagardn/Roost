#!/bin/sh
#
# Removes Roost and everything it leaves on a Mac.
#
#   sh /Applications/Roost.app/Contents/Resources/Scripts/uninstall.sh
#   sh Tools/uninstall.sh            # if the app is already in the Trash
#
# The list is what Roost itself writes, and nothing else: the app, its
# preferences domain, its Application Support folder, the caches and saved
# state macOS keeps for it, and the Accessibility and notification grants.
# Roost installs no helper, no launch daemon and no kernel extension, so
# nothing here needs administrator rights unless the app was copied into
# /Applications by another user.
#
# Run it as yourself, not with sudo: every path but the app is in your home
# folder, and the permission resets are per user.

set -u

ID="com.sagar.roost"
# Roost was called Perch until 1.0.19, and a Mac that ran it still has that
# name's preferences, folder and grants. Left behind, the preferences would be
# carried into the next install by Roost/Startup/FormerName.swift.
OLD_ID="com.sagar.perch"

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this without sudo -- Roost's data is in your home folder." >&2
    exit 1
fi

echo "Quitting Roost..."
osascript -e "quit app id \"$ID\"" >/dev/null 2>&1 || true
osascript -e "quit app id \"$OLD_ID\"" >/dev/null 2>&1 || true
pkill -x Roost >/dev/null 2>&1 || true
pkill -x Perch >/dev/null 2>&1 || true

echo "Removing the app..."
for app in "/Applications/Roost.app" "$HOME/Applications/Roost.app" \
           "/Applications/Perch.app" "$HOME/Applications/Perch.app"; do
    [ -d "$app" ] || continue
    rm -rf "$app" 2>/dev/null || {
        echo "  $app needs an administrator to remove:"
        sudo rm -rf "$app"
    }
done

echo "Removing preferences and data..."
rm -rf "$HOME/Library/Application Support/Roost" "$HOME/Library/Application Support/Perch"
for id in "$ID" "$OLD_ID"; do
    defaults delete "$id" >/dev/null 2>&1 || true
    defaults delete "$id.LaunchAtLogin" >/dev/null 2>&1 || true
    rm -rf \
        "$HOME/Library/Caches/$id" \
        "$HOME/Library/HTTPStorages/$id" \
        "$HOME/Library/Saved Application State/$id.savedState" \
        "$HOME/Library/Preferences/$id.plist" \
        "$HOME/Library/Preferences/$id.LaunchAtLogin.plist"
done

# The login item is registered through SMAppService against the app's own
# bundle, so it goes when the bundle does; System Settings drops the entry
# on its next refresh. The two grants below do not -- macOS keeps them by
# bundle identifier -- so a reinstall would otherwise inherit stale ones.
echo "Resetting Accessibility and notification permissions..."
for id in "$ID" "$OLD_ID"; do
    tccutil reset Accessibility "$id" >/dev/null 2>&1 || true
    tccutil reset All "$id" >/dev/null 2>&1 || true
done

echo "Roost has been uninstalled."
