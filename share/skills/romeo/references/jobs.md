# ROMEO: job scripts

Each command starts with `. ~/.agents/skills/romeo/scripts/env.sh` (SKILL.md, section 1), which defines `R`. Write the script on the machine you run on, copy it to ROMEO if needed, then `id=$(R 'cd ~/proj && sbatch --parsable job.sh')`. Replace `<project>` with the project code.

Every template starts with `set -euo pipefail` and checks what it loaded: an ambiguous `spack load` otherwise leaves the system's Python 3.9 and GCC 11 in place, and the job "succeeds" with the wrong tools. Output files land in the directory `sbatch` was run from (`$SLURM_SUBMIT_DIR`, e.g. `/gpfs/home/<user>/proj`).

## CPU (x64cpu, OpenMP threads)

```bash
#!/usr/bin/env bash
#SBATCH --account=<project>
#SBATCH --time=00:30:00
#SBATCH --mem=8G
#SBATCH --constraint=x64cpu
#SBATCH --nodes=1
#SBATCH --cpus-per-task=16
#SBATCH --job-name=cpu-job
#SBATCH --output=job.%j.out
#SBATCH --error=job.%j.err
set -euo pipefail

romeo_load_x64cpu_env
spack load /2celb2j                  # python@3.11.9: hashes from `spack find --long python`
which python3 && python3 --version

export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
work=/scratch_p/$USER/$SLURM_JOB_ID  # fast space for the job's data; if myquotas.sh says scratch is blocked,
                                     # use work=$SLURM_SUBMIT_DIR/run.$SLURM_JOB_ID (home) instead
mkdir -p "$work" && cp -r "$SLURM_SUBMIT_DIR"/{calcul.py,input.data} "$work"/ && cd "$work"
python3 calcul.py input.data
cp -r results "$SLURM_SUBMIT_DIR"/   # bring back what matters
```

## GPU (armgpu, one node, 4 H100)

```bash
#!/usr/bin/env bash
#SBATCH --account=<project>
#SBATCH --time=01:00:00
#SBATCH --mem=128G
#SBATCH --constraint=armgpu
#SBATCH --nodes=1
#SBATCH --gpus-per-node=4
#SBATCH --cpus-per-task=72           # 72 Grace cores per GH200: 72 x gpus is the whole share
#SBATCH --job-name=gpu-job
#SBATCH --output=job.%j.out
#SBATCH --error=job.%j.err
set -euo pipefail

romeo_load_armgpu_env
spack load /dvle736                  # cuda@13.0.2, only if you compile CUDA code
nvcc -O3 -arch=sm_90 vecadd.cu -o vecadd   # sm_90 = H100
nvidia-smi --query-gpu=index,name,memory.total --format=csv
spack load py-pip ^python@3.13.0/gzl2pkh   # the interpreter the venv was made with
source ~/envs/torch/bin/activate     # a venv made ON an armgpu node (software.md)
python train.py
```

Inside a job, only the allocated GPUs are visible (`CUDA_VISIBLE_DEVICES` is set by Slurm, ids 0 to 3).

Sizing per GPU: a node is 4 x (1 H100 96 GB, 72 Grace cores, ~200 GB RAM). Start from `--cpus-per-task=8` and `--mem=32G` per GPU for a first run (more cores for heavy DataLoaders), then size from what it used. Measured on a 21M-parameter MLP, batch 4096: 1.3 GB host RAM, one busy core, 2.2 GB on the GPU, 377k samples/s.

Measure GPU memory from inside the job, since Slurm does not record it:

```bash
nvidia-smi --query-gpu=timestamp,memory.used,utilization.gpu --format=csv -l 5 > gpu.$SLURM_JOB_ID.csv &
smi=$!
python train.py      # in PyTorch also print torch.cuda.max_memory_allocated() / max_memory_reserved()
kill $smi
```

`nvidia-smi` counts the CUDA context and the allocator cache, so it reads higher than `max_memory_allocated`.

## Several GPUs or nodes (torchrun)

```bash
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=4
#SBATCH --cpus-per-task=288
#SBATCH --mem=700G
...
head=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n1)
srun torchrun --nnodes="$SLURM_NNODES" --nproc-per-node=4 \
  --rdzv-backend=c10d --rdzv-endpoint="$head:29500" train.py
```

## MPI on x64cpu (OpenMPI)

```bash
#!/usr/bin/env bash
#SBATCH --account=<project>
#SBATCH --time=00:10:00
#SBATCH --mem=4G
#SBATCH --constraint=x64cpu
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=96
#SBATCH --cpus-per-task=2
#SBATCH --output=job.%j.out
#SBATCH --error=job.%j.err
set -euo pipefail

romeo_load_x64cpu_env
spack load openmpi@4.1.7 %aocc       # or %gcc; 5.0.5 also exists
mpicc -O2 hello.c -o hello
srun ./hello                         # srun, not mpirun: it reads the allocation
```

mpi4py: `spack load py-mpi4py ^python@3.8.19 ^openmpi@4.1.7 %aocc`, then `srun python3 calcul.py`.

## MPI on armgpu (NVHPC + HPC-X)

```bash
romeo_load_armgpu_env
spack load nvhpc@24.11               # or nvhpc@26.3; brings mpicc, nvc, nvfortran, CUDA
mpicc hello.c -o hello
srun ./hello
```

## Job arrays and chains

```bash
#SBATCH --array=0-19%5               # 20 tasks, at most 5 at once; $SLURM_ARRAY_TASK_ID = 0..19
#SBATCH --output=job.%A_%a.out       # %A array id, %a task id
```

```bash
a=$(R 'cd ~/proj && sbatch --parsable prepare.sh')
R "cd ~/proj && sbatch --parsable --dependency=afterok:$a compute.sh"
```

## Short jobs without a script (srun from the login node)

```bash
R "srun --account=$ROMEO_PROJECT --time=00:05:00 --mem=4G --constraint=x64cpu --cpus-per-task=4 hostname"
R "srun --account=$ROMEO_PROJECT --time=00:20:00 --mem=32G --constraint=armgpu --gpus-per-node=1 --cpus-per-task=16 \
     bash -lc 'romeo_load_armgpu_env >/dev/null && cd ~/proj && cmake -B build && cmake --build build -j16 && ./build/test'"
```

`srun` waits in the queue and streams the output; the `R` call returns when the job ends. Keep it under a few minutes, or the tool call may time out: use `sbatch` beyond that. `sbatch --wait job.sh` blocks until the job ends, for the same short jobs.

`salloc` + `srun --pty bash` (the doc's interactive jobs) is for a human at a terminal; an agent uses the forms above. If the user asks for one, give them the command to run.

## Useful variables in a job

`SLURM_JOB_ID`, `SLURM_SUBMIT_DIR`, `SLURM_JOB_NODELIST` (expand with `scontrol show hostnames`), `SLURM_NNODES`, `SLURM_NTASKS`, `SLURM_CPUS_PER_TASK`, `SLURM_ARRAY_TASK_ID`, `CUDA_VISIBLE_DEVICES`, `TMPDIR=/tmp` (small on armgpu nodes: prefer scratch or `/dev/shm`).

## Reading the result

```bash
R "sacct -j $id -P --format=JobID,State,ExitCode,Elapsed,ReqMem,MaxRSS,TotalCPU,AllocTRES"   # MaxRSS on the step lines
R "/apps/romeotools/getJobInfo.sh $id"     # RAM_USE and CPU_USE: lower --mem and cores next time if low
```

States: `COMPLETED`, `FAILED` (non-zero exit: read `.err`), `OUT_OF_MEMORY` (raise `--mem`), `TIMEOUT` (raise `--time` or checkpoint), `CANCELLED`, `NODE_FAIL` (resubmit).
