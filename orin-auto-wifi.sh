#!/usr/bin/env bash
set -euo pipefail

# This script runs on the Orin. It is intended to be launched by systemd at
# boot, after NetworkManager starts. It follows /etc/orin-wifi-target, or uses
# auto mode to choose the strongest visible configured lab WiFi.

CONFIG_FILE="${ORIN_AUTO_WIFI_CONFIG:-/etc/orin-auto-wifi.conf}"
TARGET_FILE="${ORIN_WIFI_TARGET_FILE:-/etc/orin-wifi-target}"

IOTSWARM_CON="${IOTSWARM_CON:-iotswarm_5G}"
IOTSWARM_SSID="${IOTSWARM_SSID:-iotswarm_5G}"
IOTLAB_CON="${IOTLAB_CON:-IoTLab_5G}"
IOTLAB_SSID="${IOTLAB_SSID:-IoTLab_5G}"
ORIN_AUTOWIFI_ATTEMPTS="${ORIN_AUTOWIFI_ATTEMPTS:-18}"
ORIN_AUTOWIFI_INTERVAL="${ORIN_AUTOWIFI_INTERVAL:-5}"
LOCK_SELECTED_WIFI="${LOCK_SELECTED_WIFI:-yes}"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

log() {
  printf '[orin-auto-wifi] %s\n' "$*"
}

ssid_aliases() {
  local ssid="$1"
  printf '%s\n' "$ssid"
  case "$ssid" in
    *_5g)
      printf '%s\n' "${ssid%_5g}_5G"
      ;;
    *_5G)
      printf '%s\n' "${ssid%_5G}_5g"
      ;;
  esac
}

ssid_matches() {
  local visible="$1"
  local configured="$2"
  local alias
  while IFS= read -r alias; do
    [ "$visible" = "$alias" ] && return 0
  done < <(ssid_aliases "$configured")
  return 1
}

connection_exists() {
  nmcli -t -f NAME connection show | awk -F: -v name="$1" '$1 == name {found=1} END {exit found ? 0 : 1}'
}

connection_uuid_by_name() {
  nmcli -t -f NAME,UUID connection show | awk -F: -v name="$1" '$1 == name {print $2; exit}'
}

set_connection_autoconnect() {
  local con="$1"
  local value="$2"
  local con_id

  connection_exists "$con" || return 0
  con_id="$(connection_uuid_by_name "$con")"
  nmcli connection modify "$con_id" connection.autoconnect "$value" >/dev/null 2>&1 || true
}

active_wifi_connection() {
  nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1; exit}'
}

resolve_target() {
  case "$1" in
    ''|auto)
      printf 'auto\n'
      ;;
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

read_boot_target() {
  local target="${ORIN_WIFI_TARGET:-}"

  if [ -z "$target" ] && [ -f "$TARGET_FILE" ]; then
    target="$(head -n 1 "$TARGET_FILE" 2>/dev/null | tr -d '\r' || true)"
  fi
  resolve_target "$target"
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

best_visible_profile() {
  local wanted="${1:-auto}"
  local best_con=""
  local best_ssid=""
  local best_signal="-1"
  local ssid signal rest

  nmcli device wifi rescan >/dev/null 2>&1 || true
  sleep 2

  while IFS=: read -r ssid signal rest; do
    [ -z "${ssid:-}" ] && continue
    [ -z "${signal:-}" ] && continue
    case "$signal" in
      *[!0-9]*)
        continue
        ;;
    esac

    if [ "$wanted" != "$IOTLAB_CON" ] && ssid_matches "$ssid" "$IOTSWARM_SSID" && [ "$signal" -gt "$best_signal" ]; then
      best_signal="$signal"
      best_ssid="$ssid"
      best_con="$IOTSWARM_CON"
    fi
    if [ "$wanted" != "$IOTSWARM_CON" ] && ssid_matches "$ssid" "$IOTLAB_SSID" && [ "$signal" -gt "$best_signal" ]; then
      best_signal="$signal"
      best_ssid="$ssid"
      best_con="$IOTLAB_CON"
    fi
  done < <(nmcli -t -f SSID,SIGNAL device wifi list 2>/dev/null)

  [ -n "$best_con" ] || return 1
  printf '%s|%s|%s\n' "$best_con" "$best_ssid" "$best_signal"
}

connect_best_once() {
  local wanted="${1:-auto}"
  local result con ssid signal active con_id

  result="$(best_visible_profile "$wanted")" || return 1
  IFS='|' read -r con ssid signal <<< "$result"

  if ! connection_exists "$con"; then
    log "visible SSID $ssid, but connection profile $con does not exist"
    return 1
  fi

  active="$(active_wifi_connection || true)"
  if [ "$active" = "$con" ]; then
    log "already connected to $con ($ssid, signal $signal)"
    lock_selected_wifi "$con"
    disable_wifi_powersave
    return 0
  fi

  con_id="$(connection_uuid_by_name "$con")"
  log "connecting to $con ($ssid, signal $signal)"
  nmcli connection modify "$con_id" 802-11-wireless.ssid "$ssid" >/dev/null
  nmcli connection up "$con_id" >/dev/null
  lock_selected_wifi "$con"
  disable_wifi_powersave
}

lock_selected_wifi() {
  local selected="$1"
  [ "$LOCK_SELECTED_WIFI" = "yes" ] || return 0

  if [ "$selected" = "$IOTSWARM_CON" ]; then
    set_connection_autoconnect "$IOTSWARM_CON" yes
    set_connection_autoconnect "$IOTLAB_CON" no
    log "locked this boot to $IOTSWARM_CON; disabled $IOTLAB_CON autoconnect"
  elif [ "$selected" = "$IOTLAB_CON" ]; then
    set_connection_autoconnect "$IOTLAB_CON" yes
    set_connection_autoconnect "$IOTSWARM_CON" no
    log "locked this boot to $IOTLAB_CON; disabled $IOTSWARM_CON autoconnect"
  fi
}

main() {
  command -v nmcli >/dev/null 2>&1 || {
    log "nmcli not found"
    exit 1
  }

  local boot_target
  boot_target="$(read_boot_target)"

  case "$boot_target" in
    "$IOTSWARM_CON")
      set_connection_autoconnect "$IOTSWARM_CON" yes
      set_connection_autoconnect "$IOTLAB_CON" no
      log "boot target is $IOTSWARM_CON"
      ;;
    "$IOTLAB_CON")
      set_connection_autoconnect "$IOTLAB_CON" yes
      set_connection_autoconnect "$IOTSWARM_CON" no
      log "boot target is $IOTLAB_CON"
      ;;
    *)
      boot_target="auto"
      set_connection_autoconnect "$IOTSWARM_CON" yes
      set_connection_autoconnect "$IOTLAB_CON" yes
      log "boot target is auto"
      ;;
  esac

  local attempt
  for attempt in $(seq 1 "$ORIN_AUTOWIFI_ATTEMPTS"); do
    if connect_best_once "$boot_target"; then
      exit 0
    fi
    log "no configured WiFi visible yet, attempt $attempt/$ORIN_AUTOWIFI_ATTEMPTS"
    sleep "$ORIN_AUTOWIFI_INTERVAL"
  done

  log "failed to connect to configured WiFi"
  exit 1
}

main "$@"
