# Tuning

[README](../README.md) · [Usage](usage.md) · [Other clients](clients.md) · **Tuning** · [How it works](how-it-works.md) · [Troubleshooting](troubleshooting.md) · [Changes](changes.md) · [Development](development.md)

What an A/B study on ROMEO (October 2026, up to 7 jobs and 3584 concurrent requests) kept, and where it is:

| | | Where |
|---|---|---|
| Tensor parallelism over 8 GH200 on 2 nodes, no pipeline parallelism | without patches that `romeollmtool` cannot load, the pipeline variants of V4.1 on vLLM 0.31 garble long agent contexts (12 to 18 sessions out of 24) | fiche |
| `--gpu-memory-utilization 0.88` (was 0.82), FlashInfer's JIT cache on the node's `/tmp` | 9.09M tokens of KV cache instead of 6.19M (+47 %), same speed; 0.82 dated from mid-October starts with 77-80 GiB free, none since | fiche |
| vLLM 0.33.0, its Humming MoE kernels compiled into each node's own `/tmp` | +19 % per agent alone, +22 % at 16 agents, +34 % at 64 (2249 against 1505 tok/s in all), half the time to first token at 64, 6.66M tokens of KV cache instead of 6.21M, against 0.31 measured at the same time (2026-11-06) | fiche |
| DSpark draft tokens drawn from the draft's distribution (`draft_sample_method: probabilistic`), still exact rejection | +26 to +36 % per agent at 4 agents, +15 to +19 % at 16, +12 to +19 % at 64, two runs against greedy on 0.33 (2026-11-06); 4 % less KV cache | fiche |
| DSpark speculative decoding, 2 draft tokens with the 1017 weights (3 with September's); 32 CPUs per node; `--stream-interval 4` | +61 % per agent at 16 agents per job and +70 % at 64, against 5 draft tokens and 8 CPUs; on 1017, k=2 beats k=3 by 3 to 9 % and k=4 loses up to 21 % | fiche |
| Full 1M context, 256K output, images on (the vision encoder served) | the context the model was trained for; images read correctly on the production fiche (2026-11-06) | fiche |
| DeepSeek's sampling (temperature 1.0, top_p 0.95), maximum reasoning by default | `DSH_ROMEO_EFFORT` to change it | fiche, launcher |
| Several jobs behind one gateway | `dsh-romeo --launch N` | launcher |
| Fast gateway: no 100-stream cap, session affinity across jobs, longer timeouts, 4 processes | 3584 of 3584 concurrent requests served (the standard gateway: 502 errors beyond about 100 streams); -20 to -28 % wall time and -59 % time to first token late in multi-turn sessions with several jobs | `DSH_ROMEO_GATEWAY=fast` |

With all of them, fast gateway included, 7 jobs served about 530 agents at once at 30 tokens/s each (235 multi-turn agents), against 165 for the first setup.

Tried on the 1017 weights (2026-10-28) and left out: data parallelism over 2 x TP4 with expert parallelism (+28 % on 128 independent requests, but -23 % output and 3x the late time to first token on 42 multi-turn agent sessions, since each data-parallel rank has its own prefix cache), `--max-num-batched-tokens` 16K or 32K (+3 %, half the KV cache), vLLM 0.32.0 (its humming kernels fail to compile on SM90). On 0.33 (2026-11-06): DSpark's official recipe (k=5, probabilistic draft, block verification, adaptive) gives +7 to +11 % up to 16 agents and +2 % at 64, but halves the KV cache (3.36M): its adaptive verification needs 16 GiB more per GPU (also alone, at k=3 or k=5). Block verification at k=5 loses from 16 agents on. Also left out on 0.33 at 0.88 (2026-11-06, two or three runs each): 4 NCCL queue pairs per InfiniBand connection (+5 to +7 % up to 4 agents, nothing at 16-64, 10 % less KV cache), `--async-scheduling` (nothing at 16-64), `--max-num-batched-tokens 16384` (20 % faster first token, same tok/s per agent, 30 % less KV cache: the KV cache holds the prefix cache of long dsh sessions).

The fiche is [share/fiches/dsh-deepseek-v4.1-flash-1017-1m.yaml](../share/fiches/dsh-deepseek-v4.1-flash-1017-1m.yaml).

## Kimi-K3.1-Pro

`dsh-romeo --models kimi` (or `kimi+deepseek`) serves Kimi-K3.1-Pro instead (experimental): 1.56 TB of MXFP4 weights on 8 nodes (32 GH200, one replica within the 60-GPU account limit), 1M context, 10.96M tokens of KV cache (10 full 1M contexts; Kimi serves 6-8 agents at once). No vLLM release has K3.1 yet ([vllm-project/vllm#65685](https://github.com/vllm-project/vllm/pull/65685)): the fiche points to a personal engine (`engine_dir:`) and to weights on project `r260105`; other projects stage their own and change the fiche's `/project/r260105/rmdraux` paths (weights, engine, caches, `TMPDIR`).

It starts from the Kimi K3 measurements (October 2026): TP8 x PP4, DCP8, `--no-async-scheduling`, fastsafetensors, Marlin for the MXFP4 experts, `--gpu-memory-utilization 0.78`. An A/B on ROMEO (2026-11-04) added breakable CUDA graphs: K3.1 has no compiled submodule, so without them every mixed step runs eager (+4 to +11 % per agent). Since 2026-11-06 the engine carries vllm-project/vllm#53948, ported (`vllm-k31-pp`), and runs with async scheduling: +14 % for one agent, +35 to +38 % per agent at 16 agents, +48 % for 9 agents at 128K, in two runs; without the patch async scheduling collapses from 4 agents. Then DCP4 with all-to-all exchanges (`--dcp-comm-backend a2a --dcp-q-replicate`) instead of DCP8 keeps each request's KV exchanges inside a node: +10 % for one agent, +47 % at 4 agents, +60 % at 9, +48 % for 9 agents at 128K, in two runs, for half the KV cache.

| Agents (16K prompts) | 1 | 4 | 9 | 16 |
|---|---|---|---|---|
| tok/s per agent, 2026-11-04 | 30.5 | 15.4 | 12.0 | 9.4 |
| tok/s per agent, now | 38.0-38.6 | 23.1-23.8 | 28.4-29.4 | 22-23 |

9 agents on 128K prompts: 14.0-14.7 tok/s each (6.4 before). One agent at 800K tokens: 37 tok/s. Images read correctly on the production fiche. Left out: 16K prefill chunks (-28 to -39 % per agent from 4 agents), DSpark (no Hopper backend runs its draft under DCP; without DCP, 804K tokens of KV cache in all), and on the current engine (2026-11-06): CUDA graphs up to 8192 tokens (same speed, 16 % less KV cache), `--max-num-seqs 8` (19 % slower for 9 agents at 128K), 4 NCCL queue pairs (within the noise), DCP2 (same speed as DCP4, half the KV cache), TP4 x PP8 (-23 to -52 % from 4 agents), Humming (no change). The model starts in about 12 min, 6 of them reading the weights.

## The fast gateway

`DSH_ROMEO_GATEWAY=fast` starts a second, unmanaged gateway on the login node ([share/gateway](../share/gateway)): `romeollmtool`'s own gateway with a patch loaded at start, the same key and the same jobs, 4 processes sharing the port, 8 hours of life, stopped by `dsh-romeo --stop`. If it cannot start (for example after an update of `romeollmtool`), dsh-romeo says so and uses the standard gateway.

Use it for more than 100 agents at once, or with several jobs (the affinity keeps a session on the job that holds its cache). One job and a few agents do not need it.

## Left out on purpose

- The pipeline-parallel variant with DSpark: more throughput only at saturation, and it needs vLLM patches that `romeollmtool` cannot load.
- Token savers that rewrite the agent's instructions (Caveman, Ponytail): they change how the agent works, so they are a choice for your own `AGENTS.md`.
