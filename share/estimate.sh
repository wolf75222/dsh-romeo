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
#   all ok EPOCH | all err MESSAGE    the whole-node jobs together: one job with all their nodes,
#                                     since every model must run for dsh to work
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
echo "nodes $(sinfo -h -N -o '%N %T %f' | awk '/armgpu/' | sort -u | awk '{ print $2 }' | sort | uniq -c | tr '\n' ' ')"

base='' whole=0 nodes=0 mem=0 cpus=0
for f in "$@"; do
  s=$("$rlt" launch "$f" --project-code "$project" --time "$time" --dry-run --no-wait 2>&1)
  case $s in *'#!'*) ;; *) echo "one $f err $(printf '%s\n' "$s" | tail -1)"; continue ;; esac
  sb=$(printf '%s\n' "$s" | grep '^#SBATCH' | grep -vE -- '--(output|error|comment)=')
  n=$(printf '%s\n' "$sb" | sed -n 's/^#SBATCH --nodes=//p'); n=${n:-1}
  g=$(printf '%s\n' "$sb" | sed -n 's/^#SBATCH --gres=gpu:\([0-9]*\).*/\1/p'); g=${g:-0}
  r=$(printf '%s\n' "$sb" | test_only)
  case $r in err*) echo "one $f $r" ;; *) echo "one $f ok $r $((n * g)) $n" ;; esac
  [ "$g" -ge 4 ] || continue  # a job on part of a node fits beside the others
  whole=$((whole + 1)) nodes=$((nodes + n))
  m=$(printf '%s\n' "$sb" | sed -n 's/^#SBATCH --mem=\([0-9]*\)G$/\1/p'); [ "${m:-0}" -le "$mem" ] || mem=$m
  c=$(printf '%s\n' "$sb" | sed -n 's/^#SBATCH --cpus-per-task=//p'); [ "${c:-0}" -le "$cpus" ] || cpus=$c
  [ -n "$base" ] || base=$(printf '%s\n' "$sb" | grep -E -- '--(account|time|constraint|partition|reservation|ntasks-per-node)=')
done
if [ "$whole" -ge 2 ]; then
  r=$(printf '%s\n#SBATCH --nodes=%s\n#SBATCH --gres=gpu:4\n#SBATCH --cpus-per-task=%s\n#SBATCH --mem=%sG\n' "$base" "$nodes" "$cpus" "$mem" | test_only)
  case $r in err*) echo "all $r" ;; *) echo "all ok $r" ;; esac
fi
