# Other clients

[README](../README.md) · [Usage](usage.md) · **Other clients** · [Tuning](tuning.md) · [How it works](how-it-works.md) · [Troubleshooting](troubleshooting.md) · [Changes](changes.md) · [Development](development.md)

The gateway forwards every `/v1/...` request to vLLM, which speaks three APIs: OpenAI Chat Completions, OpenAI Responses and Anthropic Messages. So dsh is only one possible client. `dsh-romeo --run CMD` prepares the model and the tunnel like for dsh, then runs `CMD` with the endpoint in its environment:

| Client | Command | Through |
|---|---|---|
| [opencode](https://opencode.ai) | `dsh-romeo --run opencode` | a `romeo` provider in `~/.config/dsh-romeo/opencode.json`, given by `OPENCODE_CONFIG` and made the default model |
| [Codex CLI](https://github.com/openai/codex) | `dsh-romeo --run codex` | a `romeo` provider passed as `-c` options, on the Responses API |
| [Claude Code](https://code.claude.com) | `dsh-romeo --run claude` | `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` and the model for every alias |
| [Aider](https://aider.chat) | `dsh-romeo --run aider` | `OPENAI_API_BASE`, `OPENAI_API_KEY` and `AIDER_MODEL=openai/<model>` |
| OpenAI and Anthropic SDKs, curl, scripts | `dsh-romeo --run python3 my_agent.py` | `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `ANTHROPIC_BASE_URL`, `DSH_ROMEO_MODEL` |

Arguments after the command are the client's own: `dsh-romeo --run codex exec "fix the tests"`, `dsh-romeo --run claude -p "..."`. None of these clients' own settings are modified, and the key is never written to disk.

## Editors and other tools

```bash
dsh-romeo --serve            # the model and the tunnel, then it prints the endpoint and returns
eval "$(dsh-romeo --env)"    # the endpoint and the key in this shell
```

Then declare an OpenAI-compatible provider (Continue, Cline, Zed, Cursor, ...) with:

| | |
|---|---|
| base URL | `http://127.0.0.1:11318/v1` (Anthropic-compatible tools: `http://127.0.0.1:11318`) |
| model | `dsh-deepseek-v4.1-flash-1017-1m` |
| key | the value of `$OPENAI_API_KEY` after `eval "$(dsh-romeo --env)"` |

The tunnel stays open until `dsh-romeo --stop`. After your computer slept, run `dsh-romeo --serve` again.

On native Windows, the same clients run as Windows processes. Import the endpoint
with `dsh-romeo --env | Invoke-Expression` in PowerShell; use `python` instead of
`python3` when that is your Python command. The generated opencode and dsh files
are in the Windows config directory (see [Platforms](usage.md#platforms)).

## Variables

| Variable | Value |
|---|---|
| `OPENAI_BASE_URL`, `OPENAI_API_BASE`, `DSH_ROMEO_BASE_URL` | `http://127.0.0.1:11318/v1` |
| `OPENAI_API_KEY`, `ROMEO_LLM_KEY`, `ANTHROPIC_AUTH_TOKEN` | the gateway's key |
| `DSH_ROMEO_MODEL`, `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL` | the served model, `dsh-deepseek-v4.1-flash-1017-1m` |
| `ANTHROPIC_BASE_URL` | `http://127.0.0.1:11318` |
| `AIDER_MODEL` | `openai/dsh-deepseek-v4.1-flash-1017-1m` |
| `OPENCODE_CONFIG` | `~/.config/dsh-romeo/opencode.json` |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `1` |

## Tested

On 2026-10-25, against one model job, each client was asked to run the tests of a small project, fix its bug and run them again:

| Client | Version | Result |
|---|---|---|
| dsh | 0.2.1-rc.2 | fixed, tests pass (Web UI and headless) |
| opencode | 1.19.4 | fixed, tests pass |
| Codex CLI | 0.143.0 | fixed, tests pass (provider `romeo`, Responses API) |
| Claude Code | 2.1.197 | fixed, tests pass (10 turns, only `dsh-deepseek-v4.1-flash-1017-1m` used) |
| Aider | 0.86.2 | fixed, tests pass |
| OpenAI Python SDK | 3.37.0 | a tool call, then a streamed answer ([tests/clients/openai_sdk.py](../tests/clients/openai_sdk.py)) |

Aider on macOS 27: the scipy 1.13 it pins does not load (`__thread_bss` section). Run it with a newer one: `printf 'scipy>=1.15\n' > o.txt; dsh-romeo --run uvx --overrides o.txt --from aider-chat aider`.
