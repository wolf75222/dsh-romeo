# Troubleshooting

[README](../README.md) · [Usage](usage.md) · [Other clients](clients.md) · [Tuning](tuning.md) · [How it works](how-it-works.md) · **Troubleshooting** · [Changes](changes.md) · [Development](development.md)

- **Start here**: `dsh-romeo --doctor` checks each piece in turn and says what to type for the one that fails.
- **`cannot connect to 'romeo' over SSH`**: `ssh romeo hostname` must work without a password (see [Usage](usage.md#install)).
- **The job waits in the queue**: `dsh-romeo --status` says why (`Resources`: no free GPU nodes yet; `Priority`: other jobs first). Waiting can stop with Ctrl-C: the job stays in the queue and `dsh-romeo` picks it up later.
- **The job ends while loading**: read its log with `dsh-romeo --logs` (or `ssh romeo /apps/romeotools/romeollmtool/romeollmtool logs`). A node whose GPU memory is partly taken makes vLLM fail at start: `dsh-romeo --launch` again.
- **`cannot forward 127.0.0.1:11318`**: the message names the program that holds the port (stop it, or set `DSH_ROMEO_PORT`), or gives ssh's own reason when the port is free; dsh-romeo first retries on a new SSH connection. `dsh-romeo --stop`, then `dsh-romeo` again, starts from a clean connection.
- **The model is ready but dsh answers `Clé API invalide ou absente`**: dsh used another key than the gateway's. A `ROMEO_LLM_KEY` saved in dsh's credential store (`~/.dsh/.credentials.yaml`, from its Settings) wins over the one dsh-romeo passes; dsh-romeo now removes it at each start, and `dsh-romeo --doctor` reports it. A dsh or desktop app started by hand (not through dsh-romeo) has no key at all.
- **A client shows connection errors after your computer slept**: run `dsh-romeo` (or `--serve`) again; the tunnel is reopened and dsh keeps your sessions.
- **`fast gateway unavailable`**: the patch no longer fits `romeollmtool` (after an update, for example); dsh-romeo uses the standard gateway meanwhile. The reason is the last line of the message; the logs are in `~/.dsh-romeo/gateway` on ROMEO.
- **`fiche ... not found on ROMEO`**: `dsh-romeo --setup`.
- **opencode: `Database is not empty and has no session table`**: a database left by another opencode version in `~/.local/share/opencode`; nothing to do with dsh-romeo.
