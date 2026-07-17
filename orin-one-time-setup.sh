#!/usr/bin/env bash
set -euo pipefail

# Run this script once on the Orin, not on the laptop.
# It creates/updates NetworkManager WiFi profiles so the headless Orin can join
# a known lab or room WiFi after boot.

ORIN_HOSTNAME="${ORIN_HOSTNAME:-onboard-nx}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IOTSWARM_CON="${IOTSWARM_CON:-iotswarm_5G}"
IOTSWARM_SSID="${IOTSWARM_SSID:-iotswarm_5G}"
IOTSWARM_PSK="${IOTSWARM_PSK:-}"
IOTLAB_CON="${IOTLAB_CON:-IoTLab_5G}"
IOTLAB_SSID="${IOTLAB_SSID:-IoTLab_5G}"
IOTLAB_PSK="${IOTLAB_PSK:-}"
ORIN_EXTRA_WIFI_PROFILES="${ORIN_EXTRA_WIFI_PROFILES:-}"
PRIORITY="${WIFI_AUTOCONNECT_PRIORITY:-100}"
WIFI_ROUTE_METRIC="${WIFI_ROUTE_METRIC:-100}"
TARGET_FILE="${ORIN_WIFI_TARGET_FILE:-/etc/orin-wifi-target}"
ORIN_WIFI_TARGET="${ORIN_WIFI_TARGET:-auto}"
CONFIGURE_AVAHI_WIFI_ONLY="${CONFIGURE_AVAHI_WIFI_ONLY:-yes}"
AVAHI_ALLOW_INTERFACES="${AVAHI_ALLOW_INTERFACES:-auto}"
AVAHI_DISABLE_REFLECTOR="${AVAHI_DISABLE_REFLECTOR:-yes}"
INSTALL_AUTO_WIFI="${INSTALL_AUTO_WIFI:-yes}"
DISABLE_OTHER_WIFI_AUTOCONNECT="${DISABLE_OTHER_WIFI_AUTOCONNECT:-yes}"
STATE_DIR="${ORIN_WIFI_STATE_DIR:-/etc/orin-nomachine-wifi}"
AUTOCONNECT_STATE_FILE="$STATE_DIR/wifi-autoconnect.before"
HOSTNAME_STATE_FILE="$STATE_DIR/hostname.before"
AVAHI_BACKUP_FILE="$STATE_DIR/avahi-daemon.conf.before"
AVAHI_SERVICE_STATE_FILE="$STATE_DIR/avahi-daemon.enabled.before"
NXSERVER_SERVICE_STATE_FILE="$STATE_DIR/nxserver.enabled.before"

usage() {
  cat <<'EOF'
Usage:
  sudo ./orin-one-time-setup.sh

Optional environment variables:
  ORIN_HOSTNAME=onboard-nx
  IOTSWARM_SSID='iotswarm_5G'
  IOTSWARM_PSK='wifi password'
  IOTLAB_SSID='IoTLab_5G'
  IOTLAB_PSK='wifi password'
  ORIN_EXTRA_WIFI_PROFILES='connection name|SSID|wifi password|alias1,alias2'
  INSTALL_AUTO_WIFI=yes
  DISABLE_OTHER_WIFI_AUTOCONNECT=yes
  AVAHI_ALLOW_INTERFACES=auto

Example:
  sudo env IOTSWARM_SSID='iotswarm(5g)' IOTSWARM_PSK='xxx' \
    IOTLAB_SSID='IoTLab(5g)' IOTLAB_PSK='yyy' \
    ./orin-one-time-setup.sh

Add one more WiFi:
  sudo env ORIN_EXTRA_WIFI_PROFILES='room_wifi|Room WiFi|secret|room' \
    ./orin-one-time-setup.sh
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

connection_exists() {
  nmcli -t -f NAME connection show | awk -F: -v name="$1" '$1 == name {found=1} END {exit found ? 0 : 1}'
}

connection_uuid_by_name() {
  nmcli -t -f NAME,UUID connection show | awk -F: -v name="$1" '$1 == name {print $2; exit}'
}

prompt_psk_if_needed() {
  local var_name="$1"
  local con_name="$2"
  local current_value="$3"

  if [ -n "$current_value" ] || connection_exists "$con_name"; then
    printf '%s' "$current_value"
    return 0
  fi

  if [ ! -t 0 ]; then
    die "$var_name is required because connection $con_name does not exist"
  fi

  local secret
  read -r -s -p "$var_name: " secret
  printf '\n' >&2
  printf '%s' "$secret"
}

upsert_wifi() {
  local con_name="$1"
  local ssid="$2"
  local psk="$3"
  local con_id

  if connection_exists "$con_name"; then
    con_id="$(connection_uuid_by_name "$con_name")"
    nmcli connection modify "$con_id" 802-11-wireless.ssid "$ssid"
  else
    nmcli connection add type wifi ifname "*" con-name "$con_name" ssid "$ssid"
    con_id="$(connection_uuid_by_name "$con_name")"
  fi

  nmcli connection modify "$con_id" \
    connection.autoconnect yes \
    connection.autoconnect-priority "$PRIORITY" \
    connection.autoconnect-retries 0 \
    ipv4.method auto \
    ipv4.route-metric "$WIFI_ROUTE_METRIC" \
    ipv6.method auto \
    ipv6.route-metric "$WIFI_ROUTE_METRIC" \
    802-11-wireless.powersave 2 \
    802-11-wireless.mode infrastructure

  if [ -n "$psk" ]; then
    nmcli connection modify "$con_id" \
      wifi-sec.key-mgmt wpa-psk \
      wifi-sec.psk "$psk"
  fi
}

enable_service_if_present() {
  local service="$1"
  if systemctl list-unit-files "$service" >/dev/null 2>&1; then
    systemctl enable --now "$service" >/dev/null 2>&1 || true
  fi
}

wifi_interfaces() {
  local dev type

  while IFS=: read -r dev type; do
    [ -n "$dev" ] || continue
    case "$type" in
      wifi|802-11-wireless)
        printf '%s\n' "$dev"
        ;;
    esac
  done < <(nmcli -t -f DEVICE,TYPE device status 2>/dev/null)

  for dev in /sys/class/net/*; do
    [ -d "$dev/wireless" ] && basename "$dev"
  done
}

resolve_avahi_allow_interfaces() {
  local interfaces

  if [ "$AVAHI_ALLOW_INTERFACES" != "auto" ]; then
    printf '%s\n' "$AVAHI_ALLOW_INTERFACES"
    return 0
  fi

  interfaces="$(wifi_interfaces | awk '!seen[$0]++' | paste -sd, -)"
  [ -n "$interfaces" ] || die "could not find a WiFi interface; set AVAHI_ALLOW_INTERFACES explicitly"
  printf '%s\n' "$interfaces"
}

set_avahi_option() {
  local conf="$1"
  local section="$2"
  local option="$3"
  local value="$4"
  local tmp

  tmp="$(mktemp)"
  awk -v section="$section" -v option="$option" -v value="$value" '
    BEGIN { in_section = 0; saw_section = 0; wrote = 0; option_re = "^[#[:space:]]*" option "[[:space:]]*=" }
    $0 == "[" section "]" {
      in_section = 1
      saw_section = 1
      print
      next
    }
    /^\[/ {
      if (in_section && !wrote) {
        print option "=" value
        wrote = 1
      }
      in_section = 0
      print
      next
    }
    in_section && $0 ~ option_re {
      if (!wrote) {
        print option "=" value
        wrote = 1
      }
      next
    }
    { print }
    END {
      if (in_section && !wrote) {
        print option "=" value
      }
      if (!saw_section) {
        print ""
        print "[" section "]"
        print option "=" value
      }
    }
  ' "$conf" > "$tmp"
  install -m 0644 "$tmp" "$conf"
  rm -f "$tmp"
}

configure_avahi_wifi_only() {
  local conf="/etc/avahi/avahi-daemon.conf"

  [ "$CONFIGURE_AVAHI_WIFI_ONLY" = "yes" ] || return 0
  [ -f "$conf" ] || return 0

  cp -n "$conf" "$conf.bak" 2>/dev/null || true
  set_avahi_option "$conf" server allow-interfaces "$AVAHI_ALLOW_INTERFACES"
  if [ "$AVAHI_DISABLE_REFLECTOR" = "yes" ]; then
    set_avahi_option "$conf" reflector enable-reflector no
  fi
  systemctl restart avahi-daemon.service >/dev/null 2>&1 || true
}

shell_quote() {
  printf '%q' "$1"
}

MANAGED_WIFI_NAMES=""
AUTO_WIFI_PROFILES=""

append_managed_wifi_name() {
  if [ -z "$MANAGED_WIFI_NAMES" ]; then
    MANAGED_WIFI_NAMES="$1"
  else
    MANAGED_WIFI_NAMES="$MANAGED_WIFI_NAMES"$'\n'"$1"
  fi
}

append_auto_wifi_profile() {
  local con_name="$1"
  local ssid="$2"
  local aliases="$3"
  local line="$con_name|$ssid|$aliases"

  if [ -z "$AUTO_WIFI_PROFILES" ]; then
    AUTO_WIFI_PROFILES="$line"
  else
    AUTO_WIFI_PROFILES="$AUTO_WIFI_PROFILES"$'\n'"$line"
  fi
}

default_wifi_profiles() {
  printf '%s|%s|%s|%s\n' "$IOTSWARM_CON" "$IOTSWARM_SSID" "$IOTSWARM_PSK" "iotswarm,iotswarm_5G,iotswarm_5g"
  printf '%s|%s|%s|%s\n' "$IOTLAB_CON" "$IOTLAB_SSID" "$IOTLAB_PSK" "iotlab,IoTLab_5G,IoTLab_5g"
}

wifi_profile_lines() {
  local line

  default_wifi_profiles
  if [ -n "$ORIN_EXTRA_WIFI_PROFILES" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      printf '%s\n' "$line"
    done <<< "$ORIN_EXTRA_WIFI_PROFILES"
  fi
}

configure_wifi_profiles() {
  local line con_name ssid psk aliases psk_label

  MANAGED_WIFI_NAMES=""
  AUTO_WIFI_PROFILES=""
  while IFS= read -r line; do
    IFS='|' read -r con_name ssid psk aliases _ <<< "$line"
    [ -n "$con_name" ] || continue
    [ -n "$ssid" ] || ssid="$con_name"
    aliases="${aliases:-}"
    psk_label="PSK for $con_name"
    psk="$(prompt_psk_if_needed "$psk_label" "$con_name" "${psk:-}")"
    upsert_wifi "$con_name" "$ssid" "$psk"
    append_managed_wifi_name "$con_name"
    append_auto_wifi_profile "$con_name" "$ssid" "$aliases"
  done < <(wifi_profile_lines)
}

connection_name_is_managed() {
  local wanted="$1"
  local name

  while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    [ "$wanted" = "$name" ] && return 0
  done <<< "$MANAGED_WIFI_NAMES"
  return 1
}

disable_other_wifi_autoconnect() {
  local name uuid type

  [ "$DISABLE_OTHER_WIFI_AUTOCONNECT" = "yes" ] || return 0

  while IFS=: read -r name uuid type; do
    [ "$type" = "802-11-wireless" ] || [ "$type" = "wifi" ] || continue
    connection_name_is_managed "$name" && continue
    nmcli connection modify "$uuid" connection.autoconnect no >/dev/null 2>&1 || true
  done < <(nmcli -t -f NAME,UUID,TYPE connection show)
}

init_rollback_state() {
  install -d -m 0700 "$STATE_DIR"
}

save_hostname_before_change() {
  local current

  [ -f "$HOSTNAME_STATE_FILE" ] && return 0
  current="$(hostnamectl --static 2>/dev/null || hostname)"
  [ -n "$current" ] || return 0
  printf '%s\n' "$current" > "$HOSTNAME_STATE_FILE"
  chmod 0600 "$HOSTNAME_STATE_FILE"
}

save_wifi_autoconnect_before_change() {
  local tmp uuid type autoconnect

  [ -f "$AUTOCONNECT_STATE_FILE" ] && return 0
  tmp="$(mktemp "$STATE_DIR/wifi-autoconnect.before.XXXXXX")"
  while IFS=: read -r uuid type autoconnect; do
    [ "$type" = "802-11-wireless" ] || [ "$type" = "wifi" ] || continue
    [ -n "$uuid" ] || continue
    printf '%s\t%s\n' "$uuid" "$autoconnect" >> "$tmp"
  done < <(nmcli -t -f UUID,TYPE,AUTOCONNECT connection show)
  install -m 0600 "$tmp" "$AUTOCONNECT_STATE_FILE"
  rm -f "$tmp"
}

backup_avahi_before_change() {
  local conf="/etc/avahi/avahi-daemon.conf"

  [ "$CONFIGURE_AVAHI_WIFI_ONLY" = "yes" ] || return 0
  [ -f "$conf" ] || return 0
  [ -f "$AVAHI_BACKUP_FILE" ] && return 0
  cp -p "$conf" "$AVAHI_BACKUP_FILE"
  chmod 0600 "$AVAHI_BACKUP_FILE"
}

save_service_enabled_before_change() {
  local service="$1"
  local state_file="$2"
  local state

  [ -f "$state_file" ] && return 0
  systemctl list-unit-files "$service" >/dev/null 2>&1 || return 0
  state="$(systemctl is-enabled "$service" 2>/dev/null || true)"
  case "$state" in
    enabled|enabled-runtime|linked|linked-runtime|alias)
      printf 'yes\n' > "$state_file"
      ;;
    *)
      printf 'no\n' > "$state_file"
      ;;
  esac
  chmod 0600 "$state_file"
}

save_rollback_state() {
  init_rollback_state
  save_hostname_before_change
  save_wifi_autoconnect_before_change
  backup_avahi_before_change
  save_service_enabled_before_change avahi-daemon.service "$AVAHI_SERVICE_STATE_FILE"
  save_service_enabled_before_change nxserver.service "$NXSERVER_SERVICE_STATE_FILE"
}

install_auto_wifi_service() {
  local source_script="$SCRIPT_DIR/orin-auto-wifi.sh"
  local installed_script="/usr/local/sbin/orin-auto-wifi"
  local config_file="/etc/orin-auto-wifi.conf"
  local service_file="/etc/systemd/system/orin-auto-wifi.service"

  [ "$INSTALL_AUTO_WIFI" = "yes" ] || return 0
  [ -f "$source_script" ] || {
    printf 'Skipping auto WiFi service: %s not found.\n' "$source_script" >&2
    return 0
  }

  install -m 0755 "$source_script" "$installed_script"

  {
    printf 'WIFI_PROFILES=%s\n' "$(shell_quote "$AUTO_WIFI_PROFILES")"
    printf 'IOTSWARM_CON=%s\n' "$(shell_quote "$IOTSWARM_CON")"
    printf 'IOTSWARM_SSID=%s\n' "$(shell_quote "$IOTSWARM_SSID")"
    printf 'IOTLAB_CON=%s\n' "$(shell_quote "$IOTLAB_CON")"
    printf 'IOTLAB_SSID=%s\n' "$(shell_quote "$IOTLAB_SSID")"
    printf 'TARGET_FILE=%s\n' "$(shell_quote "$TARGET_FILE")"
    printf 'ORIN_WIFI_STATE_DIR=%s\n' "$(shell_quote "$STATE_DIR")"
    printf 'ORIN_AUTOWIFI_ATTEMPTS=18\n'
    printf 'ORIN_AUTOWIFI_INTERVAL=5\n'
    printf 'LOCK_SELECTED_WIFI=yes\n'
    printf 'DISABLE_UNMANAGED_WIFI_AUTOCONNECT=yes\n'
  } > "$config_file"
  chmod 0644 "$config_file"

  cat > "$service_file" <<'EOF'
[Unit]
Description=Choose the best configured lab WiFi for the headless Orin
Wants=NetworkManager.service
After=NetworkManager.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/orin-auto-wifi
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable orin-auto-wifi.service >/dev/null
}

install_switch_wifi_script() {
  local source_script="$SCRIPT_DIR/orin-switch-wifi.sh"
  local installed_script="/usr/local/sbin/orin-switch-wifi"

  [ -f "$source_script" ] || return 0
  install -m 0755 "$source_script" "$installed_script"
}

install_cleanup_script() {
  local source_script="$SCRIPT_DIR/orin-cleanup.sh"
  local installed_script="/usr/local/sbin/orin-wifi-cleanup"

  [ -f "$source_script" ] || {
    printf 'Skipping cleanup command: %s not found.\n' "$source_script" >&2
    return 0
  }
  install -m 0755 "$source_script" "$installed_script"
}

init_wifi_target_file() {
  [ -f "$TARGET_FILE" ] && return 0
  printf '%s\n' "$ORIN_WIFI_TARGET" > "$TARGET_FILE"
  chmod 0644 "$TARGET_FILE"
}

main() {
  case "${1:-}" in
    -h|--help|help)
      usage
      exit 0
      ;;
  esac

  [ "${EUID:-$(id -u)}" -eq 0 ] || die "run this on the Orin with sudo"
  command -v nmcli >/dev/null 2>&1 || die "nmcli is required"

  if [ "$CONFIGURE_AVAHI_WIFI_ONLY" = "yes" ]; then
    AVAHI_ALLOW_INTERFACES="$(resolve_avahi_allow_interfaces)"
  fi

  save_rollback_state
  hostnamectl set-hostname "$ORIN_HOSTNAME" 2>/dev/null || true
  configure_wifi_profiles
  disable_other_wifi_autoconnect

  enable_service_if_present avahi-daemon.service
  configure_avahi_wifi_only
  enable_service_if_present nxserver.service
  install_auto_wifi_service
  install_switch_wifi_script
  install_cleanup_script
  init_wifi_target_file

  nmcli device wifi rescan >/dev/null 2>&1 || true

  printf 'Configured hostname: %s\n' "$ORIN_HOSTNAME"
  printf 'Avahi interfaces: %s\n' "$AVAHI_ALLOW_INTERFACES"
  printf 'Configured WiFi profiles:\n'
  printf '%s\n' "$MANAGED_WIFI_NAMES" | sed 's/^/  /'
  if [ "$INSTALL_AUTO_WIFI" = "yes" ]; then
    printf '\nInstalled boot service: orin-auto-wifi.service\n'
    printf 'WiFi boot target: %s\n' "$(head -n 1 "$TARGET_FILE" 2>/dev/null || printf 'auto')"
  fi
  if [ -x /usr/local/sbin/orin-wifi-cleanup ]; then
    printf 'To remove this setup later, run: sudo orin-wifi-cleanup\n'
  fi
  printf '\nAfter reboot, the Orin follows /etc/orin-wifi-target.\n'
  printf 'From the laptop, try: ping %s.local\n' "$ORIN_HOSTNAME"
}

main "$@"
