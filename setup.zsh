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

# --- Settings ----------------------------------------------------------------

# Answers the user typed in, saved so later runs don't ask again. The file is
# plain zsh (one `NAME=value` per line) and is sourced on startup; edit or
# delete a line to change or re-ask a setting.
SETTINGS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/setup-macos/settings.zsh"

load_settings() {
  mkdir -p "${SETTINGS_FILE:h}"  # :h is zsh for dirname
  touch "$SETTINGS_FILE"
  source "$SETTINGS_FILE"
}

# Usage: ask_setting NAME "Prompt" [REGEX]
# If NAME is unset or empty, prompt until the answer is non-empty (and matches
# REGEX, if given), then append it to the settings file. ${(P)name} reads the
# variable whose name is in $name; ${(q)value} quotes the value so the line
# can be sourced back safely.
ask_setting() {
  local name=$1 prompt=$2 regex=${3:-.} value=""
  [[ -n "${(P)name:-}" ]] && return 0
  while [[ -z "$value" || ! "$value" =~ $regex ]]; do
    read -r "value?$prompt: "
  done
  print -r -- "$name=${(q)value}" >> "$SETTINGS_FILE"
  typeset -g "$name=$value"
}

# Ask everything up front, so the rest of the script can run unattended.
# (The username isn't asked: it's set in Setup Assistant before this runs.)
ask_settings() {
  # A valid hostname: lowercase letters, digits, hyphens; no hyphen at either end.
  ask_setting MACHINE_NAME "Machine name (lowercase, e.g. 'worf')" \
    '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
}

# --- Machine name ------------------------------------------------------------

# Sets all three of macOS's names to the same value:
#   ComputerName  - "Name" in System Settings > General > About; AirDrop.
#   LocalHostName - Bonjour address (NAME.local).
#   HostName      - shown in the shell prompt; pinned so DHCP can't change it.
set_machine_name() {
  local kind
  if [[ "$(scutil --get ComputerName 2>/dev/null)" == "$MACHINE_NAME" &&
        "$(scutil --get LocalHostName 2>/dev/null)" == "$MACHINE_NAME" &&
        "$(scutil --get HostName 2>/dev/null)" == "$MACHINE_NAME" ]]; then
    echo "Machine name: already '$MACHINE_NAME', skipping."
    return 0
  fi

  echo "Machine name: setting to '$MACHINE_NAME'..."
  for kind in ComputerName LocalHostName HostName; do
    sudo scutil --set "$kind" "$MACHINE_NAME"
  done
  echo "Machine name: done."
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

# --- Caps Lock -> Control ----------------------------------------------------

# Writes the same pref as System Settings > Keyboard > Keyboard Shortcuts >
# Modifier Keys. The pref is per keyboard, keyed by VendorID-ProductID-0; the
# built-in keyboard on Apple Silicon is 0-0-0. External keyboards aren't covered.
# Values are HID usages (page 7 << 32 | key): 0x39 is Caps Lock, 0xE4 is Control
# (right Control, which is what System Settings writes).
CAPS_LOCK=30064771129  # 0x700000039
CONTROL=30064771300    # 0x7000000E4
MODIFIER_PREF="com.apple.keyboard.modifiermapping.0-0-0"

# Writing it again is harmless, so there's no already-set check. The pref is
# read at login, so the change takes effect after logging out and back in.
caps_lock_to_control() {
  echo "Caps Lock: mapping to Control..."
  defaults -currentHost write -g "$MODIFIER_PREF" -array \
    "<dict><key>HIDKeyboardModifierMappingSrc</key><integer>$CAPS_LOCK</integer><key>HIDKeyboardModifierMappingDst</key><integer>$CONTROL</integer></dict>"
  echo "Caps Lock: done (takes effect after logging out and back in)."
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

load_settings
ask_settings
start_sudo
set_machine_name
install_gallium
show_input_menu
caps_lock_to_control
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
