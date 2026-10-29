# Troubleshooting

[README](../README.md) · [Usage](usage.md) · [Other clients](clients.md) · [Tuning](tuning.md) · [How it works](how-it-works.md) · **Troubleshooting** · [Changes](changes.md) · [Development](development.md)

- **npm `EACCES`, `mkdir /usr/local/lib/node_modules/@deepseek-ai`**: update and rerun `install.sh` (or `install.ps1` on Windows). Missing dsh is now installed with `--prefix` in your user-owned config directory, without changing npm's global prefix. Do not use `sudo npm install`. The unrelated `Unknown builtin config "globalignorefile"` warning comes from your existing npm configuration.
- **`cannot connect to 'romeo' over SSH`**: `ssh romeo hostname` must work without a password in the same environment as dsh-romeo. Windows and WSL have separate home directories and SSH settings (see [Platforms](usage.md#platforms)).
- **`bad interpreter`, `bash\r`, or `$'\r': command not found`**: update/reclone with the repository's `.gitattributes`; shell scripts and remote fiches must use LF line endings, including in a Windows checkout used by WSL.
- **PowerShell says script execution is disabled**: run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1`. The installed `dsh-romeo.cmd` launcher also works without changing the system execution policy.
- **`install Linux Node.js inside WSL`**: WSL found Windows Node.js. Install a Linux Node.js 20+ distribution and ensure its `node` and `npm` precede Windows tools in the WSL PATH.
- **The job waits in the queue**: `dsh-romeo --status` says why (`Resources`: no free GPU nodes yet; `Priority`: other jobs first). Waiting can stop with Ctrl-C: the job stays in the queue and `dsh-romeo` picks it up later.
- **The job ends while loading**: read its log with `ssh romeo /apps/romeotools/romeollmtool/romeollmtool logs`. A node whose GPU memory is partly taken makes vLLM fail at start: `dsh-romeo --launch` again.
- **`cannot forward 127.0.0.1:11318`**: another program uses the port: set `DSH_ROMEO_PORT`.
- **A client shows connection errors after your computer slept**: run `dsh-romeo` (or `--serve`) again; the tunnel is reopened and dsh keeps your sessions.
- **`fast gateway unavailable`**: the patch no longer fits `romeollmtool` (after an update, for example); dsh-romeo uses the standard gateway meanwhile. The reason is the last line of the message; the logs are in `~/.dsh-romeo/gateway` on ROMEO.
- **`fiche ... not found on ROMEO`**: `dsh-romeo --setup`.
- **opencode: `Database is not empty and has no session table`**: a database left by another opencode version in `~/.local/share/opencode`; nothing to do with dsh-romeo.
