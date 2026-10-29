# How it works

[README](../README.md) · [Usage](usage.md) · [Other clients](clients.md) · [Tuning](tuning.md) · **How it works** · [Troubleshooting](troubleshooting.md) · [Changes](changes.md) · [Development](development.md)

```
your computer                                      ROMEO
dsh / opencode / codex / claude ...                login node                       GPU nodes (armgpu)
  -> 127.0.0.1:11318 ===== one SSH connection ===> romeollmtool gateway :11318 ---> model jobs (vLLM, 2 x 4 GH200)
                                                   (or the fast gateway :11320)
```

- **The model.** Launched with ROMEO's own tool, `romeollmtool`, from a fiche tuned for agents (see [Tuning](tuning.md)), installed in `~/.romeollmtool/configs` by `install.sh`.
- **The gateway.** `romeollmtool`'s gateway runs on the login node: one URL and one key for all your model jobs, requests spread over them. dsh-romeo starts it if needed and pushes its automatic stop 24 hours away at each run, since that stop also cancels the jobs.
- **Waiting.** The model counts as ready when a real one-token request succeeds; until then dsh-romeo shows where the job is: in the queue and why, or loading.
- **The tunnel.** One SSH connection (a control socket in `~/.ssh`) carries every command and the tunnel `127.0.0.1:11318` to the gateway, reused from one run to the next and reopened after your computer slept.
- **dsh.** Runs with an overlay (`dsh --patch ~/.config/dsh-romeo/dsh.patch.yml`) that adds the `romeo` provider and makes DeepSeek-V4.1-Flash-1017 the default model, with maximum reasoning. Your own dsh profiles are not modified. The key reaches dsh through its environment (`ROMEO_LLM_KEY`) and is never written to disk.
- **Other clients.** The same endpoint, given in the variables each client reads (see [Other clients](clients.md)).
- **Messages** go to stderr, so `--env` and `--serve` can be read by scripts.

Files:

| | |
|---|---|
| `bin/dsh-romeo` | the command |
| `install.sh` | the installer |
| `share/fiches/` | the model's fiche for `romeollmtool` |
| `share/gateway/` | the fast gateway: its start script and patch |
| `share/web-search-searxng.mjs`, `share/searxng/` | web search: the dsh plugin and SearXNG's settings |
| `share/skills/romeo/` | the `romeo` skill: Slurm jobs, Spack and GPFS from the agent, linked into `~/.agents/skills` |
| `~/.config/dsh-romeo/` | your settings, the dsh overlay, opencode's config |
