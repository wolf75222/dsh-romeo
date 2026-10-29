"""Opt-in live API check: models, tool calling, then an SSE streamed answer.

    dsh-romeo --run python tests/clients/live_smoke.py windows
    dsh-romeo --run python3 tests/clients/live_smoke.py wsl

Uses the already-running model. Never submits or stops jobs; uses only Python's
standard library. The gateway key stays in the environment and is never printed.
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request


def main():
    label = sys.argv[1] if len(sys.argv) > 1 else "client"
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", label):
        raise ValueError("label must contain only letters, digits, '_' or '-'")
    base = os.environ["OPENAI_BASE_URL"].rstrip("/")
    key = os.environ["OPENAI_API_KEY"]
    model = os.environ["DSH_ROMEO_MODEL"]
    marker = "DSH_ROMEO_LIVE_" + label.upper().replace("-", "_")
    started = time.monotonic()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(path, body=None):
        headers = {"Authorization": "Bearer " + key}
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        query = urllib.request.Request(base + path, data=data, headers=headers)
        try:
            return opener.open(query, timeout=120)
        except urllib.error.HTTPError as exc:
            code = exc.code
            exc.close()
            raise RuntimeError(f"{path}: HTTP {code}") from None

    with request("/models") as response:
        models = json.load(response)
    if model not in {item["id"] for item in models.get("data", [])}:
        raise RuntimeError("configured model is missing from /models")

    tools = [{"type": "function", "function": {
        "name": "echo_token",
        "description": "Return the requested token unchanged.",
        "parameters": {"type": "object", "properties": {"token": {"type": "string"}},
                       "required": ["token"], "additionalProperties": False},
    }}]
    messages = [{"role": "user", "content": (
        f"Call echo_token once with token {marker}. After receiving its result, "
        "reply with that exact token and nothing else."
    )}]
    body = {"model": model, "messages": messages, "tools": tools,
            "max_tokens": 256, "reasoning_effort": "none"}
    with request("/chat/completions", body) as response:
        first = json.load(response)["choices"][0]["message"]
    calls = first.get("tool_calls") or []
    if len(calls) != 1 or calls[0]["function"]["name"] != "echo_token":
        raise RuntimeError("expected exactly one echo_token tool call")
    call = calls[0]
    if json.loads(call["function"]["arguments"]).get("token") != marker:
        raise RuntimeError("tool arguments did not preserve the test marker")
    messages += [
        {"role": "assistant", "content": first.get("content"), "tool_calls": calls},
        {"role": "tool", "tool_call_id": call["id"], "content": marker},
    ]
    body["stream"] = True
    chunks = []
    with request("/chat/completions", body) as response:
        for raw_line in response:
            line = raw_line.decode("utf-8").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            choices = json.loads(data).get("choices", [])
            if choices:
                chunks.append(choices[0].get("delta", {}).get("content") or "")
    if marker not in "".join(chunks):
        raise RuntimeError("streamed answer did not contain the tool result")
    print(json.dumps({"test": "live_smoke", "label": label, "model": model,
                      "models_ok": True, "tool_call_ok": True, "stream_ok": True,
                      "elapsed_seconds": round(time.monotonic() - started, 2)}))


if __name__ == "__main__":
    main()
