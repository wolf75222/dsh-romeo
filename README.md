# dsh-romeo

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh), DeepSeek's coding agent, on your computer, with DeepSeek-V4.1-Flash-1017 running on the GPUs of the [ROMEO](https://romeo.univ-reims.fr/) cluster: one command starts the model, opens the tunnel and opens dsh. The same model serves any other client: opencode, Codex, Claude Code, Aider, your editor.

![dsh-romeo --launch starts DeepSeek-V4.1-Flash-1017 on ROMEO and opens the dsh Web UI, where an agent fixes a failing test; then the Trajectory tab of that session](img/dsh-romeo.gif)

The model is DeepSeek's 17 October 2026 release of V4.1-Flash, with its full 1M-token context, on 2 nodes (8 GH200, tensor parallel) with DSpark speculative decoding: the settings an A/B study on ROMEO kept ([Tuning](docs/tuning.md)).

## Install

On macOS, Linux or **WSL**, once `ssh romeo` logs you into ROMEO without a password
and Linux/macOS Node.js 20 or later is installed:

```bash
git clone https://github.com/wolf75222/dsh-romeo.git ~/dsh-romeo && ~/dsh-romeo/install.sh
```

Then run `dsh-romeo --launch`. To update: `cd ~/dsh-romeo && git pull && ./install.sh`.

On **native Windows**, with Windows Node.js 20 or later and the
[OpenSSH Client](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-overview)
installed, run in PowerShell (5.1 or 7), after checking `ssh romeo hostname`:

```powershell
git clone https://github.com/wolf75222/dsh-romeo.git "$HOME\dsh-romeo"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME\dsh-romeo\install.ps1"
```

Open a new terminal, then run `dsh-romeo.cmd --launch`. Both installers install missing dsh into a
user-owned npm prefix: no `sudo`, administrator rights, or global npm configuration
change. Existing dsh installations are reused. [Windows/WSL details](docs/usage.md#platforms).

## Use

| Command | |
|---|---|
| `dsh-romeo --launch` | starts the model on ROMEO (2 nodes, 8 GH200), waits until it answers, opens the dsh Web UI |
| `dsh-romeo` | opens the Web UI while the model job runs |
| `dsh-romeo --desktop` | the [DeepSeek Harness desktop app](https://github.com/deepseek-ai/deepseek-harness/releases) (macOS) instead of the Web UI |
| `dsh-romeo headless "a task"` | one task, the answer on stdout: for scripts |
| `dsh-romeo --run opencode` | any other client: `codex`, `claude`, `aider`, `python3 my_agent.py`... |
| `dsh-romeo --serve` | only the model and the tunnel, for an editor or any OpenAI-compatible tool |
| `dsh-romeo --status` | the gateway, the model jobs, the tunnel |
| `dsh-romeo --stop` | stops the model job: it uses your project's GPU hours while it runs |

## Docs

[Usage](docs/usage.md) · [Other clients](docs/clients.md) · [Tuning](docs/tuning.md) · [How it works](docs/how-it-works.md) · [Troubleshooting](docs/troubleshooting.md) · [Changes](docs/changes.md) · [Development](docs/development.md)
