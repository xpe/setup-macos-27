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

# Called by each step that needs sudo, just before its first use, so a run
# where those steps all skip never asks for a password.
start_sudo() {
  [[ -n "$keepalive_pid" ]] && return 0  # already started
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

  start_sudo
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
    start_sudo
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

  start_sudo
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

  start_sudo
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

# --- Preferences -------------------------------------------------------------

# Apps to restart at the end so pref changes take effect (see restart_apps).
# typeset -U keeps the array's entries unique.
typeset -U apps_to_restart=()

# Usage: set_default [-r APP] LABEL DOMAIN KEY TYPE VALUE [NOTE]
# Writes one pref with `defaults write DOMAIN KEY -TYPE VALUE`, unless it
# already holds VALUE. `defaults read` prints booleans as 1/0, so -bool values
# are compared in that form. With -r, APP is restarted at the end of the run if
# the pref was written. NOTE, if given, is appended to the done message.
set_default() {
  local app=""
  if [[ "$1" == -r ]]; then
    app=$2
    shift 2
  fi
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
  [[ -n "$app" ]] && apps_to_restart+=("$app")
  echo "$label: done${note:+ ($note)}."
}

# Restart each app in apps_to_restart. Dock and Finder relaunch on their own
# when killed.
restart_apps() {
  local app
  for app in "${apps_to_restart[@]}"; do
    echo "$app: restarting so changes take effect..."
    killall "$app" 2>/dev/null || true
  done
}

# --- Keyboard and text -------------------------------------------------------

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
  apps_to_restart+=(Dock)
  echo "Dock: done."
}

# System Settings > Desktop & Dock > "Automatically hide and show the Dock".
enable_dock_autohide() {
  set_default -r Dock "Dock auto-hide" com.apple.dock autohide bool true
}

# System Settings > Desktop & Dock > Size. Stored as a float, in points.
set_dock_icon_size() {
  set_default -r Dock "Dock icon size" com.apple.dock tilesize float 48
}

# System Settings > Desktop & Dock > "Show suggested and recent apps in Dock".
hide_dock_recent_apps() {
  set_default -r Dock "Dock recent apps" com.apple.dock show-recents bool false
}

# System Settings > Desktop & Dock > Mission Control > "Automatically rearrange
# Spaces based on most recent use".
disable_rearranging_spaces() {
  set_default -r Dock "Rearrange Spaces" com.apple.dock mru-spaces bool false
}

# System Settings > Desktop & Dock > Mission Control > "Group windows by
# application".
group_windows_by_app() {
  set_default -r Dock "Group windows by app" com.apple.dock expose-group-apps bool true
}

# System Settings > Desktop & Dock > Hot Corners: bottom right. Action 1 is
# "-" (no action); modifier 0 is no modifier key. The default is Quick Note.
disable_bottom_right_hot_corner() {
  set_default -r Dock "Bottom-right hot corner" com.apple.dock wvous-br-corner int 1
  set_default -r Dock "Bottom-right hot corner modifier" com.apple.dock wvous-br-modifier int 0
}

# --- Appearance --------------------------------------------------------------

# System Settings > Appearance > Dark. Apps already open switch after logging
# out and back in.
use_dark_mode() {
  set_default "Dark mode" -g AppleInterfaceStyle string Dark \
    "takes effect after logging out and back in"
}

# Finder > Settings > Advanced > "Show all filename extensions".
show_all_extensions() {
  set_default -r Finder "Show all extensions" -g AppleShowAllExtensions bool true
}

# System Settings > Desktop & Dock > "Double-click a window's title bar to":
# not Minimize. (This matches the macOS default.)
disable_minimize_on_double_click() {
  set_default "Minimize on double-click" -g AppleMiniaturizeOnDoubleClick bool false
}

# --- Desktop and window tiling -----------------------------------------------

# System Settings > Desktop & Dock > Windows. The WindowManager prefs are
# picked up after logging out and back in.
WINDOW_MANAGER_NOTE="takes effect after logging out and back in"

# "Tiled windows have margins".
disable_tiled_window_margins() {
  set_default "Tiled window margins" com.apple.WindowManager \
    EnableTiledWindowMargins bool false "$WINDOW_MANAGER_NOTE"
}

# "Drag windows to screen edges to tile".
disable_edge_drag_tiling() {
  set_default "Tile by dragging to edges" com.apple.WindowManager \
    EnableTilingByEdgeDrag bool false "$WINDOW_MANAGER_NOTE"
}

# "Drag windows to menu bar to fill screen".
disable_top_edge_drag_tiling() {
  set_default "Fill by dragging to menu bar" com.apple.WindowManager \
    EnableTopTilingByEdgeDrag bool false "$WINDOW_MANAGER_NOTE"
}

# "Hold ⌥ key while dragging windows to tile".
disable_option_drag_tiling() {
  set_default "Tile by Option-dragging" com.apple.WindowManager \
    EnableTilingOptionAccelerator bool false "$WINDOW_MANAGER_NOTE"
}

# System Settings > Desktop & Dock > Desktop & Stage Manager > Show Items >
# "On Desktop" (off).
hide_desktop_items() {
  set_default "Desktop items" com.apple.WindowManager \
    HideDesktop bool true "$WINDOW_MANAGER_NOTE"
}

# System Settings > Desktop & Dock > Desktop & Stage Manager > Show Widgets >
# "On Desktop" (off).
hide_desktop_widgets() {
  set_default "Desktop widgets" com.apple.WindowManager \
    StandardHideWidgets bool true "$WINDOW_MANAGER_NOTE"
}

# --- Finder ------------------------------------------------------------------

# View > as List. Folders that already have a saved view keep it.
use_finder_list_view() {
  set_default -r Finder "Finder list view" com.apple.finder FXPreferredViewStyle string Nlsv
}

# Finder > Settings > General > "New Finder windows show": Recents (PfAF).
set_finder_new_window_target() {
  set_default -r Finder "Finder new window target" com.apple.finder NewWindowTarget string PfAF
}

# View > Show Path Bar.
show_finder_path_bar() {
  set_default -r Finder "Finder path bar" com.apple.finder ShowPathbar bool true
}

# Finder > Settings > Advanced > "Show warning before changing an extension".
disable_extension_change_warning() {
  set_default -r Finder "Extension change warning" com.apple.finder \
    FXEnableExtensionChangeWarning bool false
}

# Finder > Settings > General > "Show these items on the desktop".
hide_hard_disks_on_desktop() {
  set_default -r Finder "Hard disks on desktop" com.apple.finder \
    ShowHardDrivesOnDesktop bool false
}

hide_external_disks_on_desktop() {
  set_default -r Finder "External disks on desktop" com.apple.finder \
    ShowExternalHardDrivesOnDesktop bool false
}

hide_removable_media_on_desktop() {
  set_default -r Finder "Removable media on desktop" com.apple.finder \
    ShowRemovableMediaOnDesktop bool false
}

# --- Trackpad ----------------------------------------------------------------

# Usage: set_trackpad_default LABEL KEY TYPE VALUE
# System Settings writes each trackpad pref twice: once for the built-in
# trackpad and once for Bluetooth trackpads (Magic Trackpad). This does the
# same. The trackpad driver reads these at login.
set_trackpad_default() {
  local note="takes effect after logging out and back in"
  set_default "$1 (built-in)" com.apple.AppleMultitouchTrackpad "$2" "$3" "$4" "$note"
  set_default "$1 (Bluetooth)" com.apple.driver.AppleBluetoothMultitouch.trackpad \
    "$2" "$3" "$4" "$note"
}

# Point & Click > "Tap to click" (off; the macOS default).
disable_tap_to_click() {
  set_trackpad_default "Tap to click" Clicking int 0
}

# Accessibility > Pointer Control > Trackpad Options > "Use trackpad for
# dragging: Three Finger Drag" (off; the macOS default).
disable_three_finger_drag() {
  set_trackpad_default "Three-finger drag" TrackpadThreeFingerDrag bool false
}

# Point & Click > "Look up & data detectors": not "Tap with three fingers".
disable_three_finger_tap_lookup() {
  set_trackpad_default "Three-finger tap lookup" TrackpadThreeFingerTapGesture int 0
}

# Scroll & Zoom > "Zoom in or out" (pinch).
disable_pinch_to_zoom() {
  set_trackpad_default "Pinch to zoom" TrackpadPinch bool false
}

# Scroll & Zoom > "Smart zoom" (double-tap with two fingers).
disable_smart_zoom() {
  set_trackpad_default "Smart zoom" TrackpadTwoFingerDoubleTapGesture int 0
}

# Scroll & Zoom > "Rotate".
disable_rotate_gesture() {
  set_trackpad_default "Rotate gesture" TrackpadRotate bool false
}

# More Gestures > "Notification Center" (swipe left from the right edge).
disable_notification_center_gesture() {
  set_trackpad_default "Notification Center gesture" \
    TrackpadTwoFingerFromRightEdgeSwipeGesture int 0
}

# More Gestures > pinch with thumb and three fingers (Launchpad / Apps).
# System Settings sets both the four- and five-finger keys.
disable_thumb_pinch_gesture() {
  set_trackpad_default "Four-finger pinch" TrackpadFourFingerPinchGesture int 0
  set_trackpad_default "Five-finger pinch" TrackpadFiveFingerPinchGesture int 0
}

# More Gestures > "Show Desktop" (spread thumb and three fingers). This one
# lives in the Dock's prefs, not the trackpad's.
disable_show_desktop_gesture() {
  set_default -r Dock "Show Desktop gesture" com.apple.dock \
    showDesktopGestureEnabled bool false
}

# --- Main --------------------------------------------------------------------

load_settings
ask_settings
# The steps that may need sudo run first, so on a new machine the password
# prompt comes right away and the rest of the run is unattended.
set_machine_name
install_gallium
install_command_line_tools
install_homebrew
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
use_dark_mode
show_all_extensions
disable_minimize_on_double_click
clear_dock
enable_dock_autohide
set_dock_icon_size
hide_dock_recent_apps
disable_rearranging_spaces
group_windows_by_app
disable_bottom_right_hot_corner
disable_tiled_window_margins
disable_edge_drag_tiling
disable_top_edge_drag_tiling
disable_option_drag_tiling
hide_desktop_items
hide_desktop_widgets
use_finder_list_view
set_finder_new_window_target
show_finder_path_bar
disable_extension_change_warning
hide_hard_disks_on_desktop
hide_external_disks_on_desktop
hide_removable_media_on_desktop
disable_tap_to_click
disable_three_finger_drag
disable_three_finger_tap_lookup
disable_pinch_to_zoom
disable_smart_zoom
disable_rotate_gesture
disable_notification_center_gesture
disable_thumb_pinch_gesture
disable_show_desktop_gesture
restart_apps

echo "All steps complete."

if (( gallium_installed )); then
  cat <<'EOF'

The Gallium keyboard layout was just installed. To enable it:
  1. Log out and back in.
  2. System Settings > Keyboard > Text Input > Input Sources > Edit...
  3. Click +, find Gallium, click Add.
EOF
fi
