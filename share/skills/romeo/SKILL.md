---
name: romeo
description: Run work on the ROMEO 2025 supercomputer (URCA, Reims), either from the user's computer over SSH or directly on a ROMEO login node: Slurm jobs (sbatch, srun, squeue, sacct, scancel), x64cpu (AMD EPYC) and armgpu (GH200 Grace Hopper, H100) nodes, Spack software (compilers, CUDA, MPI, Python, PyTorch), GPFS storage and quotas, copying files to and from ROMEO. Use whenever a task mentions ROMEO, Slurm, sbatch, a cluster, HPC, GPUs, GH200 or H100, or needs more compute than this machine has.
---

# ROMEO 2025

Supercomputer of the Centre de Calcul Régional ROMEO (Université de Reims Champagne-Ardenne, Eviden-Bull). Slurm 23.11, Spack 1.0, RHEL 9, GPFS. Two incompatible architectures: x86_64 CPU nodes and aarch64 GPU nodes.

## 1. Where am I?

Start every shell command with the helper next to this file (`scripts/env.sh`, installed as `~/.agents/skills/romeo/scripts/env.sh`). Shell state does not survive between tool calls, so source it in each one:

```bash
. ~/.agents/skills/romeo/scripts/env.sh
R 'hostname; whoami; squeue --me'
```

It defines `R`, which runs one command on a ROMEO login node: locally when you already are on ROMEO (`/apps/romeotools` exists), else over `ssh $ROMEO_SSH_HOST` (default `romeo`; key, no password), reusing dsh-romeo's connection when open. Off ROMEO it also sets `RSYNC_SSH` for copies:

```bash
rsync -az -e "$RSYNC_SSH" ./proj/ "$ROMEO_SSH_HOST":proj/              # up (paths relative to the ROMEO home)
rsync -az -e "$RSYNC_SSH" "$ROMEO_SSH_HOST":proj/results/ ./results/   # down
```

- Each `R` call is a fresh login shell: `cd`, variables and `romeo_load_*` do not carry over, so chain them: `R 'cd ~/proj && sbatch job.sh'`. In `R '...'` variables expand on ROMEO; in `R "..."` they expand here first (use that for `$ROMEO_PROJECT`, `$id`).
- `hostname`: `romeo1`..`romeo4` are login nodes (x86_64), `romeo-cNNN` x64cpu nodes, `romeo-aNNN` armgpu nodes. Inside a job `SLURM_JOB_ID` is set: then you are on a compute node, and `sbatch`/`srun` start new jobs.

**Project to charge** (`--account`): `$ROMEO_PROJECT` (from dsh-romeo's config). If it is empty, list the user's projects with `R 'sacctmgr -n -P show assoc user=$USER format=account' | grep -vx default`; one: use it; several: ask the user. Then `export ROMEO_PROJECT=<code>` at the start of each later command. An empty value gives `--account=` and the job is refused. Never guess.

## 2. Rules

1. **Never cancel what you did not submit.** `squeue --me` also shows the user's other jobs, among them `romeollmtool-*`: the LLM you may be running on. `scancel <id>` only for ids you got from your own `sbatch`/`srun`. Never `scancel --me`, `-u`, `-n` or `--state`.
2. **Jobs cost the project's hours.** Before submitting, say: account, partition/time, nodes, cores, GPUs, memory. Ask the user first for anything beyond what they asked for that exceeds 1 node, 4 GPUs, 4 hours, the `long` partition, or 10 jobs in the task; resources the user named themselves ("on 2 nodes") need no second confirmation. Ask for the least that works: smaller and shorter jobs start sooner. Debug on a tiny case before the big run: a failed build in a GPU job still costs a job.
3. **Check quotas once per task, before writing data:** `R '/apps/romeotools/myquotas.sh --short --no-color; echo "rc=$?"'`, alone in its call (rc 0 ok, 1 grace period, 2 writes blocked somewhere). The report is in French: `<user> (scratch, fichiers) : écriture bloquée` means scratch is blocked by its **number of files** (`fichiers`), or by space (`espace`/`blocs`), its grace period over. Writes there fail with `Disk quota exceeded`: tell the user (in their words: which space, space or file count, what takes it: `myquotas.sh` without `--short`), work in another space (blocked scratch: run from `$SLURM_SUBMIT_DIR` in the home, `/dev/shm` for temporary files), never delete their files to make room.
4. **No backups on GPFS.** A deletion is final. `rm` only what you created in this session; ask for anything else. Copy results worth keeping back to the user's computer.
5. **Login nodes are shared and x86_64:** editing, small x86_64 builds, `spack find`, submitting. No runs longer than a minute or two, no heavy builds, no GPU work; nothing aarch64 runs there. Put heavy work in a job.
6. **Never `salloc` from an agent** (it waits for a terminal). Use `sbatch` for real work and one-shot `srun` for short checks (section 5).
7. **Wait politely:** poll `squeue -j <id>` about every 30 to 60 s for a bounded time, or `sbatch --wait` for jobs of a few minutes; then read the logs. A job in `PD` may wait: report its reason instead of resubmitting.
8. Nothing in `~/.bashrc` (above all no `romeo_load_*`), no files left in `/project/<id>` without the user's say (shared by the project), no ssh to a compute node to use its GPUs (they may belong to another job).

## 3. Hardware and partitions

| `--constraint` | Nodes | Per node | Load with |
|---|---|---|---|
| `x64cpu` | 44: `romeo-c[001-040]`, Fat `romeo-c[101-104]` | 2 x AMD EPYC 9654 = 192 cores (zen4), ~1.1 TB RAM (Fat: ~1.5 TB), Ethernet 100 Gb/s, no GPU | `romeo_load_x64cpu_env` |
| `armgpu` | 58: `romeo-a[001-058]` | 4 x GH200: 288 Arm Neoverse V2 cores (72 per GPU), 4 x H100 with 96 GB HBM3 each (`nvidia-smi`: "GH200 120GB", 97871 MiB), ~800 GB RAM for jobs, Infiniband 200 Gb/s per GPU | `romeo_load_armgpu_env` |

Usable `--mem` per node: about `1100G` x64cpu, `1500G` Fat, `800G` armgpu. Login nodes `romeo1..4.univ-reims.fr`: AMD x86_64. Compute nodes reach the internet (pip, git, Hugging Face work); `/tmp` on armgpu nodes is a small 16 GB root disk, `/dev/shm` is large (RAM).

| Partition | Max time | Priority | Nodes |
|---|---|---|---|
| `instant` | 1 h | highest | all |
| `short` | 24 h | high | `romeo-c[001-039,101-104]`, `romeo-a[001-056]` |
| `long` | 30 days | low | `romeo-c[001-020,101-104]`, `romeo-a[001-040]` |

Leave out `--partition`: ROMEO puts the job in the partition that fits its `--time` (up to 1 h: `instant`, up to 24 h: `short`, beyond: `long`). Per user: 100 jobs, 1536 cores, 60 GPUs at once (`R 'sacctmgr show assoc where user=$USER'`); more by ticket.

## 4. Slurm

Four options are required or the job is refused:

| Option | Example | Meaning |
|---|---|---|
| `--account` | `r250127` | project charged |
| `--time` | `00:30:00`, `1-02:00:00` | wall time; the job is killed after it |
| `--mem` | `8G` | RAM **per node**; the job is killed above it |
| `--constraint` | `x64cpu` or `armgpu` | architecture |

Common others: `--nodes`, `--ntasks` / `--ntasks-per-node` (MPI processes), `--cpus-per-task` (threads), `--gpus-per-node` (armgpu, 1 to 4), `--gpus`, `--gpus-per-task`, `--job-name`, `--output=job.%j.out`, `--error=job.%j.err`, `--array`, `--dependency=afterok:<id>`, `--reservation`.

```bash
R 'squeue --me -o "%.10i %.9P %.30j %.2t %.10M %.10l %.5D %R"'   # ST: PD pending (reason at the end), R running
R 'scontrol show job <id>'                       # everything about a job still known to Slurm
R 'sacct -j <id> -P --format=JobID,JobName,State,ExitCode,Elapsed,ReqMem,MaxRSS,TotalCPU,NodeList'
R 'sstat -a -j <id> -P --format=JobID,MaxRSS,AveCPU'   # a running job
R '/apps/romeotools/getJobInfo.sh <id>'          # reserved vs used RAM and CPU of a finished job
R 'sinfo -s'                                     # nodes allocated/idle/other/total per partition
R 'sbatch --parsable job.sh'                     # prints only the job id
R 'scancel <id>'                                 # your own job ids only
```

Sizing the next job: `MaxRSS` is per step and per task (lines `.batch`, `.0`...: the job's own line is empty, so no `-X`), `ReqMem` is the total over all nodes. Memory is sampled every 10 s, so jobs or steps of a few seconds show `0` or nothing; for those, print the peak from the program (`getrusage` `ru_maxrss`, or `grep VmHWM /proc/self/status` at the end). `/usr/bin/time` is not installed on armgpu nodes.

## 5. Running something

The usual loop: copy the code, write a job script (templates in [references/jobs.md](references/jobs.md)), submit with `--parsable`, follow it, read `job.<id>.out` / `.err`, check `sacct`, copy the results back.

```bash
id=$(R 'cd ~/proj && sbatch --parsable job.sh') && echo "$id"
R "squeue -j $id -h -o '%T %R'"                  # empty once it ended
R "cd ~/proj && tail -n 50 job.$id.out job.$id.err; sacct -j $id -P --format=JobID,State,ExitCode,Elapsed,MaxRSS"
```

A short check without a script, from the login node (queues like any job, returns when done; `instant` usually starts within seconds):

```bash
R "srun --account=$ROMEO_PROJECT --time=00:10:00 --mem=16G --constraint=armgpu --gpus-per-node=1 --cpus-per-task=8 \
     bash -lc 'romeo_load_armgpu_env >/dev/null && nvidia-smi && cd ~/proj && make && ./test'"
```

This is also how to build and test aarch64 and CUDA code: the login nodes have no `nvcc` and no CUDA toolkit for x86_64, so compile in such a short armgpu `srun`, then run the real job. CUDA for the H100: `nvcc -O3 -arch=sm_90` (`CMAKE_CUDA_ARCHITECTURES=90`) after `spack load cuda@13.0.2`.

In job scripts, start with `set -euo pipefail`: otherwise a failed `spack load` lets the job go on with the system's Python 3.9 and GCC 11, and it "succeeds" with the wrong tools.

## 6. Software: Spack

No software, not even `spack`, exists before `romeo_load_x64cpu_env` or `romeo_load_armgpu_env`. Load exactly one, matching `--constraint`, in the same shell as the commands that use it; the login node can list both.

```bash
R 'romeo_load_armgpu_env >/dev/null; spack find --long cuda 2>/dev/null'   # versions with hashes
R 'romeo_load_x64cpu_env >/dev/null; spack find --variants --long openmpi'
```

On armgpu `spack find` prints `Warning: Missing dependency not in database` lines on stderr: harmless, hence `2>/dev/null`. `export SPACK_COLOR=never` removes colour codes.

- `spack load <name>@<version>` fails when several builds match (it prints them): load by hash `spack load /<hash>` or add `%compiler` / variants. Then check with `which` and `--version`.
- Python: one interpreter only. Load modules against a hashed Python: `spack load py-numpy ^python@3.11.9/<hash>`; or a venv/uv environment built **on the architecture that will run it**. PyTorch with CUDA on the GH200 (tested recipe, a job that builds the venv, ~5 GB): [references/software.md](references/software.md).
- `spack install <spec>` installs into `~/.spack/userspace-installed` (counts on the home quota); for aarch64, run it inside an armgpu job. `spack spec -t <spec>` shows what it would build.

What is installed, compilers, CUDA, MPI, Python, PyTorch, uv, Jupyter: [references/software.md](references/software.md).

## 7. Storage (GPFS, 2.8 PB, no backup)

| Path | Real path | For |
|---|---|---|
| `/home/$USER` | `/gpfs/home` | code, environments, results in progress |
| `/scratch_p/$USER` | `/gpfs/scratch` | data of running and queued jobs: the fastest |
| `/project/<id>` | `/gpfs/projet` | shared by a project's members, counted on the project's quota |
| `/apps` | | ROMEO's software, read only |

Quotas (space and number of files) are per user on home and scratch, per project on `/project`. They differ per account (documented default 15/20 GB soft/hard, many accounts have 100 GB): read them with `myquotas.sh`, never assume. Details, the group pitfall on `/project` and transfers: [references/storage.md](references/storage.md).

## 8. ROMEO's own tools (`/apps/romeotools`)

| Tool | Does |
|---|---|
| `myquotas.sh [--short]` | readable quota report, with the fix for files in `/project` owned by the wrong group |
| `getJobInfo.sh <id>[,<id>]` | reserved vs used RAM and CPU of finished jobs |
| `myjobs.v3.sh` | the user's jobs, drawn per node (cores and GPUs) |
| `runjupyter.sh` | JupyterLab in a job, with the tunnel command |
| `romeovisu.sh prepare\|start` | VNC visualisation session on `romeo2` |
| `romeollmtool` | LLMs (vLLM, SGLang, llama.cpp) as Slurm jobs behind an OpenAI-compatible gateway: what dsh-romeo uses |

## 9. When something fails

[references/troubleshooting.md](references/troubleshooting.md): pending reasons, `OUT_OF_MEMORY`, `Exec format error`, `Illegal instruction`, quota errors, Spack ambiguity, CUDA not found.

## 10. Official documentation

All pages: [references/docs.md](references/docs.md). The main ones: [ROMEO 2025](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/) · [Lancer un calcul](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/lancer_un_calcul) · [Fichier de soumission](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/ecrire_un_fichier_de_soumission) · [GPU](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/utiliser_des_gpu) · [Charger ses logiciels](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/charger_ses_logiciels) · [Stockage](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/espaces_de_stockage). Support tickets: https://romeo-ticket.univ-reims.fr/ (quota increase, software install, limits, account).
