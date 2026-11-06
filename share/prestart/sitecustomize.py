"""Clean-up before a dsh-romeo model job starts on a GH200 node, once per node and job.

dsh-romeo installs this file in ~/.dsh-romeo/prestart on ROMEO, and its fiches put that directory on
PYTHONPATH: the first Python of the job on each node (ray start, vllm serve) imports it.

- Page cache on the GPU memory: GH200 exposes each GPU's HBM as a NUMA node, and the kernel can leave
  the cache of model files read by an earlier job there, so vLLM finds 72-74 GiB free instead of 93
  and refuses to start (seen on ROMEO, 2026-11-06). POSIX_FADV_DONTNEED on the files named in
  DSH_ROMEO_EVICT (":"-separated directories, unreadable ones skipped) gives that memory back.
- NCCL shared-memory files of earlier jobs that were cancelled (/dev/shm/nccl-*, 34 MB each): ours
  only, older than 5 minutes (GPU nodes run one job at a time).
"""
import os
import time


def _prestart():
    job, roots = os.environ.get("SLURM_JOB_ID"), os.environ.get("DSH_ROMEO_EVICT", "")
    if not job or not roots:
        return
    try:  # once per node and job, whatever the number of Python processes
        os.close(os.open(f"/tmp/dsh-romeo-prestart-{os.getuid()}-{job}", os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
    except OSError:
        return
    uid, now = os.getuid(), time.time()
    try:
        for entry in os.scandir("/dev/shm"):
            st = entry.stat(follow_symlinks=False)
            if entry.name.startswith("nccl-") and st.st_uid == uid and now - st.st_mtime > 300:
                os.unlink(entry.path)
    except OSError:
        pass
    for root in roots.split(":"):
        for directory, _, files in os.walk(root):
            for name in files:
                try:
                    fd = os.open(os.path.join(directory, name), os.O_RDONLY)
                except OSError:
                    continue
                try:
                    os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
                except OSError:
                    pass
                finally:
                    os.close(fd)


try:
    _prestart()
except Exception:  # never stop the job for a clean-up
    pass
