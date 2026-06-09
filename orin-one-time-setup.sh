#!/usr/bin/env bash
set -euo pipefail

# Run this script once on the Orin, not on the laptop.
# It creates/updates two NetworkManager WiFi profiles so the headless Orin can
# join either lab WiFi after boot.

ORIN_HOSTNAME="${ORIN_HOSTNAME:-onboard-nx}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IOTSWARM_CON="${IOTSWARM_CON:-iotswarm_5G}"
IOTSWARM_SSID="${IOTSWARM_SSID:-iotswarm_5G}"
IOTSWARM_PSK="${IOTSWARM_PSK:-}"
IOTLAB_CON="${IOTLAB_CON:-IoTLab_5G}"
IOTLAB_SSID="${IOTLAB_SSID:-IoTLab_5G}"
IOTLAB_PSK="${IOTLAB_PSK:-}"
PRIORITY="${WIFI_AUTOCONNECT_PRIORITY:-100}"
WIFI_ROUTE_METRIC="${WIFI_ROUTE_METRIC:-100}"
TARGET_FILE="${ORIN_WIFI_TARGET_FILE:-/etc/orin-wifi-target}"
ORIN_WIFI_TARGET="${ORIN_WIFI_TARGET:-auto}"
CONFIGURE_AVAHI_WIFI_ONLY="${CONFIGURE_AVAHI_WIFI_ONLY:-yes}"
AVAHI_ALLOW_INTERFACES="${AVAHI_ALLOW_INTERFACES:-wlan0}"
INSTALL_AUTO_WIFI="${INSTALL_AUTO_WIFI:-yes}"
DISABLE_OTHER_WIFI_AUTOCONNECT="${DISABLE_OTHER_WIFI_AUTOCONNECT:-yes}"

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
  INSTALL_AUTO_WIFI=yes
  DISABLE_OTHER_WIFI_AUTOCONNECT=yes

Example:
  sudo env IOTSWARM_SSID='iotswarm(5g)' IOTSWARM_PSK='xxx' \
    IOTLAB_SSID='IoTLab(5g)' IOTLAB_PSK='yyy' \
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

configure_avahi_wifi_only() {
  local conf="/etc/avahi/avahi-daemon.conf"
  local tmp

  [ "$CONFIGURE_AVAHI_WIFI_ONLY" = "yes" ] || return 0
  [ -f "$conf" ] || return 0

  cp -n "$conf" "$conf.bak" 2>/dev/null || true
  tmp="$(mktemp)"
  awk -v allow="$AVAHI_ALLOW_INTERFACES" '
    BEGIN { in_server = 0; wrote = 0 }
    /^\[server\][[:space:]]*$/ { in_server = 1; print; next }
    /^\[/ {
      if (in_server && !wrote) {
        print "allow-interfaces=" allow
        wrote = 1
      }
      in_server = 0
    }
    in_server && /^[#[:space:]]*allow-interfaces=/ {
      if (!wrote) {
        print "allow-interfaces=" allow
        wrote = 1
      }
      next
    }
    { print }
    END {
      if (in_server && !wrote) {
        print "allow-interfaces=" allow
      }
    }
  ' "$conf" > "$tmp"
  install -m 0644 "$tmp" "$conf"
  rm -f "$tmp"
  systemctl restart avahi-daemon.service >/dev/null 2>&1 || true
}

shell_quote() {
  printf '%q' "$1"
}

disable_other_wifi_autoconnect() {
  local keep_a="$1"
  local keep_b="$2"
  local name uuid type

  [ "$DISABLE_OTHER_WIFI_AUTOCONNECT" = "yes" ] || return 0

  while IFS=: read -r name uuid type; do
    [ "$type" = "802-11-wireless" ] || [ "$type" = "wifi" ] || continue
    [ "$name" = "$keep_a" ] && continue
    [ "$name" = "$keep_b" ] && continue
    nmcli connection modify "$uuid" connection.autoconnect no >/dev/null 2>&1 || true
  done < <(nmcli -t -f NAME,UUID,TYPE connection show)
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
    printf 'IOTSWARM_CON=%s\n' "$(shell_quote "$IOTSWARM_CON")"
    printf 'IOTSWARM_SSID=%s\n' "$(shell_quote "$IOTSWARM_SSID")"
    printf 'IOTLAB_CON=%s\n' "$(shell_quote "$IOTLAB_CON")"
    printf 'IOTLAB_SSID=%s\n' "$(shell_quote "$IOTLAB_SSID")"
    printf 'TARGET_FILE=%s\n' "$(shell_quote "$TARGET_FILE")"
    printf 'ORIN_AUTOWIFI_ATTEMPTS=18\n'
    printf 'ORIN_AUTOWIFI_INTERVAL=5\n'
    printf 'LOCK_SELECTED_WIFI=yes\n'
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

  IOTSWARM_PSK="$(prompt_psk_if_needed IOTSWARM_PSK "$IOTSWARM_CON" "$IOTSWARM_PSK")"
  IOTLAB_PSK="$(prompt_psk_if_needed IOTLAB_PSK "$IOTLAB_CON" "$IOTLAB_PSK")"

  hostnamectl set-hostname "$ORIN_HOSTNAME" 2>/dev/null || true
  upsert_wifi "$IOTSWARM_CON" "$IOTSWARM_SSID" "$IOTSWARM_PSK"
  upsert_wifi "$IOTLAB_CON" "$IOTLAB_SSID" "$IOTLAB_PSK"
  disable_other_wifi_autoconnect "$IOTSWARM_CON" "$IOTLAB_CON"

  enable_service_if_present avahi-daemon.service
  configure_avahi_wifi_only
  enable_service_if_present nxserver.service
  install_auto_wifi_service
  install_switch_wifi_script
  init_wifi_target_file

  nmcli device wifi rescan >/dev/null 2>&1 || true

  printf 'Configured hostname: %s\n' "$ORIN_HOSTNAME"
  printf 'Avahi interfaces: %s\n' "$AVAHI_ALLOW_INTERFACES"
  printf 'Configured WiFi profiles:\n'
  nmcli -f NAME,UUID,TYPE,AUTOCONNECT,AUTOCONNECT-PRIORITY connection show | awk -v a="$IOTSWARM_CON" -v b="$IOTLAB_CON" 'NR == 1 || $1 == a || $1 == b'
  if [ "$INSTALL_AUTO_WIFI" = "yes" ]; then
    printf '\nInstalled boot service: orin-auto-wifi.service\n'
    printf 'WiFi boot target: %s\n' "$(head -n 1 "$TARGET_FILE" 2>/dev/null || printf 'auto')"
  fi
  printf '\nAfter reboot, the Orin follows /etc/orin-wifi-target.\n'
  printf 'From the laptop, try: ping %s.local\n' "$ORIN_HOSTNAME"
}

main "$@"
