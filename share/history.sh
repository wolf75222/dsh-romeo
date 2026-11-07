#!/usr/bin/env bash
# Runs on the ROMEO login node (piped to bash -s): the model jobs of the last DAYS days.
#   bash -s -- DAYS FICHE...
# One line each, oldest first: "job ID FICHE SUBMIT START END STATE READY GPUS NOTE"
# Epochs, "-" when unknown: START for a job that never ran, END for one still running, READY when
# its log never said "Application startup complete" (READY is the last time logged before it).
# NOTE: idle:MINUTES when dsh-romeo's watcher stopped it, relayed when it launched the next one,
# else "-" (share/watch.sh, ~/.dsh-romeo/watch.log).
set -u
days=$1
shift
epoch() { date -d "$1" +%s 2>/dev/null || date -j -f %Y-%m-%dT%H:%M:%S "$1" +%s 2>/dev/null || echo -; }
logs=$HOME/.romeollmtool/logs
names=$(printf 'romeollmtool-%s,' "$@")
sacct -X -nP -S "now-${days}days" --name "${names%,}" -o JobID,JobName,Submit,Start,End,State,AllocTRES 2>/dev/null |
while IFS='|' read -r id name submit start end state tres; do
  case $id in *[!0-9]*) continue ;; esac
  gpus=$(printf '%s\n' "$tres" | grep -oE 'gres/gpu=[0-9]+' | cut -d= -f2)
  ready=-
  if [ -f "$logs/slurm-$id.err" ] && line=$(grep -n -m1 'Application startup complete' "$logs/slurm-$id.err" | cut -d: -f1) && [ -n "$line" ]; then
    # The last time printed before it: "2026-11-07 12:19:41", torch's "W1107 12:25:18", vLLM's "INFO 11-07 12:25:18"
    t=$(head -n "$line" "$logs/slurm-$id.err" | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}|[IWE][0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}|[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' | tail -1)
    y=${submit%%-*}
    case $t in
      20*) ready=$(epoch "${t/ /T}") ;;
      [IWE]*) ready=$(epoch "$y-${t:1:2}-${t:3:2}T${t#* }") ;;
      ?*) ready=$(epoch "$y-${t%% *}T${t#* }") ;;
    esac
  fi
  case $start in Unknown | None | '') s=- ;; *) s=$(epoch "$start") ;; esac
  case $end in Unknown | None | '') e=- ;; *) e=$(epoch "$end") ;; esac
  note=$(awk -v id="$id" '$2 == "stopped" { for (i = 3; i < NF - 1; i++) if ($i == id) n = "idle:" $NF } $2 == "relay" && $4 == id { n = "relayed" } END { print n ? n : "-" }' "$HOME/.dsh-romeo/watch.log" 2>/dev/null || echo -)
  echo "job $id ${name#romeollmtool-} $(epoch "$submit") $s $e ${state%% *} $ready ${gpus:-0} ${note:--}"
done
