# Changes

[README](../README.md) · [Usage](usage.md) · [Other clients](clients.md) · [Tuning](tuning.md) · [How it works](how-it-works.md) · [Troubleshooting](troubleshooting.md) · **Changes** · [Development](development.md)

## 2026-11-05

- The ready line gives the gateway's URL on ROMEO and the local tunnel URL, each on its own line.
- Fix: a `ROMEO_LLM_KEY` saved in dsh's credential store won over the gateway's key passed by dsh-romeo, so dsh got `Clé API invalide ou absente` once the model was up; dsh-romeo removes that entry before starting dsh or the app, and `--doctor` reports it. A refused SSH forward is retried on a new connection, then reported with ssh's own reason or the program holding the port, instead of always blaming "another program".
- Terminal: `--status` is a table (model, job, state, nodes, time left or the queue's estimated start), the tunnel counts as open only when it leads to the gateway, errors end with the command to type next, `--launch` with `--status`/`--stop`/`--setup` is refused instead of ignored, Ctrl-C while waiting says the job keeps running, the waiting line no longer repeats every poll in a log, `NO_COLOR` and `TERM=dumb` turn colors off, and a bell plus a desktop notification say when a model is ready after a long wait. New `--doctor` (checks this computer, SSH, ROMEO, the fiches and the key), `--completion bash|zsh`, `--logs [-f]`; `--version` also gives dsh's, the app's and Node.js's versions. `--help` is grouped by use.
- `--stop` cancels every dsh-romeo job, also those of an earlier `--models`, and goes on past a job it cannot cancel; Kimi takes one job at most (a second `--launch` says one is queued); curl reads the gateway key from stdin; the fast gateway refuses a port held by another user; `install.sh` checks its options' values, keeps settings it does not write, and needs Node.js 20.3. `DSH_ROMEO_EFFORT=none` is now `off` (dsh refused `none`). `--desktop` quits the app before writing its patch, and stops if it does not quit.
- With `kimi+deepseek`, DeepSeek also writes the session titles and dsh-prompt-predict's suggestions (when it is on, without reasoning); before, they ran on Kimi or on the plugin's own setting. The MCP client needs servers of your own: documented.
- Voice input with a Whisper job that starts after dsh: a background watcher opens the tunnel once the job runs, and the plugin reads the job's key from a file at each recording, so the microphone works without restarting dsh.
- `install.sh` keeps the optional plugins working on a newer dsh: an installed version outside its declared dsh range moves to the latest version (keeping its on/off state), and a refused pinned version falls back to the latest.
- Test suite: passes in full on a ROMEO login node too (the skill's env.sh can be told it runs remote, and the fast gateway test no longer finds ROMEO's real romeollmtool Python).
- `install.sh` installs optional third-party dsh plugins, turned off, in the `web` and desktop app profiles: dsh-prompt-predict (next-prompt suggestions) and dsh-sidenote (side chat). Turn them on in dsh's Plugins page; `--no-plugins` skips them. Checked on dsh 0.2.2-rc.1: they load and show under *Installed plugins* with their switch off. Plugins that import dsh internals (dsh-answer-reviewer, dsh-task-supervisor, dsh-claude-move) do not load on 0.2.2 and are left out.
- The README GIF plays in 16 s instead of 33: `tests/demo.py render` cuts pauses to 45 % (typing kept as recorded).
- Images with DeepSeek-V4.1-Flash-1017: its fiche now serves the vision encoder (tested on ROMEO: image read correctly, 6.34M tokens of KV cache instead of 6.5M, 160 tok/s for one agent), and dsh-romeo declares a model `input: [ text, image ]` unless its fiche passes `--language-model-only`, so you can paste screenshots in dsh. Kimi-K3.1-Pro stays text only until its own test runs. Run `dsh-romeo --setup` (or `./install.sh`) to copy the new fiche, then relaunch the DeepSeek job.
- Voice input: `dsh-romeo --voice on --launch` runs Whisper large-v3-turbo on 1 GPU (new fiche `dsh-whisper-large-v3-turbo`) and turns on dsh's microphone button with Whisper as its recognizer ([share/speech-whisper-romeo.mjs](../share/speech-whisper-romeo.mjs)); dsh's own local recognizer, SenseVoice, does not know French. Remembered like `--models`. Tested on ROMEO: Whisper starts in under 4 minutes on 1 GPU and transcribes 8 s of French in 0.2 s; recordings go straight to the job through a second SSH forward, since romeollmtool's gateway cannot relay audio uploads (python-multipart missing).
- `--models`, `--launch` and `--serve`/`--env`/`--desktop` go in any order: `dsh-romeo --models kimi+deepseek --desktop --launch` launched nothing before (`--launch` was only read before the command).

## 2026-11-04

- Checked with dsh 0.2.2-rc.1 (npm `next`, and the desktop app 0.2.2-rc.1). `install.sh` installs that version when Node.js is 24.9 or later. `--desktop` reads the presets it restates with the app's own dsh, whose version can differ from the npm one (0.2.1 kept a `list_agents` tool that 0.2.2-alpha.3 lacks).

- `--models` is remembered for the next runs, so `dsh-romeo --desktop` after `dsh-romeo --models kimi+deepseek --launch` opens the app on Kimi. `--desktop` keeps the settings the app saves in its `cordis.patch.yml` (it overwrote them at every start) and replaces only dsh-romeo's own rows.

- Choice of models: `dsh-romeo --models deepseek|kimi|kimi+deepseek` (or `DSH_ROMEO_MODELS` in the config). `kimi+deepseek` runs Kimi-K3.1-Pro as the agent and DeepSeek-V4.1-Flash-1017 for its subagents: both jobs launched and waited for, both models in dsh's list, dsh's `subagent` tool routed to DeepSeek in every preset. `install.sh` writes `DSH_ROMEO_MODELS`; a `DSH_ROMEO_FICHE` left at the old default is dropped, a fiche of your own is kept.

- Kimi-K3.1-Pro, with `DSH_ROMEO_FICHE=dsh-kimi-k3.1-pro-1m`: 8 nodes, TP8 x PP4 x DCP8, 1M context, tuned by an A/B on ROMEO ([Tuning](tuning.md#kimi-k31-pro)). Tested on a real job: answers at the four reasoning efforts, parallel tool calls, 763K-token prompts. dsh, opencode and `--serve` show the model's own name.

## 2026-10-29

- The `romeo` skill: the agent runs Slurm jobs on ROMEO (`x64cpu`, `armgpu`), Spack software and GPFS, from your computer over the shared SSH connection or on ROMEO itself. Written from the whole ROMEO 2025 documentation and checked on the cluster (test jobs on both architectures, then an agent given only the skill). `./install.sh` links it into `~/.agents/skills` (an existing `romeo` skill of yours is kept as `romeo.before-dsh-romeo`).

## 2026-10-28

- `dsh-romeo --desktop`: the DeepSeek Harness desktop app (macOS) on the ROMEO model, checked with the app 0.2.1-rc.3 (the same patch as a real session on ROMEO) and by the offline tests.
- The model is DeepSeek-V4.1-Flash-1017, DeepSeek's 17 October update of V4.1-Flash, read from ROMEO's shared storage (`/gpfs/scratch/romeotools/llmstorage/unsloth/DeepSeek-V4.1-Flash-1017`). New fiche `dsh-deepseek-v4.1-flash-1017-1m` (job `romeollmtool-dsh-deepseek-v4.1-flash-1017-1m`, served model of the same name), same settings. Run `./install.sh` again (it moves `DSH_ROMEO_FICHE` to the new fiche if you kept the default), then `--launch`. Tested on a real job: answers, reasoning, streaming, tool calls (parallel too), a needle at 893K tokens; throughput per replica matches the September weights (170 tokens/s for one agent, 34 each for 64), DSpark acceptance 41 %.
- Tuned for the 1017 weights by an A/B on ROMEO (6 variants at once, 1 to 128 requests, then 42 agent sessions of 10 turns): DSpark 2 draft tokens instead of 3 (+3 to +9 %) and `gpu-memory-utilization` 0.82 instead of 0.78 (6.5M tokens of KV cache instead of 4.7M). Expert parallelism, larger prefill chunks and vLLM 0.32 were tried and left out: the fiche says why.

## 2026-10-25

- Any client on the ROMEO model: `--run CMD` (opencode, Codex CLI, Claude Code, Aider, SDKs), `--serve`, `--env`. Each tested against a real job.
- `DSH_ROMEO_GATEWAY=fast`: the patched gateway of the A/B study, with a fallback to the standard one.
- Messages on stderr; documentation split into these pages.

## 2026-10-24

- The README's GIF: the launch in a terminal, then the dsh Web UI it opens, a chat that fixes a test and the Trajectory tab, recorded from a real run.
- First version: `install.sh`, `dsh-romeo` with `--launch`, `--status`, `--stop`, `--setup`, the tuned fiche, optional SearXNG web search, offline tests against a fake ROMEO.
