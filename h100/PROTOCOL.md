# H100 / A100 telemetry protocol, registered before the run

Registered: 2026-09-16, before any instance was rented.

Hardware: 1x H100 80GB. 1x A100 as a second run if available the same day.
Sampling: dcgmi dmon, fields 203,1001,1002,1003,1004,1005,155, 1 Hz, GPU 0.

Order:
1. baseline_empty 120 s
2. control_proftester_tenso 60 s (dcgmproftester, field 1004, 45 s load)
3. Two repeats of: vllm_idle_loaded 300 s; vllm_rate_0.2 600 s; vllm_rate_2 600 s; vllm_saturated 600 s
4. Two repeats of: train_untuned 600 s; train_tuned 600 s
5. baseline_empty_end 120 s

Serving: vLLM, Qwen/Qwen2.5-7B-Instruct, max model length 4096, random prompts with 512 input and 256 output tokens, seed 42. Rate scenarios cap concurrency at 256; the saturated scenario uses request rate inf with concurrency 64.
Training: Qwen/Qwen2.5-0.5B on wikitext-2-raw-v1. untuned: per-step CPU tokenization, num_workers 0, fp32, padded to 512, batch 4. tuned: pre-tokenized packed 512-token blocks, num_workers 8, pinned memory, bf16 autocast, batch 16.
Analysis: per-window mean of each field after dropping 45 s at each end (summarize.py).
Publication: every row is published, including rows where GPUTL and SMACT agree. No scenario is dropped or selectively re-run. Deviations go in DEVIATIONS.md.
