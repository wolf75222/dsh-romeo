#!/usr/bin/env bash
# Runs on the ROMEO login node for dsh-romeo --clean (piped to bash -s): romeollmtool's job logs
# older than DAYS days, never those of a job still in the queue, and the ROMEO home's use.
#   bash -s -- DAYS list|delete
# Prints "logs COUNT KB" (found, or deleted with delete) and "home USED LIMIT PERCENT" when known.
set -u
days=$1 mode=$2
dir=$HOME/.romeollmtool/logs
keep=$(squeue -u "$USER" -h -o '%i' 2>/dev/null | tr '\n' ' ')
old() {
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -name 'slurm-*.*' -mtime +"$days" | while read -r f; do
    id=${f##*/slurm-}; id=${id%%.*}
    case " $keep " in *" $id "*) continue ;; esac
    echo "$f"
  done
}
files=$(old)
n=$(printf '%s' "$files" | grep -c . || true)
kb=0
[ "$n" = 0 ] || kb=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 du -k 2>/dev/null | awk '{ s += $1 } END { print s + 0 }')
[ "$mode" != delete ] || [ "$n" = 0 ] || printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 rm -f
echo "logs $n $kb"
q=/apps/romeotools/myquotas.sh
if [ -x "$q" ]; then
  "$q" 2>/dev/null | awk -v u="$USER" '$1 == u && $2 == "home" && $4 ~ /o$/ { p = ""; for (i = 9; i <= NF; i++) if ($i ~ /^[0-9]+%$/) p = $i; print "home", $3, $4, $7, $8, p; exit }'
fi
