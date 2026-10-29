#!/usr/bin/env bash
# Installer regression tests. Fake npm refuses installs without a private prefix,
# reproducing the /usr/local EACCES case without touching npm configuration.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/dsh-install.XXXXXX")
trap 'rm -rf "$T"' EXIT
FAKE=$ROOT/tests/fake-romeo/bin
export FAKE_ROMEO_STATE=$T/state FAKE_ROMEO_HOME=$T/romeo-home
export FAKE_INSTALL_LOG=$T/npm.log FAKE_REAL_SSH=$FAKE/ssh
export DSH_ROMEO_CONFIG_DIR="$T/config with spaces" DSH_ROMEO_SOCKET=$T/ctl
export DSH_ROMEO_DSH=$T/not-installed ROMEO_PROJECT=r000000 ROMEO_SSH_HOST=romeo
export PATH=$T/tools:$FAKE:$PATH ROMEOLLMTOOL=$FAKE/romeollmtool
mkdir -p "$T/tools" "$FAKE_ROMEO_STATE" "$FAKE_ROMEO_HOME"
cat >"$T/tools/node" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in
  process.platform) echo "${FAKE_NODE_PLATFORM:-linux}" ;;
  *) echo 22 ;;
esac
SH
cat >"$T/tools/npm" <<'SH'
#!/usr/bin/env bash
set -eu
echo "$*" >>"$FAKE_INSTALL_LOG"
[ "$1" = install ] && [ "$2" = --global ] && [ "$3" = --prefix ] \
  || { echo "EACCES: refusing default /usr/local prefix" >&2; exit 13; }
prefix=$4
[ "$5" = @deepseek-ai/dsh ] || exit 2
mkdir -p "$prefix/bin"
printf '#!/usr/bin/env bash\necho fake-dsh-0.2.1\n' >"$prefix/bin/dsh"
chmod +x "$prefix/bin/dsh"
SH
cat >"$T/tools/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *sacctmgr*) printf 'rlt=yes\naccount=r000000\n' ;;
  *) exec "$FAKE_REAL_SSH" "$@" ;;
esac
SH
chmod +x "$T/tools/"*

out=$(bash "$ROOT/install.sh" --yes --bin-dir "$T/bin with spaces" 2>&1) \
  || { printf '%s\n' "$out"; exit 1; }
grep -q -- "--global --prefix $DSH_ROMEO_CONFIG_DIR/npm @deepseek-ai/dsh" "$FAKE_INSTALL_LOG"
test -L "$T/bin with spaces/dsh-romeo"
test -f "$FAKE_ROMEO_HOME/.romeollmtool/configs/dsh-deepseek-v4.1-flash-1017-1m.yaml"
echo '  ok    installer uses user-owned npm prefix (no sudo or global config)'
unset DSH_ROMEO_DSH
# shellcheck source=/dev/null
. "$DSH_ROMEO_CONFIG_DIR/config"
test "$DSH_ROMEO_DSH" = "$DSH_ROMEO_CONFIG_DIR/npm/bin/dsh"
test "$("$DSH_ROMEO_DSH" --version)" = fake-dsh-0.2.1
echo '  ok    saved dsh executable works with spaces, without PATH changes'
bash "$ROOT/install.sh" --yes --bin-dir "$T/bin with spaces" >/dev/null 2>&1
test "$(wc -l <"$FAKE_INSTALL_LOG" | tr -d ' ')" = 1
echo '  ok    reinstall preserves settings and reuses private dsh'

export FAKE_NODE_PLATFORM=win32
if out=$(bash "$ROOT/install.sh" --yes 2>&1); then echo 'FAIL: Windows Node accepted in WSL'; exit 1; fi
[[ $out = *"install Linux Node.js inside WSL"* ]]
echo '  ok    Windows Node in WSL gets actionable guidance'
echo '4 passed, 0 failed'
