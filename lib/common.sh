#!/bin/bash
# netcut shared helpers. Sourced by netcutd (root) and netcut (unprivileged).
# No side effects beyond variable definition.

NETCUT_RUN_DIR=${NETCUT_RUN_DIR:-/var/run/netcut}
NETCUT_FIFO=${NETCUT_FIFO:-$NETCUT_RUN_DIR/ctl}
NETCUT_LOG=${NETCUT_LOG:-/var/log/netcut.log}
NETCUT_ANCHOR=${NETCUT_ANCHOR:-com.apple/netcut}
NETCUT_LIBEXEC=${NETCUT_LIBEXEC:-/usr/local/libexec/netcut}
NETCUT_PROFILE_DIR=${NETCUT_PROFILE_DIR:-$NETCUT_LIBEXEC/profiles}
NETCUT_MAX_SECONDS=${NETCUT_MAX_SECONDS:-120}
# Request-protocol version. 1 = whitespace-split, profiles only. 2 = pipe-
# delimited fields plus the "app" and "probe" verbs. 3 = "latch" and "toggle".
# netcutd publishes the version it speaks in $NETCUT_RUN_DIR/protocol so the
# client can tell an old installed helper from a current one without waiting
# out a timeout on a verb that helper answers with silence.
NETCUT_PROTOCOL=${NETCUT_PROTOCOL:-3}
NETCUT_LATCH_CAP=${NETCUT_LATCH_CAP:-1800}   # a held cut still lifts eventually
NETCUT_DEFAULT_HOLD=${NETCUT_DEFAULT_HOLD:-asap}

# Addresses that must never be blocked: loopback, RFC1918, the CGNAT/tailnet
# space this machine's own default route and SSH sessions live in, multicast.
NETCUT_NEVER_BLOCK_V4='127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 224.0.0.0/4 0.0.0.0/8'
NETCUT_NEVER_BLOCK_V6='::1/128 fe80::/10 fd7a:115c:a1e0::/48 fc00::/7 ff00::/8'

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# profile_get <file> <key>  -> value (first match, trimmed)
profile_get() {
  sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" 2>/dev/null \
    | sed 's/[[:space:]]*$//' | head -1
}

# ip_family <addr-or-cidr> -> v4 | v6 | bad
ip_family() {
  case "$1" in
    *:*) printf 'v6\n' ;;
    [0-9]*.[0-9]*.[0-9]*.[0-9]*|[0-9]*.[0-9]*.[0-9]*.[0-9]*/[0-9]*) printf 'v4\n' ;;
    *) printf 'bad\n' ;;
  esac
}

# prefix_len <addr-or-cidr> <family> -> integer
prefix_len() {
  case "$1" in
    */*) printf '%s\n' "${1##*/}" ;;
    *) [ "$2" = v6 ] && printf '128\n' || printf '32\n' ;;
  esac
}

# in_range <addr> <cidr>  (string/boundary check only; exact for the guard list)
# Guard is enforced by comparing the address against each never-block prefix
# numerically for v4 and by textual prefix for v6.
v4_to_int() {
  local IFS=. a b c d; read -r a b c d <<< "${1%%/*}"
  printf '%s\n' $(( (a<<24) + (b<<16) + (c<<8) + d ))
}

v4_in_cidr() { # v4_in_cidr <addr> <cidr>
  local addr net len mask ai ni
  addr=${1%%/*}; net=${2%%/*}; len=${2##*/}
  ai=$(v4_to_int "$addr"); ni=$(v4_to_int "$net")
  if [ "$len" -eq 0 ]; then return 0; fi
  mask=$(( 0xFFFFFFFF << (32 - len) & 0xFFFFFFFF ))
  [ $(( ai & mask )) -eq $(( ni & mask )) ]
}

# guard_ok <addr> <family> -> 0 if safe to block
guard_ok() {
  local addr=$1 fam=$2 c len
  len=$(prefix_len "$addr" "$fam")
  if [ "$fam" = v4 ]; then
    [ "$len" -ge 16 ] || return 1
    for c in $NETCUT_NEVER_BLOCK_V4; do
      v4_in_cidr "$addr" "$c" && return 1
    done
  else
    [ "$len" -ge 32 ] || return 1
    case "$addr" in
      ::1*|fe80:*|fd7a:*|fc*:*|fd*:*|ff0*:*) return 1 ;;
    esac
  fi
  return 0
}

# first_bundle <executable path> -> the outermost .app, or the basename
first_bundle() {
  printf '%s\n' "$1" | awk '{ i = index($0, ".app/"); if (i > 0) print substr($0, 1, i + 3); else print $0 }'
}

# app_label <bundle path> -> human name
app_label() { printf '%s\n' "${1##*/}" | sed 's/\.app$//'; }
