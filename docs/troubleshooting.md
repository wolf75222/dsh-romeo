# Troubleshooting

[README](../README.md) · [Usage](usage.md) · [Other clients](clients.md) · [Tuning](tuning.md) · [How it works](how-it-works.md) · **Troubleshooting** · [Changes](changes.md) · [Development](development.md)

- **Start here**: `dsh-romeo --doctor` checks each piece in turn and says what to type for the one that fails.
- **`cannot connect to 'romeo' over SSH`**: `ssh romeo hostname` must work without a password (see [Usage](usage.md#install)).
- **The job waits in the queue**: `dsh-romeo --status` says why (`Resources`: no free GPU nodes yet; `Priority`: other jobs first). Waiting can stop with Ctrl-C: the job stays in the queue and `dsh-romeo` picks it up later.
- **The job ends while loading**: read its log with `dsh-romeo --logs` (or `ssh romeo /apps/romeotools/romeollmtool/romeollmtool logs`). A node whose GPU memory is partly taken makes vLLM fail at start: `dsh-romeo --launch` again.
- **`cannot forward 127.0.0.1:11318`**: another program uses the port: set `DSH_ROMEO_PORT`.
- **A client shows connection errors after your computer slept**: run `dsh-romeo` (or `--serve`) again; the tunnel is reopened and dsh keeps your sessions.
- **`fast gateway unavailable`**: the patch no longer fits `romeollmtool` (after an update, for example); dsh-romeo uses the standard gateway meanwhile. The reason is the last line of the message; the logs are in `~/.dsh-romeo/gateway` on ROMEO.
- **`fiche ... not found on ROMEO`**: `dsh-romeo --setup`.
- **opencode: `Database is not empty and has no session table`**: a database left by another opencode version in `~/.local/share/opencode`; nothing to do with dsh-romeo.
