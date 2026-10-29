# ROMEO: official documentation

In French. Read a page with a web fetch when a detail is missing here; the pages change, this skill was written from them on 2026-10-29.

| Page | Covers |
|---|---|
| [ROMEO 2025, index](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/) | entry point |
| [Se connecter](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/se_connecter) | login nodes romeo1..4, ssh config |
| [Clés SSH](https://romeo.univ-reims.fr/documentation/ressources/connexion_ssh) | ed25519 keys, adding them on the portal, linking them to the machine, valid account checklist |
| [Lancer un calcul](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/lancer_un_calcul) | Slurm commands, required options, partitions, limits, interactive jobs |
| [Écrire un fichier de soumission](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/ecrire_un_fichier_de_soumission) | job scripts: x64cpu, armgpu, OpenMPI |
| [Utiliser des GPU](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/utiliser_des_gpu) | `--gpus-per-node`, `CUDA_VISIBLE_DEVICES`, CUDA |
| [Utiliser OpenMPI](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/utiliser_openmpi) | OpenMPI on x64cpu, NVHPC/HPC-X on armgpu, `srun` |
| [Charger ses logiciels](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/charger_ses_logiciels) | the two environments, `spack find`, `spack load`, hashes |
| [Installer un logiciel](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/installer_un_logiciel) | `spack list/info/spec/install`, compilers, variants, flags |
| [Utiliser Python](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/utiliser_python) | Python through Spack, venvs |
| [PyTorch sur ARM](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/Logiciels/pytorch-romeo-arm) | PyTorch CUDA 13 on GH200, step by step |
| [Logiciels x86_64](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/Logiciels/Architecture%20x86_64) · [aarch64](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/Logiciels/Architecture%20Aarch64) | software notes per architecture (Gaussian 16) |
| [JupyterLab](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/7.1.utiliser_jupyterlab) | Jupyter in a job, SSH tunnel |
| [Session de visualisation](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/utiliser_une_session_de_visu) | VNC on romeo2 (`romeovisu.sh`) |
| [Espaces de stockage](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/espaces_de_stockage) | home, scratch_p, project, quotas, grace, group pitfall |
| [Transférer ses données](https://romeo.univ-reims.fr/documentation/ressources/romeo_2025/transferer_donn%C3%A9es) | WinSCP, FileZilla, data from ROMEO 2018 |
| [Description matérielle](https://romeo.univ-reims.fr/documentation/ressources/description_mat%C3%A9rielle_des_ressources) | hardware of ROMEO 2025 and of the Juliet cluster (8 x A100) |
| [Création de compte](https://romeo.univ-reims.fr/documentation/creation_compte) · [Charte](https://romeo.univ-reims.fr/documentation/2.5.charte) · [Cybersécurité](https://romeo.univ-reims.fr/documentation/bonnes_pratiques_cybersecurite) | account, rules of use |

Other links: [portal](https://romeo.univ-reims.fr/portal) (projects, keys, hours) · [support tickets](https://romeo-ticket.univ-reims.fr/) · [maintenance](https://romeo.univ-reims.fr/maintenance) · [Slurm 23.11 manual](https://slurm.schedmd.com/archive/slurm-23.11.6/man_index.html) · [Spack](https://spack.readthedocs.io) · contact romeo@univ-reims.fr.
