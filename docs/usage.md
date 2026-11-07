# Usage

[README](../README.md) · **Usage** · [Other clients](clients.md) · [Tuning](tuning.md) · [How it works](how-it-works.md) · [Troubleshooting](troubleshooting.md) · [Changes](changes.md) · [Development](development.md)

## Install

On your computer (macOS or Linux), once `ssh romeo` logs you into ROMEO without a password:

```bash
git clone https://github.com/wolf75222/dsh-romeo.git ~/dsh-romeo && ~/dsh-romeo/install.sh
```

`install.sh` installs dsh if it is missing (`npm install -g @deepseek-ai/dsh@next`, 0.2.2, with Node.js 24.9 or later; `@latest`, 0.2.1, with Node.js 20 to 24.8), asks which ROMEO project pays for the model jobs, links `dsh-romeo` in `~/.local/bin` and copies the models' fiches to `~/.romeollmtool/configs` on ROMEO. Run it again after `git pull`: it keeps your settings.

| Option | |
|---|---|
| `--project r123456` | the Slurm project code charged for the model jobs (asked otherwise) |
| `--host romeo` | the ssh alias of ROMEO |
| `--bin-dir DIR` | where to link `dsh-romeo` (default `~/.local/bin`) |
| `--search` | also runs SearXNG in Docker for web search (`127.0.0.1:8888`) |
| `--search-engine rustxng` | RustXNG instead of SearXNG, same address (see below) |
| `--no-plugins` | skips the optional dsh plugins below |
| `--yes` | no questions |

`install.sh` also installs a few third-party dsh plugins, **turned off**, in the dsh profiles dsh-romeo opens (`web`, and the desktop app's): turn them on or off in dsh's **Plugins** page, under *Installed plugins*. A plugin you already have is left as you set it, unless its installed version no longer fits your dsh (its declared dsh range, as dsh-sidenote's `<0.2.3`): then it moves to the plugin's latest version, on or off as it was. A pinned version that your dsh refuses also falls back to the latest one. Run `./install.sh` again after updating dsh. The list, with pinned versions read and checked on dsh 0.2.2-rc.1, is [share/plugins.txt](../share/plugins.txt):

| Plugin | |
|---|---|
| [dsh-prompt-predict](https://github.com/ferrisching/dsh-prompt-predict) | suggests your next prompt after each answer, accepted with Tab; with `kimi+deepseek`, dsh-romeo points it to DeepSeek without reasoning so that it stays fast; otherwise it follows the session's model |
| [dsh-sidenote](https://github.com/g-yixuan/dsh-sidenote) | side chat: a temporary conversation seeded from the session, whose answer comes back to the main thread |

dsh already has plan mode (`/plan`) and a background jobs panel in the session header.

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
| `dsh-romeo --desktop` | opens the DeepSeek Harness desktop app (macOS) on the ROMEO model instead of the Web UI: it writes the provider into the app's `~/.dsh/profiles/desktop/cordis.patch.yml`, keeping the settings the app saves there (theme, permissions, account...; a copy of the file before dsh-romeo's first run is in `cordis.patch.yml.before-dsh-romeo`) and restarts the app if it runs, since it reads the key at start only. Combines with `--launch` |
| `dsh-romeo headless "run the tests and fix them"` | one task, the answer printed on stdout: for scripts |
| `dsh-romeo web --port 3000` | any dsh profile and argument pass through |
| `dsh-romeo --launch 3` | three jobs: the gateway spreads the agents over them |
| `dsh-romeo --run CMD [ARGS]` | another client instead of dsh: see [Other clients](clients.md) |
| `dsh-romeo --serve` | only the model and the tunnel, then it prints the endpoint and returns |
| `eval "$(dsh-romeo --env)"` | the endpoint and the key as variables of this shell |
| `dsh-romeo --status` | the gateway, the tunnel, and a table of the model jobs: state, nodes, time left, or Slurm's estimated start while queued |
| `dsh-romeo --stop` | cancels every dsh-romeo model job (also of an earlier `--models`) and closes the tunnel |
| `dsh-romeo --doctor` | checks this computer (Node.js, dsh, the tunnel's port), SSH, romeollmtool, the project, the fiches on ROMEO, the key and the gateway; changes nothing, exits 1 if a check fails |
| `dsh-romeo --completion bash\|zsh` | shell completion of the options, models and dsh profiles: `eval "$(dsh-romeo --completion zsh)"` in `~/.zshrc` (`bash`: `~/.bashrc`) |
| `dsh-romeo --logs [-f]` | the last 40 lines of the agent's model job log (`-f` follows it) |
| `dsh-romeo --version`, `--help` | `-V`, `-h`: the versions of dsh-romeo, dsh, the app's dsh and Node.js |
| `dsh-romeo --setup` | copies the models' fiches and the job clean-up to ROMEO again; `--launch` also does it, for the fiches it launches, when this version's differ |
| `dsh-romeo --models kimi ...` | the models, kept for the next runs (see below); options go in any order |
| `dsh-romeo --voice on --launch` | voice input: dsh's microphone button, transcribed by Whisper on ROMEO (see below); kept for the next runs |
| `dsh-romeo --web on` | web search through RustXNG on the ROMEO login node (see below); kept for the next runs |

`--launch [N]` (1 to 8 jobs; Kimi: 1) combines with the others, in any order with `--models`, `--voice`, `--serve`, `--env` and `--desktop`: `dsh-romeo --desktop --launch`, `dsh-romeo --launch --run opencode` (before `--run`, whose arguments are the client's). While the model loads, Ctrl-C stops waiting, not the job: run `dsh-romeo` again later.

## Models

| `--models` / `DSH_ROMEO_MODELS` | Agent | Subagents | Jobs |
|---|---|---|---|
| `deepseek` (default) | DeepSeek-V4.1-Flash-1017 | the same | 2 nodes, 8 GH200 |
| `kimi` | Kimi-K3.1-Pro | the same | 8 nodes, 32 GH200: one job at most within ROMEO's 60-GPU account limit |
| `kimi+deepseek` | Kimi-K3.1-Pro | DeepSeek-V4.1-Flash-1017 | one Kimi job and one DeepSeek job (40 GPUs) |

`--models` is remembered (in `~/.config/dsh-romeo/models`): after `dsh-romeo --models kimi+deepseek --launch`, a plain `dsh-romeo --desktop` or `dsh-romeo --status` uses the same models, until the next `--models`. `DSH_ROMEO_MODELS` set in the environment wins over it for one command.

`dsh-romeo --models kimi+deepseek --launch` submits both jobs (the DeepSeek one only if none runs) and waits until both models answer. dsh then starts on Kimi, with both models in its model list, and its `subagent` tool sends subagents to DeepSeek: the faster, cheaper model for delegated work, Kimi for the main thread. In the Web UI and the desktop app the agent may also pick Kimi for a subagent (dsh's model selection, with both models allowed: ask it, for example "start a Kimi subagent that..."); each keeps its full 1M context. A subagent can start its own subagents up to dsh's subagent depth (2 in the Web and desktop profiles), so a Kimi agent can run Kimi subagents that each hand work to DeepSeek. The agent is told all this in its system prompt (dsh's `personaSuffix`), so it knows it can pick Kimi or DeepSeek; in `headless`, where dsh offers no choice, it is told its subagents run on DeepSeek. The choice is recorded when a session starts: open a new session after changing `--models`. Kimi serves 6 to 8 agents at once well, subagents included. `subagent_fork` children keep Kimi, since they continue the agent's own conversation. DeepSeek also writes the session titles and, when you turn it on, dsh-prompt-predict's suggestions (without reasoning), so this side work never waits for Kimi. With `deepseek` or `kimi` alone, all of it follows the session's model; a model you pick yourself in dsh-prompt-predict's settings wins.

dsh's MCP client has no server by default: add one in your own dsh patch, as its README shows. `--status` and `--stop` cover the jobs of both models. With `--run`, Claude Code's small model (`ANTHROPIC_DEFAULT_HAIKU_MODEL`) and opencode's `small_model` go to DeepSeek; `--env` adds `DSH_ROMEO_SUB_MODEL`.

The Kimi weights and its vLLM engine live on project `r260105`'s storage (see [Tuning](tuning.md#kimi-k31-pro)): its fiche works for that project's members.

## Images

Both models read images (their vision encoder is served): paste a screenshot or attach a picture in dsh, or send `image_url` parts to the endpoint from another client. dsh-romeo declares `input: [text, image]` for each model in dsh's provider, so dsh offers the attachment. Tested on ROMEO on each production fiche: the number in a test image read correctly, at the same speed and with about the same KV cache as text only.

## Voice input

`dsh-romeo --voice on --launch` adds a third job, Whisper large-v3-turbo on 1 GPU (fiche `dsh-whisper-large-v3-turbo`, French and 98 other languages), and turns on the microphone button of dsh's input box: record, release, and the transcript lands in the box (nothing is sent by itself). dsh's own voice plugin recognizes speech on your computer with SenseVoice, which does not know French; dsh-romeo keeps its button and replaces the recognizer by Whisper on ROMEO ([share/speech-whisper-romeo.mjs](../share/speech-whisper-romeo.mjs)). Recordings go straight to the Whisper job through a second forward of the same SSH connection (`127.0.0.1:11319`, `DSH_ROMEO_VOICE_PORT`), with the job's own key: romeollmtool's gateway cannot relay audio uploads (its `python-multipart` is missing). Measured: 8 s of French speech transcribed in 0.2 s, the language given or detected. dsh does not wait for Whisper: the button works once its job is up (under 4 minutes; the first start downloads 1.6 GB into the Hugging Face cache of your ROMEO home). If the job only starts after dsh, a watcher left in the background opens the tunnel and writes the job's key (`~/.config/dsh-romeo/whisper.key`, read at each recording) once it runs: no need to restart dsh. `--voice off` removes it; `--status` and `--stop` cover its job.

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

`dsh-romeo --web on` (remembered, like `--voice`): dsh's `web_search` tool searches through [RustXNG](https://github.com/sahenjp/RustXNG) on the ROMEO login node, nothing to install on your computer. The first start downloads RustXNG's static binary (0.28.0, 32 MB, its SHA-256 pinned in dsh-romeo and checked) into `~/.dsh-romeo/rustxng` on ROMEO. Each search runs it over dsh-romeo's SSH connection (`rustxng mcp`, on stdin and stdout): no port is opened on the login node, which other ROMEO users share, and the queries leave from ROMEO with RustXNG's `standard` profile (engines that allow automated use). About 1 s per search, 10 results. Pages are read from your computer, as before. `--web off` turns it off; `--status` and `--doctor` show it. Searches from ROMEO share the university's address with every ROMEO user: an engine may answer with fewer results some days.

On your computer instead, with Docker:

`install.sh --search` runs [SearXNG](https://docs.searxng.org/) in Docker on `127.0.0.1:8888` (container `dsh-romeo-searxng`, settings in `~/.config/dsh-romeo/searxng`) and sets `DSH_ROMEO_SEARXNG_URL`: dsh's `web_search` tool then searches through it. Any SearXNG with the JSON format enabled works.

`install.sh --search-engine rustxng` runs [RustXNG](https://github.com/sahenjp/RustXNG) instead (container `dsh-romeo-rustxng`, image pinned to 0.28.0 by its digest), a rewrite of SearXNG in Rust with the same JSON API: no change on dsh's side. Measured on ROMEO (2026-11-06, 20 coding queries): about as relevant as SearXNG (better on library docs, worse on GitHub issues), a fifth of its memory (68 MB at peak), instant repeated queries from its cache. It is three weeks old and AGPL-3.0; never switch it to its `full` profile, which queries engines whose terms forbid automated access. `--search-engine searxng` (or `--search`) goes back to SearXNG.

## Settings

`install.sh` writes most of them to `~/.config/dsh-romeo/config`; a variable set in the environment wins. `--models` and `--voice` are remembered in `~/.config/dsh-romeo/models` and `voice`. Rarely needed: `DSH_ROMEO_POLL` (seconds between checks while a model loads, or while the voice watcher waits for the Whisper job), `DSH_ROMEO_NOTIFY=off` (no bell or desktop notification when a model is ready after a wait of `DSH_ROMEO_NOTIFY_AFTER`, 60 s), `NO_COLOR` (no colors), `DSH_ROMEO_SOCKET` (the SSH control socket), `DSH_ROMEO_DSH`, `DSH_ROMEO_DESKTOP_APP`, `DSH_ROMEO_DESKTOP_DSH` (which dsh and app to use), `DSH_ROMEO_CONFIG_DIR`, `ROMEOLLMTOOL`.

| Variable | Default | |
|---|---|---|
| `ROMEO_PROJECT` | asked | Slurm project code charged for the model jobs |
| `ROMEO_SSH_HOST` | `romeo` | ssh alias of a ROMEO login node |
| `DSH_ROMEO_MODELS` | `deepseek` | `deepseek`, `kimi` or `kimi+deepseek` (see [Models](#models)); the last `--models` wins over the config file |
| `DSH_ROMEO_VOICE` | `off` | `on`: voice input with Whisper on ROMEO (see [Voice input](#voice-input)); the last `--voice` wins over the config file |
| `DSH_ROMEO_VOICE_PORT` | `11319` | local port of the tunnel to the Whisper job |
| `DSH_ROMEO_FICHE` | empty | a `romeollmtool` fiche of your own for the agent's model, e.g. `deepseek-v4.1-flash-vllm`, ROMEO's validated one (1 node, 262K context, longer to load) |
| `DSH_ROMEO_TIME` | `08:00:00` | duration of a model job (24 h at most) |
| `DSH_ROMEO_EFFORT` | `max` | default reasoning effort: `off`, `low`, `high`, `max` |
| `DSH_ROMEO_PORT` | `11318` | local port of the tunnel |
| `DSH_ROMEO_SEARXNG_URL` | empty | SearXNG for web search, e.g. `http://127.0.0.1:8888` |
| `DSH_ROMEO_GATEWAY` | `standard` | `fast`: the patched gateway (see [Tuning](tuning.md)) |
| `DSH_ROMEO_FAST_PORT`, `DSH_ROMEO_FAST_PROCS` | `11320`, `4` | its port on the login node and its processes |

## Cost

A model job uses the GPU hours of your project for as long as it runs, even when no agent works: `dsh-romeo --stop` when you are done. It ends anyway after `DSH_ROMEO_TIME`. `romeollmtool`'s gateway stops by itself 24 hours after the last `dsh-romeo`, and cancels your model jobs then.
