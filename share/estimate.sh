#!/usr/bin/env bash
# Runs on the ROMEO login node for dsh-romeo --estimate (piped to bash -s): when the model jobs
# would start if launched now. Slurm's own estimate (sbatch --test-only), nothing is submitted.
#   bash -s -- ROMEOLLMTOOL PROJECT TIME FICHE...
# One line each, for dsh-romeo to read:
#   now EPOCH
#   held GPUS                         GPUs your running and pending jobs hold or wait for
#   limit GPUS                        your GPU limit (GrpTRES), empty when none
#   nodes N STATE N STATE...          GPU nodes by state
#   one FICHE ok EPOCH GPUS NODES     a job of that fiche alone
#   one FICHE err MESSAGE
#   plimit GPUS                       the project's GPU limit, for all its members together
#   pjob USER STATE GPUS END          a GPU job of the project (USER "-": yours), END its end
#   fairshare F                       your fair-share in the project (0-1)
#   ahead JOBS GPUS                   other projects' GPU jobs waiting with a higher priority
#   queue JOBS GPUS                   GPU jobs waiting in the queue (everyone's), GPUs they ask
#   fitnow TIME                       the longest job (by half hours) that would start now, when
#                                     TIME itself waits
#   overall TIME EPOCH | overall TIME err MESSAGE
#                                     when every job runs, for a job length TIME: the whole-node
#                                     jobs as one job with all their nodes (every model must run
#                                     for dsh to work), the others alone; TIME, then shorter ones
#                                     (Slurm fits a shorter job into a gap sooner)
set -u
rlt=$1 project=$2 time=$3
shift 3
epoch() { date -d "$1" +%s 2>/dev/null || date -j -f %Y-%m-%dT%H:%M:%S "$1" +%s; }
test_only() {  # stdin: #SBATCH lines. "EPOCH" or "err MESSAGE"
  local o at
  o=$({ echo '#!/bin/bash'; cat; echo true; } | sbatch --test-only 2>&1)
  at=$(printf '%s\n' "$o" | sed -n 's/.* to start at \([0-9T:-]*\) .*/\1/p' | head -1)
  if [ -n "$at" ]; then epoch "$at"; else echo "err $(printf '%s\n' "$o" | tail -1)"; fi
}

echo "now $(date +%s)"
echo "held $(squeue -u "$USER" -h -t R,PD -o '%D %b' | awk '{ n = $2; sub(/.*:/, "", n); if (n ~ /^[0-9]+$/) s += $1 * n } END { print s + 0 }')"
echo "limit $(sacctmgr -nP show assoc user="$USER" account="$project" format=GrpTRES 2>/dev/null | grep -oE 'gres/gpu=[0-9]+' | head -1 | cut -d= -f2)"
# Why a job may wait. The project's GPU limit, shared by its members, and what each holds or waits
# for, with when their running jobs end ("pjob USER STATE GPUS END", USER - for yours); your
# fair-share (0-1: low when the project used ROMEO a lot lately) and the GPU jobs waiting with a
# higher priority than yours would get from it.
echo "plimit $(sacctmgr -nP show assoc account="$project" user= format=GrpTRES 2>/dev/null | grep -oE 'gres/gpu=[0-9]+' | head -1 | cut -d= -f2)"
squeue -A "$project" -h -t R,PD -o '%u|%T|%D|%b|%e' 2>/dev/null | awk -F'|' -v me="$USER" '{ n = $4; sub(/.*:/, "", n); if (n !~ /^[0-9]+$/) n = 0; if (n > 0) print "pjob", ($1 == me ? "-" : $1), $2, $3 * n, $5 }'
fs=$(sshare -hP -U -A "$project" -o FairShare 2>/dev/null | tail -1)
echo "fairshare ${fs:-}"
w=$(scontrol show config 2>/dev/null | awk -F'= *' '/^PriorityWeightFairShare/ { print $2 + 0 }')
mine=$(awk -v f="${fs:-1}" -v w="${w:-0}" 'BEGIN { printf "%d", f * w }')
echo "ahead $(squeue -h -t PD -o '%D|%b|%Q|%a' 2>/dev/null | awk -F'|' -v p="$mine" -v a="$project" '{ n = $2; sub(/.*:/, "", n); if (n ~ /^[0-9]+$/ && n > 0 && $3 > p && $4 != a) { j++; s += $1 * n } } END { print j + 0, s + 0 }')"
# The GPU jobs waiting in the queue, everyone's: how many, and how many GPUs they ask for.
echo "queue $(squeue -h -t PD -o '%D %b' 2>/dev/null | awk '{ n = $2; sub(/.*:/, "", n); if (n ~ /^[0-9]+$/ && n > 0) { j++; s += $1 * n } } END { print j + 0, s + 0 }')"
echo "nodes $(sinfo -h -N -o '%N %T %f' | awk '/armgpu/' | sort -u | awk '{ print $2 }' | sort | uniq -c | tr '\n' ' ')"

whole_sb='' parts=() nodes=0 mem=0 cpus=0
for f in "$@"; do
  s=$("$rlt" launch "$f" --project-code "$project" --time "$time" --dry-run --no-wait 2>&1)
  case $s in *'#!'*) ;; *) echo "one $f err $(printf '%s\n' "$s" | tail -1)"; continue ;; esac
  sb=$(printf '%s\n' "$s" | grep '^#SBATCH' | grep -vE -- '--(output|error|comment)=')
  n=$(printf '%s\n' "$sb" | sed -n 's/^#SBATCH --nodes=//p'); n=${n:-1}
  g=$(printf '%s\n' "$sb" | sed -n 's/^#SBATCH --gres=gpu:\([0-9]*\).*/\1/p'); g=${g:-0}
  r=$(printf '%s\n' "$sb" | test_only)
  case $r in err*) echo "one $f $r"; continue ;; *) echo "one $f ok $r $((n * g)) $n" ;; esac
  if [ "$g" -lt 4 ]; then parts+=("$sb"); continue; fi  # a job on part of a node fits beside the others
  nodes=$((nodes + n))
  m=$(printf '%s\n' "$sb" | sed -n 's/^#SBATCH --mem=\([0-9]*\)G$/\1/p'); [ "${m:-0}" -le "$mem" ] || mem=$m
  c=$(printf '%s\n' "$sb" | sed -n 's/^#SBATCH --cpus-per-task=//p'); [ "${c:-0}" -le "$cpus" ] || cpus=$c
  [ -n "$whole_sb" ] || whole_sb=$(printf '%s\n' "$sb" | grep -E -- '--(account|time|constraint|partition|reservation|ntasks-per-node)=')
done
[ -z "$whole_sb" ] || whole_sb=$(printf '%s\n#SBATCH --nodes=%s\n#SBATCH --gres=gpu:4\n#SBATCH --cpus-per-task=%s\n#SBATCH --mem=%sG\n' "$whole_sb" "$nodes" "$cpus" "$mem")
[ -n "$whole_sb" ] || [ ${#parts[@]} -gt 0 ] || exit 0
seconds() { local h m s; IFS=: read -r h m s <<<"$1"; echo $((10#$h * 3600 + 10#$m * 60 + 10#${s:-0})); }
hms() { printf '%02d:%02d:00' $(($1 / 3600)) $(($1 % 3600 / 60)); }
overall_at() {  # $1 a job length: when every job runs (EPOCH), or "err MESSAGE"
  local latest=0 r sb
  for sb in "$whole_sb" ${parts[@]+"${parts[@]}"}; do
    [ -n "$sb" ] || continue
    r=$(printf '%s\n' "$sb" | sed "s/^#SBATCH --time=.*/#SBATCH --time=$1/" | test_only)
    case $r in err*) echo "$r"; return ;; esac
    [ "$r" -le "$latest" ] || latest=$r
  done
  echo "$latest"
}
main=$(overall_at "$time")
echo "overall $time $main"
for t in 04:00:00 02:00:00 01:00:00; do
  [ "$(seconds "$t")" -lt "$(seconds "$time")" ] && echo "overall $t $(overall_at "$t")"
done
# The longest job that starts now, by half hours, when the length asked waits: Slurm fits a job
# into the gap before the next big job's start (backfill), so shorter starts sooner.
case $main in
  err*) ;;
  *) now=$(date +%s)
     if [ "$main" -gt $((now + 120)) ]; then
       lo=0 hi=$(($(seconds "$time") / 1800 - 1))
       while [ "$lo" -lt "$hi" ]; do
         mid=$(((lo + hi + 1) / 2))
         r=$(overall_at "$(hms $((mid * 1800)))")
         case $r in err*) hi=$((mid - 1)); continue ;; esac
         if [ "$r" -le $((now + 120)) ]; then lo=$mid; else hi=$((mid - 1)); fi
       done
       [ "$lo" = 0 ] || echo "fitnow $(hms $((lo * 1800)))"
     fi ;;
esac
