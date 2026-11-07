#!/usr/bin/env bash
# Runs on the ROMEO login node for dsh-romeo --top (piped to bash -s): each running model job's
# vLLM counters, from its own /metrics (the job's direct address, from romeollmtool endpoint, kept
# in ~/.dsh-romeo/endpoints). One line each:
#   now EPOCH
#   last EPOCH                        the last request through the gateway (its stats file)
#   job ID FICHE LEFT RUNNING WAITING KV GENERATED PROMPT     LEFT: Slurm's, KV: 0-1, totals
#   job ID FICHE LEFT - - - - -                                 no metrics (loading)
#   bash -s -- ROMEOLLMTOOL FICHE...
set -u
rlt=$1
shift
cache=$HOME/.dsh-romeo/endpoints
mkdir -p "$cache"
echo "now $(date +%s)"
newest=$(ls -t "$HOME"/.romeollmtool/stats/requests-*.jsonl 2>/dev/null | head -1)
[ -z "$newest" ] || echo "last $(stat -c %Y "$newest" 2>/dev/null || stat -f %m "$newest")"
names=$(printf 'romeollmtool-%s,' "$@")
squeue -u "$USER" -h -t R -n "${names%,}" -o '%i %j %L' 2>/dev/null | while read -r id name left; do
  url=$(cat "$cache/$id" 2>/dev/null)
  if [ -z "$url" ]; then
    url=$("$rlt" endpoint "$id" 2>/dev/null | sed -n 's|.*direct *: *\(http://[^ ]*\)/v1.*|\1|p' | head -1)
    [ -z "$url" ] || echo "$url" >"$cache/$id"
  fi
  m=$([ -z "$url" ] || curl -s -m 3 "$url/metrics" 2>/dev/null | awk '
    /^vllm:num_requests_running[{ ]/ { r += $NF } /^vllm:num_requests_waiting[{ ]/ { w += $NF }
    /^vllm:(kv|gpu)_cache_usage_perc[{ ]/ { if ($NF > k) k = $NF } /^vllm:generation_tokens_total[{ ]/ { g += $NF }
    /^vllm:prompt_tokens_total[{ ]/ { p += $NF } /^vllm:/ { seen = 1 }
    END { if (seen) printf "%d %d %.3f %d %d", r, w, k, g, p }')
  echo "job $id ${name#romeollmtool-} $left ${m:-- - - - -}"
done
find "$cache" -type f -mtime +2 -delete 2>/dev/null || true
