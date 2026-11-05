# dsh-romeo

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh), DeepSeek's coding agent, on your computer, with DeepSeek-V4.1-Flash-1017 or Kimi-K3.1-Pro running on the GPUs of the [ROMEO](https://romeo.univ-reims.fr/) cluster: one command starts the model, opens the tunnel and opens dsh. Kimi can also run the agent while DeepSeek runs its subagents. The same model serves any other client: opencode, Codex, Claude Code, Aider, your editor.

![dsh-romeo --launch starts DeepSeek-V4.1-Flash-1017 on ROMEO and opens the dsh Web UI, where an agent fixes a failing test; then the Trajectory tab of that session](img/dsh-romeo.gif)

The model is DeepSeek's 17 October 2026 release of V4.1-Flash, with its full 1M-token context, on 2 nodes (8 GH200, tensor parallel) with DSpark speculative decoding: the settings an A/B study on ROMEO kept ([Tuning](docs/tuning.md)).

## Install

On your computer (macOS or Linux), with Node.js 20 or later (24.9+ gets dsh 0.2.2) and once `ssh romeo` logs you into ROMEO without a password (the `~/.ssh/config` entry is in [Usage](docs/usage.md#install)):

```bash
git clone https://github.com/wolf75222/dsh-romeo.git ~/dsh-romeo && ~/dsh-romeo/install.sh
```

Then run `dsh-romeo --launch` (in a new terminal if `install.sh` said `~/.local/bin` is not on your `PATH`). To update: `cd ~/dsh-romeo && git pull && ./install.sh`.

## Use

| Command | |
|---|---|
| `dsh-romeo --launch` | starts the model on ROMEO (2 nodes, 8 GH200), waits until it answers, opens the dsh Web UI |
| `dsh-romeo` | opens the Web UI while the model job runs |
| `dsh-romeo --desktop` | the [DeepSeek Harness desktop app](https://github.com/deepseek-ai/deepseek-harness/releases) (macOS) instead of the Web UI |
| `dsh-romeo headless "a task"` | one task, the answer on stdout: for scripts |
| `dsh-romeo --run opencode` | any other client: `codex`, `claude`, `aider`, `python3 my_agent.py`... |
| `dsh-romeo --serve` | only the model and the tunnel, for an editor or any OpenAI-compatible tool |
| `dsh-romeo --status` | the gateway, the tunnel, and the model jobs with their queue start time |
| `dsh-romeo --stop` | stops the model jobs: they use your project's GPU hours while they run |
| `dsh-romeo --doctor` | checks Node.js, dsh, SSH, romeollmtool, the project, the fiches and the key; when something does not work |
| `dsh-romeo --models kimi --launch` | Kimi-K3.1-Pro instead (8 nodes, 32 GH200; for now project r260105 only); `--models kimi+deepseek`: Kimi for the agent, DeepSeek for its subagents |
| `dsh-romeo --voice on --launch` | voice input in dsh, transcribed by Whisper on ROMEO (1 GPU, French included) |

## Docs

[Usage](docs/usage.md) · [Other clients](docs/clients.md) · [Tuning](docs/tuning.md) · [How it works](docs/how-it-works.md) · [Troubleshooting](docs/troubleshooting.md) · [Changes](docs/changes.md) · [Development](docs/development.md)
