#!/usr/bin/env sh
# Bounded, symlink-safe I/O helper for the omarchiumdash Quickshell plugin.
#
# The Quickshell engine has no way to cap XMLHttpRequest buffering or to open
# FileView with O_NOFOLLOW, so all network and state-file I/O runs here where a
# hard producer-side byte ceiling, deadline, and descriptor-bound file checks
# are enforced before any bytes reach the long-lived shell.
#
# Subcommands:
#   fetch <url>        HTTPS-only, host-allowlisted GET, byte + time bounded.
#   read-state <path>  No-follow, size-bounded read of the state file to stdout.
#   write-state <path> Atomic, symlink-safe write of stdin to the state file.
set -eu

MAX_FETCH_BYTES=4194304
MAX_STATE_BYTES=262144
FETCH_TIMEOUT=20

allowed_host() {
  case $1 in
    versionhistory.googleapis.com|chromiumdash.appspot.com|*-review.googlesource.com) return 0 ;;
    *) return 1 ;;
  esac
}

fetch() {
  url=$1
  case $url in
    https://*) ;;
    *) echo "scheme not allowed" >&2; exit 2 ;;
  esac
  rest=${url#https://}
  host=${rest%%/*}
  host=${host%%\?*}
  host=${host%%:*}
  allowed_host "$host" || { echo "host not allowed: $host" >&2; exit 2; }
  # --max-filesize bounds responses that advertise a length; the head pipe caps
  # chunked responses that do not, so StdioCollector never sees more than the
  # ceiling regardless of what the server sends.
  curl --silent --show-error --fail --proto '=https' \
    --max-filesize "$MAX_FETCH_BYTES" --max-time "$FETCH_TIMEOUT" \
    -- "$url" | head -c "$MAX_FETCH_BYTES"
}

read_state() {
  path=$1
  [ -e "$path" ] || exit 0
  # Validate the descriptor we hold, not the name, so a symlink swapped in after
  # open cannot redirect the read to another file.
  {
    want=$(readlink -f -- "$(dirname -- "$path")")/$(basename -- "$path")
    got=$(readlink -- /proc/self/fd/3 2>/dev/null || true)
    [ "$got" = "$want" ] || exit 3
    [ -f /proc/self/fd/3 ] || exit 3
    head -c "$MAX_STATE_BYTES" <&3
  } 3<"$path"
}

write_state() {
  path=$1
  dir=$(dirname -- "$path")
  mkdir -p -- "$dir"
  tmp=$(mktemp -- "$dir/.omarchiumdash.XXXXXX") || exit 1
  trap 'rm -f -- "$tmp"' EXIT
  head -c "$MAX_STATE_BYTES" > "$tmp"
  mv -fT -- "$tmp" "$path"
  trap - EXIT
}

case ${1:-} in
  fetch) shift; fetch "$@" ;;
  read-state) shift; read_state "$@" ;;
  write-state) shift; write_state "$@" ;;
  *) echo "usage: io.sh {fetch|read-state|write-state} ..." >&2; exit 64 ;;
esac
