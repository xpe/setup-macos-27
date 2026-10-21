#!/bin/zsh

# Strict mode: exit on any error (-e), on unset variables (-u),
# and on failure anywhere in a pipeline (pipefail).
set -euo pipefail

# --- Cleanup ---------------------------------------------------------------

# Globals: set by start_sudo / install_gallium, read by cleanup.
# Defined empty up front so cleanup can read them under `set -u` even if
# the script exits before they are set.
keepalive_pid=""
tmp=""

# Stop the sudo keep-alive loop and remove the temp directory, if they exist.
cleanup() {
  [[ -n "$keepalive_pid" ]] && kill "$keepalive_pid" 2>/dev/null
  [[ -n "$tmp" ]] && rm -rf "$tmp"
  return 0
}

# Run cleanup when the script exits. Must be set at top level: in zsh,
# an EXIT trap set inside a function fires when that function returns.
trap cleanup EXIT

# zsh skips the EXIT trap on signals; convert Ctrl-C / kill into a normal exit.
trap 'exit 130' INT TERM

# --- sudo --------------------------------------------------------------------

start_sudo() {
  # Prompt for the password once.
  sudo -v
  # Refresh sudo's cached credentials every 60s in the background.
  while true; do sudo -n true; sleep 60; done 2>/dev/null &
  keepalive_pid=$!
}

# --- Gallium keyboard layout -------------------------------------------------

GALLIUM_DEST="/Library/Keyboard Layouts/Gallium_r5.bundle"
GALLIUM_URL="https://github.com/xpe/gallium/raw/trunk/macOS/Gallium_r5.bundle.zip"

# Set to 1 by install_gallium when it installs; gates the manual-step message.
gallium_installed=0

install_gallium() {
  if [[ -d "$GALLIUM_DEST" ]]; then
    echo "Gallium: already installed, skipping."
    return 0
  fi

  echo "Gallium: installing..."
  tmp=$(mktemp -d)

  # -f fail on HTTP error, -sS quiet but show errors, -L follow redirects.
  curl -fsSL -o "$tmp/gallium.zip" "$GALLIUM_URL"

  # ditto: Apple's unzipper; preserves macOS file metadata. -x extract, -k zip.
  ditto -x -k "$tmp/gallium.zip" "$tmp/unzipped"

  # The zip has Gallium_r5.bundle at its top level.
  sudo cp -R "$tmp/unzipped/Gallium_r5.bundle" "/Library/Keyboard Layouts/"
  gallium_installed=1
  echo "Gallium: done."
}

# --- Input sources -----------------------------------------------------------

# Enabling Gallium as an input source is left to the user (see end of script):
# macOS doesn't see a newly installed layout until after logout, and the
# AppleEnabledInputSources pref isn't a reliable record of what's enabled.

# Show the input menu (layout switcher) in the menu bar.
show_input_menu() {
  echo "Input menu: showing in menu bar..."
  defaults write com.apple.TextInputMenu visible -bool true
  killall TextInputMenuAgent 2>/dev/null || true  # restarts the menu agent
  echo "Input menu: done."
}

# --- Dock --------------------------------------------------------------------

clear_dock() {
  # An empty persistent-apps array reads back as "(\n)".
  local current
  current=$(defaults read com.apple.dock persistent-apps 2>/dev/null || true)
  if [[ "$current" == $'(\n)' ]]; then
    echo "Dock: already empty, skipping."
    return 0
  fi

  echo "Dock: clearing pinned apps..."
  defaults write com.apple.dock persistent-apps -array
  killall Dock  # restarts the Dock so the change takes effect
  echo "Dock: done."
}

# --- Main --------------------------------------------------------------------

start_sudo
install_gallium
show_input_menu
clear_dock

echo "All steps complete."

if (( gallium_installed )); then
  cat <<'EOF'

The Gallium keyboard layout was just installed. To enable it:
  1. Log out and back in.
  2. System Settings > Keyboard > Text Input > Input Sources > Edit...
  3. Click +, find Gallium, click Add.
EOF
fi
