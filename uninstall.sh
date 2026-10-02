#!/bin/bash
# Removes everything install.sh put on this machine.
set -uo pipefail
[ "$(id -u)" != 0 ] || { printf 'run this WITHOUT sudo\n' >&2; exit 1; }

launchctl bootout "gui/$(id -u)/com.netcut.hotkey" >/dev/null 2>&1
rm -f "$HOME/Library/LaunchAgents/com.netcut.hotkey.plist"
rm -rf "/Applications/App Test.app"
rm -f "$HOME/.local/bin/netcut"
rm -rf "$HOME/.local/libexec/netcut"

printf 'Removing the privileged helper (needs your password)...\n'
sudo launchctl bootout system/com.netcut.helper >/dev/null 2>&1
sudo pfctl -a com.apple/netcut -F all >/dev/null 2>&1
sudo rm -f /Library/LaunchDaemons/com.netcut.helper.plist
sudo rm -rf /usr/local/libexec/netcut /var/run/netcut

printf 'Done. \u2318\u0039 goes back to whatever app you are in.\n'
