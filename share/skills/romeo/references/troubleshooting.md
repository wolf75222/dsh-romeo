# ROMEO: when something fails

| Symptom | Cause | Fix |
|---|---|---|
| `sbatch: error: ... account` / `Invalid account` | no or wrong `--account` | a code from `sacctmgr -n -P show assoc user=$USER format=account` |
| job refused, asks for memory or constraint | one of the 4 required options missing | `--account --time --mem --constraint` |
| `PD (Priority)` / `(Resources)` | waiting for its turn or for free nodes | wait; shorter `--time`, fewer nodes/GPUs, or `instant` (1 h) start sooner. `sinfo -s` shows free nodes |
| `PD (PartitionTimeLimit)` | `--time` above the partition's max | lower `--time` or drop `--partition` |
| `PD (QOSMaxGRESPerUser)`, `(QOSMaxCpuPerUserLimit)`, `(AssocGrpGRES)` | user limit reached (60 GPUs, 1536 cores, 100 jobs) | wait for own jobs to end; a ticket raises limits |
| `PD (ReqNodeNotAvail, Reserved for maintenance)` | maintenance ahead | shorter `--time`, or wait (https://romeo.univ-reims.fr/maintenance) |
| `OUT_OF_MEMORY`, `oom-kill` in `.err` | above `--mem` (per node) | raise `--mem`; `getJobInfo.sh` shows the peak |
| `TIMEOUT`, `DUE TO TIME LIMIT` | above `--time` | raise it, or checkpoint and chain jobs |
| `Exec format error`, `cannot execute binary file` | binary built for the other architecture | rebuild on the architecture that runs it (aarch64: in an armgpu job) |
| `Illegal instruction` | built with `-march=native` on another CPU | rebuild on the target node type |
| `romeo_load_..._env: command not found` | not a login shell (`bash -c` instead of `bash -lc`, or `ssh host 'sh ...'`) | `bash -lc '...'`, or the job's `#!/usr/bin/env bash` |
| `spack: command not found` | environment not loaded in this shell | `romeo_load_<arch>_env` first |
| `Error: <pkg> matches multiple packages` | ambiguous `spack load` | load by hash (`spack find --long <pkg>`, `spack load /<hash>`) or add `%compiler`/variants |
| job used `/usr/bin/python3` (3.9) | `spack load` failed and the script went on | `set -euo pipefail`, then `which python3` |
| two Pythons loaded, odd import errors | modules from different interpreters | `spack unload`, reload against one `^python@x/<hash>` |
| `Disk quota exceeded` | space or file count over the limit (grace expired) | `myquotas.sh`; tell the user, do not delete their data |
| writes refused in `/project` though it has room | files owned by the personal group | storage.md, the group pitfall |
| `CUDA error: no CUDA-capable device` / `torch.cuda.is_available()` False | no `--gpus-per-node`, x64cpu node, or x86_64 wheel/venv | armgpu + `--gpus-per-node`, venv built on armgpu |
| `nvcc: command not found` | CUDA toolkit not loaded | `spack load cuda@13.0.2` (armgpu) |
| `srun: error: ... Unable to create step` inside sbatch | step asks more than the allocation | match `srun -n/-c` to the job's `--ntasks/--cpus-per-task` |
| MPI runs N copies of rank 0 / no communication | `mpirun` or plain `./prog` instead of `srun` | `srun ./prog` |
| `Permission denied (publickey)` | key not deployed or not linked to a project | ROMEO portal: My keys, then "gérer mes clés sur cette machine"; deployment takes up to an hour |
| ssh `WARNING: connection is not using a post-quantum key exchange` | informational, from the local OpenSSH | ignore (`-o LogLevel=ERROR` hides it) |

Still stuck: open a ticket at https://romeo-ticket.univ-reims.fr/ with the job id, the script and the `.err` file (draft it for the user; they send it).
