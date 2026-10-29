# Source me (bash or zsh): defines R (one command on a ROMEO login node) and, off ROMEO, RSYNC_SSH.
#   . ~/.agents/skills/romeo/scripts/env.sh        # or the scripts/ folder next to this skill's SKILL.md
# Works on the user's computer (over ssh) and on ROMEO itself (runs locally).
# ROMEO_PROJECT: from the environment, else dsh-romeo's config, else empty (then choose one, see SKILL.md).
# shellcheck disable=SC2034,SC1091   # variables are for the caller; the config is the user's

if [ -d /apps/romeotools ]; then
  ROMEO_WHERE=romeo
  R() { bash -lc "$1"; }
else
  ROMEO_WHERE=remote
  [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/dsh-romeo/config" ] && . "${XDG_CONFIG_HOME:-$HOME/.config}/dsh-romeo/config"
  ROMEO_SSH_HOST=${ROMEO_SSH_HOST:-romeo}
  # dsh-romeo's shared connection when it is open, a normal one otherwise.
  ROMEO_CTL=$HOME/.ssh/dsh-romeo-$ROMEO_SSH_HOST.sock
  RSYNC_SSH="ssh -o BatchMode=yes -o LogLevel=ERROR -o ControlPath=$ROMEO_CTL"   # for rsync -e
  R() { ssh -n -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=20 -o ControlPath="$ROMEO_CTL" "$ROMEO_SSH_HOST" "$1"; }
fi
export ROMEO_PROJECT=${ROMEO_PROJECT:-}
