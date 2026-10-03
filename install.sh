#!/bin/bash
# One command. Builds the hotkey app, installs the privileged helper, starts
# both, and leaves you with ⌘9.
#
# Run it WITHOUT sudo. It asks for your password once, for the one part that
# genuinely needs root: loading firewall rules.
set -euo pipefail

[ "$(id -u)" != 0 ] || { printf 'Run this WITHOUT sudo:  ./install.sh\n' >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || { printf 'macOS only (it is built on pf and the macOS window server).\n' >&2; exit 1; }

SRC=$(cd "$(dirname "$0")" && pwd)
APP="/Applications/App Test.app"
CLI_DIR="$HOME/.local/libexec/netcut"
BIN="$HOME/.local/bin"
AGENT_LABEL=com.netcut.hotkey
HELPER_LABEL=com.netcut.helper

step() { printf '\n==> %s\n' "$*"; }

command -v swiftc >/dev/null || {
  printf 'swiftc not found. Install the Command Line Tools first:\n'
  printf '    xcode-select --install\n' >&2
  exit 1; }

# ---------------------------------------------------------------- hotkey app
step "Building the hotkey app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 5 -O -framework AppKit -framework Carbon \
  "$SRC/hotkey/main.swift" -o "$APP/Contents/MacOS/AppTest"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>App Test</string>
  <key>CFBundleDisplayName</key>     <string>App Test</string>
  <key>CFBundleExecutable</key>      <string>AppTest</string>
  <key>CFBundleIdentifier</key>      <string>com.netcut.hotkey</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>LSMinimumSystemVersion</key>  <string>12.0</string>
  <key>LSUIElement</key>             <true/>
</dict>
PLIST
printf '</plist>\n' >> "$APP/Contents/Info.plist"
# So Spotlight sees it immediately rather than on its next sweep.
touch "$APP"; /usr/bin/mdimport "$APP" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------- CLI
step "Installing the netcut command"
mkdir -p "$CLI_DIR/lib" "$BIN"
install -m 755 "$SRC/netcut"        "$CLI_DIR/netcut"
install -m 644 "$SRC/lib/common.sh" "$CLI_DIR/lib/common.sh"
ln -sf "$CLI_DIR/netcut" "$BIN/netcut"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) printf '    note: %s is not on your PATH; the menu-bar app works regardless\n' "$BIN" ;;
esac

# ----------------------------------------------------------- privileged half
step "Checking the firewall rules parse"
"$SRC/netcutd" rulecheck || {
  printf 'refusing to install: the generated pf rules do not parse\n' >&2; exit 1; }

step "Installing the privileged helper (this is the password prompt)"
ME=$(id -un)
TMP_PLIST=$(mktemp)
cat > "$TMP_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>              <string>$HELPER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/libexec/netcut/netcutd</string>
    <string>serve</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>NETCUT_TRIGGER_USER</key> <string>$ME</string>
    <key>PATH</key>                <string>/usr/sbin:/usr/bin:/sbin:/bin</string>
  </dict>
  <key>RunAtLoad</key>          <true/>
  <key>KeepAlive</key>          <true/>
  <key>ProcessType</key>        <string>Interactive</string>
  <key>StandardErrorPath</key>  <string>/var/log/netcut.err</string>
</dict>
PLIST
printf '</plist>\n' >> "$TMP_PLIST"

sudo install -d -o root -g wheel -m 755 /usr/local/libexec/netcut \
                                        /usr/local/libexec/netcut/lib \
                                        /usr/local/libexec/netcut/profiles
sudo install -o root -g wheel -m 755 "$SRC/netcutd"        /usr/local/libexec/netcut/netcutd
sudo install -o root -g wheel -m 644 "$SRC/lib/common.sh"  /usr/local/libexec/netcut/lib/common.sh
sudo install -o root -g wheel -m 644 "$SRC"/profiles/*.conf /usr/local/libexec/netcut/profiles/
# Never clobber a curated list: the shipped one lands as .default, and is
# promoted only if nothing is installed yet.
sudo install -o root -g wheel -m 644 "$SRC/exclusions.txt" /usr/local/libexec/netcut/exclusions.txt.default
[ -f /usr/local/libexec/netcut/exclusions.txt ] \
  || sudo install -o root -g wheel -m 644 "$SRC/exclusions.txt" /usr/local/libexec/netcut/exclusions.txt
sudo install -o root -g wheel -m 644 "$TMP_PLIST" "/Library/LaunchDaemons/$HELPER_LABEL.plist"
rm -f "$TMP_PLIST"

sudo launchctl bootout "system/$HELPER_LABEL" >/dev/null 2>&1 || true
sudo pfctl -a com.apple/netcut -F all >/dev/null 2>&1 || true
sudo rm -f /var/run/netcut/state
sudo launchctl bootstrap system "/Library/LaunchDaemons/$HELPER_LABEL.plist" >/dev/null 2>&1 || true

# --------------------------------------------------------------- the agent
step "Starting the hotkey"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$HOME/Library/LaunchAgents/$AGENT_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>              <string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/AppTest</string></array>
  <key>RunAtLoad</key>          <true/>
  <key>KeepAlive</key>          <true/>
  <key>ProcessType</key>        <string>Interactive</string>
  <key>StandardErrorPath</key>  <string>$HOME/Library/Logs/netcut-hotkey-stderr.log</string>
</dict>
PLIST
printf '</plist>\n' >> "$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

launchctl bootout "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$AGENT_LABEL.plist" >/dev/null 2>&1 || true
sleep 1

# ------------------------------------------------------------------- verify
ok=1
launchctl print "system/$HELPER_LABEL" >/dev/null 2>&1 || { printf '\nthe privileged helper did not start (see /var/log/netcut.err)\n' >&2; ok=0; }
launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 || { printf '\nthe hotkey app did not start (see ~/Library/Logs/netcut-hotkey-stderr.log)\n' >&2; ok=0; }
[ "$ok" = 1 ] || exit 1

cat <<DONE

Done.

  Press ⌘9                 cut the app you are in. Press it again to reconnect.
  The dot in the menu bar  blue = that app's network is down, grey = connected.
  Click the dot            to pick a specific app instead of the one in front.
  Spotlight "App Test"     same thing, if the dot ever goes missing.

  netcut toggle            the same from a terminal
  ./uninstall.sh           removes all of it
  lab/netcut-lab           fault injection for a service you run

DONE
