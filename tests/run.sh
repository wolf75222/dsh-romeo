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

run --completion bash
check "--completion bash: completes the models" bash -c "eval \"\$1\"; COMP_WORDS=(dsh-romeo --models k); COMP_CWORD=2; _dsh_romeo; [ \"\${COMPREPLY[*]}\" = 'kimi kimi+deepseek' ]" _ "$out"
run --completion fish
check "--completion fish: refused" has "takes bash or zsh"
run --version
check "--version" has "dsh-romeo 0."

run --status
check "status: gateway stopped, no job, tunnel closed" has "gateway  *stopped"
check "status: no model job" has "DeepSeek-V4.1-Flash-1017  *-  *no job"

run
check "start before --setup: fiche missing" has "next: dsh-romeo --setup"
check "start before --setup: exit 1" test "$code" = 1
check "start starts the gateway" test -e "$FAKE_ROMEO_STATE/gateway"

run --setup
check "--setup copies the fiche" test -f "$FAKE_ROMEO_HOME/.romeollmtool/configs/dsh-deepseek-v4.1-flash-1017-1m.yaml"
check "--setup installs the job clean-up" test -f "$FAKE_ROMEO_HOME/.dsh-romeo/prestart/sitecustomize.py"
check "job clean-up: imports cleanly, once per job" bash -c "d=\$(mktemp -d); touch \$d/w; SLURM_JOB_ID=t\$\$ DSH_ROMEO_EVICT=\$d:/nonexistent PYTHONPATH='$ROOT/share/prestart' python3 -c 'import sitecustomize' && ls /tmp/dsh-romeo-prestart-\$(id -u)-t\$\$ >/dev/null && rm -rf \$d /tmp/dsh-romeo-prestart-\$(id -u)-t\$\$"
check "--setup: the login in the Humming cache path" grep -q "HUMMING_CACHE_DIR: \"/tmp/humming-demo/cache\"" "$FAKE_ROMEO_HOME/.romeollmtool/configs/dsh-deepseek-v4.1-flash-1017-1m.yaml"
check "--setup: no placeholder left" bash -c "! grep -rq __USER__ '$FAKE_ROMEO_HOME/.romeollmtool/configs'"
# A last job that failed: --status and a start say why, from sacct and the end of its log.
mkdir -p "$FAKE_ROMEO_HOME/.romeollmtool/logs"
echo "romeollmtool-dsh-deepseek-v4.1-flash-1017-1m 900099|FAILED|2026-11-06T14:26:49|romeo-a[031-032]|1:0" >"$FAKE_ROMEO_STATE/sacct"
printf '%s\n' "ValueError: Free memory on device cuda:0 (73.82/95.0 GiB) on startup is less than desired" >"$FAKE_ROMEO_HOME/.romeollmtool/logs/slurm-900099.err"
run --status
check "status: a failed last job and why" has "failed .*14:26: a GPU had only 73.82/95.0 GiB free at start"
run headless x
check "start after a failed job: says why" has "no model job on ROMEO (dsh-deepseek-v4.1-flash-1017-1m): a GPU had only 73.82/95.0 GiB free"
check "start after a failed job: what to type" has "next: dsh-romeo --launch   (another node"
echo "romeollmtool-dsh-deepseek-v4.1-flash-1017-1m 900099|TIMEOUT|2026-11-06T14:26:49|romeo-a031|0:0" >"$FAKE_ROMEO_STATE/sacct"
: >"$FAKE_ROMEO_HOME/.romeollmtool/logs/slurm-900099.err"
run headless x
check "start after a timed-out job: says so" has "it reached its time limit"
echo "romeollmtool-dsh-deepseek-v4.1-flash-1017-1m 900099|CANCELLED by 0|2026-11-06T12:48:01|romeo-a031|0:0" >"$FAKE_ROMEO_STATE/sacct"
printf '%s\n' "INFO Free memory on device cuda:0 (91.3/95.0 GiB) on startup. Desired GPU memory utilization is (0.88, 83.6 GiB)" >"$FAKE_ROMEO_HOME/.romeollmtool/logs/slurm-900099.err"
run --status
check "status: a stopped job with vLLM's memory info line is not a failure" lacks "failed"
rm -f "$FAKE_ROMEO_STATE/gateway"   # the gateway stopped at the end of its lifetime
run --status
check "status: a cancelled last job, the gateway stopped" has "last one: it was cancelled at 12:48: romeollmtool's gateway stopped"
rm -f "$FAKE_ROMEO_STATE/sacct"

run
check "start without a job: says --launch" has "next: dsh-romeo --launch"
check "start without a job: exit 1" test "$code" = 1

ROMEO_PROJECT='' run --launch
check "--launch without a project: says so" has "no project code"

run --launch 9
check "--launch 9: refused" has "--launch takes 1 to 8 jobs"

DSH_ROMEO_TIME=8h run --launch
check "--launch: DSH_ROMEO_TIME not HH:MM:SS, refused" has "DSH_ROMEO_TIME: HH:MM:SS up to 24:00:00, not '8h'"
DSH_ROMEO_TIME=25:00:00 run --launch
check "--launch: DSH_ROMEO_TIME over 24 h, refused" has "not '25:00:00'"
check "--launch: refused time submits nothing" bash -c "! grep -q . '$FAKE_ROMEO_STATE/jobs' 2>/dev/null"
fiche=$FAKE_ROMEO_HOME/.romeollmtool/configs/dsh-deepseek-v4.1-flash-1017-1m.yaml
echo "# an older version" >>"$fiche"
DSH_ROMEO_TIME=bad run --launch
check "--launch: an outdated fiche on ROMEO is updated" has "updated on ROMEO .*dsh-deepseek-v4.1-flash-1017-1m"
check "--launch: the fiche is this version's again" bash -c "! grep -q 'an older version' '$fiche'"
DSH_ROMEO_TIME=bad run --launch
check "--launch: an up-to-date fiche is left alone" lacks "updated on ROMEO"
# A fiche whose weights this login cannot read (Kimi's, for a login outside project r260105).
mkdir -p "$T/proj/r9/w" "$T/missing"
sed "s|^  model: .*|  model: \"$T/proj/r9/w\"|" "$fiche" >"$FAKE_ROMEO_HOME/.romeollmtool/configs/my-locked.yaml"
sed "s|^  model: .*|  model: \"$T/missing/w\"|" "$fiche" >"$FAKE_ROMEO_HOME/.romeollmtool/configs/my-gone.yaml"
chmod 000 "$T/proj/r9"
DSH_ROMEO_FICHE=my-locked run --launch
chmod 755 "$T/proj/r9"
check "--launch: unreadable weights, said before any job" has "cannot read the weights of DeepSeek-V4.1-Flash-1017 ($T/proj/r9/w)"
check "--launch: unreadable weights, what to type" has "next: dsh-romeo --models deepseek --launch"
check "--launch: unreadable weights, no job" bash -c "! grep -q . '$FAKE_ROMEO_STATE/jobs' 2>/dev/null"
chmod 000 "$T/proj/r9"
DSH_ROMEO_FICHE=my-locked run --doctor
chmod 755 "$T/proj/r9"
check "--doctor: unreadable weights, a failed row" has "weights .*failed .*your login cannot read $T/proj/r9/w"
DSH_ROMEO_FICHE=my-gone run --launch
check "--launch: missing weights, said" has "weights are not on ROMEO at $T/missing/w"
rm -f "$FAKE_ROMEO_HOME/.romeollmtool/configs/my-locked.yaml" "$FAKE_ROMEO_HOME/.romeollmtool/configs/my-gone.yaml"

run --launch
check "--launch: job submitted" has "model job 900001 submitted"
check "--launch: waits, then ready" has "ready"
check "ready: the gateway's URL" has "gateway  http://romeo1.example:$FAKE_GATEWAY_PORT/v1"
check "ready: the local URL" has "local    http://127.0.0.1:$PORT/v1"
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
check "overlay: SearXNG when configured" grep -q "baseURL: 'http://127.0.0.1:8888'" "$overlay"
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
  # A patch the app left empty ("[]") still gives valid YAML.
  echo '[]' >"$T/home/.dsh/profiles/desktop/cordis.patch.yml"
  touch "$FAKE_ROMEO_STATE/app-running"
  HOME=$T/home run --desktop
  check "--desktop from an empty [] patch: no [] left" bash -c "! grep -q '^\[\]' '$T/home/.dsh/profiles/desktop/cordis.patch.yml'"
  printf '%s\n' '- id: ui-theme' '  config: { theme: dark }' >>"$T/home/.dsh/profiles/desktop/cordis.patch.yml"
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
  check "--desktop back to deepseek: no model choice left" bash -c "! grep -q 'subagent-model-selection-settings' '$T/home/.dsh/profiles/desktop/cordis.patch.yml'"
  check "--desktop back to deepseek: no subagent model label left" bash -c "! grep -q 'subagent-model-label' '$T/home/.dsh/profiles/desktop/cordis.patch.yml'"
  # The Kimi job ends (scancel), the DeepSeek job stays for the tests below.
  grep -v kimi "$FAKE_ROMEO_STATE/jobs" >"$FAKE_ROMEO_STATE/jobs.new"; mv "$FAKE_ROMEO_STATE/jobs.new" "$FAKE_ROMEO_STATE/jobs"
  run --models deepseek --status
  FAKE_NO_APP=1 HOME=$T/home run --desktop
  check "--desktop without the app: says so" has "app is not installed"
  touch "$FAKE_ROMEO_STATE/app-running"
  HOME=$T/home run --desktop
  check "--desktop: the key for apps opened later" grep -q "setenv ROMEO_LLM_KEY test-key" "$FAKE_ROMEO_STATE/launchctl"
  rm -f "$FAKE_ROMEO_STATE/osascript-call"
  HOME=$T/home run --desktop
  check "--desktop again, nothing changed: the app is not restarted" has "already runs on ROMEO"
  check "--desktop again, nothing changed: no quit" test ! -e "$FAKE_ROMEO_STATE/osascript-call"
  echo "# edited" >>"$T/home/.dsh/cordis.patch.yml"
  HOME=$T/home run --desktop
  check "--desktop after an edit of ~/.dsh/cordis.patch.yml: the app is restarted" grep -q "quit app" "$FAKE_ROMEO_STATE/osascript-call"
  rm -f "$FAKE_ROMEO_STATE/osascript-call"
  HOME=$T/home run --desktop
  echo '{"dsh":{"profile":{"bundles":["a-new-plugin"]}}}' >"$T/home/.dsh/profiles/desktop/package.json"
  HOME=$T/home run --desktop
  check "--desktop after a plugin was added: the app is restarted" grep -q "quit app" "$FAKE_ROMEO_STATE/osascript-call"
  rm -f "$T/home/.dsh/profiles/desktop/package.json"
  rm -f "$FAKE_ROMEO_STATE/app-running"
  FAKE_OPEN_FAIL=1 HOME=$T/home run --desktop
  check "--desktop: open refused, macOS's reason" has "macOS did not open DeepSeek Harness: LSOpenURLsWithRole"
  FAKE_APP_CRASH=1 DSH_ROMEO_APP_WAIT=1 HOME=$T/home run --desktop
  check "--desktop: an app that does not start is said" has "is not running 30 s after opening"
  HOME=$T/home run --stop
  check "--stop: the key unset for later apps" grep -q "unsetenv ROMEO_LLM_KEY" "$FAKE_ROMEO_STATE/launchctl"
  run --launch
fi

# A refused forward with the port free: once more on a new connection, then ssh's reason.
rm -f "$DSH_ROMEO_SOCKET.target"   # no tunnel to reuse: the forward is asked for
# (here the fake gateway itself listens on the port: an lsof that sees nothing, as on a real computer)
mkdir -p "$T/nolsof"; printf '#!/bin/sh\nexit 0\n' >"$T/nolsof/lsof"; chmod +x "$T/nolsof/lsof"
rm -f "$FAKE_ROMEO_STATE/forward-fails"
PATH=$T/nolsof:$PATH FAKE_FORWARD_FAIL=1 run --serve
check "forward refused once: a new connection and it works" has "base URL"
rm -f "$FAKE_ROMEO_STATE/forward-fails" "$DSH_ROMEO_SOCKET.target"
PATH=$T/nolsof:$PATH FAKE_FORWARD_FAIL=2 run --serve
check "forward refused twice: ssh's reason, not a guess" has "ssh refused it: mux_client_forward"
check "forward refused twice: next step keeps the jobs" lacks "next: dsh-romeo --stop"
rm -f "$FAKE_ROMEO_STATE/forward-fails"
# A ROMEO_LLM_KEY saved in dsh's credential store would replace the gateway's key.
mkdir -p "$T/dsh-store"
printf '%s\n' 'version: 1' 'refs:' '  OTHER_KEY: keep-me' '  ROMEO_LLM_KEY: stale-key' 'records: {}' >"$T/dsh-store/.credentials.yaml"
DSH_HOME=$T/dsh-store run --doctor
check "--doctor: a stored ROMEO_LLM_KEY reported" has "dsh key .*warning"
DSH_HOME=$T/dsh-store run headless "x"
check "stored ROMEO_LLM_KEY removed" bash -c "! grep -q ROMEO_LLM_KEY '$T/dsh-store/.credentials.yaml'"
check "other stored keys kept" grep -q "OTHER_KEY: keep-me" "$T/dsh-store/.credentials.yaml"
check "removal said" has "removed a ROMEO_LLM_KEY"

run --doctor
check "--doctor: all good" has "doctor: all good"
check "--doctor: the fiche checked" has "fiche .*ok .*dsh-deepseek-v4.1-flash-1017-1m"
check "--doctor: exit 0" test "$code" = 0
ROMEO_PROJECT= run --doctor
check "--doctor without a project: fails and says so" bash -c "[ $code != 0 ] && grep -q 'project .*failed' <<<\"\$1\"" _ "$out"
FAKE_ROMEO_UNREACHABLE=1 DSH_ROMEO_SOCKET=$T/other.sock run --doctor
check "--doctor, ROMEO unreachable: ssh failed" has "ssh .*failed"
run --logs
check "--logs: the agent's job" has "log of model job 900001"
check "--logs: its lines" has "log line of job 900001"
# Failures found before anything starts on ROMEO, or right away: no job submitted for nothing.
jobs_before=$(wc -l <"$FAKE_ROMEO_STATE/jobs")
run --stauts
check "unknown option: refused" has "unknown option --stauts"
run --launch --run no-such-client
check "--run, client missing: said before launching" has "no-such-client: command not found"
DSH_ROMEO_DSH=no-such-dsh run --launch
check "dsh missing: said before launching" has "dsh is not installed"
check "no job submitted by these" test "$(wc -l <"$FAKE_ROMEO_STATE/jobs")" = "$jobs_before"
FAKE_KEY=stale-key run headless "x"
check "a key the gateway refuses: said, no endless wait" has "the gateway refuses the key"
FAKE_KEY=stale-key run --doctor
check "--doctor: a refused key fails" has "key .*failed .*refuses"
touch "$FAKE_ROMEO_STATE/squeue-fail"
run --stop
check "--stop, squeue down: never 'no model job'" lacks "no model job of dsh-romeo"
check "--stop, squeue down: says jobs may still run, exit 1" bash -c "[ $code = 1 ] && grep -q 'may still run' <<<\"\$1\"" _ "$out"
rm -f "$FAKE_ROMEO_STATE/squeue-fail"
run --version
check "--version: dsh-romeo and dsh" bash -c "grep -q '^dsh-romeo ' <<<\"\$1\" && grep -q '^dsh ' <<<\"\$1\"" _ "$out"

run --status
check "status: job listed" has "900001  *running  *2  *0:42 elapsed"

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
check "models remembered: kimi again without --models" has "Kimi-K3.1-Pro  *-  *no job"
DSH_ROMEO_MODELS=deepseek run --status
check "models: the environment wins over the remembered choice" has "DeepSeek-V4.1-Flash-1017  *-  *no job"

# Kimi as the agent, DeepSeek for its subagents: two jobs, both models waited for and listed.
run --models kimi+deepseek --launch headless "both"
check "kimi+deepseek: a Kimi job" grep -q " dsh-kimi-k3.1-pro-1m " "$FAKE_ROMEO_STATE/jobs"
check "kimi+deepseek: a DeepSeek job" grep -q " dsh-deepseek-v4.1-flash-1017-1m " "$FAKE_ROMEO_STATE/jobs"
check "kimi+deepseek: Kimi ready" has "Kimi-K3.1-Pro ready"
check "kimi+deepseek: DeepSeek ready for the subagents" has "DeepSeek-V4.1-Flash-1017 ready for the subagents"
check "kimi+deepseek overlay: both models" bash -c "grep -q 'id: dsh-kimi-k3.1-pro-1m' '$overlay' && grep -q 'id: dsh-deepseek-v4.1-flash-1017-1m' '$overlay'"
check "kimi+deepseek overlay: the agent may choose either model for a subagent" bash -c "grep -A6 '^- id: subagent-model-selection-settings' '$overlay' | grep -q 'enabled: true' && grep -A6 '^- id: subagent-model-selection-settings' '$overlay' | grep -q 'model: dsh-kimi-k3.1-pro-1m' && grep -A6 '^- id: subagent-model-selection-settings' '$overlay' | grep -q 'model: dsh-deepseek-v4.1-flash-1017-1m'"
check "kimi+deepseek overlay: subagent names carry their model" bash -c "grep -A6 '    - id: dsh-romeo-subagent-model-label' '$overlay' | grep -q \"'dsh-kimi-k3.1-pro-1m': Kimi\" && grep -A6 '    - id: dsh-romeo-subagent-model-label' '$overlay' | grep -q \"'dsh-deepseek-v4.1-flash-1017-1m': DeepSeek\""
label_out=$(node --input-type=module -e "
  const m = await import(process.argv[1])
  class S { async startActivation(spec) { return spec.label } }
  const s = new S(); let off
  m.apply({ subagents: s, on: (e, f) => { off = f } }, { labels: { k: 'Kimi', d: 'DeepSeek' } })
  m.apply({ subagents: s, on: () => {} }, { labels: {} })
  const parent = { options: { model: 'k' }, session: { requestHeader: () => undefined } }
  const out = [
    await s.startActivation({ label: 'Fix it', request: { parent, agentOptions: { model: 'd' } } }),
    await s.startActivation({ label: 'Review', request: { parent } }),
    await s.startActivation({ label: 'Again · Kimi', request: { parent } }),
    await s.startActivation({ request: { parent: { session: { requestHeader: () => ({ config: { model: 'd' } }) } } } }),
    await s.startActivation({ label: 'Odd', request: { parent: {}, agentOptions: { model: 'other' } } }),
  ]
  off(); out.push(await s.startActivation({ label: 'After', request: { parent } }))
  console.log(out.join('|'))" "$ROOT/share/subagent-model-label.mjs" 2>&1)
check "subagent label plugin: the chosen model, the parent's, once, unknown ids, removed on dispose" test "$label_out" = "Fix it · DeepSeek|Review · Kimi|Again · Kimi|Subagent · DeepSeek|Odd · other|After"
check "kimi+deepseek overlay: the agent is told it may pick either model" bash -c "grep -A5 '^- id: system-prompt' '$overlay' | grep 'personaSuffix:' | grep -q 'model dsh-kimi-k3.1-pro-1m to run it on Kimi-K3.1-Pro'"
check "kimi+deepseek overlay: the persona prefix kept" bash -c "grep -A5 '^- id: system-prompt' '$overlay' | grep -q 'personaPrefix: You are a coding agent'"
check "kimi+deepseek overlay: one persona suffix" bash -c "[ \$(grep -c 'personaSuffix:' '$overlay') = 1 ] && ! grep -q 'an older suffix' '$overlay'"
check "kimi+deepseek overlay: dsh's own subagent settings untouched" bash -c "! grep -q '^- id: subagent\$' '$overlay'"
check "kimi+deepseek overlay: DeepSeek takes images" bash -c "grep -A5 'id: dsh-deepseek-v4.1-flash-1017-1m' '$overlay' | grep -q 'input: \[ text, image \]'"
check "kimi+deepseek overlay: Kimi takes images" bash -c "grep -A5 'id: dsh-kimi-k3.1-pro-1m' '$overlay' | grep -q 'input: \[ text, image \]'"
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
check "models: back to deepseek" has "DeepSeek-V4.1-Flash-1017  *-  *no job"

# Voice input: a Whisper job, dsh's microphone wired to it, remembered like --models.
DSH_ROMEO_VOICE_PORT=$PORT run --voice on --launch headless "voice"
check "voice: a Whisper job" grep -q " dsh-whisper-large-v3-turbo " "$FAKE_ROMEO_STATE/jobs"
check "voice: ready or loading" grep -q -E "voice input (ready|loading)" <<<"$out"
check "voice overlay: the provider plugin" grep -q "name: $ROOT/share/speech-whisper-romeo.mjs" "$overlay"
check "voice overlay: Whisper selected" grep -q "defaultProvider: dsh-romeo-whisper" "$overlay"
check "voice overlay: straight to the job, not the gateway" grep -q "baseURL: http://127.0.0.1:$PORT/v1" "$overlay"
check "voice overlay: the job's key from a file" grep -q "apiKeyFile: $DSH_ROMEO_CONFIG_DIR/whisper.key" "$overlay"
check "voice: the job's key written" grep -qx "test-key-of-the-job-0123456789" "$DSH_ROMEO_CONFIG_DIR/whisper.key"
check "voice overlay: the microphone button" grep -q "dsh-experimental-client-ui-voice-input" "$overlay"
check "voice overlay: no local SenseVoice" bash -c "! grep -q sensevoice '$overlay'"
run --status
check "voice: remembered, its job listed" has "Whisper-large-v3-turbo  *9000"
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

# State that goes stale: a dead connection, a refused key, a remembered value, voice turned off.
run --launch
FAKE_ROMEO_UNREACHABLE=1 run --stop
check "dead connection: --stop does not claim there is no job" lacks "no model job of dsh-romeo"
check "dead connection: --stop fails" test "$code" != 0
check "dead connection: the job is still there" grep -q dsh-deepseek "$FAKE_ROMEO_STATE/jobs"
run --stop
check "--stop on a new connection: the job stopped" has "model job .* stopped"
run --launch
printf '#!/usr/bin/env bash\n[ "$1 ${2:-}" = "gateway show-key" ] && { echo someone-elses-key; exit; }\nexec "%s" "$@"\n' "$FAKE/romeollmtool" >"$T/rlt-other-key"
chmod +x "$T/rlt-other-key"
out=$(ROMEOLLMTOOL=$T/rlt-other-key perl -e 'alarm 20; exec @ARGV' "$ROOT/bin/dsh-romeo" headless x 2>&1)  # an endless wait is killed
check "refused key: stops at once and says so, no endless wait" has "the gateway refuses the key dsh-romeo read (HTTP 401"
echo gpt >"$DSH_ROMEO_CONFIG_DIR/models"
run --stop
check "invalid remembered --models: --stop still works" has "model job .* stopped"
check "invalid remembered --models: forgotten" test ! -e "$DSH_ROMEO_CONFIG_DIR/models"
DSH_ROMEO_VOICE_PORT=$PORT run --voice on --launch headless "voice"
run --voice off headless "no voice"
check "voice off: no Whisper key left" test ! -e "$DSH_ROMEO_CONFIG_DIR/whisper.key"
check "voice off: no voice forward noted" test ! -e "$DSH_ROMEO_SOCKET.voice"
check "voice off: its running job said" has "Whisper job .* still runs"
run --voice off --stop
# Edited config values: quotes stay valid YAML, spaces and ';' stay one argument on ROMEO.
DSH_ROMEO_TIME="08:00:00; touch $FAKE_ROMEO_HOME/injected" run --launch headless x
check "config with ';': refused, not run on ROMEO" bash -c "[ $code = 1 ] && [ ! -e '$FAKE_ROMEO_HOME/injected' ]"
DSH_ROMEO_SEARXNG_URL='http://127.0.0.1:8888/?q="x"' run --launch headless x
check "config with quotes: SearXNG URL single-quoted" grep -q "baseURL: 'http://127.0.0.1:8888/?q=\"x\"'" "$overlay"
run --stop
# A login script on ROMEO that prints: --env keeps only exports, the job list keeps only jobs.
run --launch
env_out=$(FAKE_REMOTE_NOISE='Loading modules' DSH_ROMEO_GATEWAY=fast "$ROOT/bin/dsh-romeo" --env 2>/dev/null)
check "--env with a chatty ROMEO login: only exports" only_exports
out=$env_out
check "--env with a chatty ROMEO login: the gateway key" has "export OPENAI_API_KEY=test-key"
FAKE_REMOTE_NOISE='Loading modules' run --status
check "status with a chatty ROMEO login: no job named Loading" lacks "Loading"
run --stop
# Another ROMEO_SSH_HOST before: --stop closes that connection too.
H2=$T/home2
env -u DSH_ROMEO_SOCKET HOME=$H2 ROMEO_SSH_HOST=romeo-a "$ROOT/bin/dsh-romeo" --status >/dev/null 2>&1
out=$(env -u DSH_ROMEO_SOCKET HOME=$H2 ROMEO_SSH_HOST=romeo-b "$ROOT/bin/dsh-romeo" --stop 2>&1)
check "host changed: --stop closes the earlier host's connection" test ! -e "$H2/.ssh/dsh-romeo-romeo-a.sock"
check "missing ~/.ssh: created private" test "$(stat -c %a "$H2/.ssh" 2>/dev/null || stat -f %Lp "$H2/.ssh")" = 700
if [ "$(uname)" = Darwin ]; then
  run --launch
  mkdir -p "$T/home3" "$T/dsh-home3"
  HOME=$T/home3 DSH_HOME=$T/dsh-home3 run --desktop
  check "--desktop with DSH_HOME: the app's profile in ~/.dsh" grep -q "provider: romeo" "$T/home3/.dsh/profiles/desktop/cordis.patch.yml"
  DSH_ROMEO_DESKTOP_APP='No Such App' HOME=$T/home3 run --models kimi+deepseek --launch --desktop
  check "--desktop, app's dsh not found: no presets of another dsh" bash -c "! grep -q preset-standard '$T/home3/.dsh/profiles/desktop/cordis.patch.yml'"
  DSH_ROMEO_MODELS=kimi+deepseek run --stop
  run --models deepseek --status
fi

if [ -n "$REAL_DSH" ]; then
  # The overlay must compose with the real dsh (fresh DSH_HOME, no network needed).
  DSH_ROMEO_SEARXNG_URL=http://127.0.0.1:8888 run --launch
  composed=$(cd "$T" && DSH_HOME=$T/dsh-home "$REAL_DSH" --profile headless --patch "$overlay" --dump-config 2>&1)
  out=$composed
  check "real dsh: romeo is the default provider" has "provider: romeo"
  check "real dsh: SearXNG plugin inserted" has "id: dsh-romeo-searxng"
  # Subagents on DeepSeek in every preset of the real Web composition.
  FAKE_DSH_REAL=$REAL_DSH run --models kimi+deepseek --launch
  composed=$(cd "$T" && DSH_HOME=$T/dsh-home "$REAL_DSH" --profile web --patch "$overlay" --dump-config 2>&1); code=$?
  out=$composed
  check "real dsh: the patch applies" test "$code" = 0
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

# dsh-romeo's build of dsh-prompt-predict (share/plugins): linked from the repository, and it replaces
# another version of the plugin, on or off as it was.
check "plugins: dsh-prompt-predict linked from share/plugins" node -e 'process.exit(require(process.argv[1]).dependencies["dsh-prompt-predict"] === "link:" + process.argv[2] ? 0 : 1)' "$P/profiles/web/package.json" "$ROOT/share/plugins/dsh-prompt-predict"
P7=$T/plugins-home7; mkdir -p "$P7/profiles/web"
echo '{"dependencies":{"dsh-prompt-predict":"0.2.11"},"dsh":{"profile":{"bundles":["@deepseek-ai/dsh-base","dsh-prompt-predict"]}}}' >"$P7/profiles/web/package.json"
out=$(DSH_HOME=$P7 "$ROOT/share/optional-plugins.sh" web "$FAKE/dsh" 2>&1)
check "plugins: an npm dsh-prompt-predict is replaced by dsh-romeo's build" has "dsh-prompt-predict: 0.2.11 replaced by dsh-romeo's build (on)"
check "plugins: and stays on" node -e 'const d=require(process.argv[1]); process.exit(d.dsh.profile.bundles.includes("dsh-prompt-predict") && d.dependencies["dsh-prompt-predict"].startsWith("link:") ? 0 : 1)' "$P7/profiles/web/package.json"
out=$(DSH_HOME=$P7 "$ROOT/share/optional-plugins.sh" web "$FAKE/dsh" 2>&1)
check "plugins: the build already linked is left alone" has "dsh-prompt-predict: already in the web profile, left as it is"
PP=$ROOT/share/plugins/dsh-prompt-predict
check "dsh-prompt-predict: client.js is built from client/src" bash -c "cd '$PP' && cat client/src/0*.js | cmp -s - client/client.js"
for t in predict assist client-render; do
  out=$(cd "$PP" && node "test/$t.mjs" 2>&1)
  check "dsh-prompt-predict: test/$t.mjs" has "^RESULT PASS"
done

# --update: a fast-forward of the clone, then install.sh (replaced here), asked first.
U=$T/update; mkdir -p "$U"
git clone -q --bare "$ROOT" "$U/up.git" 2>/dev/null
rsync -a --exclude node_modules "$ROOT/" "$U/clone/"
G() { git -c user.name=test -c user.email=test@example.invalid "$@"; }
G -C "$U/clone" add -A >/dev/null 2>&1; G -C "$U/clone" commit -qm wip >/dev/null 2>&1
git -C "$U/clone" remote set-url origin "$U/up.git"
git -C "$U/clone" push -qf origin HEAD:main 2>/dev/null; git -C "$U/clone" fetch -q
git -C "$U/clone" branch -q --set-upstream-to=origin/main 2>/dev/null
out=$("$U/clone/bin/dsh-romeo" --update </dev/null 2>&1)
check "--update: up to date" has "ok.*dsh-romeo is up to date"
git clone -q "$U/up.git" "$U/other" 2>/dev/null; echo news >"$U/other/NEWS"
G -C "$U/other" add NEWS; G -C "$U/other" commit -qm "A new feature"; git -C "$U/other" push -q origin HEAD:main 2>/dev/null
out=$("$U/clone/bin/dsh-romeo" --update </dev/null 2>&1)
check "--update: the new change listed" has "1 new change in dsh-romeo"
check "--update: its title shown" has "A new feature"
check "--update: no terminal, nothing installed" has "not installed (no terminal to ask)"
check "--update: still behind" test ! -f "$U/clone/NEWS"
out=$(DSH_ROMEO_INSTALL="echo install-ran" "$U/clone/bin/dsh-romeo" --update --yes </dev/null 2>&1)
check "--update --yes: fast-forwarded" test -f "$U/clone/NEWS"
check "--update --yes: install.sh run" has "install-ran"
check "--update --yes: says it" has "ok.*dsh-romeo updated to"
echo local >>"$U/clone/README.md"; echo more >"$U/other/NEWS"; G -C "$U/other" commit -qam more; git -C "$U/other" push -q origin HEAD:main 2>/dev/null
out=$(DSH_ROMEO_INSTALL=true "$U/clone/bin/dsh-romeo" --update --yes </dev/null 2>&1)
check "--update: local changes stop it" has "has local changes"
check "--update: --help lists it" bash -c "'$ROOT/bin/dsh-romeo' --help 2>&1 | grep -q -- '--update'"

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

# Queue reasons in words, and jobs that would never start by waiting.
cp "$FAKE_ROMEO_STATE/jobs" "$T/jobs.saved" 2>/dev/null || : >"$T/jobs.saved"
echo "990001 dsh-deepseek-v4.1-flash-1017-1m 9999999999" >"$FAKE_ROMEO_STATE/jobs"
echo dsh-deepseek-v4.1-flash-1017-1m >"$FAKE_ROMEO_STATE/pending"
DSH_ROMEO_MODELS=deepseek DSH_ROMEO_VOICE=off FAKE_REASON=AssocGrpGRES run --status
check "status: the project's GPU limit, in words" has "the project's GPU limit is reached"
DSH_ROMEO_MODELS=deepseek DSH_ROMEO_VOICE=off FAKE_REASON=AssocGrpGRESMinutes run --serve
check "wait: GPU hours used up stops the wait" has "project r000000 has used up its GPU hours"
check "wait: GPU hours used up, exit 1" test "$code" = 1
DSH_ROMEO_MODELS=deepseek DSH_ROMEO_VOICE=off FAKE_REASON=JobHeldUser run --serve
check "wait: a held job stops the wait" has "next: ssh romeo scontrol release 990001"
rm -f "$FAKE_ROMEO_STATE/pending"
echo "990001 dsh-deepseek-v4.1-flash-1017-1m 1" >"$FAKE_ROMEO_STATE/jobs"
DSH_ROMEO_MODELS=deepseek DSH_ROMEO_VOICE=off FAKE_LEFT=12:00 run --serve
check "ready: a job that ends soon is said" has "model job ends in 12 min"
DSH_ROMEO_MODELS=deepseek DSH_ROMEO_VOICE=off run --serve
check "ready: a job with hours left says nothing" lacks "ends in"
cp "$T/jobs.saved" "$FAKE_ROMEO_STATE/jobs"
# Web search on ROMEO (--web on): RustXNG's binary installed once (checksum), run per search over SSH.
cat >"$T/fake-rustxng" <<'RX'
#!/usr/bin/env bash
# Fake RustXNG: "mcp" answers initialize and one search on stdin/stdout.
[ "${1:-}" = mcp ] || exit 2
while read -r line; do
  case $line in
    *'"id":1'*) echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"rustxng","version":"0.28.0"}}}' ;;
    *'"id":2'*) q=$(sed -E 's/.*"query":"([^"]*)".*/\1/' <<<"$line")
                echo '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{}"}],"structuredContent":{"query":"'"$q"'","results":[{"url":"https://example.org/a","title":"A for '"$q"'","snippet":"first"},{"url":"https://example.org/a","title":"dup"},{"url":"https://example.org/b","title":"B"}],"truncated":false}}}' ;;
  esac
done
RX
chmod +x "$T/fake-rustxng"
rx_sum=$( { sha256sum "$T/fake-rustxng" 2>/dev/null || shasum -a 256 "$T/fake-rustxng"; } | cut -d' ' -f1)
export DSH_ROMEO_RUSTXNG_URL=file://$T/fake-rustxng DSH_ROMEO_RUSTXNG_SHA256=$rx_sum
cp "$FAKE_ROMEO_STATE/jobs" "$T/jobs.saved2" 2>/dev/null || : >"$T/jobs.saved2"
echo "990002 dsh-deepseek-v4.1-flash-1017-1m 1" >"$FAKE_ROMEO_STATE/jobs"
run --web foo
check "--web foo: refused" has "web: on or off, not 'foo'"
DSH_ROMEO_MODELS=deepseek DSH_ROMEO_VOICE=off run --web on headless "web"
check "--web on: RustXNG installed on ROMEO, checksum verified" has "web search installed on ROMEO"
check "--web on: the binary is on ROMEO" test -x "$FAKE_ROMEO_HOME/.dsh-romeo/rustxng/rustxng-v0.28.0-x86_64-unknown-linux-musl"
check "--web on: ready" has "web search ready"
check "--web on: the overlay selects it" grep -q "searchProvider: dsh-romeo-rustxng" "$overlay"
check "--web on: over the shared SSH connection" grep -q "socket: '$DSH_ROMEO_SOCKET'" "$overlay"
check "--web on: dsh still starts" grep -q "args: headless --patch .* web" "$FAKE_ROMEO_STATE/dsh-call"
DSH_ROMEO_MODELS=deepseek DSH_ROMEO_VOICE=off run headless "web again"
check "--web remembered, not installed twice" bash -c 'grep -q "web search ready" <<<"$1" && ! grep -q "installed on ROMEO" <<<"$1"' _ "$out"
out=$(cd "$T" && node --input-type=module -e "
  const m = await import(process.argv[1])
  let p; m.apply({ web: { registerSearchProvider: (x) => { p = x } } }, { host: 'romeo', socket: process.argv[2], binary: '~/.dsh-romeo/rustxng/rustxng-v0.28.0-x86_64-unknown-linux-musl' })
  const r = await p.search({ query: 'vllm dcp' })
  console.log(JSON.stringify(r))" "$ROOT/share/web-search-romeo.mjs" "$DSH_ROMEO_SOCKET" 2>&1)
check "web plugin: results through ssh + rustxng mcp" has '"url":"https://example.org/a","title":"A for vllm dcp","snippet":"first"'
check "web plugin: duplicates dropped" bash -c '[ "$(grep -o example.org/a <<<"$1" | wc -l | tr -d " ")" = 1 ]' _ "$out"
out=$(cd "$T" && FAKE_ROMEO_UNREACHABLE=1 node --input-type=module -e "
  const m = await import(process.argv[1])
  let p; m.apply({ web: { registerSearchProvider: (x) => { p = x } } }, { binary: 'x' })
  try { await p.search({ query: 'q' }) } catch (e) { console.log(e.message) }" "$ROOT/share/web-search-romeo.mjs" 2>&1)
check "web plugin: a closed SSH connection, said" has "SSH connection to ROMEO is closed"
DSH_ROMEO_MODELS=deepseek DSH_ROMEO_VOICE=off run --status
check "status: web search row" has "web  *on  *RustXNG on the ROMEO login node"
mkdir -p "$T/dsh-home-web"; printf '%s\n' '- id: web' '  config: { searchProvider: searxng }' >"$T/dsh-home-web/cordis.patch.yml"
DSH_HOME=$T/dsh-home-web DSH_ROMEO_MODELS=deepseek DSH_ROMEO_VOICE=off run headless "override"
check "--web on: a web row in ~/.dsh/cordis.patch.yml, said" has "cordis.patch.yml sets dsh's web search itself"
DSH_HOME=$T/dsh-home-web DSH_ROMEO_MODELS=deepseek DSH_ROMEO_VOICE=off run --doctor
check "--doctor: the overriding web row, a warning" has "web row  *warning"
rm -f "$FAKE_ROMEO_HOME/.dsh-romeo/rustxng/rustxng-v0.28.0-x86_64-unknown-linux-musl"
DSH_ROMEO_RUSTXNG_SHA256=0000 DSH_ROMEO_MODELS=deepseek DSH_ROMEO_VOICE=off run headless "bad sum"
check "--web on, checksum mismatch: not installed, said" has "web search unavailable: RustXNG on ROMEO: checksum mismatch"
check "--web on, checksum mismatch: dsh starts without it" grep -q "args: headless --patch .* bad sum" "$FAKE_ROMEO_STATE/dsh-call"
check "--web on, checksum mismatch: no binary left" test ! -e "$FAKE_ROMEO_HOME/.dsh-romeo/rustxng/rustxng-v0.28.0-x86_64-unknown-linux-musl"
DSH_ROMEO_MODELS=deepseek DSH_ROMEO_VOICE=off run --web off headless "no web"
check "--web off: not in the overlay" bash -c "! grep -q dsh-romeo-rustxng '$overlay'"
cp "$T/jobs.saved2" "$FAKE_ROMEO_STATE/jobs"
unset DSH_ROMEO_RUSTXNG_URL DSH_ROMEO_RUSTXNG_SHA256
check "minutes of Slurm durations" bash -c 'eval "$(sed -n "/^minutes_of()/,/^}/p" "$1")"; [ "$(minutes_of 1-02:03:04)" = 1563 ] && [ "$(minutes_of 12:00)" = 12 ] && [ "$(minutes_of 2:00:00)" = 120 ] && [ "$(minutes_of N/A)" = 0 ]' _ "$ROOT/bin/dsh-romeo"
run --help
check "--help: the everyday commands first" has "^Every day"
check "--help: what to run when something is wrong" has "dsh-romeo --doctor"
run --doctor
check "--doctor: the weights checked" has "weights .*ok .*DeepSeek-V4.1-Flash-1017"

for f in "$ROOT/bin/dsh-romeo" "$ROOT/install.sh" "$ROOT/share/rustxng-install.sh" "$ROOT/share/optional-plugins.sh" "$ROOT/share/gateway/start.sh" "$HERE/run.sh" "$SKILL/scripts/env.sh"; do
  out=$(bash -n "$f" 2>&1); check "syntax: $(basename "$f")" test -z "$out"
done
if command -v shellcheck >/dev/null; then
  out=$(shellcheck -S warning "$ROOT/bin/dsh-romeo" "$ROOT/install.sh" "$ROOT/share/optional-plugins.sh" "$ROOT/share/gateway/start.sh" 2>&1); check "shellcheck" test -z "$out"
  out=$(shellcheck -S warning -s bash "$SKILL/scripts/env.sh" 2>&1); check "shellcheck: skill env.sh" test -z "$out"
fi

out=$(DSH_ROMEO_RLT_CHECK=/bin/sh bash "$ROOT/install.sh" --yes 2>&1); code=$?
check "install.sh on ROMEO: says to run it on your computer" has "run install.sh on your own computer"
check "install.sh on ROMEO: exit 1" test "$code" = 1
out=$(bash "$ROOT/install.sh" --search-engine foo 2>&1); code=$?
check "install.sh --search-engine: unknown engine refused" bash -c "[ $code = 2 ] && grep -q 'searxng or rustxng' <<<\"\$1\"" _ "$out"
out=$(bash "$ROOT/install.sh" --help 2>&1)
check "install.sh --help: RustXNG option listed" has "--search-engine rustxng"
check "install.sh: RustXNG pinned by digest" grep -q "rustxng:0.28.0@sha256:" "$ROOT/install.sh"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
