# Usage

[README](../README.md) · **Usage** · [Other clients](clients.md) · [Tuning](tuning.md) · [How it works](how-it-works.md) · [Troubleshooting](troubleshooting.md) · [Changes](changes.md) · [Development](development.md)

## Install

On your computer (macOS or Linux), once `ssh romeo` logs you into ROMEO without a password:

```bash
git clone https://github.com/wolf75222/dsh-romeo.git ~/dsh-romeo && ~/dsh-romeo/install.sh
```

`install.sh` installs dsh if it is missing (`npm install -g @deepseek-ai/dsh`, Node.js 20 or later), asks which ROMEO project pays for the model jobs, links `dsh-romeo` in `~/.local/bin` and copies the model's fiche to `~/.romeollmtool/configs` on ROMEO. Run it again after `git pull`: it keeps your settings.

| Option | |
|---|---|
| `--project r123456` | the Slurm project code charged for the model jobs (asked otherwise) |
| `--host romeo` | the ssh alias of ROMEO |
| `--bin-dir DIR` | where to link `dsh-romeo` (default `~/.local/bin`) |
| `--search` | also runs SearXNG in Docker for web search (`127.0.0.1:8888`) |
| `--yes` | no questions |

No `romeo` alias yet? Add it to `~/.ssh/config`:

```
Host romeo
    HostName romeo1.univ-reims.fr
    User <your ROMEO login>
    IdentityFile ~/.ssh/<your key registered on ROMEO>
```

## Commands

| Command | |
|---|---|
| `dsh-romeo --launch` | starts the model (one job, 2 nodes, 8 GH200), waits until it answers (8 to 13 min in our tests), opens the dsh Web UI |
| `dsh-romeo` | opens the Web UI while the job runs |
| `dsh-romeo --desktop` | opens the DeepSeek Harness desktop app (macOS) on the ROMEO model instead of the Web UI: it writes the provider into the app's `~/.dsh/profiles/desktop/cordis.patch.yml` (a patch of your own there is kept as `cordis.patch.yml.before-dsh-romeo`) and restarts the app if it runs, since it reads the key at start only. Combines with `--launch` |
| `dsh-romeo headless "run the tests and fix them"` | one task, the answer printed on stdout: for scripts |
| `dsh-romeo web --port 3000` | any dsh profile and argument pass through |
| `dsh-romeo --launch 3` | three jobs: the gateway spreads the agents over them |
| `dsh-romeo --run CMD [ARGS]` | another client instead of dsh: see [Other clients](clients.md) |
| `dsh-romeo --serve` | only the model and the tunnel, then it prints the endpoint and returns |
| `eval "$(dsh-romeo --env)"` | the endpoint and the key as variables of this shell |
| `dsh-romeo --status` | the gateway, the model jobs, the tunnel |
| `dsh-romeo --stop` | stops the model jobs and closes the tunnel |
| `dsh-romeo --setup` | copies the model's fiche to ROMEO again |

`--launch` combines with the others: `dsh-romeo --launch --run opencode`. While the model loads, Ctrl-C stops waiting, not the job: run `dsh-romeo` again later.

## Where the agents work

On your computer: only the model runs on ROMEO. In the Web UI, a session works in the workspace chosen above the message box: on first use dsh creates `~/Documents/deepseek-harness/default-workspace`; add your project folder with the button next to *Workspaces*. `dsh-romeo headless` and the other clients work in the current folder.

## Jobs on ROMEO

`install.sh` links the `romeo` skill ([share/skills/romeo](../share/skills/romeo/SKILL.md)) into `~/.agents/skills`, where dsh finds it, as do the other clients that read that folder. With it the agent submits and follows Slurm jobs on `x64cpu` or `armgpu`, loads Spack software (compilers, CUDA, MPI, Python, PyTorch), checks quotas and copies files to and from ROMEO, over the same SSH connection as the tunnel, charged to `ROMEO_PROJECT`. It asks before jobs larger than one node, 4 GPUs or 4 hours, and never cancels a job it did not submit, such as the model's own. Load it with `/romeo`, or let the agent pick it when a task mentions ROMEO, Slurm or GPUs.

The skill holds what ROMEO's documentation says (each page is linked from it), checked against the cluster on 2026-10-29: hardware, partitions and limits, job templates, installed software, storage, ROMEO's own tools in `/apps/romeotools`, and a troubleshooting table.

It also works for an agent running on ROMEO itself (on a login node, the commands run locally instead of over SSH). There, link it by hand:

```bash
git clone https://github.com/wolf75222/dsh-romeo.git ~/dsh-romeo
mkdir -p ~/.agents/skills && ln -s ~/dsh-romeo/share/skills/romeo ~/.agents/skills/romeo
```

For Claude Code, link the same folder into `~/.claude/skills/romeo`.

## Web search

`install.sh --search` runs [SearXNG](https://docs.searxng.org/) in Docker on `127.0.0.1:8888` (container `dsh-romeo-searxng`, settings in `~/.config/dsh-romeo/searxng`) and sets `DSH_ROMEO_SEARXNG_URL`: dsh's `web_search` tool then searches through it. Any SearXNG with the JSON format enabled works.

## Settings

`install.sh` writes them to `~/.config/dsh-romeo/config`; a variable set in the environment wins.

| Variable | Default | |
|---|---|---|
| `ROMEO_PROJECT` | asked | Slurm project code charged for the model jobs |
| `ROMEO_SSH_HOST` | `romeo` | ssh alias of a ROMEO login node |
| `DSH_ROMEO_FICHE` | `dsh-deepseek-v4.1-flash-1017-1m` | `romeollmtool` fiche of the model; `deepseek-v4.1-flash-vllm` is ROMEO's validated one (1 node, 262K context, longer to load) |
| `DSH_ROMEO_TIME` | `08:00:00` | duration of a model job (24 h at most) |
| `DSH_ROMEO_EFFORT` | `max` | default reasoning effort: `none`, `low`, `high`, `max` |
| `DSH_ROMEO_PORT` | `11318` | local port of the tunnel |
| `DSH_ROMEO_SEARXNG_URL` | empty | SearXNG for web search, e.g. `http://127.0.0.1:8888` |
| `DSH_ROMEO_GATEWAY` | `standard` | `fast`: the patched gateway (see [Tuning](tuning.md)) |
| `DSH_ROMEO_FAST_PORT`, `DSH_ROMEO_FAST_PROCS` | `11320`, `4` | its port on the login node and its processes |

## Cost

A model job uses the GPU hours of your project for as long as it runs, even when no agent works: `dsh-romeo --stop` when you are done. It ends anyway after `DSH_ROMEO_TIME`. `romeollmtool`'s gateway stops by itself 24 hours after the last `dsh-romeo`, and cancels your model jobs then.
