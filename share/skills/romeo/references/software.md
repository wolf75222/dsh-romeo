# ROMEO: software

## Spack basics

`romeo_load_x64cpu_env` or `romeo_load_armgpu_env` first, in the same shell. `export SPACK_COLOR=never` keeps escape codes out of the output.

```bash
spack find [--explicit] [<name>]       # installed (explicit: requested, not pulled in as dependencies)
spack find --long <name>               # with hashes, to load one build exactly: spack load /<hash>
spack find --variants <name>           # build options: +on ~off key=value
spack find --paths <name>              # install prefix
spack find --loaded                    # what this shell has loaded
spack find --loaded --long --deps | grep python@   # must show a single Python hash
spack load <spec> ; spack unload [<spec>]
spack list <word> ; spack info <name>  # installable packages, their versions and variants
spack spec -t <spec>                   # what an install would build: [+] installed, - to build
spack install <spec>                   # into ~/.spack/userspace-installed (home quota); spack clean afterwards
```

Specs: `name@version`, `%compiler@version`, `+variant ~variant key=value`, `^dependency@version/hash`. Example: `spack install curl@8.7.1 %aocc@4.2.0 +libssh`, `spack install zlib cflags=-O3 cxxflags=-O3`. ROMEO's builds are `-O2`. aarch64 installs run inside an armgpu job; installs for one architecture are only seen by `spack find` on that architecture. A package many users need: ask ROMEO by ticket.

On the login node, `romeo_load_armgpu_env` lists the ARM packages (`linux-rhel9-neoverse_v2`) and may also show `zen4` ones: on armgpu use only the `neoverse_v2` builds.

## Installed (2026-10-29; check with spack find, hashes change)

**x64cpu** (`linux-rhel9-zen4`)
- Compilers: `gcc@11.4.1` (system), `gcc@14.2.0`, `aocc@4.2.0`, `aocc@5.0.0` (AMD), `intel-oneapi-compilers@2024.0.2`, `llvm@17.0.6`, `pgi@18.10`.
- MPI: `openmpi@4.1.7`, `openmpi@5.0.5` (aocc and gcc builds), `intel-oneapi-mpi`; `py-mpi4py@4.0.1`.
- Python: 3.8.19 `zcpokjg`, 3.9.19 `2vmdaje`, 3.10.14 `p3ga5vd`, 3.11.9 `2celb2j`/`esusxhd`/`hlq244h`, 3.12.5 `sll2qkp`, 3.13.0 `wvvw4jo`/`wdxjcri`, 3.13.5 `vuonfl6`; `py-numpy` 1.24/1.26/2.1, `py-scipy`, `py-matplotlib`, `py-jupyterlab`, `py-pip@23.1.2`, `py-uv@0.4.27`, `anaconda3`, `miniconda3`.
- Also: `intel-oneapi-mkl`, `openblas`, `netcdf-c`, `metis`, `boost`, `cmake`, `gromacs`, `nwchem`, `psi4`, `molpro`, `xtb`, `meep`, `freefem`, `matlab`, `abaqus`, `lumerical`, `r`, `apptainer`, `linaro-forge` (debugger/profiler), `maqao`, `hpcviewer`, `nvidia-nsight-systems`, `vmd`, `gnuplot`, `git`, `git-lfs`.

**armgpu** (`linux-rhel9-neoverse_v2`)
- Compilers: `gcc@11.4.1` (system), `gcc@15.1.0`, `nvhpc@24.11` `flxzygw`, `nvhpc@26.3` `4wv5zzd` (nvc, nvc++, nvfortran, CUDA, HPC-X MPI).
- CUDA: 12.3.2 `kvg5az3`, 12.6.2 `3mzltpz`, 12.6.3 `uxlsycg`, 12.9.0 `iw66xwz`, 13.0.2 `dvle736`, 13.1.1 `jluyrr5` (driver 590, supports up to CUDA 13.1); cuDNN 8.9.5, 9.2.0, 9.17.0; `nccl@2.28.7-1`.
- MPI: `openmpi@4.1.7`, HPC-X through `nvhpc`; `py-mpi4py`.
- Python: 3.8.19 `raoq5bs`, 3.9.19 `74xrf37`, 3.10.14 `b6k3ajo`, 3.11.9 `a6m2qcc`/`oxq4fb7`, 3.12.5 `zrtbeqk`, 3.13.0 `rom3mjf`/`gzl2pkh`; `py-numpy`, `py-tensorflow`, `py-pip`, `py-uv@0.4.27`, `anaconda3`.
- Also: `gromacs`, `namd`, `autodock-gpu`, `apptainer`, `linaro-forge`, `hpctoolkit`, `nvidia-nsight-systems`, `maqao`, `ffmpeg`, `bazel`, `rust`, `npm`, `cmake`.

Compile CUDA for H100 with `-arch=sm_90` (`nvcc`, or `CMAKE_CUDA_ARCHITECTURES=90`).

## Python

Through Spack (the doc's main way): load modules against one hashed interpreter.

```bash
romeo_load_x64cpu_env
spack find --variants --long py-numpy ^python@3.8.19
spack load py-numpy ^python@3.8.19/zcpokjg
```

A venv, built on the architecture that will run it (an x86_64 venv does not run on armgpu):

```bash
romeo_load_armgpu_env
spack load py-pip ^python@3.13.0/gzl2pkh
python -m venv ~/envs/myenv && source ~/envs/myenv/bin/activate
python -m pip install --upgrade pip --index-url https://pypi.org/simple
python -m pip install numpy matplotlib
```

In a job: `romeo_load_<arch>_env`, the same `spack load py-pip ^python@.../<hash>`, then `source ~/envs/myenv/bin/activate`.

uv (fast, used by ROMEO's Jupyter doc): `spack load py-uv`, `uv init --python 3.13 myproj`, `cd myproj && uv add jupyterlab`, `uv run ...`. Do not name a project like a package (not `jupyterlab`).

## PyTorch on armgpu

Tested 2026-10-29: the `cu130` index installs `torch 2.15.0+cu132`, `torch.cuda.is_available()` True on `NVIDIA GH200 120GB` (ROMEO's doc shows 2.14.1+cu130; pin `torch==2.14.1` to get that one). The venv takes about **5.3 GB and many thousand files**: check the home quota first, and put it where the user wants to keep it (default `~/envs/<name>`, a durable place, not a task's scratch directory). Installing takes about 2 minutes.

Build it in a job on an armgpu node (an x86_64 venv does not run there). A batch job avoids a tool-call timeout:

```bash
#!/usr/bin/env bash
#SBATCH --account=<project>
#SBATCH --time=00:20:00
#SBATCH --mem=16G
#SBATCH --constraint=armgpu
#SBATCH --gpus-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --job-name=torch-env
#SBATCH --output=env.%j.out
set -euo pipefail
romeo_load_armgpu_env
spack load py-pip ^python@3.13.0/gzl2pkh
python -m venv ~/envs/torch
source ~/envs/torch/bin/activate
python -m pip install --upgrade pip setuptools wheel --index-url https://pypi.org/simple
python -m pip install torch torchvision torchaudio numpy \
  --index-url https://download.pytorch.org/whl/cu130 --extra-index-url https://pypi.org/simple
python -c 'import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0))'
```

To use it in a job: `romeo_load_armgpu_env`, `spack load py-pip ^python@3.13.0/gzl2pkh` (the interpreter the venv was made with: its `bin/python` points there), then `source ~/envs/torch/bin/activate`. After `spack load py-pip`, `which python` shows a `python-venv-...` wrapper from Spack, not the hashed Python itself: normal. Once the venv is active, `which python` must show `~/envs/torch/bin/python`. Pip's "A new release of pip is available" notice can be ignored.

The wheel brings its own CUDA runtime: no `spack load cuda` needed, only the driver. Without `numpy` in the list torch warns `Failed to initialize NumPy`. With uv: `uv add torch torchvision torchaudio numpy --index https://download.pytorch.org/whl/cu130 --index-strategy unsafe-best-match`. An `flit_core` resolution error means pip is too old: upgrade it from PyPI first.

## JupyterLab

`/apps/romeotools/runjupyter.sh` does it all. By hand: a job runs `uv run jupyter-lab --no-browser --port=2345 --ip=0.0.0.0`; `squeue --me` gives its node; on the user's computer `ssh -N -L 8888:<node>:2345 romeo`, then http://localhost:8888 with the token from the job's log. `scancel` the job afterwards.

## Containers

`apptainer` exists in both environments (`spack load apptainer`). Pull or build images for the right architecture (`linux/arm64` on armgpu); `--nv` gives a container the GPUs.

## Licensed software

Gaussian 16 (x64cpu only, on request by ticket): `export g16root=/apps/2025/manual_install/gaussian/; source $g16root/g16/bsd/g16.profile`, `GAUSS_SCRDIR=/scratch_p/$USER/Gaussian/$SLURM_JOB_ID`. Matlab, Abaqus, Molpro, Lumerical are in Spack; their use may depend on licences: ask the user.
