#!/usr/bin/env bash
set -euo pipefail

# Run on the Orin. This schedules a WiFi handoff so a NoMachine session can drop
# cleanly while the Orin switches to the target room WiFi.

CONFIG_FILE="${ORIN_AUTO_WIFI_CONFIG:-/etc/orin-auto-wifi.conf}"
IOTSWARM_CON="${IOTSWARM_CON:-iotswarm_5G}"
IOTSWARM_SSID="${IOTSWARM_SSID:-iotswarm_5G}"
IOTLAB_CON="${IOTLAB_CON:-IoTLab_5G}"
IOTLAB_SSID="${IOTLAB_SSID:-IoTLab_5G}"
WIFI_PROFILES="${WIFI_PROFILES:-}"
TARGET_FILE="${ORIN_WIFI_TARGET_FILE:-/etc/orin-wifi-target}"
DEFAULT_DELAY="${ORIN_SWITCH_DELAY:-5}"
LOG_FILE="${ORIN_SWITCH_LOG:-/var/log/orin-switch-wifi.log}"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  sudo $0 <profile-or-connection> [delay_seconds]
  sudo $0 target <profile-or-connection>

Examples:
  sudo $0 iotlab
  sudo $0 iotswarm 10
  sudo $0 target iotlab
  sudo $0 room
EOF
}

default_wifi_profiles() {
  printf '%s|%s|%s\n' "$IOTSWARM_CON" "$IOTSWARM_SSID" "iotswarm,iotswarm_5G,iotswarm_5g"
  printf '%s|%s|%s\n' "$IOTLAB_CON" "$IOTLAB_SSID" "iotlab,IoTLab_5G,IoTLab_5g"
}

wifi_profile_lines() {
  local line

  if [ -n "${WIFI_PROFILES:-}" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      printf '%s\n' "$line"
    done <<< "$WIFI_PROFILES"
  else
    default_wifi_profiles
  fi
}

ssid_aliases() {
  local ssid="$1"
  local aliases="${2:-}"

  printf '%s\n' "$ssid"
  case "$ssid" in
    *_5g)
      printf '%s\n' "${ssid%_5g}_5G"
      ;;
    *_5G)
      printf '%s\n' "${ssid%_5G}_5g"
      ;;
  esac

  if [ -n "$aliases" ]; then
    printf '%s\n' "$aliases" | tr ',' '\n'
  fi
}

profile_matches_target() {
  local target="$1"
  local con="$2"
  local ssid="$3"
  local aliases="${4:-}"
  local alias

  [ "$target" = "$con" ] && return 0
  while IFS= read -r alias; do
    [ -n "$alias" ] || continue
    [ "$target" = "$alias" ] && return 0
  done < <(ssid_aliases "$ssid" "$aliases")
  return 1
}

profile_is_managed() {
  local wanted="$1"
  local line con ssid aliases

  while IFS= read -r line; do
    IFS='|' read -r con ssid aliases _ <<< "$line"
    [ "$wanted" = "$con" ] && return 0
  done < <(wifi_profile_lines)
  return 1
}

resolve_target() {
  local target="$1"
  local line con ssid aliases

  while IFS= read -r line; do
    IFS='|' read -r con ssid aliases _ <<< "$line"
    [ -n "$con" ] || continue
    [ -n "$ssid" ] || ssid="$con"
    if profile_matches_target "$target" "$con" "$ssid" "${aliases:-}"; then
      printf '%s\n' "$con"
      return 0
    fi
  done < <(wifi_profile_lines)

  printf '%s\n' "$target"
}

connection_exists() {
  nmcli -t -f NAME connection show | awk -F: -v name="$1" '$1 == name {found=1} END {exit found ? 0 : 1}'
}

connection_uuid_by_name() {
  nmcli -t -f NAME,UUID connection show | awk -F: -v name="$1" '$1 == name {print $2; exit}'
}

active_wifi_connection() {
  nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1; exit}'
}

active_wifi_device() {
  nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $3; exit}'
}

disable_wifi_powersave() {
  local dev

  command -v iw >/dev/null 2>&1 || return 0
  dev="$(active_wifi_device || true)"
  [ -n "$dev" ] || return 0
  iw dev "$dev" set power_save off >/dev/null 2>&1 || true
}

set_autoconnect() {
  local con="$1"
  local value="$2"
  local uuid

  connection_exists "$con" || return 0
  uuid="$(connection_uuid_by_name "$con")"
  nmcli connection modify "$uuid" connection.autoconnect "$value" >/dev/null 2>&1 || true
}

set_managed_autoconnect() {
  local selected="$1"
  local line con ssid aliases value

  profile_is_managed "$selected" || return 0
  while IFS= read -r line; do
    IFS='|' read -r con ssid aliases _ <<< "$line"
    [ -n "$con" ] || continue
    if [ "$con" = "$selected" ]; then
      value="yes"
    else
      value="no"
    fi
    set_autoconnect "$con" "$value"
  done < <(wifi_profile_lines)
}

write_target() {
  local target="$1"

  printf '%s\n' "$target" > "$TARGET_FILE"
  chmod 0644 "$TARGET_FILE"
}

connection_down_if_exists() {
  local con="$1"
  local uuid

  connection_exists "$con" || return 0
  uuid="$(connection_uuid_by_name "$con")"
  nmcli connection down "$uuid" >/dev/null 2>&1 || true
}

disconnect_other_managed_connections() {
  local selected="$1"
  local line con ssid aliases

  profile_is_managed "$selected" || return 0
  while IFS= read -r line; do
    IFS='|' read -r con ssid aliases _ <<< "$line"
    [ -n "$con" ] || continue
    [ "$con" = "$selected" ] && continue
    connection_down_if_exists "$con"
  done < <(wifi_profile_lines)
}

set_next_boot_target() {
  local target="$1"

  command -v nmcli >/dev/null 2>&1 || die "nmcli is required"
  target="$(resolve_target "$target")"
  connection_exists "$target" || die "connection not found: $target"

  write_target "$target"
  set_autoconnect "$target" yes
  set_managed_autoconnect "$target"

  printf 'Next reboot target is now %s.\n' "$target"
}

switch_now() {
  local target="$1"
  local old target_uuid old_uuid

  command -v nmcli >/dev/null 2>&1 || die "nmcli is required"
  target="$(resolve_target "$target")"
  connection_exists "$target" || die "connection not found: $target"

  old="$(active_wifi_connection || true)"
  target_uuid="$(connection_uuid_by_name "$target")"

  printf '[orin-switch-wifi] switching to %s\n' "$target"
  write_target "$target"
  set_autoconnect "$target" yes
  set_managed_autoconnect "$target"

  if nmcli connection up "$target_uuid"; then
    set_autoconnect "$target" yes
    set_managed_autoconnect "$target"
    write_target "$target"
    disable_wifi_powersave
    disconnect_other_managed_connections "$target"
    printf '[orin-switch-wifi] switched to %s\n' "$target"
    return 0
  fi

  printf '[orin-switch-wifi] failed to switch to %s\n' "$target" >&2
  if [ -n "$old" ] && connection_exists "$old"; then
    old_uuid="$(connection_uuid_by_name "$old")"
    set_autoconnect "$old" yes
    set_managed_autoconnect "$old"
    write_target "$old"
    nmcli connection up "$old_uuid" >/dev/null 2>&1 || true
    printf '[orin-switch-wifi] restored %s\n' "$old"
  fi
  return 1
}

schedule_switch() {
  local target="$1"
  local delay="${2:-$DEFAULT_DELAY}"
  local script_path

  case "$delay" in
    ''|*[!0-9]*)
      die "delay must be a number"
      ;;
  esac

  target="$(resolve_target "$target")"
  connection_exists "$target" || die "connection not found: $target"
  write_target "$target"

  script_path="$(readlink -f "$0")"
  mkdir -p "$(dirname "$LOG_FILE")"
  nohup bash -c 'sleep "$1"; exec "$2" --worker "$3"' _ "$delay" "$script_path" "$target" >> "$LOG_FILE" 2>&1 &

  printf 'Scheduled WiFi switch to %s in %s seconds.\n' "$target" "$delay"
  printf 'Next reboot target is now %s.\n' "$target"
  printf 'Current NoMachine session will disconnect when the Orin changes WiFi.\n'
  printf 'Then switch the laptop to the same WiFi and reconnect.\n'
}

main() {
  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
    target|set-target|--target)
      [ "${EUID:-$(id -u)}" -eq 0 ] || die "run with sudo"
      [ -n "${2:-}" ] || die "missing target"
      set_next_boot_target "$2"
      ;;
    --worker)
      [ "${EUID:-$(id -u)}" -eq 0 ] || die "run with sudo"
      [ -n "${2:-}" ] || die "missing target"
      switch_now "$2"
      ;;
    *)
      [ "${EUID:-$(id -u)}" -eq 0 ] || die "run with sudo"
      [ -n "${1:-}" ] || die "missing target"
      schedule_switch "$1" "${2:-$DEFAULT_DELAY}"
      ;;
  esac
}

main "$@"
