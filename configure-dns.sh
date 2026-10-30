#!/usr/bin/env bash
# Interactively configure DNS servers and a DNS search domain on SSH hosts.
set -uo pipefail

readonly SSH_PORT=22
readonly CONNECT_TIMEOUT=4

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
ask_yes_no() {
  local prompt="$1" default="$2" answer
  while true; do
    if [[ "$default" == y ]]; then read -r -p "$prompt [Y/n] " answer || return 1
    else read -r -p "$prompt [y/N] " answer || return 1; fi
    answer=${answer,,}
    case "$answer" in y|yes) return 0;; n|no) return 1;; '') [[ "$default" == y ]] && return 0 || return 1;; *) printf 'Please answer y/yes or n/no.\n';; esac
  done
}
ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  [[ "$a$b$c$d" =~ ^[0-9]+$ ]] || return 1
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
  printf '%u' "$(( (a<<24) | (b<<16) | (c<<8) | d ))"
}
int_to_ipv4() { local n=$1; printf '%d.%d.%d.%d' "$((n>>24&255))" "$((n>>16&255))" "$((n>>8&255))" "$((n&255))"; }
valid_domain() { [[ ${#1} -le 253 && "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$1" != *..* ]]; }

command -v ssh >/dev/null || die 'OpenSSH client (ssh) is required.'
command -v timeout >/dev/null || die "The 'timeout' command is required (available on Linux and WSL)."

while true; do
  printf '\nEnter the DNS settings to apply to selected devices.\n'
  read -r -p 'DNS server IPv4 address: ' dns_server || exit 0
  dns_n=$(ipv4_to_int "$dns_server") || { printf 'Invalid DNS server IPv4 address.\n'; continue; }
  read -r -p 'DNS search domain (e.g. office.example): ' search_domain || exit 0
  valid_domain "$search_domain" || { printf 'Invalid search domain.\n'; continue; }
  printf 'DNS server: %s\nSearch domain: %s\n' "$dns_server" "$search_domain"
  if ask_yes_no 'Are these DNS settings correct?' y; then break; fi
done

while true; do
  printf '\nEnter the first and last IPv4 address in the range.\n'
  read -r -p 'First address: ' first || exit 0
  read -r -p 'Last address:  ' last || exit 0
  first_n=$(ipv4_to_int "$first") || { printf 'Invalid first IPv4 address.\n'; continue; }
  last_n=$(ipv4_to_int "$last") || { printf 'Invalid last IPv4 address.\n'; continue; }
  (( first_n <= last_n )) || { printf 'The first address must not be greater than the last address.\n'; continue; }
  (( last_n - first_n <= 65535 )) || { printf 'Ranges are limited to 65,536 addresses.\n'; continue; }
  if ask_yes_no "Scan ${first} through ${last}?" y; then break; fi
done

printf '\nScanning for SSH services on TCP port %d...\n' "$SSH_PORT"
declare -a reachable=()
for ((n=first_n; n<=last_n; n++)); do
  ip=$(int_to_ipv4 "$n")
  probe=$(timeout "$CONNECT_TIMEOUT" ssh -F /dev/null -p "$SSH_PORT" -o BatchMode=yes \
    -o ConnectTimeout="$CONNECT_TIMEOUT" -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" "dns-scan@$ip" true 2>&1 || true)
  if [[ "$probe" == *'Permission denied'* || "$probe" == *'Too many authentication failures'* || "$probe" == *'no mutual signature'* ]]; then reachable+=("$ip"); fi
done
if ((${#reachable[@]} == 0)); then printf 'No SSH-reachable devices found in the range.\n'; exit 0; fi
printf 'Found %d SSH-reachable device(s).\n' "${#reachable[@]}"

for ip in "${reachable[@]}"; do
  printf '\nDevice: %s\n' "$ip"
  ask_yes_no 'Configure DNS on this device?' y || { printf 'Skipped %s.\n' "$ip"; continue; }
  read -r -p 'SSH username: ' username
  [[ -n "$username" ]] || { printf 'Skipped: username cannot be empty.\n'; continue; }
  configured=false
  # Authentication is retried up to three times per device. Host OS and privilege
  # detection happen remotely; user-facing messages remain OS-neutral.
  for attempt in 1 2 3; do
    printf 'SSH login attempt %d of 3 for %s.\n' "$attempt" "$ip"
    result=$(timeout 45 ssh -tt -p "$SSH_PORT" -o ConnectTimeout="$CONNECT_TIMEOUT" \
      -o NumberOfPasswordPrompts=1 -o PreferredAuthentications=publickey,password,keyboard-interactive \
      -o StrictHostKeyChecking=accept-new "$username@$ip" 'sh -s' "$dns_server" "$search_domain" 2>&1 <<'REMOTE'
set +e
dns=$1
domain=$2
if [ "$(uname -s 2>/dev/null)" != Linux ]; then echo 'RESULT:UNSUPPORTED'; exit 20; fi
if [ -r /etc/resolv.conf ]; then
  printf 'CURRENT_DNS:'; awk '/^[[:space:]]*nameserver[[:space:]]/{printf "%s ",$2} END{print ""}' /etc/resolv.conf
  printf 'CURRENT_SEARCH:'; awk '/^[[:space:]]*(search|domain)[[:space:]]/{for(i=2;i<=NF;i++)printf "%s ",$i} END{print ""}' /etc/resolv.conf
else echo 'RESULT:READ_FAILED'; exit 21; fi
if command -v nmcli >/dev/null 2>&1; then
  con=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: '$2!=""{print $1;exit}')
  if [ -n "$con" ]; then
    if [ "$(id -u)" = 0 ]; then nmcli connection modify "$con" ipv4.ignore-auto-dns yes ipv4.dns "$dns" ipv4.dns-search "$domain" && nmcli connection up "$con"; rc=$?
    elif command -v sudo >/dev/null 2>&1; then sudo nmcli connection modify "$con" ipv4.ignore-auto-dns yes ipv4.dns "$dns" ipv4.dns-search "$domain" && sudo nmcli connection up "$con"; rc=$?
    else echo 'RESULT:PRIVILEGE'; exit 22; fi
    [ "$rc" -eq 0 ] || { echo 'RESULT:APPLY_FAILED'; exit 23; }
  else echo 'RESULT:NO_ACTIVE_CONNECTION'; exit 24; fi
elif command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  dev=$(ip -o route show default 2>/dev/null | awk 'NR==1{print $5}')
  [ -n "$dev" ] || { echo 'RESULT:NO_INTERFACE'; exit 25; }
  if [ "$(id -u)" = 0 ]; then resolvectl dns "$dev" "$dns" && resolvectl domain "$dev" "$domain"; rc=$?
  elif command -v sudo >/dev/null 2>&1; then sudo resolvectl dns "$dev" "$dns" && sudo resolvectl domain "$dev" "$domain"; rc=$?
  else echo 'RESULT:PRIVILEGE'; exit 22; fi
  [ "$rc" -eq 0 ] || { echo 'RESULT:APPLY_FAILED'; exit 23; }
else
  # Last-resort static resolv.conf. Avoid overwriting a symlink managed by
  # NetworkManager, systemd-resolved, or another network service.
  [ ! -L /etc/resolv.conf ] || { echo 'RESULT:MANAGED_RESOLV_CONF'; exit 26; }
  tmp="/tmp/resolv.conf.codex.$$"
  { printf 'nameserver %s\nsearch %s\n' "$dns" "$domain"; } > "$tmp" || { echo 'RESULT:WRITE_FAILED'; exit 27; }
  if [ "$(id -u)" = 0 ]; then install -m 644 "$tmp" /etc/resolv.conf; rc=$?
  elif command -v sudo >/dev/null 2>&1; then sudo install -m 644 "$tmp" /etc/resolv.conf; rc=$?
  else rm -f "$tmp"; echo 'RESULT:PRIVILEGE'; exit 22; fi
  rm -f "$tmp"
  [ "$rc" -eq 0 ] || { echo 'RESULT:APPLY_FAILED'; exit 23; }
fi
if command -v resolvectl >/dev/null 2>&1; then check=$(resolvectl status 2>/dev/null); else check=$(cat /etc/resolv.conf 2>/dev/null); fi
printf '%s' "$check" | grep -Fq "$dns" && printf '%s' "$check" | grep -Fq "$domain" || { echo 'RESULT:VERIFY_FAILED'; exit 28; }
echo 'RESULT:SUCCESS'
REMOTE
    ) || true
    if [[ "$result" == *'RESULT:'* ]]; then
      case "$result" in
        *'RESULT:SUCCESS'*) printf 'DNS settings applied and verified on %s.\n' "$ip" ;;
        *'RESULT:PRIVILEGE'*) printf 'Could not configure DNS: administrator privileges are unavailable.\n' ;;
        *'RESULT:MANAGED_RESOLV_CONF'*) printf 'Could not configure DNS safely: the resolver file is managed by another service and no supported network manager was detected.\n' ;;
        *'RESULT:NO_ACTIVE_CONNECTION'*) printf 'Could not configure DNS: no active supported network connection was found.\n' ;;
        *'RESULT:UNSUPPORTED'*) printf 'Could not configure DNS: this operating system is not supported yet.\n' ;;
        *'RESULT:VERIFY_FAILED'*) printf 'DNS settings were changed, but verification failed.\n' ;;
        *'RESULT:READ_FAILED'*) printf 'Could not read the current DNS configuration.\n' ;;
        *'RESULT:NO_INTERFACE'*) printf 'Could not identify the active network interface.\n' ;;
        *) printf 'Could not apply DNS settings. Check administrator permissions and network configuration.\n' ;;
      esac
      if [[ "$result" == *'CURRENT_DNS:'* ]]; then printf '%s\n' "$result" | sed -n 's/^.*CURRENT_DNS:/Current DNS server(s): /p' | tail -n 1; fi
      if [[ "$result" == *'CURRENT_SEARCH:'* ]]; then printf '%s\n' "$result" | sed -n 's/^.*CURRENT_SEARCH:/Current search domain(s): /p' | tail -n 1; fi
      configured=true
      break
    fi
    if (( attempt < 3 )); then printf 'SSH login failed.\n'; else printf 'SSH login failed after 3 attempts; moving to the next device.\n'; fi
  done
  [[ "$configured" == true ]] || continue
done
printf '\nFinished.\n'
