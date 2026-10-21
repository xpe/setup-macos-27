#!/bin/zsh

# Strict mode: exit on any error (-e), on unset variables (-u),
# and on failure anywhere in a pipeline (pipefail).
set -euo pipefail

# --- Cleanup ---------------------------------------------------------------

# Globals: set by start_sudo / install_command_line_tools / install_gallium,
# read by cleanup.
# Defined empty up front so cleanup can read them under `set -u` even if
# the script exits before they are set.
keepalive_pid=""
tmp=""
clt_placeholder=""

# Stop the sudo keep-alive loop and remove the temp files, if they exist.
cleanup() {
  [[ -n "$keepalive_pid" ]] && kill "$keepalive_pid" 2>/dev/null
  [[ -n "$tmp" ]] && rm -rf "$tmp"
  [[ -n "$clt_placeholder" ]] && rm -f "$clt_placeholder"
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

# --- Command Line Tools ------------------------------------------------------

# Apple's developer tools (clang, git, make, ...). Homebrew needs them.
CLT_DIR="/Library/Developer/CommandLineTools"

# softwareupdate lists the Command Line Tools only while this file exists. It's
# how the Homebrew installer installs them without the GUI dialog that
# `xcode-select --install` pops up (which would need someone to click through).
CLT_PLACEHOLDER="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"

install_command_line_tools() {
  local label
  if [[ -x "$CLT_DIR/usr/bin/git" ]]; then
    echo "Command Line Tools: already installed, skipping."
    return 0
  fi

  echo "Command Line Tools: finding latest version (can take a minute)..."
  touch "$CLT_PLACEHOLDER"
  clt_placeholder="$CLT_PLACEHOLDER"

  # Lines look like "* Label: Command Line Tools for Xcode-16.0"; keep the
  # newest version's label.
  label=$(softwareupdate --list 2>&1 |
    sed -n 's/^ *\* Label: \(Command Line Tools.*\)$/\1/p' |
    sort -V | tail -n 1)
  if [[ -z "$label" ]]; then
    echo "Command Line Tools: not offered by softwareupdate." >&2
    echo "Run 'xcode-select --install', then rerun this script." >&2
    return 1
  fi

  echo "Command Line Tools: installing '$label'..."
  sudo softwareupdate --install "$label"
  # Point xcode-select at the new tools if nothing is selected yet.
  xcode-select -p &>/dev/null || sudo xcode-select --switch "$CLT_DIR"
  echo "Command Line Tools: done."
}

# --- Homebrew ----------------------------------------------------------------

# Homebrew's prefix on Apple Silicon.
BREW="/opt/homebrew/bin/brew"
BREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

install_homebrew() {
  local installer
  if [[ -x "$BREW" ]]; then
    echo "Homebrew: already installed, skipping."
  else
    echo "Homebrew: installing..."
    # Download first, so a failed download stops the script (a failing
    # $(curl ...) inside a command's arguments wouldn't).
    installer=$(curl -fsSL "$BREW_INSTALL_URL")
    # NONINTERACTIVE skips the "Press RETURN" prompt. The installer needs sudo;
    # it uses the credentials cached by start_sudo.
    NONINTERACTIVE=1 /bin/bash -c "$installer"
    echo "Homebrew: done."
  fi
  # Put brew on PATH for the rest of this script.
  eval "$("$BREW" shellenv)"
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

# Usage: modifier_mapping KEYPATH
# Prints the value at KEYPATH inside the pref (e.g. ".0.HIDKeyboardModifierMappingSrc"),
# or nothing if it isn't set. plutil splits key paths on dots, so the dots in the
# pref's name are escaped. For an array, plutil's raw output is its length.
modifier_mapping() {
  defaults -currentHost export -g - |
    plutil -extract "${MODIFIER_PREF//./\\.}$1" raw -o - - 2>/dev/null || true
}

# The pref is read at login, so the change takes effect after logging out and back in.
caps_lock_to_control() {
  if [[ "$(modifier_mapping '')" == 1 &&
        "$(modifier_mapping .0.HIDKeyboardModifierMappingSrc)" == "$CAPS_LOCK" &&
        "$(modifier_mapping .0.HIDKeyboardModifierMappingDst)" == "$CONTROL" ]]; then
    echo "Caps Lock: already Control, skipping."
    return 0
  fi

  echo "Caps Lock: mapping to Control..."
  # Write through `defaults`, which goes via cfprefsd (the prefs daemon). Editing
  # the plist file directly (plutil, PlistBuddy) is the fragile route: cfprefsd
  # caches prefs and can ignore or overwrite such edits. `defaults import` is no
  # better: it replaces the whole domain, not one key. The inline XML is how
  # `defaults` takes an array of dicts (see `man defaults`: values may be given
  # in plist format). Reading, by contrast, is safe with any parser, hence plutil
  # in modifier_mapping above. The pref itself is undocumented; it's what
  # System Settings writes.
  defaults -currentHost write -g "$MODIFIER_PREF" -array \
    "<dict><key>HIDKeyboardModifierMappingSrc</key><integer>$CAPS_LOCK</integer><key>HIDKeyboardModifierMappingDst</key><integer>$CONTROL</integer></dict>"
  echo "Caps Lock: done (takes effect after logging out and back in)."
}

# --- Keyboard and text -------------------------------------------------------

# Usage: set_default LABEL DOMAIN KEY TYPE VALUE [NOTE]
# Writes one pref with `defaults write DOMAIN KEY -TYPE VALUE`, unless it
# already holds VALUE. `defaults read` prints booleans as 1/0, so -bool values
# are compared in that form. NOTE, if given, is appended to the done message.
set_default() {
  local label=$1 domain=$2 key=$3 type=$4 value=$5 note=${6:-} expected=$5
  if [[ "$type" == bool ]]; then
    [[ "$value" == true ]] && expected=1 || expected=0
  fi
  if [[ "$(defaults read "$domain" "$key" 2>/dev/null)" == "$expected" ]]; then
    echo "$label: already $value, skipping."
    return 0
  fi

  echo "$label: setting to $value..."
  defaults write "$domain" "$key" "-$type" "$value"
  echo "$label: done${note:+ ($note)}."
}

# System Settings > Keyboard > Key repeat rate. Lower is faster; 2 is the
# fastest step on the slider (about 30 ms between repeats).
set_key_repeat_rate() {
  set_default "Key repeat rate" -g KeyRepeat int 2 \
    "takes effect after logging out and back in"
}

# System Settings > Keyboard > Delay until repeat. 25 is the second-shortest
# step on the slider (about 375 ms).
set_key_repeat_delay() {
  set_default "Key repeat delay" -g InitialKeyRepeat int 25 \
    "takes effect after logging out and back in"
}

# System Settings > Keyboard > Keyboard Shortcuts > Function Keys >
# "Use F1, F2, etc. keys as standard function keys". Hold Fn for brightness,
# volume, etc.
use_standard_function_keys() {
  set_default "Function keys" -g com.apple.keyboard.fnState bool true
}

# System Settings > Keyboard > "Press 🌐 key to": 0 is Do Nothing.
set_globe_key_action() {
  set_default "Globe key" com.apple.HIToolbox AppleFnUsageType int 0
}

# System Settings > Keyboard > Text Input > Input Sources > Edit... : the
# toggles below.
disable_auto_correct() {
  set_default "Auto-correct" -g NSAutomaticSpellingCorrectionEnabled bool false
}

disable_auto_capitalize() {
  set_default "Auto-capitalize" -g NSAutomaticCapitalizationEnabled bool false
}

disable_double_space_period() {
  set_default "Double-space period" -g NSAutomaticPeriodSubstitutionEnabled bool false
}

disable_smart_quotes() {
  set_default "Smart quotes" -g NSAutomaticQuoteSubstitutionEnabled bool false
}

disable_smart_dashes() {
  set_default "Smart dashes" -g NSAutomaticDashSubstitutionEnabled bool false
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
install_command_line_tools
install_homebrew
set_machine_name
install_gallium
show_input_menu
caps_lock_to_control
set_key_repeat_rate
set_key_repeat_delay
use_standard_function_keys
set_globe_key_action
disable_auto_correct
disable_auto_capitalize
disable_double_space_period
disable_smart_quotes
disable_smart_dashes
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
