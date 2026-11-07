#!/usr/bin/env bash
# Runs on the ROMEO login node (piped to bash -s): ROMEO's coming stops that take its GPU nodes,
# from Slurm's reservations. One line each: "maint START END NAME COMMENT" (epochs), soonest first.
# A stop: a reservation of ROMEO's admins (group romeoadmin) or flagged MAINT, on 10 nodes or more
# with GPU nodes (romeo-a); trainings and one-node repairs are left out.
epoch() { date -d "$1" +%s 2>/dev/null || date -j -f %Y-%m-%dT%H:%M:%S "$1" +%s; }
now=$(date +%s)
scontrol show res -o 2>/dev/null | while read -r line; do
  get() { printf '%s\n' "$line" | grep -oE "(^| )$1=[^ ]*" | head -1 | cut -d= -f2-; }
  case " $(get Flags) $(get Groups) " in *MAINT* | *romeoadmin*) ;; *) continue ;; esac
  [ "$(get NodeCnt)" -ge 10 ] 2>/dev/null || continue
  case $(get Nodes) in *romeo-a*) ;; *) continue ;; esac
  s=$(epoch "$(get StartTime)") e=$(epoch "$(get EndTime)") || continue
  [ "$e" -gt "$now" ] || continue
  comment=$(printf '%s\n' "$line" | sed -n 's/.* Comment=\(.*\)$/\1/p')
  echo "maint $s $e $(get ReservationName) ${comment:-}"
done | sort -k2 -n
