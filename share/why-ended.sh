#!/bin/bash
# Run on ROMEO by dsh-romeo (bin/dsh-romeo, why_ended): Slurm's record of the last job named $1 and
# the known failure lines at the end of its log.
acct=$(sacct -X -n -P -S now-2days --name="$1" -o JobID,State,End,NodeList,ExitCode 2>/dev/null | tail -1)
echo "acct=$acct"
id=${acct%%|*}
[ -n "$id" ] || exit 0
tail -n 400 ~/.romeollmtool/logs/slurm-$id.err ~/.romeollmtool/logs/slurm-$id.out 2>/dev/null | sed -E 's/\[[0-9;]*m//g' |
  grep -oE 'Free memory on device[^(]*\([0-9.]+/[0-9.]+ GiB\)|No available memory for the cache blocks|CUDA out of memory|OutOfMemoryError|DUE TO TIME LIMIT|Out Of Memory|oom-kill|NCCL error|Address already in use|Engine core initialization failed|No such file or directory: .[^ ]*' |
  sort -u | sed 's/^/hit=/'
