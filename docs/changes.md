# Changes

[README](../README.md) · [Usage](usage.md) · [Other clients](clients.md) · [Tuning](tuning.md) · [How it works](how-it-works.md) · [Troubleshooting](troubleshooting.md) · **Changes** · [Development](development.md)

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
