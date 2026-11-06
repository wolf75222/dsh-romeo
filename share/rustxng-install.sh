#!/bin/bash
# Run on ROMEO by dsh-romeo (bin/dsh-romeo, ensure_web): RustXNG's static binary for web search,
# downloaded once and checked against its pinned SHA-256. $1 the checksum, $2 the URL, $3 "check":
# only say whether it is there. Prints ok, installed, missing, or the reason it failed.
set -u
sum=$1 url=$2 mode=${3:-install}
bin=$HOME/.dsh-romeo/rustxng/rustxng-v0.28.0-x86_64-unknown-linux-musl
sha() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }
if [ -x "$bin" ] && [ "$(sha "$bin")" = "$sum" ]; then echo ok; exit 0; fi
[ "$mode" != check ] || { echo missing; exit 1; }
mkdir -p "$(dirname "$bin")" || { echo "cannot create $(dirname "$bin")"; exit 1; }
tmp=$(mktemp "$bin.XXXXXX") || { echo "cannot write in $(dirname "$bin") (home full?)"; exit 1; }
if ! err=$(curl -sSfL -m 180 -o "$tmp" "$url" 2>&1); then rm -f "$tmp"; echo "download failed: ${err##*: }"; exit 1; fi
if [ "$(sha "$tmp")" != "$sum" ]; then rm -f "$tmp"; echo "checksum mismatch: not installed"; exit 1; fi
chmod 700 "$tmp" && mv "$tmp" "$bin" && echo installed
