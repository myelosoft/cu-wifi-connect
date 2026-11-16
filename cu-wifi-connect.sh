#!/usr/bin/env bash
#
# cu-wifi-connect.sh - Set up ChulaWiFi / eduroam (Chulalongkorn University)
# on Linux using NetworkManager.
#
# Based on the original CU-WiFi-Connection script (TLS fix by @unwraps).
#
# Requirements:
#   - NetworkManager (nmcli). Do NOT manage the WiFi with a standalone
#     wpa_supplicant/iwd/netplan setup at the same time.
#   - whiptail (package "whiptail" or "newt") or dialog
#
# Usage:
#   ./cu-wifi-connect.sh          # interactive setup
#   ./cu-wifi-connect.sh --help
#
# Notes:
#   - Authentication settings are the same as the original script:
#     PEAP/MSCHAPv2, TLS 1.0 allowed, OpenSSL SECLEVEL=0 (NM >= 1.48).
#     The server certificate is NOT verified (no CA certificate is set).
#   - The password is handed to nmcli as a command-line argument, so it is
#     briefly visible to other users logged in to this machine (ps).
#

set -u -o pipefail

readonly APP_TITLE="CU WiFi Setup by NKR CUEE Version 1.0"
readonly CIPHERS_MIN_NM_VERSION="1.48"   # first version with 802-1x.openssl-ciphers
readonly EDUROAM_REALM="eduroam.chula.ac.th"
readonly CONNECT_TIMEOUT=45              # seconds
readonly W=66                            # dialog width

DIALOG=""
IFACE=""
SSID=""
USERNAME=""
PASSWORD=""
SIGNAL=""        # signal strength (%) of $SSID, empty = not in range

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------

# Run a dialog; anything the user typed/selected is printed on stdout.
ui() { "$DIALOG" --backtitle "$APP_TITLE" "$@" 3>&1 1>&2 2>&3; }

msg() { ui --title "$1" --msgbox "$2" "${3:-10}" "$W"; }   # title text [height]
ask() { ui --title "$1" --yesno  "$2" "${3:-10}" "$W"; }   # title text [height]

# Non-blocking "please wait" box.
info() {
  if [ "$DIALOG" = whiptail ]; then
    # whiptail's infobox is erased immediately on xterm-like terminals
    # unless TERM is something without an alternate screen.
    TERM=ansi ui --title "$1" --infobox "$2" 8 "$W"
  else
    ui --title "$1" --infobox "$2" 8 "$W"
  fi
}

die() { printf '\e[31mError:\e[0m %b\n' "$1" >&2; exit 1; }            # before the UI is up
fatal() { msg "Error" "$1" "${2:-12}"; clear; exit 1; }                # once the UI is up
quit() { clear; echo "Cancelled."; exit 1; }

# ver_ge A B  ->  true if version A >= version B
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

preflight() {
  if ! [ -t 0 ] || ! [ -t 2 ]; then
    die "This script is interactive; run it in a terminal."
  fi

  command -v nmcli >/dev/null 2>&1 ||
    die "nmcli not found. This script needs NetworkManager."

  if command -v whiptail >/dev/null 2>&1; then
    DIALOG=whiptail
  elif command -v dialog >/dev/null 2>&1; then
    DIALOG=dialog
  else
    die "whiptail (or dialog) not found. Install it first:
  Debian/Ubuntu : sudo apt install whiptail
  Fedora/RHEL   : sudo dnf install newt
  openSUSE      : sudo zypper install newt
  Arch          : sudo pacman -S libnewt"
  fi

  if [ "$(nmcli -t -f RUNNING general 2>/dev/null)" != "running" ]; then
    fatal "NetworkManager is not running.\n\nStart it with:\n  sudo systemctl enable --now NetworkManager"
  fi

  if [ "$(nmcli radio wifi 2>/dev/null)" != "enabled" ]; then
    ask "WiFi is off" "The WiFi radio is turned off.\n\nTurn it on now?" || quit
    nmcli radio wifi on >/dev/null 2>&1 ||
      fatal "Could not turn WiFi on.\nCheck the hardware switch / airplane mode."
    sleep 3   # give the adapter time to come up
  fi
}

select_interface() {
  local items=() dev type state
  while IFS=: read -r dev type state; do
    # exact match: skips "wifi-p2p" pseudo devices
    [ "$type" = "wifi" ] && items+=("$dev" "$state")
  done < <(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null)

  case $(( ${#items[@]} / 2 )) in
    0) fatal "No WiFi adapter detected.\n\nMake sure the adapter is plugged in and its driver is loaded." ;;
    1) IFACE=${items[0]} ;;   # only one adapter: nothing to choose
    *) IFACE=$(ui --title "WiFi adapter" \
         --menu "More than one WiFi adapter found. Choose one:" 15 "$W" 6 \
         "${items[@]}") || quit ;;
  esac
}

select_network() {
  SSID=$(ui --title "Network" \
    --menu "Which network do you want to set up on $IFACE?" 12 "$W" 2 \
    "ChulaWiFi" "Chulalongkorn University campus WiFi" \
    "eduroam"   "Education roaming network") || quit
}

# UUIDs of every saved profile named exactly $SSID
profile_uuids() {
  nmcli -t -f UUID,NAME connection show 2>/dev/null |
    awk -F: -v n="$SSID" '$2 == n { print $1 }'
}

check_existing_profile() {
  [ -n "$(profile_uuids)" ] || return 0
  ask "Profile exists" \
    "A saved profile named \"$SSID\" already exists.\n\nReplace it with a new one?" || quit
}

scan_for_network() {
  info "Scanning" "Looking for $SSID ..."
  SIGNAL=$(nmcli -t -f SSID,SIGNAL device wifi list ifname "$IFACE" --rescan auto 2>/dev/null |
    awk -F: -v s="$SSID" '$1 == s && $2 + 0 > m { m = $2 + 0 } END { if (m) print m }')

  if [ -z "$SIGNAL" ]; then
    ask "Not in range" \
      "$SSID was not found nearby.\n\nSave the profile anyway? Your computer will connect automatically the next time $SSID is in range." 11 || quit
  fi
}

ask_credentials() {
  local id_prompt="Student ID / Staff ID:"
  [ "$SSID" = "eduroam" ] &&
    id_prompt="Student ID / Staff ID:\n(@$EDUROAM_REALM is added automatically)"

  while true; do
    while true; do
      USERNAME=$(ui --title "Login - $SSID" --inputbox "$id_prompt" 10 "$W" "$USERNAME") || quit
      USERNAME=${USERNAME//[[:space:]]/}          # drop stray spaces
      [ -n "$USERNAME" ] && break
      msg "Missing username" "The username cannot be empty." 8
    done

    while true; do
      PASSWORD=$(ui --title "Login - $SSID" --passwordbox "CUNet password for $USERNAME:" 10 "$W") || quit
      [ -n "$PASSWORD" ] && break
      msg "Missing password" "The password cannot be empty." 8
    done

    if [ "$SSID" = "eduroam" ] && [[ "$USERNAME" != *@* ]]; then
      USERNAME="$USERNAME@$EDUROAM_REALM"
    fi

    local range="${SIGNAL:+in range, signal $SIGNAL%}"
    ask "Confirm" "\
Network   : $SSID (${range:-not in range})
Adapter   : $IFACE
Username  : $USERNAME
Password  : ${PASSWORD//?/*}

Save this profile?" 13 && break
  done
}

# Create the NetworkManager profile (replacing any old one with the same name).
save_profile() {
  local nm_version uuid out
  nm_version=$(nmcli -t -f VERSION general 2>/dev/null)

  local args=(
    connection add type wifi ifname "$IFACE" con-name "$SSID" ssid "$SSID"
    wifi-sec.key-mgmt wpa-eap
    802-1x.eap peap
    802-1x.phase2-auth mschapv2
    802-1x.identity "$USERNAME"
    802-1x.password "$PASSWORD"
    802-1x.phase1-auth-flags 32          # 0x20 = allow TLS 1.0
  )
  # Needed with OpenSSL 3: let the old TLS version/ciphers through.
  if [ -n "$nm_version" ] && ver_ge "$nm_version" "$CIPHERS_MIN_NM_VERSION"; then
    args+=(802-1x.openssl-ciphers "DEFAULT@SECLEVEL=0")
  fi

  for uuid in $(profile_uuids); do
    nmcli connection delete uuid "$uuid" >/dev/null 2>&1
  done

  if ! out=$(nmcli "${args[@]}" 2>&1); then
    msg "Error" "Could not save the WiFi profile:\n\n$out" 14
    return 1
  fi
  PASSWORD=""
}

delete_profile() {
  local uuid
  for uuid in $(profile_uuids); do
    nmcli connection delete uuid "$uuid" >/dev/null 2>&1
  done
}

# Returns 0 when connected, 1 when the user wants to re-enter credentials.
connect() {
  local out choice
  info "Connecting" "Connecting to $SSID ...\n\nThis can take up to $CONNECT_TIMEOUT seconds."
  if out=$(nmcli --wait "$CONNECT_TIMEOUT" connection up id "$SSID" ifname "$IFACE" 2>&1); then
    return 0
  fi

  msg "Connection failed" "\
Could not connect to $SSID.

$out

Most common causes: wrong username/password, or a weak signal.
More detail: journalctl -u NetworkManager -n 50" 17

  choice=$(ui --title "Connection failed" --menu "What do you want to do?" 12 "$W" 3 \
    "retry"  "Re-enter username and password" \
    "keep"   "Keep the saved profile and exit" \
    "delete" "Delete the saved profile and exit") || choice="keep"

  case $choice in
    retry)  return 1 ;;
    delete) delete_profile; clear; echo "Profile \"$SSID\" deleted."; exit 1 ;;
    *)      clear; echo "Profile \"$SSID\" kept. Not connected."; exit 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case ${1:-} in
  -h|--help)
    sed -n '2,/^$/ s/^# \{0,1\}//p' "$0"
    exit 0 ;;
  "") ;;
  *) die "Unknown option: $1 (try --help)" ;;
esac

preflight
select_interface
select_network
check_existing_profile
scan_for_network

while true; do
  ask_credentials
  save_profile || { clear; exit 1; }

  if [ -z "$SIGNAL" ]; then
    msg "Profile saved" "The profile \"$SSID\" was saved.\n\nYour computer will connect automatically when $SSID is in range."
    clear
    printf '\e[32mProfile "%s" saved (not connected yet).\e[0m\n' "$SSID"
    exit 0
  fi

  connect && break
done

ip_addr=$(nmcli -g IP4.ADDRESS device show "$IFACE" 2>/dev/null | head -n1)
msg "Connected" "\
You are now connected to $SSID.

Adapter    : $IFACE
IP address : ${ip_addr:-(not assigned yet)}

The profile is saved, so this computer will reconnect automatically." 13
clear
printf '\e[32mConnected to %s successfully.\e[0m\n' "$SSID"
