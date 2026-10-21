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

# --- Output ------------------------------------------------------------------

# Each step reports one line, indented under a section heading, starting with
# a mark:
#   ·  already set
#   +  changed
#   *  changed; takes effect after logging out and back in
#   >  starting (for steps whose commands print their own output or prompts)
#   !  failed, or not working yet
# The counts are printed in the summary at the end.
unchanged_count=0
changed_count=0
logout_needed=0

# Usage: section NAME
section() {
  print -r -- "$1"
}

# Usage: report MARK LABEL [VALUE]
report() {
  print -r -- "  $1 $2${3:+: $3}"
}

# Usage: already_set LABEL [VALUE]
already_set() {
  report "·" "$@"
  (( ++unchanged_count ))
}

# Usage: changed [-l] LABEL [VALUE]
# -l: the change takes effect after logging out and back in.
changed() {
  local mark="+"
  if [[ "$1" == -l ]]; then
    mark="*"
    logout_needed=1
    shift
  fi
  report "$mark" "$@"
  (( ++changed_count ))
}

# Usage: starting LABEL MESSAGE
starting() {
  report ">" "$1" "$2..."
}

# Usage: failed LABEL MESSAGE
failed() {
  report "!" "$@" >&2
}

print_summary() {
  local counts="$changed_count changed, $unchanged_count already set."
  if (( logout_needed )); then
    counts+=" * = after logging out and back in."
  fi
  print
  print -r -- "$counts"
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
  # The SSH key's comment: just a label inside the public key. GitHub's guide
  # suggests an email, but any word works, and one that isn't a real email is
  # preferable: it keeps the address out of anything public. (A real or noreply
  # address only buys GitHub attribution and "Verified" badges, which we don't
  # care about.)
  ask_setting SSH_KEY_COMMENT "SSH key comment (any word, e.g. 'david')"
}

# --- SSH key -----------------------------------------------------------------

# Follows GitHub's guide, "Generating a new SSH key and adding it to the
# ssh-agent" (macOS tab).
SSH_DIR="$HOME/.ssh"
SSH_KEY="$SSH_DIR/id_ed25519"
SSH_CONFIG="$SSH_DIR/config"

# Set to 1 by create_ssh_key when it creates a key; gates the GitHub message.
ssh_key_created=0

# ssh-keygen asks for a passphrase (twice), and ssh-add asks for it once more
# to save it in the login keychain. These are the only prompts besides sudo,
# so this runs before the long steps.
create_ssh_key() {
  local note=""
  # (D) shows the path with $HOME as ~.
  if [[ -f "$SSH_KEY" ]]; then
    already_set "Key" "${(D)SSH_KEY}"
    return 0
  fi

  starting "Key" "creating (choose a passphrase; it's saved in the keychain)"
  mkdir -p -m 700 "$SSH_DIR"
  # -q skips the fingerprint and randomart; it still asks for the passphrase.
  ssh-keygen -q -t ed25519 -C "$SSH_KEY_COMMENT" -f "$SSH_KEY"
  ssh_key_created=1

  # Load the key into the agent and save its passphrase in the keychain. The
  # agent is launchd's, found via SSH_AUTH_SOCK; it's missing when this script
  # runs over SSH. Then the AddKeysToAgent and UseKeychain lines written by
  # write_ssh_config do the same on the key's first use.
  if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
    ssh-add -q --apple-use-keychain "$SSH_KEY"
  else
    note=" (no ssh-agent; the passphrase is saved to the keychain on first use)"
  fi
  changed "Key" "${(D)SSH_KEY}$note"
}

# A hardened client config for all hosts: modern algorithms only, one key,
# no forwarding. It also has ssh load the key into the agent and get its
# passphrase from the keychain, so it isn't asked for again (even after a
# restart). An existing config is left alone, since it may hold other hosts;
# compare it with this one by hand.
write_ssh_config() {
  if [[ -e "$SSH_CONFIG" ]]; then
    already_set "Config" "${(D)SSH_CONFIG}"
    return 0
  fi

  mkdir -p -m 700 "$SSH_DIR"
  # The quoted 'EOF' writes the text as is, with no $ expansion.
  cat > "$SSH_CONFIG" <<'EOF'
Host *
    # --- Host keys
    # Ed25519 (certificates first), then RSA-SHA2 only (no SHA1).
    # No ECDSA: a server offering only ECDSA host keys won't connect.
    HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com,ssh-ed25519,rsa-sha2-512,rsa-sha2-256

    # --- Key exchange
    # Post-quantum first (mlkem768x25519 = NIST-standardized PQC;
    # sntrup761 = OpenSSH's own PQ hybrid). Then classic ECDH.
    # NO weak DH groups (group14, group1, etc.)
    KexAlgorithms mlkem768x25519-sha256,sntrup761x25519-sha512,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group18-sha512,diffie-hellman-group16-sha512

    # --- Ciphers
    # AEAD-only (authenticated encryption). ChaCha20 first, then
    # AES-GCM. CBC and CTR modes are excluded.
    Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com

    # --- MACs
    # AEAD ciphers don't use these; this only matters if a non-AEAD
    # cipher is ever allowed. Encrypt-then-MAC (EtM) variants only.
    MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com

    # --- Authentication ----------------------------------------------

    # Only allow use of IdentityFiles defined in this config
    IdentitiesOnly yes

    # Default key - use Ed25519. Generate with:
    # `ssh-keygen -t ed25519 -C "you@host"`
    IdentityFile ~/.ssh/id_ed25519

    # macOS. IgnoreUnknown must come before UseKeychain, which only
    # Apple's ssh knows (Homebrew's OpenSSH would stop with an error).
    IgnoreUnknown UseKeychain
    AddKeysToAgent yes
    UseKeychain yes

    # --- Attack surface reduction ------------------------------------

    # Disable host-based auth (trusts /etc/hosts.equiv — don't)
    HostbasedAuthentication no

    # Disable agent forwarding globally; enable per host only
    # when you truly need it. A compromised server can hijack it.
    ForwardAgent no

    # Disable X11 forwarding (rarely needed, big attack surface).
    ForwardX11 no
    ForwardX11Trusted no

    # Don't run local commands triggered by the server.
    PermitLocalCommand no

    # Hash entries in known_hosts so a stolen file doesn't reveal
    # which hosts you connect to. (Applies to new entries; run
    # `ssh-keygen -H` once to hash existing ones.)
    HashKnownHosts yes

    # Ask before trusting an unknown host's key. (A changed key is
    # always refused, whatever this is set to.)
    StrictHostKeyChecking ask

    # --- Session hygiene ---------------------------------------------
    # Send keepalives every 60s; drop after 3 missed replies (3 min).
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF
  chmod 600 "$SSH_CONFIG"
  changed "Config" "${(D)SSH_CONFIG}"
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
    already_set "Command Line Tools" "installed"
    return 0
  fi

  starting "Command Line Tools" "installing (finding the latest version can take a minute)"
  start_sudo
  touch "$CLT_PLACEHOLDER"
  clt_placeholder="$CLT_PLACEHOLDER"

  # Lines look like "* Label: Command Line Tools for Xcode-16.0"; keep the
  # newest version's label.
  label=$(softwareupdate --list 2>&1 |
    sed -n 's/^ *\* Label: \(Command Line Tools.*\)$/\1/p' |
    sort -V | tail -n 1)
  if [[ -z "$label" ]]; then
    failed "Command Line Tools" \
      "not offered by softwareupdate; run 'xcode-select --install', then rerun this script"
    return 1
  fi

  sudo softwareupdate --install "$label"
  # Point xcode-select at the new tools if nothing is selected yet.
  xcode-select -p &>/dev/null || sudo xcode-select --switch "$CLT_DIR"
  changed "Command Line Tools" "installed"
}

# --- Homebrew ----------------------------------------------------------------

# Homebrew's prefix on Apple Silicon.
BREW="/opt/homebrew/bin/brew"
BREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

install_homebrew() {
  local installer
  if [[ -x "$BREW" ]]; then
    already_set "Homebrew" "installed"
  else
    starting "Homebrew" "installing"
    start_sudo
    # Download first, so a failed download stops the script (a failing
    # $(curl ...) inside a command's arguments wouldn't).
    installer=$(curl -fsSL "$BREW_INSTALL_URL")
    # NONINTERACTIVE skips the "Press RETURN" prompt. The installer needs sudo;
    # it uses the credentials cached by start_sudo.
    NONINTERACTIVE=1 /bin/bash -c "$installer"
    changed "Homebrew" "installed"
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
    already_set "Machine name" "$MACHINE_NAME"
    return 0
  fi

  start_sudo
  for kind in ComputerName LocalHostName HostName; do
    sudo scutil --set "$kind" "$MACHINE_NAME"
  done
  changed "Machine name" "$MACHINE_NAME"
}

# --- Gallium keyboard layout -------------------------------------------------

GALLIUM_DEST="/Library/Keyboard Layouts/Gallium_r5.bundle"
GALLIUM_URL="https://github.com/xpe/gallium/raw/trunk/macOS/Gallium_r5.bundle.zip"

# Set to 1 by install_gallium when it installs; gates the manual-step message.
gallium_installed=0

install_gallium() {
  if [[ -d "$GALLIUM_DEST" ]]; then
    already_set "Gallium layout" "installed"
    return 0
  fi

  start_sudo
  tmp=$(mktemp -d)

  # -f fail on HTTP error, -sS quiet but show errors, -L follow redirects.
  curl -fsSL -o "$tmp/gallium.zip" "$GALLIUM_URL"

  # ditto: Apple's unzipper; preserves macOS file metadata. -x extract, -k zip.
  ditto -x -k "$tmp/gallium.zip" "$tmp/unzipped"

  # The zip has Gallium_r5.bundle at its top level.
  sudo cp -R "$tmp/unzipped/Gallium_r5.bundle" "/Library/Keyboard Layouts/"
  gallium_installed=1
  # -l: macOS doesn't see the layout until after logging out and back in.
  changed -l "Gallium layout" "installed"
}

# --- Input sources -----------------------------------------------------------

# Enabling Gallium as an input source is left to the user (see end of script):
# macOS doesn't see a newly installed layout until after logout, and the
# AppleEnabledInputSources pref isn't a reliable record of what's enabled.

# Show the input menu (layout switcher) in the menu bar. Restarting the menu
# agent applies it.
show_input_menu() {
  set_default -r TextInputMenuAgent "Input menu" com.apple.TextInputMenu visible bool true
}

# --- Karabiner-Elements ------------------------------------------------------

# Karabiner-Elements remaps keys on every keyboard, built-in or external. The
# Homebrew cask runs Karabiner's own installer package; after that, Karabiner
# updates itself.
KARABINER_APP="/Applications/Karabiner-Elements.app"
KARABINER_CLI="/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
KARABINER_JSON="$HOME/.config/karabiner/karabiner.json"

# Set by check_karabiner to what Karabiner still needs, or "" when it's
# working; gates the setup message at the end.
karabiner_needs=""

# The config these Macs share. Its rules:
#   Caps Lock: Control when held with another key, Escape when tapped alone.
#   Shift-Escape: Caps Lock.
#   Return: Control when held with another key, Return when tapped alone.
#   Comma: a symbol layer (turned off).
# No device is named, so the rules apply to every keyboard. keyboard_type_v2
# answers the keyboard-type question in Karabiner's setup.
karabiner_config() {
  cat <<'EOF'
{
    "profiles": [
        {
            "complex_modifications": {
                "rules": [
                    {
                        "description": "Change caps_lock to control if pressed with other keys, to escape if pressed alone.",
                        "manipulators": [
                            {
                                "from": {
                                    "key_code": "caps_lock",
                                    "modifiers": { "optional": ["any"] }
                                },
                                "to": [{ "key_code": "left_control" }],
                                "to_if_alone": [{ "key_code": "escape" }],
                                "type": "basic"
                            }
                        ]
                    },
                    {
                        "description": "Change shift + escape to caps_lock.",
                        "manipulators": [
                            {
                                "from": {
                                    "key_code": "escape",
                                    "modifiers": {
                                        "mandatory": ["shift"],
                                        "optional": ["caps_lock"]
                                    }
                                },
                                "to": [{ "key_code": "caps_lock" }],
                                "type": "basic"
                            }
                        ]
                    },
                    {
                        "description": "Change return_or_enter to control if pressed with other keys, to return if pressed alone.",
                        "manipulators": [
                            {
                                "from": {
                                    "key_code": "return_or_enter",
                                    "modifiers": { "optional": ["any"] }
                                },
                                "to": [{ "key_code": "right_control" }],
                                "to_if_alone": [{ "key_code": "return_or_enter" }],
                                "type": "basic"
                            }
                        ]
                    },
                    {
                        "description": "Symbol layer: backslash pipe backtick tilde",
                        "enabled": false,
                        "manipulators": [
                            {
                                "conditions": [
                                    {
                                        "name": "symbol_layer",
                                        "type": "variable_if",
                                        "value": 1
                                    }
                                ],
                                "from": { "key_code": "a" },
                                "to": [{ "key_code": "backslash" }],
                                "type": "basic"
                            },
                            {
                                "conditions": [
                                    {
                                        "name": "symbol_layer",
                                        "type": "variable_if",
                                        "value": 1
                                    }
                                ],
                                "from": { "key_code": "s" },
                                "to": [
                                    {
                                        "key_code": "backslash",
                                        "modifiers": ["left_shift"]
                                    }
                                ],
                                "type": "basic"
                            },
                            {
                                "conditions": [
                                    {
                                        "name": "symbol_layer",
                                        "type": "variable_if",
                                        "value": 1
                                    }
                                ],
                                "from": { "key_code": "d" },
                                "to": [{ "key_code": "grave_accent_and_tilde" }],
                                "type": "basic"
                            },
                            {
                                "conditions": [
                                    {
                                        "name": "symbol_layer",
                                        "type": "variable_if",
                                        "value": 1
                                    }
                                ],
                                "from": { "key_code": "f" },
                                "to": [
                                    {
                                        "key_code": "grave_accent_and_tilde",
                                        "modifiers": ["left_shift"]
                                    }
                                ],
                                "type": "basic"
                            },
                            {
                                "from": { "key_code": "comma" },
                                "parameters": { "basic.to_if_alone_timeout_milliseconds": 200 },
                                "to": [
                                    {
                                        "set_variable": {
                                            "name": "symbol_layer",
                                            "value": 1
                                        }
                                    }
                                ],
                                "to_after_key_up": [
                                    {
                                        "set_variable": {
                                            "name": "symbol_layer",
                                            "value": 0
                                        }
                                    }
                                ],
                                "to_if_alone": [{ "key_code": "comma" }],
                                "type": "basic"
                            }
                        ]
                    }
                ]
            },
            "name": "Default profile",
            "selected": true,
            "virtual_hid_keyboard": { "keyboard_type_v2": "ansi" }
        }
    ]
}
EOF
}

# Runs before the install, so Karabiner starts with this config rather than
# writing its default one. Karabiner reloads the file whenever it changes.
#
# The comparison uses jq (part of macOS since 15), so it ignores formatting and
# key order. It also ignores machine_specific: that section is keyed by a
# per-machine ID and holds per-machine choices (like the external editor), so
# it's kept as is. A config that differs otherwise is saved next to it, then
# replaced.
write_karabiner_config() {
  local current machine backup new note=""
  current=$(jq -S 'del(.machine_specific)' "$KARABINER_JSON" 2>/dev/null || true)
  if [[ "$current" == "$(karabiner_config | jq -S .)" ]]; then
    already_set "Config" "${(D)KARABINER_JSON}"
    return 0
  fi

  mkdir -p "${KARABINER_JSON:h}"
  if [[ -e "$KARABINER_JSON" ]]; then
    backup="$KARABINER_JSON.$(date +%Y%m%d-%H%M%S).bak"
    cp -p "$KARABINER_JSON" "$backup"
    note=" (the old one is saved as ${(D)backup})"
  fi
  machine=$(jq -c '.machine_specific // {}' "$KARABINER_JSON" 2>/dev/null || print -r -- '{}')

  # Write a temp file and rename it into place, so Karabiner never reads a
  # half-written config. (mktemp's mode, 600, is what Karabiner uses too.)
  new=$(mktemp "$KARABINER_JSON.XXXXXX")
  karabiner_config |
    jq --argjson machine "$machine" \
      'if $machine == {} then . else .machine_specific = $machine end' > "$new"
  mv -f "$new" "$KARABINER_JSON"
  changed "Config" "${(D)KARABINER_JSON}$note"
}

# Skips if the app is there, however it was installed (brew would refuse to
# install over it anyway).
install_karabiner() {
  if [[ -d "$KARABINER_APP" ]]; then
    already_set "App" "installed"
    return 0
  fi

  starting "App" "installing"
  # The installer package needs sudo, which brew asks for itself. There's no
  # start_sudo here: before using sudo, brew clears its cached password (on
  # purpose, so nothing it runs gets sudo unasked), so start_sudo's would only
  # be asked for and thrown away. For the same reason, a sudo step after this
  # one asks for the password again.
  brew install --cask karabiner-elements
  changed "App" "installed"
}

# Asks Karabiner whether it's working, with the same check its Settings window
# uses to decide what setup to show. current_setup names a missing permission
# or approval (services, accessibility, input_monitoring, driver_extension);
# current_alert names a problem (e.g. doctor: the config doesn't parse). Both
# are "none" when all is well, but also for the first few seconds after
# Karabiner starts, so the underlying state is checked too.
#
# On a new machine Karabiner isn't working until it's opened and given the
# permissions it asks for (see the end of the script).
check_karabiner() {
  local guidance
  # Prints nothing (and still exits 0) when Karabiner's services aren't running.
  guidance=$("$KARABINER_CLI" --show-settings-window-guidance 2>/dev/null || true)
  if [[ -z "$guidance" ]]; then
    karabiner_needs=not_running
  else
    karabiner_needs=$(jq -r '
      .core_service_daemon_state as $state
      | $state.bundle_permission_check_result as $permissions
      | if .current_setup != "none" then .current_setup
        elif .current_alert != "none" then .current_alert
        elif [.guidance_context.services_running,
              $state.driver_activated,
              $state.driver_connected,
              $state.virtual_hid_keyboard_ready,
              $permissions.accessibility_process_trusted,
              $permissions.iohid_listen_event_allowed] | all then empty
        else "starting" end' <<< "$guidance" 2>/dev/null) || karabiner_needs=unknown
  fi

  if [[ -z "$karabiner_needs" ]]; then
    already_set "Status" "working"
  else
    failed "Status" "not working yet (${karabiner_needs//_/ })"
  fi
}

# --- Caps Lock -> Control ----------------------------------------------------

# Karabiner-Elements does this (and more) on every keyboard while it runs; this
# is the fallback for when it isn't running.
#
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
    already_set "Caps Lock" "Control"
    return 0
  fi

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
  changed -l "Caps Lock" "Control"
}

# --- Preferences -------------------------------------------------------------

# Apps to restart at the end so pref changes take effect (see restart_apps).
# typeset -U keeps the array's entries unique.
typeset -U apps_to_restart=()

# Usage: shown_value TYPE VALUE
# Prints a pref's value as the report shows it: a bool (true/false, or 1/0 as
# `defaults read` prints it) as on/off, and an empty VALUE as "unset".
shown_value() {
  local type=$1 value=$2
  if [[ -z "$value" ]]; then
    value=unset
  elif [[ "$type" == bool ]]; then
    case "$value" in
      true|1) value=on ;;
      false|0) value=off ;;
    esac
  fi
  print -r -- "$value"
}

# Usage: write_default DOMAIN KEY TYPE VALUE
# Writes one pref with `defaults write DOMAIN KEY -TYPE VALUE`, unless it
# already holds VALUE. `defaults read` prints booleans as 1/0, so -bool values
# are compared in that form. Sets REPLY to the old value (as shown_value
# prints it) if the pref was written, or to "" if it wasn't.
write_default() {
  local domain=$1 key=$2 type=$3 value=$4 expected=$4 current
  if [[ "$type" == bool ]]; then
    [[ "$value" == true ]] && expected=1 || expected=0
  fi
  current=$(defaults read "$domain" "$key" 2>/dev/null || true)
  REPLY=""
  [[ "$current" == "$expected" ]] && return 0

  defaults write "$domain" "$key" "-$type" "$value"
  REPLY=$(shown_value "$type" "$current")
}

# Usage: report_default [-l] LABEL OLD TYPE VALUE [SHOWN]
# Reports a pref as already set (OLD is "") or changed (OLD -> new value).
# SHOWN is how VALUE is shown (default: as shown_value prints it). -l is
# passed to `changed`.
report_default() {
  local flags=()
  if [[ "$1" == -l ]]; then
    flags=(-l)
    shift
  fi
  local label=$1 old=$2 type=$3 value=$4 shown=${5:-}
  [[ -n "$shown" ]] || shown=$(shown_value "$type" "$value")
  if [[ -z "$old" ]]; then
    already_set "$label" "$shown"
  else
    changed "${flags[@]}" "$label" "$old -> $shown"
  fi
}

# Usage: set_default [-r APP] [-l] LABEL DOMAIN KEY TYPE VALUE [SHOWN]
# Writes one pref (see write_default) and reports it (see report_default).
# With -r, APP is restarted at the end of the run if the pref was written. -l
# marks a change that takes effect after logging out and back in.
set_default() {
  local app="" flags=()
  if [[ "$1" == -r ]]; then
    app=$2
    shift 2
  fi
  if [[ "$1" == -l ]]; then
    flags=(-l)
    shift
  fi
  local label=$1 domain=$2 key=$3 type=$4 value=$5 shown=${6:-}
  write_default "$domain" "$key" "$type" "$value"
  [[ -n "$REPLY" && -n "$app" ]] && apps_to_restart+=("$app")
  report_default "${flags[@]}" "$label" "$REPLY" "$type" "$value" "$shown"
}

# Restart each app in apps_to_restart. Dock, Finder and TextInputMenuAgent
# relaunch on their own when killed.
restart_apps() {
  local app
  (( ${#apps_to_restart} )) || return 0
  for app in "${apps_to_restart[@]}"; do
    killall "$app" 2>/dev/null || true
  done
  print -r -- "Restarted: ${(j:, :)apps_to_restart}"
}

# --- Keyboard and text -------------------------------------------------------

# System Settings > Keyboard > Key repeat rate. Lower is faster; 2 is the
# fastest step on the slider (about 30 ms between repeats).
set_key_repeat_rate() {
  set_default -l "Key repeat rate" -g KeyRepeat int 2
}

# System Settings > Keyboard > Delay until repeat. 25 is the second-shortest
# step on the slider (about 375 ms).
set_key_repeat_delay() {
  set_default -l "Key repeat delay" -g InitialKeyRepeat int 25
}

# System Settings > Keyboard > Keyboard Shortcuts > Function Keys >
# "Use F1, F2, etc. keys as standard function keys". Hold Fn for brightness,
# volume, etc.
use_standard_function_keys() {
  set_default "Standard function keys" -g com.apple.keyboard.fnState bool true
}

# System Settings > Keyboard > "Press 🌐 key to": 0 is Do Nothing.
set_globe_key_action() {
  set_default "Globe key" com.apple.HIToolbox AppleFnUsageType int 0 "Do Nothing"
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
    already_set "Pinned apps" "none"
    return 0
  fi

  defaults write com.apple.dock persistent-apps -array
  apps_to_restart+=(Dock)
  changed "Pinned apps" "none"
}

# System Settings > Desktop & Dock > "Automatically hide and show the Dock".
enable_dock_autohide() {
  set_default -r Dock "Auto-hide" com.apple.dock autohide bool true
}

# System Settings > Desktop & Dock > Size. Stored as a float, in points.
set_dock_icon_size() {
  set_default -r Dock "Icon size" com.apple.dock tilesize float 48
}

# System Settings > Desktop & Dock > "Show suggested and recent apps in Dock".
hide_dock_recent_apps() {
  set_default -r Dock "Recent apps" com.apple.dock show-recents bool false
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
  set_default -r Dock "Bottom-right hot corner" com.apple.dock wvous-br-corner int 1 none
  set_default -r Dock "Bottom-right hot corner modifier" com.apple.dock \
    wvous-br-modifier int 0 none
}

# --- Appearance --------------------------------------------------------------

# System Settings > Appearance > Dark. Apps already open switch after logging
# out and back in.
use_dark_mode() {
  set_default -l "Dark mode" -g AppleInterfaceStyle string Dark on
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
# picked up after logging out and back in (hence -l).

# "Tiled windows have margins".
disable_tiled_window_margins() {
  set_default -l "Tiled window margins" com.apple.WindowManager \
    EnableTiledWindowMargins bool false
}

# "Drag windows to screen edges to tile".
disable_edge_drag_tiling() {
  set_default -l "Tile by dragging to edges" com.apple.WindowManager \
    EnableTilingByEdgeDrag bool false
}

# "Drag windows to menu bar to fill screen".
disable_top_edge_drag_tiling() {
  set_default -l "Fill by dragging to menu bar" com.apple.WindowManager \
    EnableTopTilingByEdgeDrag bool false
}

# "Hold ⌥ key while dragging windows to tile".
disable_option_drag_tiling() {
  set_default -l "Tile by Option-dragging" com.apple.WindowManager \
    EnableTilingOptionAccelerator bool false
}

# System Settings > Desktop & Dock > Desktop & Stage Manager > Show Items >
# "On Desktop" (off).
hide_desktop_items() {
  set_default -l "Hide desktop items" com.apple.WindowManager HideDesktop bool true
}

# System Settings > Desktop & Dock > Desktop & Stage Manager > Show Widgets >
# "On Desktop" (off).
hide_desktop_widgets() {
  set_default -l "Hide desktop widgets" com.apple.WindowManager \
    StandardHideWidgets bool true
}

# --- Finder ------------------------------------------------------------------

# View > as List. Folders that already have a saved view keep it.
use_finder_list_view() {
  set_default -r Finder "Default view" com.apple.finder FXPreferredViewStyle string Nlsv list
}

# Finder > Settings > General > "New Finder windows show": Recents (PfAF).
set_finder_new_window_target() {
  set_default -r Finder "New windows show" com.apple.finder NewWindowTarget string PfAF Recents
}

# View > Show Path Bar.
show_finder_path_bar() {
  set_default -r Finder "Path bar" com.apple.finder ShowPathbar bool true
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

# Usage: set_trackpad_default LABEL KEY TYPE VALUE [SHOWN]
# System Settings writes each trackpad pref twice: once for the built-in
# trackpad and once for Bluetooth trackpads (Magic Trackpad). This does the
# same, and reports both as one line (see report_default). The trackpad driver
# reads these at login.
set_trackpad_default() {
  local label=$1 key=$2 type=$3 value=$4 shown=${5:-} old
  write_default com.apple.AppleMultitouchTrackpad "$key" "$type" "$value"
  old=$REPLY
  write_default com.apple.driver.AppleBluetoothMultitouch.trackpad "$key" "$type" "$value"
  # The built-in trackpad's old value, unless only the Bluetooth one was written.
  report_default -l "$label" "${old:-$REPLY}" "$type" "$value" "$shown"
}

# Point & Click > "Tap to click" (off; the macOS default).
disable_tap_to_click() {
  set_trackpad_default "Tap to click" Clicking int 0 off
}

# Accessibility > Pointer Control > Trackpad Options > "Use trackpad for
# dragging: Three Finger Drag" (off; the macOS default).
disable_three_finger_drag() {
  set_trackpad_default "Three-finger drag" TrackpadThreeFingerDrag bool false
}

# Point & Click > "Look up & data detectors": not "Tap with three fingers".
disable_three_finger_tap_lookup() {
  set_trackpad_default "Three-finger tap lookup" TrackpadThreeFingerTapGesture int 0 off
}

# Scroll & Zoom > "Zoom in or out" (pinch).
disable_pinch_to_zoom() {
  set_trackpad_default "Pinch to zoom" TrackpadPinch bool false
}

# Scroll & Zoom > "Smart zoom" (double-tap with two fingers).
disable_smart_zoom() {
  set_trackpad_default "Smart zoom" TrackpadTwoFingerDoubleTapGesture int 0 off
}

# Scroll & Zoom > "Rotate".
disable_rotate_gesture() {
  set_trackpad_default "Rotate gesture" TrackpadRotate bool false
}

# More Gestures > "Notification Center" (swipe left from the right edge).
disable_notification_center_gesture() {
  set_trackpad_default "Notification Center gesture" \
    TrackpadTwoFingerFromRightEdgeSwipeGesture int 0 off
}

# More Gestures > pinch with thumb and three fingers (Launchpad / Apps).
# System Settings sets both the four- and five-finger keys.
disable_thumb_pinch_gesture() {
  set_trackpad_default "Four-finger pinch" TrackpadFourFingerPinchGesture int 0 off
  set_trackpad_default "Five-finger pinch" TrackpadFiveFingerPinchGesture int 0 off
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
# The steps that prompt (for the SSH passphrase, or for sudo) run first, so on
# a new machine the prompts come right away and the rest of the run is
# unattended.
section "SSH"
create_ssh_key
write_ssh_config
section "System"
set_machine_name
install_gallium
install_command_line_tools
install_homebrew
section "Karabiner"
write_karabiner_config
install_karabiner
check_karabiner
section "Keyboard"
show_input_menu
caps_lock_to_control
set_key_repeat_rate
set_key_repeat_delay
use_standard_function_keys
set_globe_key_action
section "Text"
disable_auto_correct
disable_auto_capitalize
disable_double_space_period
disable_smart_quotes
disable_smart_dashes
section "Appearance"
use_dark_mode
show_all_extensions
disable_minimize_on_double_click
section "Dock"
clear_dock
enable_dock_autohide
set_dock_icon_size
hide_dock_recent_apps
disable_rearranging_spaces
group_windows_by_app
disable_bottom_right_hot_corner
section "Desktop and windows"
disable_tiled_window_margins
disable_edge_drag_tiling
disable_top_edge_drag_tiling
disable_option_drag_tiling
hide_desktop_items
hide_desktop_widgets
section "Finder"
use_finder_list_view
set_finder_new_window_target
show_finder_path_bar
disable_extension_change_warning
hide_hard_disks_on_desktop
hide_external_disks_on_desktop
hide_removable_media_on_desktop
section "Trackpad"
disable_tap_to_click
disable_three_finger_drag
disable_three_finger_tap_lookup
disable_pinch_to_zoom
disable_smart_zoom
disable_rotate_gesture
disable_notification_center_gesture
disable_thumb_pinch_gesture
disable_show_desktop_gesture
print_summary
restart_apps

if (( gallium_installed )); then
  cat <<'EOF'

The Gallium keyboard layout was just installed. To enable it:
  1. Log out and back in.
  2. System Settings > Keyboard > Text Input > Input Sources > Edit...
  3. Click +, find Gallium, click Add.
EOF
fi

if [[ -n "$karabiner_needs" ]]; then
  open "$KARABINER_APP"
  cat <<EOF

Karabiner-Elements isn't working yet (${karabiner_needs//_/ }). To finish:
  1. Follow the steps in its Settings window (just opened): it asks you to
     allow its background services, Accessibility, and its driver extension,
     each in System Settings.
  2. Run this script again; the Karabiner Status line should say "working".
  3. Try the keys in Karabiner-EventViewer: tapping Caps Lock shows escape;
     holding it with another key shows left_control.
EOF
fi

if (( ssh_key_created )); then
  pbcopy < "$SSH_KEY.pub"
  cat <<EOF

A new SSH key was created. To add it to GitHub:
  1. Its public key is on the clipboard (it's also in $SSH_KEY.pub).
  2. Go to https://github.com/settings/ssh/new, paste it, and add it as an
     Authentication Key.
  3. Check it works: ssh -T git@github.com
EOF
fi
