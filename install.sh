#!/usr/bin/env bash
# Installs dsh-romeo on macOS, Linux or WSL and prepares your ROMEO account.
#
#   ./install.sh                       asks what it cannot guess
#   ./install.sh --project r123456     the Slurm project code that pays for the model jobs
#   ./install.sh --host romeo          the ssh alias of ROMEO (default: romeo)
#   ./install.sh --bin-dir DIR         where to link the dsh-romeo command (default: ~/.local/bin)
#   ./install.sh --search              also run SearXNG in Docker for web search (127.0.0.1:8888)
#   ./install.sh --yes                 no questions: install dsh in a user-owned npm prefix
#
# Run it again after `git pull`: it keeps your settings.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
CONFIG_DIR=${DSH_ROMEO_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsh-romeo}
BIN_DIR=$HOME/.local/bin
HOST='' PROJECT='' SEARCH=0 YES=0
RLT_DEFAULT=/apps/romeotools/romeollmtool/romeollmtool

while [ $# -gt 0 ]; do
  case $1 in
    --project) PROJECT=$2; shift 2 ;;
    --host) HOST=$2; shift 2 ;;
    --bin-dir) BIN_DIR=$2; shift 2 ;;
    --search) SEARCH=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then B=$'\e[1m' G=$'\e[32m' R=$'\e[31m' N=$'\e[0m'; else B='' G='' R='' N=''; fi
step() { printf '%s\n' "${B}==>${N} $*"; }
ok() { printf '%s\n' "    ${G}ok${N} $*"; }
die() { printf '%s\n' "${R}error:${N} $*" >&2; exit 1; }
ask() {  # ask "question" default -> answer (the default without a terminal or with --yes)
  local answer
  if [ "$YES" = 1 ] || [ ! -t 0 ]; then printf '%s' "$2"; return; fi
  read -r -p "    $1 [$2] " answer </dev/tty
  printf '%s' "${answer:-$2}"
}

# Settings of a previous install are kept unless given again.
# shellcheck source=/dev/null
[ -f "$CONFIG_DIR/config" ] && . "$CONFIG_DIR/config"
# The September weights' fiche, the default before 2026-10-28: move to the 1017 one.
[ "${DSH_ROMEO_FICHE:-}" = dsh-deepseek-v4.1-flash-1m ] && DSH_ROMEO_FICHE=dsh-deepseek-v4.1-flash-1017-1m
HOST=${HOST:-${ROMEO_SSH_HOST:-romeo}}
PROJECT=${PROJECT:-${ROMEO_PROJECT:-}}

# ---------------------------------------------------------------- this computer

# dsh runs on your computer and reaches ROMEO over ssh: on a ROMEO login node there is nothing to install.
if [ -x "${DSH_ROMEO_RLT_CHECK:-$RLT_DEFAULT}" ]; then
  die "this is ROMEO ($(hostname -s)): run install.sh on your own computer (macOS or Linux), the one you ssh to ROMEO from.
       There: git clone https://github.com/wolf75222/dsh-romeo.git ~/dsh-romeo && ~/dsh-romeo/install.sh"
fi

step "Tools on this computer"
case $(uname -s) in
  MINGW*|MSYS*|CYGWIN*) die "use install.ps1 in PowerShell for native Windows, or run install.sh inside WSL" ;;
esac
for tool in ssh curl; do command -v $tool >/dev/null || die "$tool is missing"; done
command -v node >/dev/null || die "Node.js 20 or later is needed for dsh: https://nodejs.org (or: brew install node)"
case $(node -p 'process.platform') in
  win32) die "install Linux Node.js inside WSL, or use install.ps1 for native Windows" ;;
esac
node_major=$(node -p 'process.versions.node.split(".")[0]')
[ "$node_major" -ge 20 ] || die "Node.js $node_major is too old for dsh: install Node.js 20 or later"
ok "ssh, curl, Node.js $(node --version)"

DSH_BIN=${DSH_ROMEO_DSH:-dsh}
if command -v "$DSH_BIN" >/dev/null; then
  ok "dsh $("$DSH_BIN" --version 2>/dev/null)"
elif [ -x "$CONFIG_DIR/npm/bin/dsh" ]; then
  DSH_BIN=$CONFIG_DIR/npm/bin/dsh
  ok "dsh $("$DSH_BIN" --version 2>/dev/null)"
else
  command -v npm >/dev/null || die "npm is missing (it comes with Node.js)"
  [ "$(ask "dsh (DeepSeek Harness) is not installed. Install it with npm? (y/n)" y)" = y ] \
    || die "install dsh first or rerun install.sh --yes"
  # Never write to /usr/local, require sudo, or change the user's npm prefix/PATH.
  npm install --global --prefix "$CONFIG_DIR/npm" @deepseek-ai/dsh \
    || die "npm install in $CONFIG_DIR/npm failed"
  DSH_BIN=$CONFIG_DIR/npm/bin/dsh
  [ -x "$DSH_BIN" ] || die "npm did not create $DSH_BIN"
  ok "dsh $("$DSH_BIN" --version 2>/dev/null)"
fi

# ---------------------------------------------------------------- ROMEO

step "Connection to ROMEO ($HOST)"
quiet() { grep -v -E 'post-quantum|store now, decrypt later|openssh.com/pq|^\*\* ' >&2 || true; }
if ! ssh -n -o BatchMode=yes -o ConnectTimeout=20 "$HOST" true 2> >(quiet); then
  cat >&2 <<EOF
${R}error:${N} 'ssh $HOST' must work without typing a password. Add to ~/.ssh/config:

    Host $HOST
        HostName romeo1.univ-reims.fr
        User <your ROMEO login>
        IdentityFile ~/.ssh/<your key registered on ROMEO>

then check with: ssh $HOST hostname
EOF
  exit 1
fi
ok "ssh $HOST"

remote=$(ssh -n -o BatchMode=yes "$HOST" "
  test -x $RLT_DEFAULT && echo rlt=yes || echo rlt=no
  sacctmgr -n -P show assoc user=\$USER format=account 2>/dev/null | sort -u | grep -v -x -E 'default|' | sed 's/^/account=/'
" 2> >(quiet)) || die "cannot run commands on $HOST"
grep -q '^rlt=yes' <<<"$remote" || die "romeollmtool is not available at $RLT_DEFAULT on ROMEO (ROMEO support: https://romeo-ticket.univ-reims.fr/)"
ok "romeollmtool"

accounts=$(sed -n 's/^account=//p' <<<"$remote" | tr '\n' ' ')
if [ -z "$PROJECT" ]; then
  first=${accounts%% *}
  [ -n "$first" ] || die "no Slurm project found for your ROMEO user: give one with --project"
  [ "$(printf '%s' "$accounts" | wc -w | tr -d ' ')" -gt 1 ] && printf '%s\n' "    your projects: $accounts"
  PROJECT=$(ask "Project code to charge for the model jobs (GPU hours)" "$first")
fi
case " $accounts " in *" $PROJECT "*) ok "project $PROJECT" ;;
  *) printf '%s\n' "    ${R}warning:${N} $PROJECT is not among your Slurm accounts ($accounts)" ;; esac

# ---------------------------------------------------------------- settings and command

step "Settings: $CONFIG_DIR/config"
mkdir -p "$CONFIG_DIR"
SEARX=${DSH_ROMEO_SEARXNG_URL:-}
[ "$SEARCH" = 1 ] && SEARX=http://127.0.0.1:8888
cat >"$CONFIG_DIR/config" <<EOF
# dsh-romeo settings (sourced by bin/dsh-romeo). A variable set in the environment wins.
ROMEO_SSH_HOST=\${ROMEO_SSH_HOST:-$HOST}
ROMEO_PROJECT=\${ROMEO_PROJECT:-$PROJECT}
# romeollmtool fiche of the model: dsh-deepseek-v4.1-flash-1017-1m (2 nodes, 1M context, the fastest)
# or deepseek-v4.1-flash-vllm (ROMEO's validated fiche: 1 node, 262K context, slower to load).
DSH_ROMEO_FICHE=\${DSH_ROMEO_FICHE:-${DSH_ROMEO_FICHE:-dsh-deepseek-v4.1-flash-1017-1m}}
# Model job duration (HH:MM:SS, at most 24:00:00). The job is billed while it runs: --stop it.
DSH_ROMEO_TIME=\${DSH_ROMEO_TIME:-${DSH_ROMEO_TIME:-08:00:00}}
# Local port of the tunnel to the gateway.
DSH_ROMEO_PORT=\${DSH_ROMEO_PORT:-${DSH_ROMEO_PORT:-11318}}
# Default reasoning effort: none, low, high or max.
DSH_ROMEO_EFFORT=\${DSH_ROMEO_EFFORT:-${DSH_ROMEO_EFFORT:-max}}
# SearXNG for web search (empty: no web search). install.sh --search runs one in Docker.
DSH_ROMEO_SEARXNG_URL=\${DSH_ROMEO_SEARXNG_URL:-$SEARX}
# Gateway: standard (romeollmtool's), or fast (no 100-stream cap, affinity across jobs: docs/tuning.md).
DSH_ROMEO_GATEWAY=\${DSH_ROMEO_GATEWAY:-${DSH_ROMEO_GATEWAY:-standard}}
EOF
# %q preserves spaces and shell metacharacters in the user-owned executable path.
printf 'DSH_ROMEO_DSH=${DSH_ROMEO_DSH:-%q}\n' "$DSH_BIN" >>"$CONFIG_DIR/config"
ok "written"

mkdir -p "$BIN_DIR"
target=$BIN_DIR/dsh-romeo
if [ -e "$target" ] && [ ! -L "$target" ]; then
  mv "$target" "$target.before-dsh-romeo"
  printf '%s\n' "    an older dsh-romeo was kept as $target.before-dsh-romeo"
fi
ln -sf "$ROOT/bin/dsh-romeo" "$target"
ok "$target -> $ROOT/bin/dsh-romeo"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *)
  printf '%s\n' "    ${R}add $BIN_DIR to your PATH${N}, e.g. echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc" ;; esac

# The romeo skill (Slurm, Spack, GPFS over the shared ssh connection), in the user skill root that
# dsh scans (~/.agents/skills, or $DSH_AGENTS_HOME/skills) and other agents read too.
step "Skill romeo"
skills=${DSH_AGENTS_HOME:-$HOME/.agents}/skills
mkdir -p "$skills"
if [ -e "$skills/romeo" ] && [ ! -L "$skills/romeo" ]; then
  if [ -e "$skills/romeo.before-dsh-romeo" ]; then
    printf '%s\n' "    ${R}warning:${N} $skills/romeo is your own skill: kept, dsh-romeo's is not linked"
  else
    mv "$skills/romeo" "$skills/romeo.before-dsh-romeo"
    printf '%s\n' "    your own romeo skill was kept as $skills/romeo.before-dsh-romeo"
  fi
fi
if [ ! -e "$skills/romeo" ] || [ -L "$skills/romeo" ]; then
  ln -sfn "$ROOT/share/skills/romeo" "$skills/romeo"
  ok "$skills/romeo -> $ROOT/share/skills/romeo"
fi

step "Model fiche on ROMEO"
DSH_ROMEO_CONFIG_DIR=$CONFIG_DIR "$ROOT/bin/dsh-romeo" --setup | sed 's/^/    /'

# ---------------------------------------------------------------- web search (optional)

if [ "$SEARCH" = 1 ]; then
  step "SearXNG in Docker (web search)"
  command -v docker >/dev/null || die "Docker is needed for --search: https://www.docker.com/products/docker-desktop"
  docker info >/dev/null 2>&1 || die "Docker is installed but not running: start Docker Desktop and run install.sh --search again"
  mkdir -p "$CONFIG_DIR/searxng"
  if [ ! -f "$CONFIG_DIR/searxng/settings.yml" ]; then
    secret=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')   # no head: SIGPIPE + pipefail
    sed "s/__SECRET__/$secret/" "$ROOT/share/searxng/settings.yml" >"$CONFIG_DIR/searxng/settings.yml"
  fi
  docker rm -f dsh-romeo-searxng >/dev/null 2>&1 || true
  docker run -d --name dsh-romeo-searxng --restart unless-stopped -p 127.0.0.1:8888:8080 \
    -v "$CONFIG_DIR/searxng:/etc/searxng" searxng/searxng >/dev/null
  for _ in $(seq 1 30); do curl -sf -m 2 'http://127.0.0.1:8888/search?q=test&format=json' >/dev/null && break; sleep 2; done
  curl -sf -m 5 'http://127.0.0.1:8888/search?q=test&format=json' >/dev/null && ok "SearXNG on http://127.0.0.1:8888" \
    || printf '%s\n' "    ${R}warning:${N} SearXNG does not answer yet (docker logs dsh-romeo-searxng)"
fi

cat <<EOF

${G}dsh-romeo is installed.${N} Start the model and open dsh:

    dsh-romeo --launch        # one model job (2 nodes, 8 GPUs), about 10 min to load, then the Web UI
    dsh-romeo                 # later, while the job runs
    dsh-romeo --stop          # when you are done: the job uses GPU hours of $PROJECT

Other clients: dsh-romeo --run opencode | codex | claude | aider | python3 ...  (docs/clients.md)
EOF
