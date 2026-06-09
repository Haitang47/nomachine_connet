#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${NOMACHINE_WIFI_CONFIG:-$SCRIPT_DIR/nomachine-wifi.conf}"
NXPLAYER="${NXPLAYER:-/usr/NX/bin/nxplayer}"
NX_PORT="${NOMACHINE_PORT:-4000}"
OPEN_TIMEOUT="${NOMACHINE_OPEN_TIMEOUT:-1}"
GENERATED_DIR="$SCRIPT_DIR/generated"
LOG_DIR="$SCRIPT_DIR/logs"

CURRENT_CONN=""
CURRENT_DEV=""
CURRENT_SSID=""
CURRENT_IP=""

usage() {
  cat <<'EOF'
Usage:
  ./nomachine-wifi.sh status
  ./nomachine-wifi.sh list
  ./nomachine-wifi.sh probe [profile]
  ./nomachine-wifi.sh connect [profile]
  ./nomachine-wifi.sh scan [192.168.230]

Examples:
  ./nomachine-wifi.sh connect
  ./nomachine-wifi.sh connect iotswarm
  ./nomachine-wifi.sh probe iotlab
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

trim() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

require_runtime() {
  command -v nmcli >/dev/null 2>&1 || die "nmcli is required"
  command -v timeout >/dev/null 2>&1 || die "timeout is required"
  [ -x "$NXPLAYER" ] || die "NoMachine player not found at $NXPLAYER"
  [ -f "$CONFIG_FILE" ] || die "config file not found: $CONFIG_FILE"
}

config_lines() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [ -z "$line" ] && continue
    printf '%s\n' "$line"
  done < "$CONFIG_FILE"
}

collect_context() {
  CURRENT_CONN="$(nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1; exit}')"
  CURRENT_DEV="$(nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $3; exit}')"

  if [ -n "$CURRENT_CONN" ]; then
    CURRENT_SSID="$(nmcli -g 802-11-wireless.ssid connection show "$CURRENT_CONN" 2>/dev/null | head -n 1 || true)"
  fi
  if [ -z "$CURRENT_SSID" ]; then
    CURRENT_SSID="$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}')"
  fi
  if [ -n "$CURRENT_DEV" ]; then
    CURRENT_IP="$(ip -o -4 addr show dev "$CURRENT_DEV" scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}')"
  fi
}

ip_matches_subnet() {
  local ip="$1"
  local subnet="$2"

  case "$subnet" in
    *".0/24")
      local prefix="${subnet%.0/24}."
      [ "${ip#"$prefix"}" != "$ip" ]
      ;;
    *".0.0/16")
      local prefix="${subnet%.0.0/16}."
      [ "${ip#"$prefix"}" != "$ip" ]
      ;;
    *)
      [ "$ip" = "$subnet" ]
      ;;
  esac
}

profile_matches_current() {
  local matches="$1"
  local term key value
  local old_ifs="$IFS"

  IFS=';'
  for term in $matches; do
    IFS="$old_ifs"
    term="$(trim "$term")"
    [ -z "$term" ] && continue
    key="$(trim "${term%%=*}")"
    value="$(trim "${term#*=}")"

    case "$key" in
      connection)
        [ -n "$CURRENT_CONN" ] && [ "$CURRENT_CONN" = "$value" ] && return 0
        ;;
      ssid)
        [ -n "$CURRENT_SSID" ] && [ "$CURRENT_SSID" = "$value" ] && return 0
        ;;
      subnet)
        [ -n "$CURRENT_IP" ] && ip_matches_subnet "$CURRENT_IP" "$value" && return 0
        ;;
      prefix)
        [ -n "$CURRENT_IP" ] && [ "${CURRENT_IP#"$value"}" != "$CURRENT_IP" ] && return 0
        ;;
      *)
        ;;
    esac
    IFS=';'
  done
  IFS="$old_ifs"
  return 1
}

find_profile_line() {
  local wanted="${1:-}"
  local line name matches hosts template

  collect_context
  while IFS= read -r line; do
    IFS='|' read -r name matches hosts template _ <<< "$line"
    name="$(trim "$name")"
    matches="$(trim "$matches")"
    if [ -n "$wanted" ]; then
      [ "$name" = "$wanted" ] && printf '%s\n' "$line" && return 0
    elif profile_matches_current "$matches"; then
      printf '%s\n' "$line"
      return 0
    fi
  done < <(config_lines)

  if [ -n "$wanted" ]; then
    return 1
  fi
  return 2
}

host_port_open() {
  local host="$1"
  local port="$2"
  timeout "$OPEN_TIMEOUT" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" >/dev/null 2>&1
}

choose_host() {
  local hosts="$1"
  local host
  hosts="${hosts//,/ }"
  for host in $hosts; do
    if host_port_open "$host" "$NX_PORT"; then
      printf '%s\n' "$host"
      return 0
    fi
  done
  return 1
}

sed_replacement_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//&/\\&}"
  s="${s//#/\\#}"
  printf '%s' "$s"
}

write_minimal_session() {
  local host="$1"
  local outfile="$2"

  cat > "$outfile" <<EOF
<!DOCTYPE NXClientSettings>
<NXClientSettings version="2.3" application="nxclient" >
 <group name="General" >
  <option key="Connection service" value="nx" />
  <option key="NoMachine daemon port" value="$NX_PORT" />
  <option key="Server host" value="$host" />
  <option key="Server port" value="22" />
  <option key="Server product" value="NoMachine" />
  <option key="Remember username" value="true" />
  <option key="Remember password" value="false" />
 </group>
 <group name="Login" >
  <option key="Server authentication method" value="system" />
  <option key="Auth" value="EMPTY_PASSWORD" />
  <option key="User" value="" />
  <option key="NX login method" value="password" />
  <option key="System login method" value="password" />
 </group>
</NXClientSettings>
EOF
}

make_session_file() {
  local profile="$1"
  local host="$2"
  local template="$3"
  local outfile="$GENERATED_DIR/$profile.nxs"
  local host_repl port_repl

  mkdir -p "$GENERATED_DIR"
  if [ -f "$template" ]; then
    host_repl="$(sed_replacement_escape "$host")"
    port_repl="$(sed_replacement_escape "$NX_PORT")"
    sed -E \
      -e "s#(<option key=\"Server host\" value=\")[^\"]*(\" />)#\1$host_repl\2#" \
      -e "s#(<option key=\"NoMachine daemon port\" value=\")[^\"]*(\" />)#\1$port_repl\2#" \
      "$template" > "$outfile.tmp"
    mv "$outfile.tmp" "$outfile"
  else
    write_minimal_session "$host" "$outfile.tmp"
    mv "$outfile.tmp" "$outfile"
  fi

  printf '%s\n' "$outfile"
}

print_status() {
  collect_context
  printf 'WiFi connection: %s\n' "${CURRENT_CONN:-unknown}"
  printf 'WiFi SSID:       %s\n' "${CURRENT_SSID:-unknown}"
  printf 'WiFi device:     %s\n' "${CURRENT_DEV:-unknown}"
  printf 'WiFi IPv4:       %s\n' "${CURRENT_IP:-unknown}"

  local line name matches hosts template
  if line="$(find_profile_line "" 2>/dev/null)"; then
    IFS='|' read -r name matches hosts template _ <<< "$line"
    printf 'Matched profile: %s\n' "$(trim "$name")"
  else
    printf 'Matched profile: none\n'
  fi
}

list_profiles() {
  local line name matches hosts template
  printf '%-12s %-45s %s\n' "PROFILE" "MATCH" "HOSTS"
  while IFS= read -r line; do
    IFS='|' read -r name matches hosts template _ <<< "$line"
    printf '%-12s %-45s %s\n' "$(trim "$name")" "$(trim "$matches")" "$(trim "$hosts")"
  done < <(config_lines)
}

probe_profile() {
  local requested="${1:-}"
  local line name matches hosts template host state

  line="$(find_profile_line "$requested")" || {
    if [ -n "$requested" ]; then
      die "profile not found: $requested"
    fi
    die "current WiFi did not match any profile; edit $CONFIG_FILE or pass a profile"
  }

  IFS='|' read -r name matches hosts template _ <<< "$line"
  name="$(trim "$name")"
  hosts="$(trim "$hosts")"

  printf 'Profile: %s\n' "$name"
  for host in ${hosts//,/ }; do
    if host_port_open "$host" "$NX_PORT"; then
      state="open"
    else
      state="closed"
    fi
    printf '%-24s %s:%s %s\n' "$host" "$host" "$NX_PORT" "$state"
  done
}

connect_profile() {
  local requested="${1:-}"
  local line name matches hosts template host session_file

  line="$(find_profile_line "$requested")" || {
    if [ -n "$requested" ]; then
      die "profile not found: $requested"
    fi
    die "current WiFi did not match any profile; run ./nomachine-wifi.sh status"
  }

  IFS='|' read -r name matches hosts template _ <<< "$line"
  name="$(trim "$name")"
  hosts="$(trim "$hosts")"
  template="$(trim "$template")"

  host="$(choose_host "$hosts")" || die "no configured host has TCP $NX_PORT open for profile $name"
  session_file="$(make_session_file "$name" "$host" "$template")"

  mkdir -p "$LOG_DIR"
  printf 'Using profile: %s\n' "$name"
  printf 'Using host:    %s\n' "$host"
  printf 'Session file:  %s\n' "$session_file"
  printf 'Starting NoMachine...\n'
  nohup "$NXPLAYER" --session "$session_file" --exit > "$LOG_DIR/nxplayer-$name.log" 2>&1 &
  printf 'NoMachine pid: %s\n' "$!"
}

scan_prefix() {
  local prefix="${1:-}"
  local self_ip

  collect_context
  self_ip="$CURRENT_IP"
  if [ -z "$prefix" ]; then
    [ -n "$CURRENT_IP" ] || die "cannot infer current subnet"
    prefix="${CURRENT_IP%.*}"
  fi

  printf 'Scanning %s.1-254 for TCP %s...\n' "$prefix" "$NX_PORT"
  seq 1 254 | xargs -I{} -P 64 bash -c '
    host="$1.$2"
    if timeout "$3" bash -c '"'"'exec 3<>"/dev/tcp/$1/$2"'"'"' _ "$host" "$4" >/dev/null 2>&1; then
      if [ "$host" = "$5" ]; then
        printf "%s (this computer)\n" "$host"
      else
        printf "%s\n" "$host"
      fi
    fi
  ' _ "$prefix" "{}" "$OPEN_TIMEOUT" "$NX_PORT" "$self_ip"
}

main() {
  local cmd="${1:-connect}"
  case "$cmd" in
    -h|--help|help)
      usage
      ;;
    status)
      require_runtime
      print_status
      ;;
    list)
      require_runtime
      list_profiles
      ;;
    probe)
      require_runtime
      probe_profile "${2:-}"
      ;;
    connect)
      require_runtime
      connect_profile "${2:-}"
      ;;
    scan)
      require_runtime
      scan_prefix "${2:-}"
      ;;
    *)
      require_runtime
      connect_profile "$cmd"
      ;;
  esac
}

main "$@"
