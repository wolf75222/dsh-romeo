#!/bin/bash
# start.sh PORT [NPROCS] (run on a ROMEO login node by dsh-romeo, DSH_ROMEO_GATEWAY=fast)
#
# A second, unmanaged romeollmtool gateway with sitecustomize.py next to this script: no
# 100-connection pool, session affinity across model jobs, longer upstream timeouts.
# Same key and same model jobs as romeollmtool's own gateway. NPROCS processes share PORT
# (SO_REUSEPORT). Each stops after 8 hours; it never cancels a job.
# Already answering on PORT: nothing to do. Prints why when it does not start (exit 1).
PORT=${1:?port}
N=${2:-4}
D=$(cd "$(dirname "$0")" && pwd)
RLT=${ROMEOLLMTOOL:-/apps/romeotools/romeollmtool/romeollmtool}
PY=${ROMEOLLMTOOL_PYTHON:-/apps/romeotools/romeollmtool/venv/bin/python3.9}
PATTERN="[r]omeollmtool.gateway.server --host 0.0.0.0 --port $PORT"

key=$("$RLT" gateway show-key 2>/dev/null | tr -d '[:space:]')
[ -n "$key" ] || { echo "no gateway key: start romeollmtool's gateway first" >&2; exit 1; }
# The key goes to curl on stdin (not in its arguments, which ps shows to everyone on the login node),
# and only to a listener of this user: ss shows the process of a socket to its owner only.
answers() {
  [ "$(printf 'header = "Authorization: Bearer %s"\n' "$key" | curl -K - -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$PORT/v1/models")" = 200 ]
}
listening() { ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q .; }
mine() { ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -q 'pid='; }
if listening && ! mine; then
  echo "port $PORT is taken by another user's process: set DSH_ROMEO_FAST_PORT to another port" >&2
  exit 1
fi

running() { pgrep -u "$USER" -f "^[^ ]*python[^ ]* -m $PATTERN" | wc -l; }   # not the timeout wrappers
have=$(running)
if answers && [ "$have" -ge "$N" ]; then exit 0; fi
[ -x "$PY" ] || { echo "romeollmtool's Python not found at $PY" >&2; exit 1; }

# Some processes still answer: start only the missing ones (SO_REUSEPORT), the others keep their
# streams. None answers: start over.
if answers && [ "$have" -gt 0 ] && [ "$N" -gt 1 ]; then
  first=$((have + 1))
else
  pkill -u "$USER" -f "$PATTERN" 2>/dev/null && sleep 2
  first=1
fi
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)"
REUSE=0
[ "$N" -gt 1 ] && REUSE=1
cd "$D" || exit 1
for i in $(seq "$first" "$N"); do
  RLT_GW_REUSEPORT=$REUSE RLT_GW_WORKERS=$N PYTHONPATH=$D \
    nohup timeout 8h "$PY" -m romeollmtool.gateway.server --host 0.0.0.0 --port "$PORT" \
    >"$D/gateway-$PORT.$i.log" 2>&1 </dev/null &
done
for _ in $(seq 1 30); do answers && exit 0; sleep 1; done
echo "the fast gateway does not answer on port $PORT:" >&2
tail -n 5 "$D/gateway-$PORT.1.log" >&2
pkill -u "$USER" -f "$PATTERN" 2>/dev/null
exit 1
