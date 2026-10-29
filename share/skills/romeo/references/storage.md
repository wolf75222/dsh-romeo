# ROMEO: storage and transfers

GPFS, 2.8 PB, one fast system for everything (flash tier for scratch). Data is replicated against hardware failure but **not backed up**: a deletion is immediate and final, snapshots are not available yet. The doc suggests URCA's SSDS virtual NAS for backups.

| Space | Path | Quota on | Use |
|---|---|---|---|
| `/apps` | | | ROMEO's software, read only |
| `/home/<user>` | `/gpfs/home/<user>` | the user | working data not in use by jobs; not long-term |
| `/scratch_p/<user>` | `/gpfs/scratch/<user>` | the user | data of running and queued jobs; newest data on flash, older moved to disk transparently |
| `/project/<id>` | `/gpfs/projet/<id>` | the project group | data shared by a project's members (exists if the project asked for it) |

Default quotas: home and scratch 15 GB soft / 20 GB hard per user, `/project` 15 / 20 GB per project, plus about 1 M files soft / 1.5 M hard; many accounts have more. Above the soft limit writes still work for a 7-day grace period; after it, the soft limit blocks writes (`Disk quota exceeded`) until usage drops below it. The number of files counts too: a Python environment or a dataset of small files can block a space with gigabytes free.

```bash
R '/apps/romeotools/myquotas.sh --no-color'          # readable report: used, left, grace, fixes
R '/apps/romeotools/myquotas.sh --short --no-color'  # one line per problem; exit 0 ok, 1 grace, 2 blocked
R 'mmlsquota --block-size auto gpfs'                 # raw GPFS view
R 'mmlsquota --block-size auto -g <project> gpfs'    # a project's quota
R 'du -sh ~/* 2>/dev/null | sort -h | tail; find /scratch_p/$USER -xdev -type f | wc -l'   # what takes the room
```

When a space is blocked, show the user what takes the room and let them choose what to delete or archive; a ticket can raise a quota (say user/project, space, amount, why).

## The `/project` group pitfall

Files in `/project/<id>` must belong to the project's group: the directories are setgid, so new files inherit it. Copies that keep the original group (`cp -a`, `rsync -a` with `-g`, `tar -p`) attach them to the user's personal group, whose quota there is almost zero: writes fail although the project has room. Fix:

```bash
chgrp -R <project> /project/<project>/<dir>
find /project/<project>/<dir> -type d -exec chmod g+s {} +
```

To copy into `/project` without the problem: `rsync -rlt` (no `-g`/`-p`), or `rsync -a --no-g --no-p`. `myquotas.sh` lists the misattached files.

## Transfers between the user's computer and ROMEO

Over SSH to a login node (`romeo1..4.univ-reims.fr`, the `romeo` alias): rsync, scp, sftp; FileZilla or WinSCP for humans (SFTP, key file). From an agent on the user's computer:

```bash
. ~/.agents/skills/romeo/scripts/env.sh                # R, RSYNC_SSH, ROMEO_SSH_HOST
u=$(R 'echo $USER')                                    # the ROMEO login, often not the local one
rsync -az -e "$RSYNC_SSH" ./data/ "$ROMEO_SSH_HOST":/scratch_p/$u/data/
rsync -az -e "$RSYNC_SSH" "$ROMEO_SSH_HOST":proj/results/ ./results/
rsync -az --exclude .git --exclude .venv --exclude __pycache__ -e "$RSYNC_SSH" ./proj/ "$ROMEO_SSH_HOST":proj/
```

A remote path without a leading `/` is relative to the ROMEO home; recent rsync does not expand `~` or `$USER` in remote paths, so write them out. Compute nodes have internet access, so a job can also `git clone`, `pip install` or download a dataset itself, straight into scratch.

Data from the old ROMEO 2018: copied by ROMEO's team on request (ticket).
