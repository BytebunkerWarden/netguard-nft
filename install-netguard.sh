#!/usr/bin/env bash
set -Eeuo pipefail

# Self-contained Netguard installer. It installs both:
#   /usr/local/sbin/netguard
#   /usr/local/sbin/netguard-access
# Run once with: sudo bash install-netguard.sh

if [[ ${EUID} -ne 0 ]]; then
  echo "Run with sudo: sudo bash install-netguard.sh" >&2
  exit 1
fi

for cmd in nft systemctl ip getent python3 install; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Required command not found: $cmd" >&2; exit 1; }
done

getent passwd debian-tor >/dev/null || getent passwd tor >/dev/null || {
  echo "No Tor service account found (expected debian-tor or tor)." >&2
  exit 1
}
ip link show eth0 >/dev/null 2>&1 || {
  echo "Configured physical interface eth0 does not exist on this system." >&2
  echo "Edit PHYSICAL_IF in the installer/controller before installing." >&2
  exit 1
}

cat <<'WARNING'
WARNING: Netguard applies a default-drop firewall and can interrupt SSH,
Remmina, browser, VPN, and other network access. Run this from the VM/local
console, not from a remote-only session. The configured network is:
  physical interface: eth0
  trusted LAN:         192.168.100.0/24
  VPN interface:       tun2
  VPN endpoint:        142.4.216.196:25000/UDP
WARNING
read -r -p 'Type INSTALL to continue: ' confirmation
[[ "$confirmation" == "INSTALL" ]] || { echo "Cancelled."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/netguard-backup-${STAMP}"
mkdir -p "$BACKUP" /usr/local/sbin /etc/netguard /etc/systemd/system/nftables.service.d
cp -a /etc/nftables.conf "$BACKUP/nftables.conf" 2>/dev/null || true
nft list ruleset > "$BACKUP/nft-ruleset.txt" 2>/dev/null || true
for f in /usr/local/sbin/netguard /usr/local/sbin/netguard-access /etc/netguard/lan-access \
         /etc/systemd/system/nftables.service.d/90-killswitch.conf; do
  if [[ -e "$f" ]]; then
    mkdir -p "$BACKUP$(dirname "$f")"
    cp -a "$f" "$BACKUP$f"
  fi
done
for unit in NetworkManager.service networking.service systemd-networkd.service; do
  f="/etc/systemd/system/${unit}.d/20-netguard-firewall.conf"
  if [[ -e "$f" ]]; then
    mkdir -p "$BACKUP$(dirname "$f")"
    cp -a "$f" "$BACKUP$f"
  fi
done

# Preserve an existing LAN profile; the first installation defaults to off.
if [[ ! -f /etc/netguard/lan-access ]]; then
  printf 'off\n' > /etc/netguard/lan-access
fi
chmod 0600 /etc/netguard/lan-access

cat > /usr/local/sbin/netguard <<'NETGUARD'
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
NETGUARD
chmod 0755 /usr/local/sbin/netguard

cat > /usr/local/sbin/netguard-access <<'ACCESS'
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
ACCESS
chmod 0755 /usr/local/sbin/netguard-access

# Install startup policy: restricted mode, with LAN access off on a new install.
BOOT_TMP="$(mktemp /etc/nftables.conf.netguard.XXXXXX)"
/usr/local/sbin/netguard render restricted > "$BOOT_TMP"
if ! nft -c -f "$BOOT_TMP"; then
  rm -f "$BOOT_TMP"
  echo "nftables rejected the generated boot configuration. Existing /etc/nftables.conf was left unchanged." >&2
  echo "Backup: $BACKUP" >&2
  exit 1
fi
install -o root -g root -m 0644 "$BOOT_TMP" /etc/nftables.conf
rm -f "$BOOT_TMP"

cat > /etc/systemd/system/nftables.service.d/90-killswitch.conf <<'UNIT'
[Unit]
DefaultDependencies=no
After=local-fs.target
Wants=network-pre.target
Before=network-pre.target NetworkManager.service networking.service systemd-networkd.service shutdown.target

[Service]
ExecStop=
UNIT

for unit in NetworkManager.service networking.service systemd-networkd.service; do
  if systemctl cat "$unit" >/dev/null 2>&1; then
    dir="/etc/systemd/system/${unit}.d"
    mkdir -p "$dir"
    cat > "${dir}/20-netguard-firewall.conf" <<'UNIT'
[Unit]
Requires=nftables.service
After=nftables.service
UNIT
  fi
done

systemctl daemon-reload
systemctl enable nftables.service
/usr/local/sbin/netguard restricted

echo
echo "Netguard installed. Backup directory: $BACKUP"
echo "Installed commands: /usr/local/sbin/netguard and /usr/local/sbin/netguard-access"
echo "Boot default: restricted. LAN profile: $(cat /etc/netguard/lan-access)"
echo
echo "Examples:"
echo "  sudo netguard lockdown"
echo "  sudo netguard vpn"
echo "  sudo netguard tor-only"
echo "  sudo netguard lan on ssh"
echo "  sudo netguard lan on ssh-remmina"
echo "  sudo netguard lan off"
echo "  sudo netguard status"
