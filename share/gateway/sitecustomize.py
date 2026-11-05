"""dsh-romeo's fast gateway: a patched romeollmtool gateway (second instance, port 11320).

Loaded through PYTHONPATH by share/gateway/start.sh (DSH_ROMEO_GATEWAY=fast),
so only that unmanaged gateway sees it. Nothing on disk changes: every change
is a monkeypatch applied at interpreter start, before server.py imports
create_app and Router. Target: romeollmtool gateway as of 2026-10-14
(app.py md5 ee8082ff..., routing.py md5 f3140656...), Python 3.9.

Features (env switches, "0" turns one off):

  pool        RLT_GW_POOL=1       httpx pool 4096/1024 for every AsyncClient,
                                  keep-alive expiry 4 s (< vLLM's 5 s, avoids the
                                  "Server disconnected" reuse race)
  affinity    RLT_GW_AFFINITY=1   session / prefix affinity: rendezvous (HRW)
                                  hashing over the READY backends of the model,
                                  bounded load, failover on refused connects
  timeouts    RLT_GW_TIMEOUTS=1   upstream connect 60 s, write 300 s, pool 300 s
                                  (was 10/10/10); mark_down only on refused or
                                  unreachable connects, never on timeouts
  probe grace RLT_GW_PROBE_GRACE=1  a ready backend survives one failed /v1/models
                                  probe unless the connect is refused
  fastpath    RLT_GW_FASTPATH=1   pure-ASGI auth instead of BaseHTTPMiddleware,
                                  one JSON parse per request, raw body forwarded
                                  when the fiche adds no defaults, usage counter
                                  written by a background thread
  uvloop      RLT_GW_UVLOOP=1     asyncio loop on uvloop (installed, unused today)
  reuseport   RLT_GW_REUSEPORT=0  1: bind with SO_REUSEPORT so N copies of the same
                                  command share the port (Linux load-balances)

Tunables: RLT_GW_AFFINITY_BALANCE (1.5; 0 = pure affinity),
RLT_GW_AFFINITY_MIN_SPILL (32 in-flight per backend before any spill, divided by
RLT_GW_WORKERS), RLT_GW_AFFINITY_HEADERS, RLT_GW_AFFINITY_FIELDS,
RLT_GW_CONNECT_TIMEOUT, RLT_GW_WRITE_TIMEOUT, RLT_GW_POOL_TIMEOUT,
RLT_GW_FAILOVER (2 extra backends tried on refused connects).
"""
import os
import sys


def _flag(name, default="1"):
    return os.environ.get(name, default).strip().lower() not in ("0", "false", "no", "off", "")


def _num(name, default):
    try:
        return type(default)(os.environ.get(name, default))
    except ValueError:
        return default


def _warn(msg):
    sys.stderr.write("[gateway_patch] %s\n" % msg)
    sys.stderr.flush()


# --------------------------------------------------------------------------
# pool: lift httpx's default 100-connection pool (the original patch)
# --------------------------------------------------------------------------
import httpx  # noqa: E402

if _flag("RLT_GW_POOL"):
    _LIMITS = httpx.Limits(
        max_connections=_num("RLT_GW_POOL_MAX", 4096),
        max_keepalive_connections=_num("RLT_GW_POOL_KEEPALIVE", 1024),
        keepalive_expiry=_num("RLT_GW_KEEPALIVE_EXPIRY", 4.0),
    )
    _orig_client_init = httpx.AsyncClient.__init__

    def _client_init(self, *args, **kwargs):
        kwargs.setdefault("limits", _LIMITS)
        _orig_client_init(self, *args, **kwargs)

    httpx.AsyncClient.__init__ = _client_init


def _apply_gateway_patches():
    import asyncio
    import contextvars
    import errno
    import hashlib
    import inspect
    import json
    import logging
    import math
    import socket
    import threading
    import time
    from collections import Counter

    from romeollmtool.gateway import app as gw_app
    from romeollmtool.gateway import routing as gw_routing

    log = logging.getLogger("romeollmtool.gateway.patch")
    Router = gw_routing.Router
    app_src = inspect.getsource(gw_app)
    routing_src = inspect.getsource(gw_routing)

    def _has(src, *needles):
        return all(n in src for n in needles)

    # One mutable dict per HTTP request, shared by the middleware, Router.pick,
    # Router.mark_down, the upstream client and the json shim. A ContextVar is
    # copied into every task the request spawns, and the dict is mutated, never
    # re-set, so writes from child tasks stay visible.
    _REQ = contextvars.ContextVar("rlt_gw_request", default=None)
    _MISSING = object()

    # ---------------------------------------------------------------- uvloop
    if _flag("RLT_GW_UVLOOP"):
        try:
            import uvloop
            asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())
        except Exception as exc:  # noqa: BLE001
            _warn("uvloop disabled: %r" % (exc,))

    # ------------------------------------------------------------- reuseport
    if _flag("RLT_GW_REUSEPORT", "0"):
        import uvicorn
        _orig_serve = uvicorn.Server.serve

        async def _serve(self, sockets=None):
            if sockets is None:
                cfg = self.config
                family = socket.AF_INET6 if ":" in (cfg.host or "") else socket.AF_INET
                sock = socket.socket(family, socket.SOCK_STREAM)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
                sock.bind((cfg.host, cfg.port))
                sock.listen(cfg.backlog)
                sock.setblocking(False)
                sock.set_inheritable(True)
                sockets = [sock]
                _warn("pid %d listening on %s:%d with SO_REUSEPORT" % (os.getpid(), cfg.host, cfg.port))
            return await _orig_serve(self, sockets=sockets)

        uvicorn.Server.serve = _serve

    # ------------------------------------------------------------- affinity
    affinity_ok = _flag("RLT_GW_AFFINITY") and _has(
        app_src, "router.pick(model)", "router.mark_down(backend)",
        "client.send(upstream_request, stream=True)",
    ) and _has(routing_src, "def pick(self, model: str)", "self._backends", "backend.ready = False")
    if _flag("RLT_GW_AFFINITY") and not affinity_ok:
        _warn("affinity disabled: gateway source does not match the expected version")

    _HEADERS = tuple(
        h.strip().lower().encode("latin-1")
        for h in os.environ.get(
            "RLT_GW_AFFINITY_HEADERS",
            "x-session-affinity,x-session-id,x-deepseek-harness-session-id,session_id,session-id",
        ).split(",") if h.strip()
    )
    _FIELDS = tuple(
        f.strip() for f in os.environ.get("RLT_GW_AFFINITY_FIELDS", "prompt_cache_key,user").split(",")
        if f.strip()
    )
    _AFFINITY_PATHS = ("/v1/chat/completions", "/v1/completions")
    _BALANCE = _num("RLT_GW_AFFINITY_BALANCE", 1.5)
    _MIN_SPILL = max(1, _num("RLT_GW_AFFINITY_MIN_SPILL", 32) // max(1, _num("RLT_GW_WORKERS", 1)))
    _FAILOVER = _num("RLT_GW_FAILOVER", 2)
    _PARSE_MAX = _num("RLT_GW_PARSE_MAX", 64 * 1024 * 1024)
    _DEBUG_HEADER = _flag("RLT_GW_DEBUG_HEADER", "0")  # x-rlt-backend / x-rlt-pid on responses
    _HEAD, _TAIL = 65536, 4096
    _INFLIGHT = Counter()  # job_id -> requests in flight through THIS process

    def _feed(h, value):
        """Hash a message content: whole text up to 68 KiB, else length + head + tail."""
        if value is None:
            h.update(b"\x00N")
            return
        if not isinstance(value, str):
            try:
                value = json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
            except (TypeError, ValueError):
                value = repr(value)
        n = len(value)
        h.update(b"\x00L%d\x00" % n)
        if n <= _HEAD + _TAIL:
            h.update(value.encode("utf-8", "surrogatepass"))
        else:
            h.update(value[:_HEAD].encode("utf-8", "surrogatepass"))
            h.update(b"\x00...\x00")
            h.update(value[-_TAIL:].encode("utf-8", "surrogatepass"))

    def affinity_key(headers, body):
        """(a) explicit session header, (b) body field (prompt_cache_key, user),
        (c) hash of the first system message + first user message."""
        for name, value in headers:
            if name in _HEADERS:
                value = value.strip()
                if value:
                    return b"h:" + value
        if not isinstance(body, dict):
            return None
        for field in _FIELDS:
            value = body.get(field)
            if isinstance(value, str) and value.strip():
                return b"f:" + value.strip().encode("utf-8", "surrogatepass")
        h = hashlib.blake2b(digest_size=16, person=b"rlt-gw-prefix")
        messages = body.get("messages")
        if isinstance(messages, list):
            system = user = None
            for m in messages:
                if not isinstance(m, dict):
                    continue
                role = m.get("role")
                if system is None and role in ("system", "developer"):
                    system = m
                elif role == "user":
                    user = m
                    break
            if system is None and user is None:
                return None
            _feed(h, system.get("content") if system else None)
            _feed(h, user.get("content") if user else None)
            return b"p:" + h.digest()
        prompt = body.get("prompt")
        if isinstance(prompt, list) and prompt:
            prompt = prompt[0]
        if isinstance(prompt, str) and prompt:
            _feed(h, prompt[:32768])
            return b"c:" + h.digest()
        return None

    def _score(key, job_id):
        d = hashlib.blake2b(key, digest_size=8, person=b"rlt-gw-hrw")
        d.update(b"\x00")
        d.update(job_id.encode())
        return int.from_bytes(d.digest(), "big")

    def rank(key, backends):
        """Rendezvous order: deterministic in every process (blake2b, not hash())."""
        return sorted(backends, key=lambda b: _score(key, b.job_id), reverse=True)

    def _account(holder, backend):
        prev = holder.get("backend")
        if prev is not None:
            _INFLIGHT[prev.job_id] -= 1
        holder["backend"] = backend
        if backend is not None:
            _INFLIGHT[backend.job_id] += 1

    def _release(holder):
        backend = holder.get("backend")
        if backend is not None:
            _INFLIGHT[backend.job_id] -= 1
            if _INFLIGHT[backend.job_id] <= 0:
                del _INFLIGHT[backend.job_id]
            holder["backend"] = None

    _orig_pick = Router.pick
    _orig_mark_down = Router.mark_down

    def _pick(self, model):
        holder = _REQ.get()
        if holder is None:
            return _orig_pick(self, model)
        holder["router"], holder["model"] = self, model
        key = holder.get("key")
        if key is None:
            backend = _orig_pick(self, model)  # unchanged round robin
            _account(holder, backend)
            return backend
        ready = [b for b in self._backends.get(model, []) if b.ready]
        if not ready:
            _account(holder, None)
            return None  # proxy answers 503 model_loading, as before
        ranked = rank(key, ready)
        holder["ranked"] = ranked
        chosen = ranked[0]
        if _BALANCE > 0 and len(ranked) > 1:
            # Consistent hashing with bounded loads (Mirrokni et al. 2016):
            # walk the HRW order until a backend under the cap.
            total = sum(_INFLIGHT.get(b.job_id, 0) for b in ranked) + 1
            cap = max(_MIN_SPILL, math.ceil(_BALANCE * total / len(ranked)))
            for b in ranked:
                if _INFLIGHT.get(b.job_id, 0) < cap:
                    chosen = b
                    break
            if chosen is not ranked[0]:
                holder["spilled"] = True
        _account(holder, chosen)
        return chosen

    # ConnectError errnos that say the backend (job/node) is gone. EMFILE,
    # EADDRNOTAVAIL, ENOBUFS... are local exhaustion: marking backends down for
    # them would turn a gateway problem into 503 model_loading for everyone.
    _DOWN_ERRNOS = {
        getattr(errno, n) for n in ("ECONNREFUSED", "EHOSTUNREACH", "ENETUNREACH", "EHOSTDOWN")
        if hasattr(errno, n)
    }

    def backend_is_gone(exc):
        if not isinstance(exc, httpx.ConnectError):
            return False  # timeouts, protocol errors, read/write errors
        # httpx.ConnectError <- httpcore.ConnectError <- OSError("All connection
        # attempts failed", errno None) <- ConnectionRefusedError, or an
        # ExceptionGroup of them when the host name has several addresses.
        errnos, todo, guard = [], [exc], 0
        while todo and guard < 32:
            guard += 1
            seen = todo.pop()
            if isinstance(seen, socket.gaierror):
                return True  # node name no longer resolves
            if isinstance(seen, OSError) and seen.errno is not None:
                errnos.append(seen.errno)
            todo.extend(getattr(seen, "exceptions", ()) or ())
            nxt = seen.__cause__ or seen.__context__
            if nxt is not None:
                todo.append(nxt)
        if any(e in _DOWN_ERRNOS for e in errnos):
            return True
        if errnos:
            return False  # EMFILE, EADDRNOTAVAIL, ENOBUFS...: local, not the backend
        text = str(exc).lower()
        if any(s in text for s in ("too many open files", "cannot assign requested address", "no buffer space")):
            return False
        return True  # unknown cause: keep the original behaviour

    def _mark_down(self, backend):
        holder = _REQ.get()
        exc = holder.get("exc") if holder is not None else None
        if exc is not None and not backend_is_gone(exc):
            log.warning("job %s: %s (%s), not marked down", backend.job_id, type(exc).__name__, exc)
            return
        _orig_mark_down(self, backend)

    def _retarget(request, backend):
        target = httpx.URL(backend.url)
        url = request.url.copy_with(scheme=target.scheme, host=target.host, port=target.port)
        headers = [(k, v) for k, v in request.headers.raw if k.lower() not in (b"host", b"authorization", b"content-length")]
        headers.append((b"authorization", ("Bearer %s" % backend.key).encode("latin-1")))
        return httpx.Request(request.method, url, headers=headers, content=request.content,
                             extensions=request.extensions)

    def _next_backend(holder, tried):
        router, model = holder.get("router"), holder.get("model")
        pool = holder.get("ranked") or (router._backends.get(model, []) if router else [])
        for b in pool:
            if b.ready and b.job_id not in tried:
                return b
        return None

    class UpstreamClient(httpx.AsyncClient):
        """The proxy's upstream client. Fails over to the next backend in the
        HRW order when a connect fails before anything was sent."""

        async def send(self, request, **kwargs):
            holder = _REQ.get()
            tried = set()
            while True:
                try:
                    response = await super().send(request, **kwargs)
                except (httpx.ConnectError, httpx.ConnectTimeout) as exc:
                    if holder is None:
                        raise
                    holder["exc"] = exc
                    current = holder.get("backend")
                    if current is None or len(tried) >= _FAILOVER:
                        raise
                    tried.add(current.job_id)
                    if backend_is_gone(exc):
                        _orig_mark_down(holder["router"], current)
                    alt = _next_backend(holder, tried)
                    if alt is None:
                        raise
                    log.warning("job %s: %s, failing over to job %s", current.job_id, type(exc).__name__, alt.job_id)
                    holder["failover"] = holder.get("failover", 0) + 1
                    _account(holder, alt)
                    request = _retarget(request, alt)
                    continue
                except httpx.HTTPError as exc:
                    if holder is not None:
                        holder["exc"] = exc
                    raise
                if holder is not None:
                    holder.pop("exc", None)
                    if holder.get("debug"):
                        b = holder.get("backend")
                        holder["served_by"] = b.job_id if b is not None else None
                return response

    # ------------------------------------------------------- probe grace
    if _flag("RLT_GW_PROBE_GRACE") and _has(routing_src, "async def _probe(self, backend: Backend)"):
        _orig_probe = Router._probe
        _was_ready = {}  # job_id -> bool, last probe outcome after grace

        async def _probe(self, backend):
            await _orig_probe(self, backend)
            if backend.ready:
                _was_ready[backend.job_id] = True
                return
            if _was_ready.pop(backend.job_id, False):
                # One failed probe: re-check only the connect; refused = gone.
                try:
                    host = httpx.URL(backend.url)
                    _, writer = await asyncio.wait_for(asyncio.open_connection(host.host, host.port), 5)
                    writer.close()
                    backend.ready = True  # alive but slow: keep it one more cycle
                    log.warning("job %s: /v1/models probe failed but port open, kept ready", backend.job_id)
                except Exception:  # noqa: BLE001
                    pass

        Router._probe = _probe

    # ------------------------------------------------------- fastpath bits
    fast_ok = _flag("RLT_GW_FASTPATH") and _has(
        app_src, 'json.loads(raw or b"{}")', "json.dumps(body).encode()", "await request.body()",
        '@app.middleware("http")',
    )
    if _flag("RLT_GW_FASTPATH") and not fast_ok:
        _warn("fastpath disabled: gateway source does not match the expected version")

    class _RawJSON(str):
        """What json.dumps returns in app.py when the body is unchanged: its
        .encode() hands back the client's bytes, no re-serialisation."""

        def encode(self, encoding="utf-8", errors="strict"):  # noqa: ARG002
            return self._raw

    def _raw_for(holder, obj):
        parsed, raw = holder.get("parsed", _MISSING), holder.get("raw")
        if raw is None or not isinstance(parsed, dict) or not isinstance(obj, dict):
            return None
        if obj is parsed:
            return raw
        for k, v in parsed.items():  # obj == {**generation, **parsed} ?
            if obj.get(k, _MISSING) is not v:
                return None
        if len(obj) == len(parsed):
            return raw
        extra = {k: v for k, v in obj.items() if k not in parsed}
        stripped = raw.rstrip()
        if not stripped.endswith(b"}"):
            return None
        sep = b", " if parsed else b""
        return stripped[:-1] + sep + json.dumps(extra)[1:-1].encode() + b"}"

    class _JsonShim:
        """Replaces the `json` name in romeollmtool.gateway.app only."""

        def loads(self, s, *args, **kwargs):
            holder = _REQ.get()
            if holder is not None and not args and not kwargs and "parsed" in holder:
                raw = holder.get("raw")
                if raw is not None and isinstance(s, (bytes, bytearray)) and len(s) == len(raw) and s == raw:
                    return holder["parsed"]
            return json.loads(s, *args, **kwargs)

        def dumps(self, obj, *args, **kwargs):
            holder = _REQ.get()
            if holder is not None and not args and not kwargs:
                raw = _raw_for(holder, obj)
                if raw is not None:
                    out = _RawJSON("")
                    out._raw = raw
                    return out
            return json.dumps(obj, *args, **kwargs)

        def __getattr__(self, name):
            return getattr(json, name)

    class _UsageBatcher:
        """record_request() writes one line per request in ~/.romeollmtool/stats,
        synchronously on the event loop (mkdir + chmod + open/append on GPFS).
        Same lines, written by a thread every 2 s."""

        def __init__(self, period=2.0):
            from romeollmtool.paths import STATS_DIR
            self.stats_dir = STATS_DIR
            self.pending = Counter()
            self.lock = threading.Lock()
            self.period = period
            threading.Thread(target=self._loop, name="usage-batcher", daemon=True).start()
            import atexit
            atexit.register(self.flush)

        def __call__(self, fiche_id):
            with self.lock:
                self.pending[fiche_id] += 1

        def _loop(self):
            while True:
                time.sleep(self.period)
                self.flush()

        def flush(self):
            with self.lock:
                pending, self.pending = self.pending, Counter()
            if not pending:
                return
            try:
                from datetime import date
                self.stats_dir.mkdir(parents=True, exist_ok=True)
                os.chmod(self.stats_dir, 0o700)
                path = self.stats_dir / ("requests-%s.jsonl" % date.today().isoformat())
                data = "".join((json.dumps({"fiche_id": f}) + "\n") * n for f, n in pending.items()).encode()
                # One O_APPEND write: lines never interleave with the managed
                # gateway or the other reuseport processes appending the same file.
                fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o666)
                try:
                    view = memoryview(data)
                    while view:
                        view = view[os.write(fd, view):]
                finally:
                    os.close(fd)
            except OSError:
                pass  # best effort, like the original

    # --------------------------------------------------- ASGI middlewares
    from starlette.requests import Request
    from starlette.responses import JSONResponse

    class AuthASGI:
        """Same check as app.py's @app.middleware("http") authenticate(), as a
        plain ASGI middleware: no BaseHTTPMiddleware task hop per SSE chunk."""

        def __init__(self, app, keys):
            self.app = app
            self.keys = keys

        async def __call__(self, scope, receive, send):
            if scope["type"] != "http":
                return await self.app(scope, receive, send)
            request = Request(scope)
            if request.url.path != "/health":
                header = request.headers.get("authorization", "")
                token = header[7:] if header.lower().startswith("bearer ") else ""
                if not self.keys.check(token):
                    response = JSONResponse(
                        {"error": {"message": "Clé API invalide ou absente.", "type": "romeollmtool",
                                   "code": "invalid_api_key"}}, status_code=401)
                    return await response(scope, receive, send)
            return await self.app(scope, receive, send)

    class RequestContextASGI:
        """Buffers the request body (the proxy reads it whole anyway), derives
        the affinity key, parses JSON once, then replays the body. Only
        `receive` is wrapped: the streamed response goes out untouched."""

        def __init__(self, app, affinity, fast):
            self.app = app
            self.affinity = affinity
            self.fast = fast

        async def __call__(self, scope, receive, send):
            if scope["type"] != "http" or scope["method"] != "POST" or not scope["path"].startswith("/v1/"):
                return await self.app(scope, receive, send)
            holder = {"key": None}
            token = _REQ.set(holder)
            try:
                headers = scope["headers"]
                ctype = b""
                for k, v in headers:
                    if k == b"content-type":
                        ctype = v
                        break
                if ctype.startswith(b"multipart/form-data"):
                    return await self.app(scope, receive, send)
                chunks = []
                size = 0
                while True:
                    message = await receive()
                    if message["type"] != "http.request":
                        return  # client gone before the body arrived
                    chunk = message.get("body", b"")
                    if chunk:
                        chunks.append(chunk)
                        size += len(chunk)
                    if not message.get("more_body", False):
                        break
                raw = chunks[0] if len(chunks) == 1 else b"".join(chunks)
                if size <= _PARSE_MAX:
                    try:
                        parsed = json.loads(raw or b"{}")
                    except ValueError:
                        parsed = _MISSING  # app.py answers 400 invalid_json itself
                    if parsed is not _MISSING:
                        if self.fast:
                            holder["raw"], holder["parsed"] = raw, parsed
                        if self.affinity and scope["path"] in _AFFINITY_PATHS:
                            holder["key"] = affinity_key(headers, parsed)
                replayed = False

                async def replay():
                    nonlocal replayed
                    if not replayed:
                        replayed = True
                        return {"type": "http.request", "body": raw, "more_body": False}
                    return await receive()  # http.disconnect, for StreamingResponse

                if _DEBUG_HEADER:
                    holder["debug"] = True

                    async def send_debug(message):
                        if message["type"] == "http.response.start":
                            b = holder.get("backend")
                            extra = [(b"x-rlt-backend", (b.job_id if b else "-").encode()),
                                     (b"x-rlt-pid", str(os.getpid()).encode())]
                            message = dict(message, headers=list(message.get("headers", [])) + extra)
                        await send(message)

                    return await self.app(scope, replay, send_debug)
                return await self.app(scope, replay, send)
            finally:
                _release(holder)
                _REQ.reset(token)

    # ------------------------------------------------------- create_app wrap
    _orig_create_app = gw_app.create_app
    timeouts = _flag("RLT_GW_TIMEOUTS")

    def create_app(router, keys, upstream=None, record_request=None):
        if upstream is None and (affinity_ok or timeouts):
            timeout = httpx.Timeout(
                connect=_num("RLT_GW_CONNECT_TIMEOUT", 60.0) if timeouts else 10.0,
                read=None,
                write=_num("RLT_GW_WRITE_TIMEOUT", 300.0) if timeouts else 10.0,
                pool=_num("RLT_GW_POOL_TIMEOUT", 300.0) if timeouts else 10.0,
            )
            upstream = UpstreamClient(timeout=timeout)
        if record_request is None:
            record_request = _UsageBatcher() if fast_ok else gw_app._record_request
        app = _orig_create_app(router, keys, upstream=upstream, record_request=record_request)
        from starlette.middleware import Middleware
        from starlette.middleware.base import BaseHTTPMiddleware
        stack = list(app.user_middleware)  # [authenticate (BaseHTTPMiddleware)]
        if fast_ok:
            kept = [m for m in stack if m.cls is not BaseHTTPMiddleware]
            if len(kept) != len(stack) - 1:
                raise RuntimeError("expected exactly one BaseHTTPMiddleware (authenticate)")
            stack = [Middleware(AuthASGI, keys=keys)] + kept
        if affinity_ok or fast_ok:
            # Innermost: runs after the auth check, so an unauthenticated client
            # never makes the gateway buffer or parse a body.
            stack.append(Middleware(RequestContextASGI, affinity=affinity_ok, fast=fast_ok))
        app.user_middleware = stack
        _warn("pid %d: affinity=%s fastpath=%s timeouts=%s uvloop=%s reuseport=%s balance=%s min_spill=%s"
              % (os.getpid(), affinity_ok, fast_ok, timeouts, _flag("RLT_GW_UVLOOP"),
                 _flag("RLT_GW_REUSEPORT", "0"), _BALANCE, _MIN_SPILL))
        return app

    if affinity_ok:
        Router.pick = _pick
    if affinity_ok or timeouts:
        Router.mark_down = _mark_down
    if fast_ok:
        gw_app.json = _JsonShim()
    gw_app.create_app = create_app

    # Exposed for tests and for the A/B harness.
    sys.modules[__name__].affinity_key = affinity_key
    sys.modules[__name__].rank = rank
    sys.modules[__name__].backend_is_gone = backend_is_gone
    sys.modules[__name__].INFLIGHT = _INFLIGHT


if _flag("RLT_GW_PATCH"):
    try:
        _apply_gateway_patches()
    except Exception as _exc:  # noqa: BLE001 - never break interpreter start
        _warn("gateway patches disabled: %r" % (_exc,))
