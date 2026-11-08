# SSH DNS Manager

An interactive Bash utility that scans an IPv4 range for SSH services and configures a DNS server and search domain on selected Linux devices.

## Supported systems

The remote script detects available tools and uses, in order:

1. NetworkManager (`nmcli`, if NetworkManager is running), updating the active connection so the settings persist.
2. `systemd-resolved` (`resolvectl`), applying DNS and the search domain to the active interface for the current runtime.
3. A plain, non-symlink `/etc/resolv.conf`, writing a static configuration (in place, so bind-mounted files in containers work too).

The script refuses to overwrite a symlinked resolver file when it cannot find a supported manager. This avoids silently fighting DHCP or a network service. Runtime settings applied with `resolvectl` may be replaced after reboot or when the network reconnects; configure the system's network manager for permanent settings.

Windows is not implemented in this version. Although the script can detect SSH reachability, its remote configuration payload requires a POSIX shell and does not alter Windows adapter DNS settings. Use a PowerShell-based Windows management tool for Windows hosts.

## Requirements and preparation

- Bash 4 or newer.
- OpenSSH client (`ssh`), `timeout`, `xargs` and `base64` (available on Linux and WSL).
- Each target must run an SSH server and accept connections on TCP port 22.
- A remote account with root or `sudo` permission to modify DNS settings.
- For persistent changes, configure NetworkManager where possible. `systemd-resolved` changes made by this tool are runtime changes.

Install and enable an SSH server on each target (commonly `openssh-server`), and allow inbound TCP port 22 through its firewall. SSH key authentication is recommended. The script prompts for the username; OpenSSH prompts for the password. If `sudo` is needed, the remote prompt may request the password again. Passwords are not stored.

The scan checks for an SSH response, so ICMP ping may be blocked. The first connection may ask you to trust the host key; verify its fingerprint before accepting it.

## Run

```bash
chmod +x configure-dns.sh
./configure-dns.sh
```

First enter the DNS server IPv4 address and search domain, then confirm them. Next enter the first and last IPv4 addresses to scan and confirm the range. For each reachable device, choose whether to configure it and enter an SSH username. Login is attempted up to three times per device; after three failures the script continues to the next host.

Yes accepts `y`, `Y`, `yes`, or `Yes`; No accepts `n`, `N`, `no`, or `No`. Pressing Enter selects the displayed default. The script prints the current DNS and search values where it can read them, applies the selected configuration, and verifies the result.

## Limits

- IPv4 only; at most 65,536 addresses per scan.
- SSH port 22 by default; set `SSH_PORT=2222` for another port. `SCAN_PARALLEL` (32) and `CONNECT_TIMEOUT` (4 s) tune the scan.
- The remote script is sent base64-encoded as the remote command of `ssh -tt`, not on stdin, so a sudo password prompt is answered on your keyboard and the reported result comes from the remote script only (never from echoed script text).
- Linux targets with a POSIX shell. Windows, macOS, and other operating systems are not currently supported for remote configuration.
- DNS server input accepts one IPv4 address. IPv6 DNS servers are not supported.
