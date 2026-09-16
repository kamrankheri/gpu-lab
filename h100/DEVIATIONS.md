# Deviations and run notes, H100 run 2026-09-16

Run directory: runs/telemetry-20260916T183702Z, started 2026-09-16T18:37:02Z. All 15 registered windows completed with the full registered sample count.

Recorded environment (env-*.txt): 1x NVIDIA H100 80GB (DCGM reports "NVIDIA H100 80GB HBM3") on Lambda, Ubuntu 22.04.5, DCGM 4.7.0, vLLM 0.29.0, torch 2.13.0, transformers 5.17.0.

No deviation from the registered hardware class, workload, order, sampling or analysis. Notes:
1. Models and dataset were downloaded before the run, and Hugging Face offline mode (HF_HUB_OFFLINE=1, HF_DATASETS_OFFLINE=1) was set for the run. No workload change.
2. vllm bench serve 0.29.0 no longer forces temperature 0, so the server default applied. --ignore-eos fixes every response at 256 output tokens, so generated-token load is unaffected.
3. Each benchmark ends by timeout at its registered window length, so no benchmark summary block is written. Completed-request counts come from the last progress line in each .stdout file.
4. transformers 5.17 logs a deprecation warning for torch_dtype. The registered train.py ran unchanged.
5. No A100 run was performed.
6. GPU UUID, serial number, board part number, module ID, instance IP and hostname were redacted from the published files after the run.
7. Throughput comparisons (completed requests per window, training tokens per second) are post-hoc. They are not part of the registered DCGM analysis and are labeled post-hoc wherever published.
