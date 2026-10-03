#!/bin/bash
# netcut shared helpers. Sourced by netcutd (root) and netcut (unprivileged).
# No side effects beyond variable definition.

TRIGGER_USER=${TRIGGER_USER:-${NETCUT_TRIGGER_USER:-$(id -un)}}
NETCUT_RUN_DIR=${NETCUT_RUN_DIR:-/var/run/netcut}
NETCUT_FIFO=${NETCUT_FIFO:-$NETCUT_RUN_DIR/ctl}
NETCUT_LOG=${NETCUT_LOG:-/var/log/netcut.log}
NETCUT_ANCHOR=${NETCUT_ANCHOR:-com.apple/netcut}
NETCUT_LIBEXEC=${NETCUT_LIBEXEC:-/usr/local/libexec/netcut}
NETCUT_PROFILE_DIR=${NETCUT_PROFILE_DIR:-$NETCUT_LIBEXEC/profiles}
NETCUT_EXCLUSIONS=${NETCUT_EXCLUSIONS:-$NETCUT_LIBEXEC/exclusions.txt}
NETCUT_MAX_SECONDS=${NETCUT_MAX_SECONDS:-120}
# Request-protocol version. 1 = whitespace-split, profiles only. 2 = pipe-
# delimited fields plus the "app" and "probe" verbs. 3 = "latch" and "toggle".
# 4 = the latch reply carries its auto-reenable window in seconds.
# 5 = the caller may ask for that window.
# 6 = the mode field may carry a direction, as mode:direction.
# netcutd publishes the version it speaks in $NETCUT_RUN_DIR/protocol so the
# client can tell an old installed helper from a current one without waiting
# out a timeout on a verb that helper answers with silence.
NETCUT_PROTOCOL=${NETCUT_PROTOCOL:-6}
NETCUT_LATCH_CAP=${NETCUT_LATCH_CAP:-20}     # default auto-reenable, seconds
NETCUT_LATCH_MIN=${NETCUT_LATCH_MIN:-2}      # a request below this is clamped up
# The chosen value lives in the user's config so the menu, the CLI and the
# daemon all read one number; the daemon clamps whatever it is handed.
NETCUT_SECONDS_FILE=${NETCUT_SECONDS_FILE:-.config/netcut/seconds}
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

# guard_filter -- reads candidate addresses on stdin, prints "4 <addr>" or
# "6 <addr>" for each one that is safe to block, and "skip" for each refusal.
#
# One awk process for the whole list. The per-address bash version forked
# about ten subshells per address (~3.5ms each, ~120ms on a browser), which
# was the single largest cost in a cut. No bitwise operators: macOS awk has
# no and()/compl(), so a prefix test is a numeric range test instead, which
# is exact for the properly-aligned prefixes in the never-block list.
guard_filter() {
  awk -v v4list="$NETCUT_NEVER_BLOCK_V4" '
    function toint(a,   p) {
      split(a, p, ".")
      return (p[1] * 16777216) + (p[2] * 65536) + (p[3] * 256) + p[4]
    }
    BEGIN {
      n = split(v4list, B, " ")
      for (i = 1; i <= n; i++) {
        split(B[i], q, "/")
        lo[i] = toint(q[1]); len[i] = q[2] + 0
        hi[i] = lo[i] + (2 ^ (32 - len[i])) - 1
      }
    }
    {
      addr = $0
      if (addr == "") next
      sl = index(addr, "/")
      if (sl) { pfx = substr(addr, sl + 1) + 0; base = substr(addr, 1, sl - 1) }
      else    { pfx = -1; base = addr }

      if (index(base, ":")) {                       # IPv6
        if (pfx == -1) pfx = 128
        if (pfx < 32) { print "skip"; next }
        low = tolower(base)
        if (low == "::1" || low ~ /^fe80:/ || low ~ /^fd/ || low ~ /^fc/ || low ~ /^ff0/) {
          print "skip"; next
        }
        print "6 " addr; next
      }

      if (base !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) next
      if (pfx == -1) pfx = 32
      if (pfx < 16) { print "skip"; next }
      ip = toint(base)
      for (i = 1; i <= n; i++) {
        if (ip >= lo[i] && ip <= hi[i]) { print "skip"; next }
      }
      print "4 " addr
    }'
}

# app_pids <pgrep -f pattern> -> comma-separated pids
# netcut's own processes are filtered out: an app target is a bundle path, and
# that same path sits in the argv of the client that asked for the cut, so an
# unfiltered pgrep would "find" the app even when it is not running.
app_pids() {
  ps -axww -o pid=,command= 2>/dev/null | NETCUT_PAT="$1" awk '
    BEGIN { pat = ENVIRON["NETCUT_PAT"] }
    $0 ~ pat && index($0, "netcut") == 0 { printf "%s%s", (n++ ? "," : ""), $1 }'
}

# pg_quote <string> -> the same string, safe as a pgrep/grep ERE literal
pg_quote() { printf '%s\n' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'; }

# proc_match_for <resolved target> -> the pattern that finds its processes
# A .app is matched by its full bundle path, which catches every helper inside
# it. A .exe is matched by filename: the process belongs to Wine, and its argv
# carries a Windows-style path that never matches the unix one.
proc_match_for() {
  case "$1" in
    *.exe|*.EXE) pg_quote "${1##*/}" ;;
    *) pg_quote "$1" ;;
  esac
}

# resolve_app_spec <spec> -> absolute bundle (or executable) path on stdout
# Accepts an absolute path to an existing .app bundle, executable or .exe, a
# bare .exe name, or a bare application name looked up in the standard
# application directories. Anything else is refused, so a target can never be
# an arbitrary string.
resolve_app_spec() {
  local spec=${1%/} base
  case "$spec" in
    *[![:print:]]*) return 1 ;;
    *'`'*|*'$'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*|*'"'*|*"'"*) return 1 ;;
  esac
  [ -n "$spec" ] || return 1
  if [ "${spec#/}" != "$spec" ]; then
    case "$spec" in
      *.app) [ -d "$spec" ] && { printf '%s\n' "$spec"; return 0; } ;;
      # A Windows binary under Wine is usually not chmod +x, so the execute
      # bit is not what makes it a target -- existing on disk is.
      *.exe|*.EXE) [ -f "$spec" ] && { printf '%s\n' "$spec"; return 0; } ;;
    esac
    [ -f "$spec" ] && [ -x "$spec" ] && { printf '%s\n' "$spec"; return 0; }
    return 1
  fi
  # A bare "Game.exe": Wine is what owns the process, so there is no bundle to
  # find on disk. It stands as the process name and must match something live.
  case "$spec" in *.exe|*.EXE) printf '%s\n' "$spec"; return 0 ;; esac
  for base in /Applications "/Users/$TRIGGER_USER/Applications" \
              /Applications/Utilities /System/Applications \
              /System/Applications/Utilities /System/Library/CoreServices; do
    [ -d "$base/$spec.app" ] && { printf '%s\n' "$base/$spec.app"; return 0; }
  done
  return 1
}

# kill_states <v4 list> <v6 list>
# Open connections match existing pf states and bypass the ruleset, so the
# states have to be killed for the block to bite. Two forms are needed: `-k
# host` kills states *originating from* that host, which only covers inbound,
# so an outbound connection needs `-k <any> -k host`. The wildcard must be of
# the same family as the address — `0.0.0.0/0` against an IPv6 address is
# rejected, which is why v6 connections used to survive a cut.
#
# Fanned out, bounded at 24 at a time: a browser holds ~90 addresses, and
# doing these one after another is the slowest part of a cut by far.
kill_states() {
  # Two forms are needed: `-k host` kills states originating FROM that host
  # (inbound), and `-k <any> -k host` kills the outbound ones a client app
  # actually has. The wildcard must match the family -- 0.0.0.0/0 against an
  # IPv6 address is rejected, which is why v6 connections once survived.
  #
  # pfctl directly under xargs, with no `sh -c` wrapper: that wrapper was an
  # extra process per address for nothing.
  if [ -n "$1" ]; then
    printf '%s\n' $1 | sed 's#/.*##' | xargs -P 24 -n1 pfctl -k >/dev/null 2>&1
    printf '%s\n' $1 | sed 's#/.*##' | xargs -P 24 -I@ pfctl -k 0.0.0.0/0 -k @ >/dev/null 2>&1
  fi
  if [ -n "$2" ]; then
    printf '%s\n' $2 | sed 's#/.*##' | xargs -P 24 -n1 pfctl -k >/dev/null 2>&1
    printf '%s\n' $2 | sed 's#/.*##' | xargs -P 24 -I@ pfctl -k ::/0 -k @ >/dev/null 2>&1
  fi
  return 0
}

# excluded <bundle path or name> -> prints the matched pattern, returns 0 if
# the target is on the exclusion list.
#
# The list is a file installed beside the privileged helper, root-owned, so
# changing it takes a deliberate edit and a reinstall. Unlike the warning it
# replaced, this one is enforced in the daemon before any rule is written.
excluded() {
  local probe pat
  [ -f "$NETCUT_EXCLUSIONS" ] || return 1
  probe=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's#.*/##; s#\.app$##; s/[^a-z0-9]//g')
  [ -n "$probe" ] || return 1
  while read -r pat; do
    case "$pat" in ''|'#'*) continue ;; esac
    pat=$(printf '%s' "$pat" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]//g')
    [ -n "$pat" ] || continue
    case "$probe" in
      *"$pat"*) printf '%s\n' "$pat"; return 0 ;;
    esac
  done < "$NETCUT_EXCLUSIONS"
  return 1
}

# first_bundle <executable path> -> the outermost .app, or the basename
first_bundle() {
  printf '%s\n' "$1" | awk '{ i = index($0, ".app/"); if (i > 0) print substr($0, 1, i + 3); else print $0 }'
}

# app_label <bundle path> -> human name
app_label() { printf '%s\n' "${1##*/}" | sed 's/\.app$//'; }
