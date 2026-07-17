#!/usr/bin/env bash
set -euo pipefail

# This script runs on the Orin. It is intended to be launched by systemd at
# boot, after NetworkManager starts. It follows /etc/orin-wifi-target, or uses
# auto mode to choose the strongest visible configured WiFi.

CONFIG_FILE="${ORIN_AUTO_WIFI_CONFIG:-/etc/orin-auto-wifi.conf}"
TARGET_FILE="${ORIN_WIFI_TARGET_FILE:-/etc/orin-wifi-target}"

IOTSWARM_CON="${IOTSWARM_CON:-iotswarm_5G}"
IOTSWARM_SSID="${IOTSWARM_SSID:-iotswarm_5G}"
IOTLAB_CON="${IOTLAB_CON:-IoTLab_5G}"
IOTLAB_SSID="${IOTLAB_SSID:-IoTLab_5G}"
WIFI_PROFILES="${WIFI_PROFILES:-}"
ORIN_AUTOWIFI_ATTEMPTS="${ORIN_AUTOWIFI_ATTEMPTS:-18}"
ORIN_AUTOWIFI_INTERVAL="${ORIN_AUTOWIFI_INTERVAL:-5}"
LOCK_SELECTED_WIFI="${LOCK_SELECTED_WIFI:-yes}"
DISABLE_UNMANAGED_WIFI_AUTOCONNECT="${DISABLE_UNMANAGED_WIFI_AUTOCONNECT:-yes}"
REFRESH_AVAHI_AFTER_WIFI="${REFRESH_AVAHI_AFTER_WIFI:-yes}"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

log() {
  printf '[orin-auto-wifi] %s\n' "$*"
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

csv_value_matches() {
  local wanted="$1"
  local csv="${2:-}"
  local item
  local old_ifs="$IFS"

  IFS=','
  for item in $csv; do
    IFS="$old_ifs"
    [ "$wanted" = "$item" ] && return 0
    IFS=','
  done
  IFS="$old_ifs"
  return 1
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

ssid_matches() {
  local visible="$1"
  local configured="$2"
  local aliases="${3:-}"
  local alias

  while IFS= read -r alias; do
    [ -n "$alias" ] || continue
    [ "$visible" = "$alias" ] && return 0
  done < <(ssid_aliases "$configured" "$aliases")
  return 1
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
  csv_value_matches "$target" "$aliases"
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

set_managed_autoconnect() {
  local selected="${1:-}"
  local line con ssid aliases value

  while IFS= read -r line; do
    IFS='|' read -r con ssid aliases _ <<< "$line"
    [ -n "$con" ] || continue
    if [ -z "$selected" ] || [ "$con" = "$selected" ]; then
      value="yes"
    else
      value="no"
    fi
    set_connection_autoconnect "$con" "$value"
  done < <(wifi_profile_lines)
}

disable_unmanaged_wifi_autoconnect() {
  local keep="${1:-}"
  local name uuid type

  [ "$DISABLE_UNMANAGED_WIFI_AUTOCONNECT" = "yes" ] || return 0

  while IFS=: read -r name uuid type; do
    [ "$type" = "802-11-wireless" ] || [ "$type" = "wifi" ] || continue
    [ -n "$name" ] || continue
    [ "$name" = "$keep" ] && continue
    profile_is_managed "$name" && continue
    nmcli connection modify "$uuid" connection.autoconnect no >/dev/null 2>&1 || true
  done < <(nmcli -t -f NAME,UUID,TYPE connection show)
}

active_wifi_connection() {
  nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1; exit}'
}

resolve_target() {
  local target="${1:-}"
  local line con ssid aliases

  case "$target" in
    ''|auto)
      printf 'auto\n'
      return 0
      ;;
  esac

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

refresh_avahi_after_wifi_connect() {
  [ "$REFRESH_AVAHI_AFTER_WIFI" = "yes" ] || return 0
  systemctl try-restart avahi-daemon.service >/dev/null 2>&1 || true
}

best_visible_profile() {
  local wanted="${1:-auto}"
  local best_con=""
  local best_ssid=""
  local best_signal="-1"
  local ssid signal rest line con configured_ssid aliases

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

    while IFS= read -r line; do
      IFS='|' read -r con configured_ssid aliases _ <<< "$line"
      [ -n "$con" ] || continue
      [ -n "$configured_ssid" ] || configured_ssid="$con"
      if [ "$wanted" != "auto" ] && [ "$wanted" != "$con" ]; then
        continue
      fi
      if ssid_matches "$ssid" "$configured_ssid" "${aliases:-}" && [ "$signal" -gt "$best_signal" ]; then
        best_signal="$signal"
        best_ssid="$ssid"
        best_con="$con"
      fi
    done < <(wifi_profile_lines)
  done < <(nmcli -t -f SSID,SIGNAL device wifi list 2>/dev/null)

  [ -n "$best_con" ] || return 1
  printf '%s|%s|%s\n' "$best_con" "$best_ssid" "$best_signal"
}

connect_explicit_connection_once() {
  local con="$1"
  local active con_id

  connection_exists "$con" || return 1
  active="$(active_wifi_connection || true)"
  if [ "$active" = "$con" ]; then
    log "already connected to $con"
    disable_wifi_powersave
    refresh_avahi_after_wifi_connect
    return 0
  fi

  con_id="$(connection_uuid_by_name "$con")"
  log "connecting to explicit NetworkManager profile $con"
  nmcli connection up "$con_id" >/dev/null
  disable_wifi_powersave
  refresh_avahi_after_wifi_connect
}

connect_best_once() {
  local wanted="${1:-auto}"
  local result con ssid signal active con_id

  if [ "$wanted" != "auto" ] && ! profile_is_managed "$wanted"; then
    connect_explicit_connection_once "$wanted"
    return
  fi

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
    refresh_avahi_after_wifi_connect
    return 0
  fi

  con_id="$(connection_uuid_by_name "$con")"
  log "connecting to $con ($ssid, signal $signal)"
  nmcli connection modify "$con_id" 802-11-wireless.ssid "$ssid" >/dev/null
  nmcli connection up "$con_id" >/dev/null
  lock_selected_wifi "$con"
  disable_wifi_powersave
  refresh_avahi_after_wifi_connect
}

lock_selected_wifi() {
  local selected="$1"
  [ "$LOCK_SELECTED_WIFI" = "yes" ] || return 0
  profile_is_managed "$selected" || return 0

  set_managed_autoconnect "$selected"
  log "locked this boot to $selected; disabled other managed WiFi autoconnect"
}

main() {
  command -v nmcli >/dev/null 2>&1 || {
    log "nmcli not found"
    exit 1
  }

  local boot_target
  boot_target="$(read_boot_target)"

  if [ "$boot_target" = "auto" ]; then
    disable_unmanaged_wifi_autoconnect
    set_managed_autoconnect
    log "boot target is auto"
  elif profile_is_managed "$boot_target"; then
    disable_unmanaged_wifi_autoconnect "$boot_target"
    set_managed_autoconnect "$boot_target"
    log "boot target is $boot_target"
  else
    disable_unmanaged_wifi_autoconnect "$boot_target"
    set_connection_autoconnect "$boot_target" yes
    log "boot target is explicit NetworkManager profile $boot_target"
  fi

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
