#!/usr/bin/env bash
# Installs the plugins of share/plugins.txt in one dsh profile, turned off: the package goes into
# the profile, its bundle stays out of the profile's selection, and the Plugins page of dsh turns it
# on. A plugin already in the profile keeps its state (enabled or not); one whose installed version
# no longer fits the running dsh (its engines.dsh range) is moved to the plugin's latest version.
# A pinned version that this dsh refuses falls back to the latest version too.
#
#   share/optional-plugins.sh PROFILE [DSH]   DSH: the dsh that manages the profile (default: dsh)
set -uo pipefail

PROFILE=$1 CLI=${2:-dsh}
LIST=$(dirname "$0")/plugins.txt
DIR=${DSH_HOME:-$HOME/.dsh}/profiles/$PROFILE
MANIFEST=$DIR/package.json
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsh-romeo-plugins.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
DSH_VERSION=$("$CLI" --version 2>/dev/null | tail -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[-.A-Za-z0-9]*' | head -1)
# npm's own semver, next to the real npm-cli.js (npm's prefix is not always the global modules').
SEMVER=${DSH_ROMEO_SEMVER:-$(node -e '
  const fs = require("fs"), path = require("path"), npm = fs.realpathSync(process.argv[1])
  console.log(path.dirname(require.resolve("semver", { paths: [path.join(path.dirname(npm), "..")] })))
' "$(command -v npm)" 2>/dev/null)}

installed() {  # $1: package name, a dependency of the profile
  [ -f "$MANIFEST" ] && node -e 'process.exit(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).dependencies?.[process.argv[2]] ? 0 : 1)' "$MANIFEST" "$1"
}

selected() {  # $1: package name, in dsh.profile.bundles (on)
  node -e 'process.exit((JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).dsh?.profile?.bundles ?? []).includes(process.argv[2]) ? 0 : 1)' "$MANIFEST" "$1"
}

turn_off() {  # $1: package name, taken out of dsh.profile.bundles
  node -e '
    const fs = require("fs"), [file, name] = process.argv.slice(1)
    const data = JSON.parse(fs.readFileSync(file, "utf8")), profile = data.dsh?.profile
    if (profile?.bundles) {
      profile.bundles = profile.bundles.filter((b) => b !== name)
      fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n")
    }' "$MANIFEST" "$1"
}

# Exit 0 when the installed package $1 declares no dsh range or one the running dsh satisfies; also
# 0 when either version or npm's semver cannot be read (nothing to decide from).
fits() {
  [ -n "$DSH_VERSION" ] && [ -d "$SEMVER" ] || return 0
  node -e '
    const fs = require("fs"), semver = require(process.argv[1])
    let pkg
    try { pkg = JSON.parse(fs.readFileSync(process.argv[2], "utf8")) } catch { process.exit(0) }
    const range = pkg.dsh?.engines?.dsh ?? pkg.engines?.dsh
    process.exit(!range || semver.satisfies(process.argv[3], range, { includePrerelease: true }) ? 0 : 1)
  ' "$SEMVER" "$DIR/node_modules/$1/package.json" "$DSH_VERSION"
}

add() {  # $1: spec; 0 when it is now a dependency of the profile
  (cd "$WORK" && "$CLI" plugin --profile "$PROFILE" add "$1") >"$WORK/log" 2>&1 && installed "${1%@*}"
}

version_of() { node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version' "$DIR/node_modules/$1/package.json" 2>/dev/null; }

status=0
while read -r spec what; do
  case $spec in '' | \#*) continue ;; esac
  name=${spec%@*}
  if installed "$name"; then
    if fits "$name"; then
      echo "$name: already in the $PROFILE profile, left as it is"
      continue
    fi
    was_on=0
    selected "$name" && was_on=1
    old=$(version_of "$name")
    if add "$name@latest" && fits "$name"; then
      [ "$was_on" = 1 ] || turn_off "$name"
      echo "$name: $old does not fit dsh $DSH_VERSION, moved to $(version_of "$name") ($([ "$was_on" = 1 ] && echo on || echo off); newer than the version reviewed for dsh-romeo)"
    else
      echo "$name: $old does not fit dsh $DSH_VERSION and no newer version does yet"
      status=1
    fi
  elif add "$spec"; then
    turn_off "$name"
    echo "$name: installed, off ($what)"
  elif add "$name@latest"; then
    turn_off "$name"
    echo "$name: $spec refused by dsh $DSH_VERSION, installed $(version_of "$name") instead, off (newer than the version reviewed for dsh-romeo)"
  else
    echo "$name: not installed ($(grep -m1 -i -E 'error|refus|incompatible|requires' "$WORK/log" || tail -1 "$WORK/log"))"
    status=1
  fi
done <"$LIST"
exit $status
