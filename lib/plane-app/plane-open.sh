#!/usr/bin/env bash
#
# plane-open.sh — open a Plane link in the desktop app via the plane:// scheme.
#
# Accepts any of:
#   http://plane.localhost:1800/pb/browse/PB-110   (the raw browser link)
#   http://localhost:1800/pb/browse/PB-110
#   plane://pb/browse/PB-110                        (already a deep link)
#   pb/browse/PB-110                                (bare path)
#
# and runs `open` on the corresponding plane:// URL, which launches/raises the
# Plane app and navigates to that exact page.
#
# Usage:
#   ./plane-open.sh 'http://plane.localhost:1800/pb/browse/PB-110'
#
set -euo pipefail

if [[ $# -lt 1 || -z "${1:-}" ]]; then
  echo "usage: plane-open.sh <plane-url-or-path>" >&2
  exit 1
fi

input="$1"

# Already a deep link? open as-is.
if [[ "$input" == plane://* ]]; then
  open "$input"
  exit 0
fi

# Strip a leading http(s)://host[:port]/ to get the bare path.
path="$input"
path="${path#http://}"
path="${path#https://}"
# Drop the host[:port] segment if one is present.
case "$path" in
  localhost*|plane.localhost*|127.0.0.1*)
    path="${path#*/}"   # remove everything up to and including the first slash
    ;;
esac
path="${path#/}"   # trim any leading slash

if [[ -z "$path" ]]; then
  echo "error: no path found in '$input'" >&2
  exit 1
fi

open "plane://${path}"
