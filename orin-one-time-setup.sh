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
INSTALL_AUTO_WIFI="${INSTALL_AUTO_WIFI:-yes}"

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
  nmcli -t -f NAME connection show "$1" >/dev/null 2>&1
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

  if connection_exists "$con_name"; then
    nmcli connection modify "$con_name" 802-11-wireless.ssid "$ssid"
  else
    nmcli connection add type wifi ifname "*" con-name "$con_name" ssid "$ssid"
  fi

  nmcli connection modify "$con_name" \
    connection.autoconnect yes \
    connection.autoconnect-priority "$PRIORITY" \
    connection.autoconnect-retries 0 \
    ipv4.method auto \
    ipv6.method auto \
    802-11-wireless.mode infrastructure

  if [ -n "$psk" ]; then
    nmcli connection modify "$con_name" \
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

shell_quote() {
  printf '%q' "$1"
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
    printf 'ORIN_AUTOWIFI_ATTEMPTS=18\n'
    printf 'ORIN_AUTOWIFI_INTERVAL=5\n'
  } > "$config_file"
  chmod 0644 "$config_file"

  cat > "$service_file" <<'EOF'
[Unit]
Description=Choose the best configured lab WiFi for the headless Orin
Wants=NetworkManager.service
After=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/orin-auto-wifi

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable orin-auto-wifi.service >/dev/null
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

  enable_service_if_present avahi-daemon.service
  enable_service_if_present nxserver.service
  install_auto_wifi_service

  nmcli device wifi rescan >/dev/null 2>&1 || true

  printf 'Configured hostname: %s\n' "$ORIN_HOSTNAME"
  printf 'Configured WiFi profiles:\n'
  nmcli -f NAME,TYPE,AUTOCONNECT,AUTOCONNECT-PRIORITY connection show "$IOTSWARM_CON" "$IOTLAB_CON"
  if [ "$INSTALL_AUTO_WIFI" = "yes" ]; then
    printf '\nInstalled boot service: orin-auto-wifi.service\n'
    printf 'It will choose the strongest visible configured WiFi after reboot.\n'
  fi
  printf '\nAfter reboot, the Orin should auto-connect to either known WiFi if it is visible.\n'
  printf 'From the laptop, try: ping %s.local\n' "$ORIN_HOSTNAME"
}

main "$@"
