#!/usr/bin/env bash
set -euo pipefail

# Run on the Orin. This schedules a WiFi handoff so a NoMachine session can drop
# cleanly while the Orin switches to the target room WiFi.

IOTSWARM_CON="${IOTSWARM_CON:-iotswarm_5G}"
IOTLAB_CON="${IOTLAB_CON:-IoTLab_5G}"
DEFAULT_DELAY="${ORIN_SWITCH_DELAY:-5}"
LOG_FILE="${ORIN_SWITCH_LOG:-/var/log/orin-switch-wifi.log}"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  sudo $0 iotswarm [delay_seconds]
  sudo $0 iotlab [delay_seconds]

Examples:
  sudo $0 iotlab
  sudo $0 iotswarm 10
EOF
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

resolve_target() {
  case "$1" in
    iotswarm|iotswarm_5G|iotswarm_5g)
      printf '%s\n' "$IOTSWARM_CON"
      ;;
    iotlab|IoTLab_5G|IoTLab_5g)
      printf '%s\n' "$IOTLAB_CON"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

other_connection() {
  case "$1" in
    "$IOTSWARM_CON")
      printf '%s\n' "$IOTLAB_CON"
      ;;
    "$IOTLAB_CON")
      printf '%s\n' "$IOTSWARM_CON"
      ;;
    *)
      printf '\n'
      ;;
  esac
}

set_autoconnect() {
  local con="$1"
  local value="$2"
  local uuid
  connection_exists "$con" || return 0
  uuid="$(connection_uuid_by_name "$con")"
  nmcli connection modify "$uuid" connection.autoconnect "$value" >/dev/null 2>&1 || true
}

connection_down_if_exists() {
  local con="$1"
  local uuid

  connection_exists "$con" || return 0
  uuid="$(connection_uuid_by_name "$con")"
  nmcli connection down "$uuid" >/dev/null 2>&1 || true
}

switch_now() {
  local target="$1"
  local other old target_uuid old_uuid

  command -v nmcli >/dev/null 2>&1 || die "nmcli is required"
  target="$(resolve_target "$target")"
  connection_exists "$target" || die "connection not found: $target"

  other="$(other_connection "$target")"
  old="$(active_wifi_connection || true)"
  target_uuid="$(connection_uuid_by_name "$target")"

  printf '[orin-switch-wifi] switching to %s\n' "$target"
  set_autoconnect "$target" yes
  [ -n "$other" ] && set_autoconnect "$other" no

  if nmcli connection up "$target_uuid"; then
    set_autoconnect "$target" yes
    if [ -n "$other" ]; then
      set_autoconnect "$other" no
      connection_down_if_exists "$other"
    fi
    printf '[orin-switch-wifi] switched to %s\n' "$target"
    return 0
  fi

  printf '[orin-switch-wifi] failed to switch to %s\n' "$target" >&2
  if [ -n "$old" ] && connection_exists "$old"; then
    old_uuid="$(connection_uuid_by_name "$old")"
    set_autoconnect "$old" yes
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

  script_path="$(readlink -f "$0")"
  mkdir -p "$(dirname "$LOG_FILE")"
  nohup bash -c 'sleep "$1"; exec "$2" --worker "$3"' _ "$delay" "$script_path" "$target" >> "$LOG_FILE" 2>&1 &

  printf 'Scheduled WiFi switch to %s in %s seconds.\n' "$target" "$delay"
  printf 'Current NoMachine session will disconnect when the Orin changes WiFi.\n'
  printf 'Then switch the laptop to the same WiFi and reconnect.\n'
}

main() {
  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
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
