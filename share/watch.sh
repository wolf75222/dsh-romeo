#!/usr/bin/env bash
# dsh-romeo's watcher on the ROMEO login node, started by dsh-romeo with the model jobs, ended with
# them (or by the next dsh-romeo, or --stop). Once a minute:
# - idle stop: no request through the gateway for IDLE minutes (the newest
#   ~/.romeollmtool/stats/requests-*.jsonl, written by romeollmtool's gateway and the fast one, at
#   each request) -> stops the model jobs, which would otherwise use GPU hours for nothing;
# - relay: a running job with less than BEFORE minutes left while the models are in use (a request
#   in the last 30 minutes) -> launches the next job of that fiche, so a long session is not cut:
#   the gateway sends requests to a job only once it answers, and the old one ends on its own.
#   Not when your GPU limit would be passed (one Kimi job is 32 GPUs of 60: no relay for Kimi).
#   bash watch.sh ROMEOLLMTOOL PROJECT TIME IDLE|off on|off BEFORE GENERATION FICHE...
# Log: ~/.dsh-romeo/watch.log, one line per action: "EPOCH stopped JOBS idle MINUTES",
# "EPOCH relay FICHE OLDJOB NEWJOB", "EPOCH no-relay FICHE OLDJOB REASON".
# Several login nodes share the home: ~/.dsh-romeo/watch.gen holds the newest watcher's
# GENERATION, and any other watcher, on any node, ends at its next round.
set -u
# It lives for hours: no descriptor of the command that started it stays open (its pipes would
# never close).
for fd in $(seq 3 255); do eval "exec $fd>&-" 2>/dev/null; done
rlt=$1 project=$2 time=$3 idle=$4 relay=$5 before=$6 gen=$7
shift 7
fiches=("$@")
dir=$HOME/.dsh-romeo
log=$dir/watch.log
mkdir -p "$dir"
echo "$gen" >"$dir/watch.gen"
started=$(date +%s)
said=' '

minutes() {  # a Slurm duration ([D-]H:MM:SS, MM:SS) in minutes
  local t=$1 d=0 a b c
  case $t in *-*) d=${t%%-*}; t=${t#*-} ;; esac
  IFS=: read -r a b c <<<"$t"
  if [ -n "${c:-}" ]; then echo $((10#$d * 1440 + 10#$a * 60 + 10#$b))
  elif [ -n "${b:-}" ]; then echo $((10#$d * 1440 + 10#$a))
  else echo $((10#$d * 1440)); fi
}
epoch() { date -d "$1" +%s 2>/dev/null || date -j -f %Y-%m-%dT%H:%M:%S "$1" +%s 2>/dev/null || echo 0; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

while :; do
  [ "$(cat "$dir/watch.gen" 2>/dev/null)" = "$gen" ] || exit 0   # a newer watcher, or --stop
  names=$(printf 'romeollmtool-%s,' "${fiches[@]}")
  jobs=$(squeue -u "$USER" -h -n "${names%,}" -o '%i %j %T %L %S %M' 2>/dev/null) || { sleep "${DSH_ROMEO_WATCH_SECONDS:-60}"; continue; }
  [ -n "$jobs" ] || exit 0   # no model job left: nothing to watch
  now=$(date +%s)
  # The last activity: a request, this watcher's start, or a job that just started (it loads).
  last=$started
  newest=$(ls -t "$HOME"/.romeollmtool/stats/requests-*.jsonl 2>/dev/null | head -1)
  [ -z "$newest" ] || { m=$(mtime "$newest"); [ "$m" -le "$last" ] || last=$m; }
  while read -r id _ st left start _; do
    [ "$st" = RUNNING ] || continue
    s=$(epoch "$start"); [ "$s" -le "$last" ] || last=$s
  done <<<"$jobs"
  if [ "$idle" != off ] && [ $((now - last)) -ge $((idle * 60)) ] && grep -q ' RUNNING ' <<<"$jobs"; then
    ids=$(awk '{ print $1 }' <<<"$jobs" | tr '\n' ' ')
    for id in $ids; do "$rlt" stop "$id" >/dev/null 2>&1 || scancel "$id" 2>/dev/null || true; done
    echo "$now stopped ${ids% } idle $(((now - last) / 60))" >>"$log"
    exit 0
  fi
  if [ "$relay" = on ] && [ $((now - last)) -lt 1800 ]; then
    held=$(squeue -u "$USER" -h -t R,PD -o '%D %b' | awk '{ n = $2; sub(/.*:/, "", n); if (n ~ /^[0-9]+$/) s += $1 * n } END { print s + 0 }')
    limit=$(sacctmgr -nP show assoc user="$USER" account="$project" format=GrpTRES 2>/dev/null | grep -oE 'gres/gpu=[0-9]+' | head -1 | cut -d= -f2)
    for f in "${fiches[@]}"; do
      mine=$(awk -v n="romeollmtool-$f" '$2 == n' <<<"$jobs")
      # A job ending soon that has run for longer than that (not itself a relay of a short job),
      # and no other job of that fiche to take over (queued, or with time left).
      old=$(awk '$3 == "RUNNING" { print $1, $4, $6 }' <<<"$mine" | while read -r id left el; do
        [ "$(minutes "$left")" -lt "$before" ] && [ "$(minutes "$el")" -ge "$before" ] && echo "$id"; done | head -1)
      [ -n "$old" ] || continue
      others=$(awk -v o="$old" '$1 != o' <<<"$mine" | while read -r id _ st left _; do
        [ "$st" = PENDING ] || [ "$(minutes "$left")" -ge "$before" ] && echo "$id"; done)
      [ -z "$others" ] || continue
      case $said in *" $old "*) continue ;; esac
      s=$("$rlt" launch "$f" --project-code "$project" --time "$time" --dry-run --no-wait 2>/dev/null | grep '^#SBATCH')
      n=$(sed -n 's/^#SBATCH --nodes=//p' <<<"$s"); g=$(sed -n 's/^#SBATCH --gres=gpu:\([0-9]*\).*/\1/p' <<<"$s")
      need=$(( ${n:-1} * ${g:-0} ))
      if [ -n "$limit" ] && [ $((held + need)) -gt "$limit" ]; then
        echo "$now no-relay $f $old over your limit of $limit GPUs ($held held, $need more)" >>"$log"
      else
        out=$("$rlt" launch "$f" --project-code "$project" --time "$time" --no-wait 2>&1)
        new=$(printf '%s\n' "$out" | grep -oE '[0-9]{5,}' | head -1)
        echo "$now relay $f $old ${new:-failed}" >>"$log"
        held=$((held + need))
      fi
      said="$said$old "
    done
  fi
  sleep "${DSH_ROMEO_WATCH_SECONDS:-60}"
done
