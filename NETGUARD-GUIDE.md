# Kali Netguard — install once, then control with `netguard`

This version is self-contained: `install-netguard.sh` installs the main controller as `/usr/local/sbin/netguard` and the temporary exception helper as `/usr/local/sbin/netguard-access`. You run the installer once. You do **not** run `netguard-access.sh` separately; after installation, use the command `netguard-access` when you need a temporary destination-specific exception.

## Before installing

The scripts are tailored to the configuration previously supplied:

- Physical interface: `eth0`
- Trusted LAN: `192.168.100.0/24`
- VPN interface: `tun2`
- VPN endpoint: `142.4.216.196:25000/UDP`
- Tor account: `debian-tor` (the scripts also detect an account named `tor`)

Inspect these values and change them in the installer/controller if your network differs. Apply from the VM console or local keyboard, not from a remote-only SSH session: firewall changes can drop remote access.

## Install

```bash
bash -n install-netguard.sh
sudo bash install-netguard.sh
```

The installer asks you to type `INSTALL`, creates a timestamped backup under `/root/netguard-backup-*`, writes `/usr/local/sbin/netguard` and `/usr/local/sbin/netguard-access`, validates a generated nftables policy with `nft -c`, configures nftables to load before the network manager, enables nftables, and applies `restricted` mode. On the first installation, the LAN profile defaults to `off`. If you reinstall, the existing LAN profile is preserved.

The boot policy is always `restricted`; changing modes only changes the live mode. The LAN profile is a separate persistent setting, which is included in the generated boot policy.

## Modes

| Command | Meaning |
|---|---|
| `sudo netguard lockdown` | Block application/internet traffic. DHCP and any explicitly enabled LAN profile remain allowed. |
| `sudo netguard restricted` | Allow the Tor daemon's TCP traffic and the configured OpenVPN endpoint; block ordinary applications, including ordinary browser traffic. |
| `sudo netguard vpn` | Allow applications through `tun2`; direct internet egress over `eth0` remains blocked except for DHCP and the configured VPN endpoint. This mode allows all applications routed through `tun2`, not just a browser. |
| `sudo netguard tor-only` | Allow Tor daemon TCP traffic through `eth0`; OpenVPN split-default routes through `tun2` must be disconnected first. Applications need to use Tor's local proxy to use Tor. |
| `sudo netguard status` | Show active mode, LAN profile, interfaces, routes, and nftables service status. |

Compatibility aliases are retained: `off` means `lockdown`, `current` and `strict` mean `restricted`, `tor` means `tor-only`, and `openvpn` means `vpn`.

## LAN SSH / Remmina setting

This setting is independent of the current firewall mode and is retained across mode changes and reboots:

```bash
sudo netguard lan status
sudo netguard lan off
sudo netguard lan on ssh
sudo netguard lan on ssh-remmina
```

- `off`: no extra LAN SSH/Remmina permissions.
- `ssh`: allow outbound SSH to LAN hosts on TCP 22, and allow new inbound SSH connections from `192.168.100.0/24` to this computer on TCP 22. An SSH server must be installed and running for inbound SSH to work. This does not start the SSH server.
- `ssh-remmina`: the `ssh` profile plus outbound RDP (TCP/UDP 3389) and VNC (TCP 5900–5999) client connections to the trusted LAN. Remmina is a client, so this does **not** open an RDP/VNC server on this computer.

These LAN rules apply only to `eth0` and `192.168.100.0/24`. Check that this is the correct trusted subnet before enabling them. In `lockdown`, selecting a LAN profile deliberately creates a limited LAN exception; choose `lan off` to remove that exception.

## Temporary exceptions to a particular remote host

`netguard-access` remains available for destination-specific permissions while the active mode is `restricted`. These rules are runtime-only and disappear when the mode or LAN profile is changed, or on reboot.

Examples:

```bash
# SSH to a specific remote IPv4 host through the VPN
sudo netguard restricted
sudo netguard-access enable ssh 203.0.113.20 vpn

# SSH directly to one specific LAN host (not through the VPN)
sudo netguard-access enable ssh 192.168.100.20 direct

# RDP to one specific remote IPv4 host through the VPN
sudo netguard-access enable remmina 203.0.113.30 rdp vpn

# Review or remove temporary exceptions
sudo netguard-access list
sudo netguard-access clear
```

Use actual destination IPv4 addresses instead of the example documentation addresses. `direct` explicitly permits that matching connection over `eth0`, so do not use it for public destinations unless you intend that bypass. `netguard-access` is not required for normal LAN access after configuring `netguard lan`.

## Verification and caveats

```bash
sudo netguard status
sudo nft list table inet killswitch
ip -4 route
```

In `vpn` mode, verify that applications cannot reach the internet if the VPN tunnel fails; do not add a broad `eth0 accept` rule to troubleshoot. Check that the active VPN really uses `tun2` and the endpoint/port above.

A default-drop nftables policy is a useful kill switch, not an absolute guarantee against every possible leak or compromise. Root processes can change firewall rules; other network namespaces, VMs, IPv6 routing, DNS configuration, and application proxy settings should be tested separately. The firewall does not force applications to use Tor. In `restricted`, Tor's traffic is allowed on `eth0` and `tun2` for the Tor service account; whether it traverses the VPN depends on the active routes.
