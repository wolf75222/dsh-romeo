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
# The fast gateway's start.sh must not find romeollmtool's real Python, even on a ROMEO login node.
export ROMEOLLMTOOL_PYTHON=$T/no-such-python
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
  check "--desktop: the app's own rows kept in the patch" grep -q "^- id: my-own" "$T/home/.dsh/profiles/desktop/cordis.patch.yml"
  printf '%s\n' '- id: ui-theme' '  config: { theme: dark }' >>"$T/home/.dsh/profiles/desktop/cordis.patch.yml"
  touch "$FAKE_ROMEO_STATE/app-running"
  HOME=$T/home run --desktop
  check "--desktop again: a setting the app saved is kept" grep -q "^- id: ui-theme" "$T/home/.dsh/profiles/desktop/cordis.patch.yml"
  check "--desktop again: dsh-romeo's rows once" test "$(grep -c '^- id: llm-pi-ai' "$T/home/.dsh/profiles/desktop/cordis.patch.yml")" = 1
  # The app's own row under an id dsh-romeo also uses stays; voice reads the desktop profile's bundles.
  DP=$T/home/.dsh/profiles/desktop
  printf '%s\n' '- id: tool-subagent' '  disabled: false' >>"$DP/cordis.patch.yml"
  echo '{"dsh":{"profile":{"bundles":["@deepseek-ai/dsh-experimental-voice-input-bundle"]}}}' >"$DP/package.json"
  touch "$FAKE_ROMEO_STATE/app-running"
  DSH_ROMEO_VOICE_PORT=$PORT HOME=$T/home run --voice on --launch --desktop
  check "--desktop: the app's own tool-subagent row kept" bash -c "grep -A1 '^- id: tool-subagent\$' '$DP/cordis.patch.yml' | grep -q 'disabled: false'"
  check "--desktop voice: the app's voice bundle configured, not inserted again" bash -c "grep -q '^- id: speech-to-text' '$DP/cordis.patch.yml' && ! grep -q 'dsh-experimental-client-ui-voice-input' '$DP/cordis.patch.yml'"
  rm -f "$DP/package.json"
  run --voice off --status
  # Kimi with DeepSeek subagents in the app: the presets come from the app's own dsh.
  printf '%s\n' '#!/usr/bin/env bash' 'sed s/preset-standard/preset-of-the-app/ "$(dirname "$0")/dump-web.yml"' >"$T/app-dsh"
  cp "$HERE/fake-romeo/dump-web.yml" "$T/dump-web.yml"
  chmod +x "$T/app-dsh"
  touch "$FAKE_ROMEO_STATE/app-running"
  DSH_ROMEO_DESKTOP_DSH=$T/app-dsh HOME=$T/home run --models kimi+deepseek --launch --desktop
  check "--desktop kimi+deepseek: presets of the app's dsh" grep -q "^- id: preset-of-the-app" "$T/home/.dsh/profiles/desktop/cordis.patch.yml"
  check "--desktop kimi+deepseek: the app's settings still kept" grep -q "^- id: ui-theme" "$T/home/.dsh/profiles/desktop/cordis.patch.yml"
  touch "$FAKE_ROMEO_STATE/app-running"
  DSH_ROMEO_DESKTOP_DSH=$T/app-dsh HOME=$T/home run --models deepseek --desktop
  check "--desktop back to deepseek: no subagent preset left" bash -c "! grep -q 'preset-of-the-app' '$T/home/.dsh/profiles/desktop/cordis.patch.yml'"
  # The Kimi job ends (scancel), the DeepSeek job stays for the tests below.
  grep -v kimi "$FAKE_ROMEO_STATE/jobs" >"$FAKE_ROMEO_STATE/jobs.new"; mv "$FAKE_ROMEO_STATE/jobs.new" "$FAKE_ROMEO_STATE/jobs"
  run --models deepseek --status
  FAKE_NO_APP=1 HOME=$T/home run --desktop
  check "--desktop without the app: says so" has "app is not installed"
fi

run --status
check "status: job listed" has "model job 900001 running"

run --stop
check "--stop: job stopped" has "model job 900001 stopped"
check "--stop: no job left" bash -c "! grep -q . '$FAKE_ROMEO_STATE/jobs'"

# --launch after the command: dsh-romeo --serve --launch, as after --desktop.
run --serve --launch
check "--serve --launch: job submitted" has "model job .* submitted (dsh-deepseek-v4.1-flash-1017-1m"
check "--serve --launch: endpoint printed" has "base URL   http://127.0.0.1:$PORT/v1"
run --stop
run --serve --models kimi --launch
check "--serve --models kimi --launch: Kimi job" has "submitted (dsh-kimi-k3.1-pro-1m"
run --models kimi --stop
run --models deepseek --status
run --serve --env
check "--serve --env: refused" has "do not combine"

run --models kimi --launch
check "kimi: job of its fiche" grep -q "dsh-kimi-k3.1-pro-1m" "$FAKE_ROMEO_STATE/jobs"
check "kimi: ready" has "Kimi-K3.1-Pro ready"
check "kimi overlay: its served model" grep -q "model: dsh-kimi-k3.1-pro-1m" "$overlay"
check "kimi overlay: its name" grep -q "name: Kimi-K3.1-Pro (ROMEO)" "$overlay"
check "kimi overlay: no subagent model" bash -c "! grep -q agentOptions '$overlay'"
run --models kimi --stop
run --models kimi --launch 2
check "kimi: one job only (32 GPUs)" has "one job fits in ROMEO's 60-GPU limit"
run --models kimi --launch
run --models kimi --launch
check "kimi: a second --launch queues no second job" test "$(grep -c ' dsh-kimi-k3.1-pro-1m ' "$FAKE_ROMEO_STATE/jobs")" = 1
check "kimi: and says one is already there" has "already queued or running"
DSH_ROMEO_MODELS=deepseek run --stop
check "--stop after switching models: the Kimi job too" bash -c "test -f '$FAKE_ROMEO_STATE/jobs' && ! grep -q kimi '$FAKE_ROMEO_STATE/jobs'"
run --models gpt
check "unknown models: clear error" has "models: deepseek, kimi or kimi+deepseek"
run --status
check "models remembered: kimi again without --models" has "no model job of dsh-kimi-k3.1-pro-1m"
DSH_ROMEO_MODELS=deepseek run --status
check "models: the environment wins over the remembered choice" has "no model job of dsh-deepseek-v4.1-flash-1017-1m"

# Kimi as the agent, DeepSeek for its subagents: two jobs, both models waited for and listed.
run --models kimi+deepseek --launch headless "both"
check "kimi+deepseek: a Kimi job" grep -q " dsh-kimi-k3.1-pro-1m " "$FAKE_ROMEO_STATE/jobs"
check "kimi+deepseek: a DeepSeek job" grep -q " dsh-deepseek-v4.1-flash-1017-1m " "$FAKE_ROMEO_STATE/jobs"
check "kimi+deepseek: Kimi ready" has "Kimi-K3.1-Pro ready"
check "kimi+deepseek: DeepSeek ready for the subagents" has "DeepSeek-V4.1-Flash-1017 ready for the subagents"
check "kimi+deepseek overlay: both models" bash -c "grep -q 'id: dsh-kimi-k3.1-pro-1m' '$overlay' && grep -q 'id: dsh-deepseek-v4.1-flash-1017-1m' '$overlay'"
check "kimi+deepseek overlay: DeepSeek takes images" bash -c "grep -A5 'id: dsh-deepseek-v4.1-flash-1017-1m' '$overlay' | grep -q 'input: \[ text, image \]'"
check "kimi+deepseek overlay: Kimi text only (--language-model-only)" bash -c "grep -A5 'id: dsh-kimi-k3.1-pro-1m' '$overlay' | grep -q 'input: \[ text \]'"
check "kimi+deepseek overlay: Kimi by default" bash -c "grep -A3 'id: agent-default-model' '$overlay' | grep -q 'model: dsh-kimi-k3.1-pro-1m'"
sub=$(sed -n '/^# Subagents/,$p' "$overlay")
out=$sub
check "kimi+deepseek overlay: the preset restated" has "^- id: preset-standard$"
check "kimi+deepseek overlay: subagents on DeepSeek" has "^              agentOptions:$"
check "kimi+deepseek overlay: in the subagent tool" bash -c "grep -A6 '^          - id: tool-subagent\$' <<<\"\$1\" | grep -q 'model: dsh-deepseek-v4.1-flash-1017-1m'" _ "$sub"
check "kimi+deepseek overlay: fork keeps the agent's model" bash -c "! grep -A6 'id: tool-subagent-fork' <<<\"\$1\" | grep -q agentOptions" _ "$sub"
check "kimi+deepseek overlay: block scalars kept" has "^            First paragraph.$"
check "kimi+deepseek overlay: their blank lines kept" bash -c "grep -A1 'First paragraph.' <<<\"\$1\" | tail -1 | grep -q '^$'" _ "$sub"
check "kimi+deepseek overlay: rows without the tool left out" lacks "id: tool-todo"
check "kimi+deepseek overlay: no dump comments" lacks "# =="
run --models kimi+deepseek --launch
check "kimi+deepseek: no second DeepSeek job" test "$(grep -c ' dsh-deepseek-v4.1-flash-1017-1m ' "$FAKE_ROMEO_STATE/jobs")" = 1
env_out=$(DSH_ROMEO_MODELS=kimi+deepseek "$ROOT/bin/dsh-romeo" --env 2>/dev/null)
out=$env_out
check "kimi+deepseek --env: Kimi" has "export DSH_ROMEO_MODEL=dsh-kimi-k3.1-pro-1m"
check "kimi+deepseek --env: DeepSeek for subagents" has "export DSH_ROMEO_SUB_MODEL=dsh-deepseek-v4.1-flash-1017-1m"
check "kimi+deepseek --env: Claude Code's Haiku on DeepSeek" has "export ANTHROPIC_DEFAULT_HAIKU_MODEL=dsh-deepseek-v4.1-flash-1017-1m"
check "kimi+deepseek opencode.json: valid, both models" python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); m=c["provider"]["romeo"]["models"]; assert len(m)==2 and c["small_model"]=="romeo/dsh-deepseek-v4.1-flash-1017-1m"' "$DSH_ROMEO_CONFIG_DIR/opencode.json"
DSH_ROMEO_MODELS=kimi+deepseek run --stop
check "kimi+deepseek --stop: both jobs" bash -c "! grep -q . '$FAKE_ROMEO_STATE/jobs'"
run --models deepseek --status
check "models: back to deepseek" has "no model job of dsh-deepseek-v4.1-flash-1017-1m"

# Voice input: a Whisper job, dsh's microphone wired to it, remembered like --models.
DSH_ROMEO_VOICE_PORT=$PORT run --voice on --launch headless "voice"
check "voice: a Whisper job" grep -q " dsh-whisper-large-v3-turbo " "$FAKE_ROMEO_STATE/jobs"
check "voice: ready" has "voice input ready"
check "voice overlay: the provider plugin" grep -q "name: $ROOT/share/speech-whisper-romeo.mjs" "$overlay"
check "voice overlay: Whisper selected" grep -q "defaultProvider: dsh-romeo-whisper" "$overlay"
check "voice overlay: straight to the job, not the gateway" grep -q "baseURL: http://127.0.0.1:$PORT/v1" "$overlay"
check "voice overlay: the job's key from a file" grep -q "apiKeyFile: $DSH_ROMEO_CONFIG_DIR/whisper.key" "$overlay"
check "voice: the job's key written" grep -qx "test-key-of-the-job-0123456789" "$DSH_ROMEO_CONFIG_DIR/whisper.key"
check "voice overlay: the microphone button" grep -q "dsh-experimental-client-ui-voice-input" "$overlay"
check "voice overlay: no local SenseVoice" bash -c "! grep -q sensevoice '$overlay'"
run --status
check "voice: remembered, its job listed" has "dsh-whisper-large-v3-turbo"
# A Whisper job that starts after dsh: a watcher opens the tunnel and writes the key by itself.
run --voice on --stop
rm -f "$DSH_ROMEO_CONFIG_DIR/whisper.key"
echo dsh-whisper-large-v3-turbo >"$FAKE_ROMEO_STATE/pending"
DSH_ROMEO_VOICE_PORT=$PORT run --voice on --launch headless "late voice"
check "late voice: waiting for its GPU" has "voice input waiting for its GPU"
check "late voice: no key yet" test ! -e "$DSH_ROMEO_CONFIG_DIR/whisper.key"
rm -f "$FAKE_ROMEO_STATE/pending"
for _ in $(seq 1 20); do [ -s "$DSH_ROMEO_CONFIG_DIR/whisper.key" ] && break; sleep 0.5; done
check "late voice: the watcher wrote the key once the job runs" grep -qx "test-key-of-the-job-0123456789" "$DSH_ROMEO_CONFIG_DIR/whisper.key"
check "late voice: and noted the tunnel" test -s "$DSH_ROMEO_SOCKET.voice"
run --voice off headless "no voice"
check "voice off: overlay without voice" bash -c "! grep -q dsh-romeo-whisper '$overlay'"
run --voice on --stop
check "voice --stop: the Whisper job too" bash -c "! grep -q whisper '$FAKE_ROMEO_STATE/jobs'"
run --voice off --status
if command -v node >/dev/null; then
  out=$(node "$HERE/speech-whisper.mjs" 2>&1); code=$?
  printf '%s\n' "$out"
  check "whisper provider tests" test "$code" = 0
fi

DSH_ROMEO_FICHE=no-such-fiche run
check "unknown fiche: clear error" has "fiche 'no-such-fiche' not found"

FAKE_ROMEO_UNREACHABLE=1 DSH_ROMEO_SOCKET=$T/ctl2 run --status
check "ROMEO unreachable: clear error" has "cannot connect to 'romeo' over SSH"

if [ -n "$REAL_DSH" ]; then
  # The overlay must compose with the real dsh (fresh DSH_HOME, no network needed).
  DSH_ROMEO_SEARXNG_URL=http://127.0.0.1:8888 run --launch
  composed=$(cd "$T" && DSH_HOME=$T/dsh-home "$REAL_DSH" --profile headless --patch "$overlay" --dump-config 2>&1)
  out=$composed
  check "real dsh: romeo is the default provider" has "provider: romeo"
  check "real dsh: SearXNG plugin inserted" has "id: dsh-romeo-searxng"
  # Subagents on DeepSeek in every preset of the real Web composition.
  FAKE_DSH_REAL=$REAL_DSH run --models kimi+deepseek --launch
  composed=$(cd "$T" && DSH_HOME=$T/dsh-home "$REAL_DSH" --profile web --patch "$overlay" --dump-config 2>&1)
  out=$composed
  check "real dsh: the patch applies" lacks "not found"
  check "real dsh: subagents of the standard preset on DeepSeek" bash -c "grep -A8 '^          - id: tool-subagent\$' <<<\"\$1\" | grep -q 'model: dsh-deepseek-v4.1-flash-1017-1m'" _ "$composed"
  DSH_ROMEO_MODELS=kimi+deepseek run --stop
fi

# Optional plugins (share/plugins.txt): installed in the profile, left out of its selection.
P=$T/plugins-home
out=$(DSH_HOME=$P "$ROOT/share/optional-plugins.sh" web "$FAKE/dsh" 2>&1); code=$?
check "plugins: installed, off" has "dsh-sidenote: installed, off"
check "plugins: exit 0" test "$code" = 0
check "plugins: dependencies of the profile" node -e 'const d=require(process.argv[1]); process.exit(d.dependencies["dsh-prompt-predict"] && d.dependencies["dsh-sidenote"] ? 0 : 1)' "$P/profiles/web/package.json"
check "plugins: not in the selection (off)" node -e 'const d=require(process.argv[1]); process.exit(d.dsh.profile.bundles.some((b) => b.startsWith("dsh-")) ? 1 : 0)' "$P/profiles/web/package.json"
node -e 'const fs=require("fs"),f=process.argv[1],d=require(f); d.dsh.profile.bundles.push("dsh-sidenote"); fs.writeFileSync(f, JSON.stringify(d))' "$P/profiles/web/package.json"
out=$(DSH_HOME=$P "$ROOT/share/optional-plugins.sh" web "$FAKE/dsh" 2>&1)
check "plugins again: left as they are" has "dsh-sidenote: already in the web profile, left as it is"
check "plugins again: one you turned on stays on" node -e 'process.exit(require(process.argv[1]).dsh.profile.bundles.includes("dsh-sidenote") ? 0 : 1)' "$P/profiles/web/package.json"
out=$(DSH_HOME=$T/plugins-home2 FAKE_DSH_REFUSE=dsh-sidenote "$ROOT/share/optional-plugins.sh" web "$FAKE/dsh" 2>&1); code=$?
check "plugins: a refused one is reported" has "dsh-sidenote: not installed (ERR_DSH_INCOMPATIBLE"
check "plugins: the others still installed" has "dsh-prompt-predict: installed, off"
check "plugins: exit 1 when one fails" test "$code" = 1
out=$(DSH_HOME=$T/plugins-home3 FAKE_DSH_REFUSE_PINNED=dsh-sidenote "$ROOT/share/optional-plugins.sh" web "$FAKE/dsh" 2>&1)
check "plugins: a refused pinned version falls back to the latest" has "dsh-sidenote: dsh-sidenote@.* refused by dsh 0.2.2-rc.1, installed 9.9.9 instead, off"
# A newer dsh: an installed version whose range excludes it moves to the latest, on or off as it was.
P4=$T/plugins-home4
DSH_HOME=$P4 FAKE_PINNED_RANGE='dsh-sidenote=>=0.2.2-rc.1 <0.2.3-0' "$ROOT/share/optional-plugins.sh" web "$FAKE/dsh" >/dev/null 2>&1
node -e 'const fs=require("fs"),f=process.argv[1],d=require(f); d.dsh.profile.bundles.push("dsh-sidenote"); fs.writeFileSync(f, JSON.stringify(d))' "$P4/profiles/web/package.json"
out=$(DSH_HOME=$P4 FAKE_DSH_VERSION=0.2.2-rc.1 "$ROOT/share/optional-plugins.sh" web "$FAKE/dsh" 2>&1)
check "plugins: a fitting version is left alone" has "dsh-sidenote: already in the web profile, left as it is"
out=$(DSH_HOME=$P4 FAKE_DSH_VERSION=0.2.3 "$ROOT/share/optional-plugins.sh" web "$FAKE/dsh" 2>&1)
check "plugins, dsh 0.2.3: sidenote moved to the latest, still on" has "dsh-sidenote: 0.8.3 does not fit dsh 0.2.3, moved to 9.9.9 (on;"
check "plugins, dsh 0.2.3: prompt-predict (no range) left alone" has "dsh-prompt-predict: already in the web profile"
check "plugins, dsh 0.2.3: sidenote still selected" node -e 'process.exit(require(process.argv[1]).dsh.profile.bundles.includes("dsh-sidenote") ? 0 : 1)' "$P4/profiles/web/package.json"
P5=$T/plugins-home5
DSH_HOME=$P5 FAKE_PINNED_RANGE='dsh-sidenote=>=0.2.2-rc.1 <0.2.3-0' "$ROOT/share/optional-plugins.sh" web "$FAKE/dsh" >/dev/null 2>&1
out=$(DSH_HOME=$P5 FAKE_DSH_VERSION=0.2.3 "$ROOT/share/optional-plugins.sh" web "$FAKE/dsh" 2>&1)
check "plugins, dsh 0.2.3: an off plugin stays off after the move" has "dsh-sidenote: 0.8.3 does not fit dsh 0.2.3, moved to 9.9.9 (off;"
check "plugins, dsh 0.2.3: and is still out of the selection" node -e 'process.exit(require(process.argv[1]).dsh.profile.bundles.includes("dsh-sidenote") ? 1 : 0)' "$P5/profiles/web/package.json"
P6=$T/plugins-home6
DSH_HOME=$P6 FAKE_PINNED_RANGE='dsh-sidenote=>=0.2.2-rc.1 <0.2.3-0' "$ROOT/share/optional-plugins.sh" web "$FAKE/dsh" >/dev/null 2>&1
out=$(DSH_HOME=$P6 FAKE_DSH_VERSION=0.2.3 FAKE_LATEST_RANGE='<0.2.3-0' "$ROOT/share/optional-plugins.sh" web "$FAKE/dsh" 2>&1)
check "plugins: no version fits the new dsh, reported" has "dsh-sidenote: 0.8.3 does not fit dsh 0.2.3, nor does its latest version 9.9.9 (installed, off)"
check "plugins: and it stays off" node -e 'process.exit(require(process.argv[1]).dsh.profile.bundles.includes("dsh-sidenote") ? 1 : 0)' "$P6/profiles/web/package.json"

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
  env -u ROMEO_PROJECT ROMEO_WHERE=remote XDG_CONFIG_HOME=$T/xdg bash -c '. "$1"; echo "project=$ROMEO_PROJECT"; R "echo remote-user=\$USER"' _ "$SKILL/scripts/env.sh" 2>&1)
check "skill env.sh: project from dsh-romeo's config" has "project=r000000"
check "skill env.sh: R runs over ssh" has "remote-user=demo"

for f in "$ROOT/bin/dsh-romeo" "$ROOT/install.sh" "$ROOT/share/optional-plugins.sh" "$HERE/run.sh" "$SKILL/scripts/env.sh"; do
  out=$(bash -n "$f" 2>&1); check "syntax: $(basename "$f")" test -z "$out"
done
if command -v shellcheck >/dev/null; then
  out=$(shellcheck -S warning "$ROOT/bin/dsh-romeo" "$ROOT/install.sh" "$ROOT/share/optional-plugins.sh" 2>&1); check "shellcheck" test -z "$out"
  out=$(shellcheck -S warning -s bash "$SKILL/scripts/env.sh" 2>&1); check "shellcheck: skill env.sh" test -z "$out"
fi

out=$(DSH_ROMEO_RLT_CHECK=/bin/sh bash "$ROOT/install.sh" --yes 2>&1); code=$?
check "install.sh on ROMEO: says to run it on your computer" has "run install.sh on your own computer"
check "install.sh on ROMEO: exit 1" test "$code" = 1

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
