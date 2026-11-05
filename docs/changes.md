# Changes

[README](../README.md) · [Usage](usage.md) · [Other clients](clients.md) · [Tuning](tuning.md) · [How it works](how-it-works.md) · [Troubleshooting](troubleshooting.md) · **Changes** · [Development](development.md)

## 2026-11-05

- Images with DeepSeek-V4.1-Flash-1017: its fiche now serves the vision encoder (tested on ROMEO: image read correctly, 6.34M tokens of KV cache instead of 6.5M, 160 tok/s for one agent), and dsh-romeo declares a model `input: [ text, image ]` unless its fiche passes `--language-model-only`, so you can paste screenshots in dsh. Kimi-K3.1-Pro stays text only until its own test runs. Run `dsh-romeo --setup` (or `./install.sh`) to copy the new fiche, then relaunch the DeepSeek job.
- Voice input: `dsh-romeo --voice on --launch` runs Whisper large-v3-turbo on 1 GPU (new fiche `dsh-whisper-large-v3-turbo`) and turns on dsh's microphone button with Whisper as its recognizer ([share/speech-whisper-romeo.mjs](../share/speech-whisper-romeo.mjs)); dsh's own local recognizer, SenseVoice, does not know French. Remembered like `--models`. Tested offline (the provider against a fake Whisper server, the overlay composed with dsh 0.2.2-rc.1); not yet on a GPU, ROMEO's queue being full.
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
