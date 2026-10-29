#!/usr/bin/env bash
# Offline tests of bin/dsh-romeo against a fake ROMEO (tests/fake-romeo): fake ssh, romeollmtool,
# squeue and gateway, and a fake dsh that records how it was started. No network, no GPU.
#
#   tests/run.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
FAKE=$HERE/fake-romeo/bin
T=$(mktemp -d "${TMPDIR:-/tmp}/dsh-romeo-test.XXXXXX")
REAL_DSH=$(command -v dsh || true)   # before the fake dsh comes first in PATH
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')

export FAKE_ROMEO_STATE=$T/state FAKE_ROMEO_HOME=$T/romeo-home FAKE_GATEWAY_PORT=$PORT FAKE_LOAD_SECONDS=2
export PATH=$FAKE:$PATH ROMEOLLMTOOL=$FAKE/romeollmtool DSH_ROMEO_DSH=$FAKE/dsh DSH_ROMEO_POLL=1
export DSH_ROMEO_CONFIG_DIR=$T/config DSH_ROMEO_SOCKET=$T/ctl DSH_ROMEO_PORT=$PORT
export ROMEO_SSH_HOST=romeo ROMEO_PROJECT=r000000
unset DSH_ROMEO_FICHE DSH_ROMEO_SEARXNG_URL DSH_ROMEO_EFFORT DSH_ROMEO_TIME
mkdir -p "$FAKE_ROMEO_STATE" "$FAKE_ROMEO_HOME"

python3 "$FAKE/gateway.py" "$PORT" &
gateway=$!
trap 'kill $gateway 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done

pass=0 fail=0
check() {  # check "name" condition...
  local name=$1; shift
  if "$@"; then pass=$((pass + 1)); printf '  ok    %s\n' "$name"
  else fail=$((fail + 1)); printf '  FAIL  %s\n' "$name"; printf '%s\n' "$out" | sed 's/^/        | /'; fi
}
has() { grep -q -- "$1" <<<"$out"; }
has_ere() { grep -qE -- "$1" <<<"$out"; }
lacks() { ! grep -q -- "$1" <<<"$out"; }
run() { out=$("$ROOT/bin/dsh-romeo" "$@" 2>&1); code=$?; }

echo "dsh-romeo offline tests"

run --version
check "--version" has "dsh-romeo 0."

run --status
check "status: gateway stopped, no job, tunnel closed" has "gateway stopped"
check "status: no model job" has "no model job of dsh-deepseek-v4.1-flash-1017-1m"

run
check "start before --setup: fiche missing" has "not found on ROMEO. Run: dsh-romeo --setup"
check "start before --setup: exit 1" test "$code" = 1
check "start starts the gateway" test -e "$FAKE_ROMEO_STATE/gateway"

run --setup
check "--setup copies the fiche" test -f "$FAKE_ROMEO_HOME/.romeollmtool/configs/dsh-deepseek-v4.1-flash-1017-1m.yaml"

run
check "start without a job: says --launch" has "Start one with: dsh-romeo --launch"
check "start without a job: exit 1" test "$code" = 1

ROMEO_PROJECT='' run --launch
check "--launch without a project: says so" has "no project code"

run --launch 9
check "--launch 9: refused" has "--launch takes 1 to 8 jobs"

run --launch
check "--launch: job submitted" has "model job 900001 submitted"
check "--launch: waits, then ready" has "ready"
check "--launch: dsh web with the overlay" grep -q "args: web --patch $DSH_ROMEO_CONFIG_DIR/dsh.patch.yml" "$FAKE_ROMEO_STATE/dsh-call"
check "--launch: dsh gets the gateway key" grep -q "key: test-key" "$FAKE_ROMEO_STATE/dsh-call"
overlay=$DSH_ROMEO_CONFIG_DIR/dsh.patch.yml
check "overlay: served model of the fiche" grep -q "model: dsh-deepseek-v4.1-flash-1017-1m" "$overlay"
check "overlay: 1M context from the fiche" grep -q "contextWindow: 1048576" "$overlay"
check "overlay: output limit from the fiche" grep -q "maxTokens: 262144" "$overlay"
check "overlay: tunnel port" grep -q "baseURL: http://127.0.0.1:$PORT/v1" "$overlay"
check "overlay: no key written" bash -c "! grep -q test-key '$overlay'"
check "overlay: no web search by default" bash -c "! grep -q searxng '$overlay'"

run headless "fix the tests"
check "job running: straight to dsh" lacks submitted
check "headless and its task pass through" grep -q "args: headless --patch .* fix the tests" "$FAKE_ROMEO_STATE/dsh-call"

DSH_ROMEO_SEARXNG_URL=http://127.0.0.1:8888 run
check "overlay: SearXNG when configured" grep -q 'baseURL: "http://127.0.0.1:8888"' "$overlay"
check "overlay: SearXNG plugin path" grep -q "name: $ROOT/share/web-search-searxng.mjs" "$overlay"

DSH_ROMEO_EFFORT=none run headless "disabled thinking"
check "none: dsh provider uses off" grep -q '^        reasoning: off$' "$overlay"
check "none: dsh agent uses off" grep -q '^    reasoningEffort: off$' "$overlay"

# Other clients: the endpoint as variables, a summary, any program, codex's flags.
env_out=$("$ROOT/bin/dsh-romeo" --env 2>/dev/null)
out=$env_out
check "--env: base URL" has "export OPENAI_BASE_URL=http://127.0.0.1:$PORT/v1"
check "--env: key" has "export OPENAI_API_KEY=test-key"
check "--env: Anthropic endpoint" has "export ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT"
check "--env: model" has "export DSH_ROMEO_MODEL=dsh-deepseek-v4.1-flash-1017-1m"
only_exports() { ! grep -v '^export ' <<<"$env_out" | grep -q .; }
check "--env: stdout holds only exports" only_exports
evals() { (eval "$env_out" && [ "$OPENAI_API_KEY" = test-key ]); }
check "--env: eval works" evals

out=$("$ROOT/bin/dsh-romeo" --serve 2>/dev/null)
check "--serve: base URL" has "base URL   http://127.0.0.1:$PORT/v1"
check "--serve: model" has "model      dsh-deepseek-v4.1-flash-1017-1m"
check "--serve: no key printed" lacks test-key

run --run env
check "--run: OpenAI variables" has "OPENAI_API_BASE=http://127.0.0.1:$PORT/v1"
check "--run: aider model" has "AIDER_MODEL=openai/dsh-deepseek-v4.1-flash-1017-1m"
check "--run: opencode config" has "OPENCODE_CONFIG=$DSH_ROMEO_CONFIG_DIR/opencode.json"
oc=$DSH_ROMEO_CONFIG_DIR/opencode.json
check "opencode.json: valid JSON" python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$oc"
check "opencode.json: default model" grep -q '"model": "romeo/dsh-deepseek-v4.1-flash-1017-1m"' "$oc"
check "opencode.json: key from the environment" grep -q '{env:ROMEO_LLM_KEY}' "$oc"
check "opencode.json: no key written" bash -c "! grep -q test-key '$oc'"

run --run codex exec "hello"
check "--run codex: provider" grep -q "arg: model_provider=romeo" "$FAKE_ROMEO_STATE/codex-call"
check "--run codex: Responses API" grep -q 'wire_api = "responses"' "$FAKE_ROMEO_STATE/codex-call"
check "--run codex: its own arguments follow" grep -q "arg: hello" "$FAKE_ROMEO_STATE/codex-call"
check "--run codex: key in its environment" grep -q "ROMEO_LLM_KEY=test-key" "$FAKE_ROMEO_STATE/codex-call"

run --run
check "--run without a command: says so" has "--run needs a command"

DSH_ROMEO_GATEWAY=fast run headless "fast"
check "fast gateway: files copied to ROMEO" test -x "$FAKE_ROMEO_HOME/.dsh-romeo/gateway/start.sh"
check "fast gateway: falls back when it cannot start" has "fast gateway unavailable"
check "fast gateway: dsh still starts" grep -q "args: headless --patch .* fast" "$FAKE_ROMEO_STATE/dsh-call"

if [ "$(uname)" = Darwin ]; then
  mkdir -p "$T/home/.dsh/profiles/desktop"
  printf '%s\n' '- id: my-own' '  config: {}' >"$T/home/.dsh/profiles/desktop/cordis.patch.yml"
  touch "$FAKE_ROMEO_STATE/app-running"
  HOME=$T/home run --desktop
  check "--desktop: opens the app with the key" grep -q "args: -a DeepSeek Harness --env ROMEO_LLM_KEY=test-key" "$FAKE_ROMEO_STATE/open-call"
  check "--desktop: quits the running app first" grep -q "quit app" "$FAKE_ROMEO_STATE/osascript-call"
  check "--desktop: overlay in the desktop profile" grep -q "provider: romeo" "$T/home/.dsh/profiles/desktop/cordis.patch.yml"
  check "--desktop: your own patch kept" grep -q "my-own" "$T/home/.dsh/profiles/desktop/cordis.patch.yml.before-dsh-romeo"
  FAKE_NO_APP=1 HOME=$T/home run --desktop
  check "--desktop without the app: says so" has "app is not installed"
fi

run --status
check "status: job listed" has "model job 900001 running"

run --stop
check "--stop: job stopped" has "model job 900001 stopped"
check "--stop: no job left" bash -c "! grep -q . '$FAKE_ROMEO_STATE/jobs'"

DSH_ROMEO_FICHE=no-such-fiche run
check "unknown fiche: clear error" has "fiche 'no-such-fiche' not found"

FAKE_ROMEO_UNREACHABLE=1 DSH_ROMEO_SOCKET=$T/ctl2 run --status
check "ROMEO unreachable: clear error" has "cannot connect to 'romeo' over SSH"

if [ -n "$REAL_DSH" ]; then
  # The overlay must compose with the real dsh (fresh DSH_HOME, no network needed).
  DSH_ROMEO_EFFORT=none DSH_ROMEO_SEARXNG_URL=http://127.0.0.1:8888 run --launch
  composed=$(cd "$T" && DSH_HOME=$T/dsh-home "$REAL_DSH" --profile headless --patch "$overlay" --dump-config 2>&1)
  out=$composed
  check "real dsh: romeo is the default provider" has "provider: romeo"
  check "real dsh: SearXNG plugin inserted" has "id: dsh-romeo-searxng"
  check "real dsh: disabled thinking uses off" has_ere "reasoning: ['\"]?off['\"]?([[:space:]]|$)"
  check "real dsh: overlay activates without validation errors" lacks "ValidationError"
fi

# The romeo skill: frontmatter dsh accepts, links that resolve, and its env.sh against the fake ROMEO.
SKILL=$ROOT/share/skills/romeo
out=$(sed -n '1,/^---$/{/^---$/d;p;}' "$SKILL/SKILL.md" | sed -n '1,4p')
check "skill: name romeo" has "^name: romeo$"
check "skill: description" has "^description: ."
out=$(cd "$SKILL" && for md in SKILL.md references/*.md; do
  grep -oE '\]\([^)#]+\)' "$md" | sed 's/^](//; s/)$//' | grep -v '^https\?:' | while read -r l; do
    [ -e "$(dirname "$md")/$l" ] || echo "$md: $l"; done; done)
check "skill: relative links resolve" test -z "$out"
out=$(printf 'ROMEO_SSH_HOST=romeo\nROMEO_PROJECT=r000000\n' >"$T/skill-config"; mkdir -p "$T/xdg/dsh-romeo"; cp "$T/skill-config" "$T/xdg/dsh-romeo/config"
  env -u ROMEO_PROJECT XDG_CONFIG_HOME=$T/xdg bash -c '. "$1"; echo "project=$ROMEO_PROJECT"; R "echo remote-user=\$USER"' _ "$SKILL/scripts/env.sh" 2>&1)
check "skill env.sh: project from dsh-romeo's config" has "project=r000000"
check "skill env.sh: R runs over ssh" has "remote-user=demo"

for f in "$ROOT/bin/dsh-romeo" "$ROOT/install.sh" "$HERE/run.sh" "$SKILL/scripts/env.sh"; do
  out=$(bash -n "$f" 2>&1); check "syntax: $(basename "$f")" test -z "$out"
done
if command -v shellcheck >/dev/null; then
  out=$(shellcheck -S warning "$ROOT/bin/dsh-romeo" "$ROOT/install.sh" 2>&1); check "shellcheck" test -z "$out"
  out=$(shellcheck -S warning -s bash "$SKILL/scripts/env.sh" 2>&1); check "shellcheck: skill env.sh" test -z "$out"
fi

out=$(DSH_ROMEO_RLT_CHECK=/bin/sh bash "$ROOT/install.sh" --yes 2>&1); code=$?
check "install.sh on ROMEO: says to run it on your computer" has "run install.sh on your own computer"
check "install.sh on ROMEO: exit 1" test "$code" = 1

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
