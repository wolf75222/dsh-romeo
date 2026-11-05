#!/usr/bin/env bash
# Installs the plugins of share/plugins.txt in one dsh profile, turned off: the package goes into
# the profile, its bundle stays out of the profile's selection, and the Plugins page of dsh turns it
# on. A plugin already in the profile is left as it is (enabled or not).
#
#   share/optional-plugins.sh PROFILE [DSH]   DSH: the dsh that manages the profile (default: dsh)
set -uo pipefail

PROFILE=$1 CLI=${2:-dsh}
LIST=$(dirname "$0")/plugins.txt
MANIFEST=${DSH_HOME:-$HOME/.dsh}/profiles/$PROFILE/package.json
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsh-romeo-plugins.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

installed() {  # $1: package name, a dependency of the profile
  [ -f "$MANIFEST" ] && node -e 'process.exit(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).dependencies?.[process.argv[2]] ? 0 : 1)' "$MANIFEST" "$1"
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

status=0
while read -r spec what; do
  case $spec in '' | \#*) continue ;; esac
  name=${spec%@*}
  if installed "$name"; then
    echo "$name: already in the $PROFILE profile, left as it is"
  elif (cd "$WORK" && "$CLI" plugin --profile "$PROFILE" add "$spec") >"$WORK/log" 2>&1 && installed "$name"; then
    turn_off "$name"
    echo "$name: installed, off ($what)"
  else
    echo "$name: not installed ($(grep -m1 -i -E 'error|refus|incompatible|requires' "$WORK/log" || tail -1 "$WORK/log"))"
    status=1
  fi
done <"$LIST"
exit $status
