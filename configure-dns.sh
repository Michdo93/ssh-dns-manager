#!/usr/bin/env bash
# Interactively configure DNS servers and a DNS search domain on SSH hosts.
set -uo pipefail

readonly SSH_PORT="${SSH_PORT:-22}"
readonly CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-4}"
readonly SCAN_PARALLEL="${SCAN_PARALLEL:-32}"

LOG=$(mktemp) || exit 1
trap 'rm -f "$LOG"' EXIT

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
ask_yes_no() {
  local prompt="$1" default="$2" answer
  while true; do
    if [[ "$default" == y ]]; then read -r -p "$prompt [Y/n] " answer || return 1
    else read -r -p "$prompt [y/N] " answer || return 1; fi
    answer=${answer,,}
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      '') [[ "$default" == y ]] && return 0 || return 1 ;;
      *) printf 'Please answer y/yes or n/no.\n' ;;
    esac
  done
}
ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 )) || return 1
  printf '%u' "$(( (10#$a<<24) | (10#$b<<16) | (10#$c<<8) | 10#$d ))"
}
int_to_ipv4() { local n=$1; printf '%d.%d.%d.%d' "$((n>>24&255))" "$((n>>16&255))" "$((n>>8&255))" "$((n&255))"; }

# Prints the address if an SSH server answers. An authentication failure for a user that
# does not exist still proves that sshd is there. No host keys are stored while scanning.
probe_ssh() {
  local ip=$1 out
  out=$(timeout "$((CONNECT_TIMEOUT + 3))" ssh -F /dev/null -p "$SSH_PORT" -o BatchMode=yes \
    -o ConnectTimeout="$CONNECT_TIMEOUT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "ssh-scan@$ip" true 2>&1) && { printf '%s\n' "$ip"; return; }
  case "$out" in
    *'Permission denied'*|*'Too many authentication failures'*|*'no mutual signature'*) printf '%s\n' "$ip" ;;
  esac
}

ask_range() {
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
}

# Fills the array "reachable" (sorted) with all addresses of the range that run sshd.
scan_range() {
  local n
  printf '\nScanning for SSH services on TCP port %d (%d parallel probes)...\n' "$SSH_PORT" "$SCAN_PARALLEL"
  export -f probe_ssh
  export SSH_PORT CONNECT_TIMEOUT
  mapfile -t reachable < <(
    for ((n=first_n; n<=last_n; n++)); do int_to_ipv4 "$n"; printf '\n'; done |
      xargs -P "$SCAN_PARALLEL" -I{} bash -c 'probe_ssh "$1"' _ {} |
      sort -t . -k1,1n -k2,2n -k3,3n -k4,4n)
  if ((${#reachable[@]} == 0)); then printf 'No SSH-reachable devices found in the range.\n'; exit 0; fi
  printf 'Found %d SSH-reachable device(s).\n' "${#reachable[@]}"
}

# run_remote USER IP SCRIPT [ARG...]
# The POSIX-sh script is sent base64-encoded as the remote command, NOT on stdin. That way
# the remote terminal (-tt) is connected to the local keyboard: password prompts of sudo and
# questions of the script work, and the script text is never echoed back (an echoed script
# would contain its own result markers). Output is shown live and copied to $LOG.
# Returns the exit code of ssh (255 = connection/authentication failed).
run_remote() {
  local user=$1 ip=$2 script=$3 b64 cmd arg q="'"
  shift 3
  b64=$(printf '%s' "$script" | base64 | tr -d '\n')
  cmd="sh -c \"\$(echo $b64 | base64 -d)\" remote"
  for arg in "$@"; do cmd+=" '${arg//$q/$q\\$q$q}'"; done
  ssh -tt -p "$SSH_PORT" -o ConnectTimeout="$CONNECT_TIMEOUT" -o ServerAliveInterval=15 \
    -o NumberOfPasswordPrompts=1 -o PreferredAuthentications=publickey,keyboard-interactive,password \
    -o StrictHostKeyChecking=accept-new "$user@$ip" "$cmd" 2>&1 | tee "$LOG"
  return "${PIPESTATUS[0]}"
}

# Last result marker the remote script printed ("" if none).
remote_result() { grep -ao '@@RESULT:[A-Z_]*@@' "$LOG" | tail -n 1 | sed 's/^@@RESULT://; s/@@$//'; }

# with_login IP REMOTE_SCRIPT [ARG...] - asks for the user name and tries up to three
# logins. Sets "result" to the marker of the remote script, or LOGIN_FAILED / NO_RESULT.
with_login() {
  local ip=$1 rc attempt
  shift
  result=LOGIN_FAILED
  read -r -p 'SSH username: ' username || return 1
  [[ -n "$username" ]] || { printf 'Skipped: username cannot be empty.\n'; result=SKIPPED; return 1; }
  for attempt in 1 2 3; do
    printf 'SSH login attempt %d of 3 for %s.\n' "$attempt" "$ip"
    run_remote "$username" "$ip" "$@"; rc=$?
    result=$(remote_result)
    [[ -n "$result" ]] && return 0
    if (( rc != 255 )); then result=NO_RESULT; return 0; fi
    if grep -aq 'REMOTE HOST IDENTIFICATION HAS CHANGED' "$LOG"; then
      printf 'The host key of %s has changed. Verify the device, then remove the old key with: ssh-keygen -R %s\n' "$ip" "$ip"
      return 1
    fi
    if (( attempt < 3 )); then printf 'SSH login failed.\n'; else printf 'SSH login failed after 3 attempts; moving to the next device.\n'; fi
  done
  return 1
}

command -v ssh >/dev/null || die 'OpenSSH client (ssh) is required.'
command -v timeout >/dev/null || die "The 'timeout' command is required (available on Linux and WSL)."
command -v base64 >/dev/null || die "The 'base64' command is required."
command -v xargs >/dev/null || die "The 'xargs' command is required."


valid_domain() { [[ ${#1} -le 253 && "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$1" != *..* ]]; }

# Remote part (POSIX sh), arguments: DNS server, search domain.
read -r -d '' REMOTE_SCRIPT <<'REMOTE'
mark() { printf '@@RESULT:%s@@\r\033[K' "$1"; }
dns=$1
domain=$2
if [ "$(uname -s 2>/dev/null)" != Linux ]; then mark UNSUPPORTED; exit 0; fi
if [ -r /etc/resolv.conf ]; then
  printf 'Current DNS server(s): '; awk '/^[[:space:]]*nameserver[[:space:]]/{printf "%s ",$2} END{print ""}' /etc/resolv.conf
  printf 'Current search domain(s): '; awk '/^[[:space:]]*(search|domain)[[:space:]]/{for(i=2;i<=NF;i++)printf "%s ",$i} END{print ""}' /etc/resolv.conf
else mark READ_FAILED; exit 0; fi
if [ "$(id -u)" = 0 ]; then SUDO=""
elif command -v sudo >/dev/null 2>&1; then SUDO="sudo"
else mark PRIVILEGE; exit 0; fi
if command -v nmcli >/dev/null 2>&1 && nmcli -t -f RUNNING general 2>/dev/null | grep -q running; then
  con=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: '$2!="" && $2!="lo"{print $1;exit}')
  [ -n "$con" ] || { mark NO_ACTIVE_CONNECTION; exit 0; }
  $SUDO nmcli connection modify "$con" ipv4.ignore-auto-dns yes ipv4.dns "$dns" ipv4.dns-search "$domain" &&
    $SUDO nmcli connection up "$con" >/dev/null || { mark APPLY_FAILED; exit 0; }
elif command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  dev=$(ip -o route show default 2>/dev/null | awk 'NR==1{print $5}')
  [ -n "$dev" ] || { mark NO_INTERFACE; exit 0; }
  $SUDO resolvectl dns "$dev" "$dns" && $SUDO resolvectl domain "$dev" "$domain" || { mark APPLY_FAILED; exit 0; }
else
  # Last resort: static resolv.conf. Never overwrite a symlink managed by another service.
  [ ! -L /etc/resolv.conf ] || { mark MANAGED_RESOLV_CONF; exit 0; }
  # written in place (not replaced), so bind-mounted files of containers work too
  printf 'nameserver %s\nsearch %s\n' "$dns" "$domain" | $SUDO sh -c 'cat > /etc/resolv.conf' || { mark APPLY_FAILED; exit 0; }
fi
if command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  check=$(resolvectl status 2>/dev/null)
else
  check=$(cat /etc/resolv.conf 2>/dev/null)
fi
printf '%s' "$check" | grep -Fq "$dns" && printf '%s' "$check" | grep -Fq "$domain" || { mark VERIFY_FAILED; exit 0; }
mark SUCCESS
REMOTE

while true; do
  printf '\nEnter the DNS settings to apply to selected devices.\n'
  read -r -p 'DNS server IPv4 address: ' dns_server || exit 0
  ipv4_to_int "$dns_server" >/dev/null || { printf 'Invalid DNS server IPv4 address.\n'; continue; }
  read -r -p 'DNS search domain (e.g. office.example): ' search_domain || exit 0
  valid_domain "$search_domain" || { printf 'Invalid search domain.\n'; continue; }
  printf 'DNS server: %s\nSearch domain: %s\n' "$dns_server" "$search_domain"
  if ask_yes_no 'Are these DNS settings correct?' y; then break; fi
done

ask_range
scan_range

for ip in "${reachable[@]}"; do
  printf '\nDevice: %s\n' "$ip"
  ask_yes_no 'Configure DNS on this device?' y || { printf 'Skipped %s.\n' "$ip"; continue; }
  with_login "$ip" "$REMOTE_SCRIPT" "$dns_server" "$search_domain" || continue
  case "$result" in
    SUCCESS) printf 'DNS settings applied and verified on %s.\n' "$ip" ;;
    PRIVILEGE) printf 'Could not configure DNS: administrator privileges are unavailable.\n' ;;
    MANAGED_RESOLV_CONF) printf 'Could not configure DNS safely: the resolver file is managed by another service and no supported network manager was detected.\n' ;;
    NO_ACTIVE_CONNECTION) printf 'Could not configure DNS: no active supported network connection was found.\n' ;;
    UNSUPPORTED) printf 'Could not configure DNS: this operating system is not supported yet.\n' ;;
    VERIFY_FAILED) printf 'DNS settings were changed, but verification failed.\n' ;;
    READ_FAILED) printf 'Could not read the current DNS configuration.\n' ;;
    NO_INTERFACE) printf 'Could not identify the active network interface.\n' ;;
    APPLY_FAILED) printf 'Could not apply DNS settings. Check administrator permissions and network configuration.\n' ;;
    *) printf 'The remote session ended without a result (unsupported shell or interrupted).\n' ;;
  esac
done
printf '\nFinished.\n'
