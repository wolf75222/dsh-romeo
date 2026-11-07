# dsh-romeo-status

dsh-romeo's model jobs on ROMEO, inside dsh: a badge beside the input box when something needs you.
For example, a model is loading or waiting for GPUs, a job ends in under 30 minutes (and whether the
next one is coming), a job is gone, or the jobs stop within 10 minutes for lack of requests. Nothing
shows when all is well. It reads `~/.config/dsh-romeo/status.json`, which dsh-romeo writes at each
start. It asks ROMEO at most every 20 s, over dsh-romeo's own SSH connection. Installed and turned on
by dsh-romeo's `install.sh`. MIT.
