#!/usr/bin/env bash
set -Eeuo pipefail

readonly TABLE_FAMILY="inet"
readonly TABLE_NAME="killswitch"
readonly PHYSICAL_IF="eth0"
readonly VPN_IF="tun2"
readonly VPN_IP="142.4.216.196"
readonly VPN_PORT="25000"
readonly LAN_CIDR="192.168.100.0/24"
readonly LAN_CONFIG="/etc/netguard/lan-access"
readonly BOOT_CONFIG="/etc/nftables.conf"

usage() {
  cat <<'USAGE'
Netguard: default-deny nftables firewall

Modes (change the live firewall):
  netguard lockdown          Block application/internet traffic; selected LAN rules may remain.
  netguard restricted        Allow Tor daemon TCP + configured VPN endpoint; block normal apps.
  netguard vpn               Allow applications through tun2; block direct internet egress.
  netguard tor-only          Allow Tor daemon TCP directly through eth0; OpenVPN routes must be down.
  netguard status            Show firewall mode, LAN profile, interfaces and routes.

Compatibility aliases:
  off -> lockdown; current/strict -> restricted; tor -> tor-only; openvpn -> vpn

LAN management (persistent across mode changes and reboots; default is off):
  netguard lan status
  netguard lan off
  netguard lan on ssh            Allow LAN SSH in/out on TCP 22.
  netguard lan on ssh-remmina    Also allow outbound RDP (3389 TCP/UDP) and VNC (5900-5999 TCP).

The LAN profile is limited to 192.168.100.0/24 on eth0. SSH inbound is only
permitted from that subnet. Remmina is a client, so RDP/VNC permissions are
outbound connections from this computer to LAN systems; no RDP/VNC server is
opened on this computer. 'lockdown' still permits DHCP and whatever LAN profile
you explicitly enable. Use 'restricted' as the boot default.

Destination-specific temporary exceptions are managed by netguard-access.
USAGE
}

tor_uid() {
  if getent passwd debian-tor >/dev/null; then
    getent passwd debian-tor | cut -d: -f3
  elif getent passwd tor >/dev/null; then
    getent passwd tor | cut -d: -f3
  else
    echo "Tor user not found (debian-tor or tor)." >&2
    return 1
  fi
}

read_lan_profile() {
  local profile="off"
  if [[ -r "$LAN_CONFIG" ]]; then
    profile="$(tr -d '[:space:]' < "$LAN_CONFIG")"
  fi
  case "$profile" in off|ssh|ssh-remmina) printf '%s' "$profile";;
    *) echo "Invalid LAN profile in $LAN_CONFIG: $profile" >&2; return 1;;
  esac
}

canonical_mode() {
  case "$1" in
    off|lockdown) printf 'lockdown';;
    current|strict|restricted) printf 'restricted';;
    tor|tor-only) printf 'tor-only';;
    vpn|openvpn) printf 'vpn';;
    *) echo "Unknown mode: $1" >&2; return 2;;
  esac
}

render_rules() {
  local mode tuid="" lan_profile
  mode="$(canonical_mode "$1")"
  lan_profile="$(read_lan_profile)"
  if [[ "$mode" == restricted || "$mode" == tor-only ]]; then
    tuid="$(tor_uid)"
  fi

  printf 'destroy table inet killswitch\n'
  printf 'table inet killswitch {\n    comment "netguard:%s";\n' "$mode"
  cat <<'NFT'
    chain input {
        type filter hook input priority filter; policy drop;
        iifname "lo" accept
NFT
  if [[ "$mode" != lockdown ]]; then
    cat <<'NFT'
        ct state established,related accept
NFT
  elif [[ "$lan_profile" != off ]]; then
    # In lockdown, retain only replies associated with selected management ports.
    printf '        iifname "%s" ip saddr %s ct state established meta l4proto tcp ct original proto-dst 22 accept\n' "$PHYSICAL_IF" "$LAN_CIDR"
    if [[ "$lan_profile" == ssh-remmina ]]; then
      printf '        iifname "%s" ip saddr %s ct state established meta l4proto tcp ct original proto-dst 3389 accept\n' "$PHYSICAL_IF" "$LAN_CIDR"
      printf '        iifname "%s" ip saddr %s ct state established meta l4proto udp ct original proto-dst 3389 accept\n' "$PHYSICAL_IF" "$LAN_CIDR"
      printf '        iifname "%s" ip saddr %s ct state established meta l4proto tcp ct original proto-dst 5900-5999 accept\n' "$PHYSICAL_IF" "$LAN_CIDR"
    fi
  fi
  # DHCP is local-link configuration traffic, not general internet access.
  printf '        iifname "%s" udp sport 67 udp dport 68 accept\n' "$PHYSICAL_IF"
  if [[ "$lan_profile" != off ]]; then
    # SSH server access INTO this machine, restricted to the trusted LAN.
    printf '        iifname "%s" ip saddr %s tcp dport 22 ct state new accept\n' "$PHYSICAL_IF" "$LAN_CIDR"
  fi
  cat <<'NFT'
        counter drop
    }

    chain output {
        type filter hook output priority filter; policy drop;
        oifname "lo" accept
NFT
  # DHCP is permitted in all modes so eth0 can obtain/renew its address.
  printf '        oifname "%s" udp sport 68 udp dport 67 accept\n' "$PHYSICAL_IF"

  if [[ "$lan_profile" != off ]]; then
    # Permit only selected management ports and their established replies.
    printf '        oifname "%s" ip daddr %s ct state established meta l4proto tcp ct original proto-dst 22 accept\n' "$PHYSICAL_IF" "$LAN_CIDR"
    printf '        oifname "%s" ip daddr %s tcp dport 22 accept\n' "$PHYSICAL_IF" "$LAN_CIDR"
    if [[ "$lan_profile" == ssh-remmina ]]; then
      printf '        oifname "%s" ip daddr %s ct state established meta l4proto tcp ct original proto-dst 3389 accept\n' "$PHYSICAL_IF" "$LAN_CIDR"
      printf '        oifname "%s" ip daddr %s ct state established meta l4proto udp ct original proto-dst 3389 accept\n' "$PHYSICAL_IF" "$LAN_CIDR"
      printf '        oifname "%s" ip daddr %s ct state established meta l4proto tcp ct original proto-dst 5900-5999 accept\n' "$PHYSICAL_IF" "$LAN_CIDR"
      printf '        oifname "%s" ip daddr %s tcp dport 3389 accept\n' "$PHYSICAL_IF" "$LAN_CIDR"
      printf '        oifname "%s" ip daddr %s udp dport 3389 accept\n' "$PHYSICAL_IF" "$LAN_CIDR"
      printf '        oifname "%s" ip daddr %s tcp dport 5900-5999 accept\n' "$PHYSICAL_IF" "$LAN_CIDR"
    fi
  fi

  if [[ "$mode" == restricted || "$mode" == vpn ]]; then
    printf '        oifname "%s" ip daddr %s udp dport %s accept\n' "$PHYSICAL_IF" "$VPN_IP" "$VPN_PORT"
  fi
  if [[ "$mode" == restricted ]]; then
    # If OpenVPN routes Tor over tun2, permit the Tor UID there too. This does
    # not permit ordinary users to use tun2 in restricted mode.
    printf '        meta skuid %s oifname "%s" meta l4proto tcp accept\n' "$tuid" "$PHYSICAL_IF"
    printf '        meta skuid %s oifname "%s" meta l4proto tcp accept\n' "$tuid" "$VPN_IF"
  elif [[ "$mode" == tor-only ]]; then
    printf '        meta skuid %s oifname "%s" meta l4proto tcp accept\n' "$tuid" "$PHYSICAL_IF"
  elif [[ "$mode" == vpn ]]; then
    printf '        oifname "%s" accept\n' "$VPN_IF"
  fi
  cat <<'NFT'
        counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }
}
NFT
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "Run this command with sudo." >&2
    exit 1
  fi
}

active_mode() {
  local mode=""
  mode="$(nft list table inet killswitch 2>/dev/null | sed -n 's/.*comment "netguard:\([^"]*\)".*/\1/p' | head -n1 || true)"
  if [[ -n "$mode" ]]; then
    canonical_mode "$mode"
  elif [[ -r /run/netguard-mode ]]; then
    canonical_mode "$(cat /run/netguard-mode)"
  else
    printf 'restricted'
  fi
}

apply_mode() {
  local mode="$1" tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  render_rules "$mode" > "$tmp"
  nft -c -f "$tmp"
  nft -f "$tmp"
  printf '%s\n' "$mode" > /run/netguard-mode
  echo "Netguard mode applied: $mode"
  case "$mode" in
    lockdown) echo "Internet/application traffic is blocked. DHCP and your selected LAN profile remain permitted.";;
    restricted) echo "Tor daemon TCP and the configured VPN endpoint are allowed; ordinary app traffic is blocked.";;
    tor-only) echo "Tor daemon TCP is allowed on eth0; OpenVPN routes must be disconnected.";;
    vpn) echo "Applications are allowed through tun2 only; direct physical internet egress remains blocked.";;
  esac
}

write_boot_config() {
  local tmp
  tmp="$(mktemp /etc/nftables.conf.netguard.XXXXXX)"
  render_rules restricted > "$tmp"
  nft -c -f "$tmp"
  install -o root -g root -m 0644 "$tmp" "$BOOT_CONFIG"
  rm -f "$tmp"
}

lan_command() {
  local requested="${1:-}" profile old_profile mode boot_tmp live_tmp
  case "$requested" in
    status)
      echo "LAN profile: $(read_lan_profile)"
      echo "Trusted LAN: $LAN_CIDR via $PHYSICAL_IF"
      echo "Active mode: $(active_mode)"
      ;;
    off)
      [[ $# -eq 1 ]] || { usage >&2; exit 2; }
      profile=off
      ;;
    on)
      [[ $# -eq 2 ]] || { echo "Usage: sudo netguard lan on ssh|ssh-remmina" >&2; exit 2; }
      profile="$2"
      case "$profile" in ssh|ssh-remmina) ;; *) echo "LAN profile must be: ssh or ssh-remmina" >&2; exit 2;; esac
      ;;
    ssh|ssh-remmina)
      [[ $# -eq 1 ]] || { usage >&2; exit 2; }
      profile="$requested"
      ;;
    *) usage >&2; exit 2;;
  esac
  [[ "$requested" == status ]] && return 0

  [[ -f "$LAN_CONFIG" ]] && old_profile="$(cat "$LAN_CONFIG")" || old_profile=off
  mode="$(active_mode)"
  printf '%s\n' "$profile" > "$LAN_CONFIG"
  chmod 0600 "$LAN_CONFIG"
  boot_tmp="$(mktemp /etc/nftables.conf.netguard.XXXXXX)"
  live_tmp="$(mktemp)"
  if ! render_rules restricted > "$boot_tmp" || ! render_rules "$mode" > "$live_tmp" ||
     ! nft -c -f "$boot_tmp" || ! nft -c -f "$live_tmp"; then
    printf '%s\n' "$old_profile" > "$LAN_CONFIG"
    rm -f "$boot_tmp" "$live_tmp"
    echo "LAN change failed validation; previous profile restored." >&2
    exit 1
  fi
  # Replace persistent boot config only after both candidate policies validate.
  install -o root -g root -m 0644 "$boot_tmp" "$BOOT_CONFIG"
  if ! nft -f "$live_tmp"; then
    printf '%s\n' "$old_profile" > "$LAN_CONFIG"
    write_boot_config || true
    rm -f "$boot_tmp" "$live_tmp"
    echo "Could not apply LAN profile; previous profile restored where possible." >&2
    exit 1
  fi
  printf '%s\n' "$mode" > /run/netguard-mode
  rm -f "$boot_tmp" "$live_tmp"
  echo "LAN profile set to: $profile"
  case "$profile" in
    off) echo "No SSH/Remmina LAN exceptions are enabled.";;
    ssh) echo "TCP 22 is allowed to/from 192.168.100.0/24; inbound SSH still requires an SSH server running.";;
    ssh-remmina) echo "LAN SSH and outbound RDP/VNC client connections are allowed. No RDP/VNC server is opened.";;
  esac
  echo "This LAN profile persists across Netguard mode changes and reboot."
}

require_root
command="${1:-status}"
case "$command" in
  status)
    nft list table inet killswitch || { echo "Netguard table is not loaded." >&2; exit 1; }
    echo
    echo "Active mode: $(active_mode)"
    echo "LAN profile: $(read_lan_profile)"
    echo "nftables service: $(systemctl is-active nftables 2>/dev/null || true)"
    echo "Boot service enabled: $(systemctl is-enabled nftables 2>/dev/null || true)"
    echo "Interfaces:"; ip -br address || true
    echo "IPv4 routes:"; ip -4 route || true
    ;;
  render)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    canonical="$(canonical_mode "$2")"
    render_rules "$canonical"
    ;;
  lan)
    shift
    lan_command "$@"
    ;;
  lockdown|off|restricted|current|strict|vpn|openvpn|tor-only|tor)
    mode="$(canonical_mode "$command")"
    if [[ "$mode" == tor-only ]] && ip -4 route show | grep -Eq '^(0\.0\.0\.0/1|128\.0\.0\.0/1).*dev tun2'; then
      echo "OpenVPN routes are still active through tun2." >&2
      echo "Disconnect OpenVPN first, then run: sudo netguard tor-only" >&2
      exit 1
    fi
    apply_mode "$mode"
    ;;
  *) usage >&2; exit 2;;
esac
