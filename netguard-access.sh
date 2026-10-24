#!/usr/bin/env bash
set -Eeuo pipefail

readonly PHYSICAL_IF="eth0"
readonly VPN_IF="tun2"

usage() {
  cat <<'USAGE'
Temporary, destination-specific exceptions for Netguard restricted mode (IPv4 only)

  netguard-access list
  netguard-access enable ssh <destination-ip> <vpn|direct>
  netguard-access disable ssh <destination-ip> <vpn|direct>
  netguard-access enable remmina <destination-ip> <rdp|vnc> <vpn|direct>
  netguard-access disable remmina <destination-ip> <rdp|vnc> <vpn|direct>
  netguard-access enable remmina <destination-ip> custom <port> <tcp|udp> <vpn|direct>
  netguard-access disable remmina <destination-ip> custom <port> <tcp|udp> <vpn|direct>
  netguard-access enable inbound-ssh <source-ip>
  netguard-access disable inbound-ssh <source-ip>
  netguard-access clear

'vpn' means the rule only matches tun2. 'direct' matches eth0 and may bypass VPN.
Rules are runtime-only and disappear when Netguard mode/LAN profile changes or on reboot.
For general trusted-LAN permissions, use 'sudo netguard lan on ssh|ssh-remmina'.
USAGE
}

if [[ ${EUID} -ne 0 ]]; then echo "Run with sudo." >&2; exit 1; fi
command -v nft >/dev/null || { echo "nft is required." >&2; exit 1; }
nft list table inet killswitch >/dev/null 2>&1 || { echo "Netguard firewall is not loaded." >&2; exit 1; }

check_ip() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    parsed = ipaddress.ip_address(sys.argv[1])
    if parsed.version != 4:
        raise ValueError("IPv4 only")
except ValueError:
    print("Enter a valid IPv4 address, not a hostname.", file=sys.stderr)
    sys.exit(1)
PY
}
get_mode() {
  nft list table inet killswitch | sed -n 's/.*comment "netguard:\([^"]*\)".*/\1/p' | head -n1
}
require_restricted() {
  local mode
  mode="$(get_mode)"
  if [[ "$mode" != restricted && "$mode" != current && "$mode" != strict ]]; then
    echo "Temporary exceptions can only be added in restricted mode (active mode: ${mode:-unknown})." >&2
    echo "Run: sudo netguard restricted" >&2
    exit 1
  fi
}
list_rules() {
  local found=0 chain lines
  for chain in output input; do
    lines="$(nft -a list chain inet killswitch "$chain" | grep 'comment "ngaccess:' || true)"
    if [[ -n "$lines" ]]; then printf '%s\n' "$lines"; found=1; fi
  done
  [[ $found -eq 1 ]] || echo "No temporary SSH/Remmina exceptions are active."
}
remove_matching() {
  local prefix="$1" chain line handle
  for chain in output input; do
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      handle="$(sed -n 's/.* handle \([0-9][0-9]*\).*/\1/p' <<<"$line")"
      [[ -n "$handle" ]] || continue
      nft delete rule inet killswitch "$chain" handle "$handle"
    done < <(nft -a list chain inet killswitch "$chain" | grep -F "comment \"${prefix}" || true)
  done
}
add_out_rule() {
  nft insert rule inet killswitch output oifname "$1" ip daddr "$2" "$3" dport "$4" counter accept comment "$5"
}

action="${1:-}"
[[ -n "$action" ]] || { usage; exit 2; }
case "$action" in
  list)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    list_rules
    ;;
  clear)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    remove_matching 'ngaccess:'
    echo "All temporary Netguard access exceptions removed."
    ;;
  enable|disable)
    [[ $# -ge 3 ]] || { usage >&2; exit 2; }
    target_kind="$2"
    if [[ "$target_kind" == inbound-ssh ]]; then
      [[ $# -eq 3 ]] || { usage >&2; exit 2; }
      ip="$3"; check_ip "$ip"
      if [[ "$action" == enable ]]; then
        require_restricted
        tag="ngaccess:inbound-ssh:${ip}:tcp22"
        remove_matching "$tag"
        nft insert rule inet killswitch input iifname "$PHYSICAL_IF" ip saddr "$ip" tcp dport 22 ct state new counter accept comment "$tag"
        echo "Inbound SSH permitted from $ip on $PHYSICAL_IF until mode change/reboot."
      else
        remove_matching "ngaccess:inbound-ssh:${ip}:"
        echo "Inbound SSH exception removed for $ip."
      fi
    elif [[ "$target_kind" == ssh ]]; then
      [[ $# -eq 4 ]] || { usage >&2; exit 2; }
      ip="$3"; route="$4"; check_ip "$ip"
      case "$route" in vpn) iface="$VPN_IF";; direct) iface="$PHYSICAL_IF";; *) usage >&2; exit 2;; esac
      tag="ngaccess:ssh:${route}:${ip}:tcp22"
      if [[ "$action" == enable ]]; then
        require_restricted; remove_matching "$tag"; add_out_rule "$iface" "$ip" tcp 22 "$tag"
        echo "Outbound SSH permitted to $ip via $route until mode change/reboot."
      else
        remove_matching "$tag"; echo "Outbound SSH exception removed for $ip via $route."
      fi
    elif [[ "$target_kind" == remmina ]]; then
      [[ $# -ge 5 ]] || { usage >&2; exit 2; }
      ip="$3"; proto="$4"
      if [[ "$proto" == custom ]]; then
        [[ $# -eq 7 ]] || { usage >&2; exit 2; }
        port="$5"; transport="$6"; route="$7"
        [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { echo "Invalid port: $port" >&2; exit 2; }
        [[ "$transport" == tcp || "$transport" == udp ]] || { usage >&2; exit 2; }
        specs=("${transport}:${port}")
      else
        [[ $# -eq 5 ]] || { usage >&2; exit 2; }
        route="$5"
        case "$proto" in rdp) specs=("tcp:3389" "udp:3389");; vnc) specs=("tcp:5900-5999");; *) usage >&2; exit 2;; esac
      fi
      check_ip "$ip"
      case "$route" in vpn) iface="$VPN_IF";; direct) iface="$PHYSICAL_IF";; *) usage >&2; exit 2;; esac
      tagbase="ngaccess:remmina:${proto}:${route}:${ip}:"
      if [[ "$action" == enable ]]; then
        require_restricted; remove_matching "$tagbase"
        for spec in "${specs[@]}"; do
          transport="${spec%%:*}"; port_expr="${spec#*:}"
          add_out_rule "$iface" "$ip" "$transport" "$port_expr" "${tagbase}${spec}"
        done
        echo "Remmina $proto permitted to $ip via $route until mode change/reboot."
      else
        remove_matching "$tagbase"; echo "Remmina $proto exception removed for $ip via $route."
      fi
    else
      usage >&2; exit 2
    fi
    ;;
  *) usage >&2; exit 2;;
esac
