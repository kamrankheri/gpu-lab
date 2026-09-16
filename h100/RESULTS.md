# H100 telemetry results, 2026-09-16

Run directory: [`runs/telemetry-20260916T183702Z`](runs/telemetry-20260916T183702Z).
Protocol registered before the run: [`PROTOCOL.md`](PROTOCOL.md). Run notes and
deviations: [`DEVIATIONS.md`](DEVIATIONS.md).

## Registered analysis

The table below is `summary.md` from the run directory, produced by
`summarize.py`, copied without change. Each value is the mean of 1 Hz
`dcgmi dmon` samples over the window after dropping 45 s at each end.

| Scenario | Samples kept | GPUTL % | GRACT % | SMACT % | SMOCC % | TENSO % | DRAMA % | Power W | GPUTL / SMACT |
|---|---|---|---|---|---|---|---|---|---|
| baseline_empty | 30 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 72 | N/A |
| control_proftester_tenso | 60 | 75.9 | 75.7 | 67.8 | 12.4 | 67.1 | 22.6 | 564 | 1.1x |
| r1_vllm_idle_loaded | 210 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 116 | N/A |
| r1_vllm_rate_0.2 | 510 | 26.7 | 27.5 | 17.9 | 2.5 | 0.6 | 18.6 | 203 | 1.5x |
| r1_vllm_rate_2 | 510 | 96.0 | 96.4 | 64.3 | 9.3 | 3.2 | 64.7 | 434 | 1.5x |
| r1_vllm_saturated | 510 | 85.9 | 85.6 | 70.0 | 12.1 | 24.6 | 50.8 | 550 | 1.2x |
| r2_vllm_idle_loaded | 210 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 117 | N/A |
| r2_vllm_rate_0.2 | 510 | 27.9 | 27.5 | 17.9 | 2.5 | 0.6 | 18.7 | 204 | 1.6x |
| r2_vllm_rate_2 | 510 | 96.4 | 96.4 | 64.3 | 9.3 | 3.1 | 64.7 | 432 | 1.5x |
| r2_vllm_saturated | 510 | 85.9 | 85.8 | 70.1 | 12.1 | 24.7 | 50.8 | 548 | 1.2x |
| r1_train_untuned | 510 | 99.5 | 99.5 | 90.0 | 22.6 | 1.5 | 18.9 | 577 | 1.1x |
| r1_train_tuned | 510 | 99.3 | 99.4 | 87.6 | 54.3 | 19.1 | 58.8 | 597 | 1.1x |
| r2_train_untuned | 510 | 99.5 | 99.5 | 90.0 | 22.6 | 1.5 | 18.9 | 577 | 1.1x |
| r2_train_tuned | 510 | 99.3 | 99.4 | 87.5 | 54.2 | 19.1 | 58.8 | 596 | 1.1x |
| baseline_empty_end | 30 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 72 | N/A |

The two saturated rows include 72 idle samples each, because the benchmark
client generated its prompts inside the sampling window and traffic started at
second 117 (DEVIATIONS.md note 8). The rows are published as registered.

What the registered rows show:

- Across the vLLM load windows and the training windows, GPUTL is 1.1x to 1.6x
  SMACT.
- A loaded vLLM server with no traffic reads 0.0 on every utilization field at
  116 W (r1) and 117 W (r2).
- The two repeats agree within 1.2 points on every percentage field and within
  2 W on power.

## Post-hoc measures

Nothing in this section was registered. It was decided after the run and is
computed by [`posthoc.py`](posthoc.py) from the same run directory.

### Training throughput

From the JSON line each training run prints at the end of its window. A token
slot is one position in a batch (steps x batch size x 512); the untuned
configuration pads every sequence to 512, so most of its slots are padding.

| Scenario | Registered GPUTL % | Registered SMACT % | Registered TENSO % | Registered Power W | Real tokens/s | Token slots/s |
|---|---|---|---|---|---|---|
| r1_train_untuned | 99.5 | 90.0 | 1.5 | 577 | 2,275.7 | 11,107 |
| r1_train_tuned | 99.3 | 87.6 | 19.1 | 597 | 60,527.6 | 60,529 |
| r2_train_untuned | 99.5 | 90.0 | 1.5 | 577 | 2,275.3 | 11,103 |
| r2_train_tuned | 99.3 | 87.5 | 19.1 | 596 | 60,471.0 | 60,474 |

In r1 the tuned configuration processed 26.6x as many real tokens per second as
the untuned one, and 5.4x as many token slots per second, while GPUTL read 99.3
against 99.5 and SMACT 87.6 against 90.0. Neither field separates the two
configurations. TENSO does differ (1.5 against 19.1), but the untuned run is
fp32 and the tuned run is bf16, and tensor pipe activity follows numeric
precision, so TENSO is not a work meter either.

### Inference, measured from load start

Method, applied to all six vLLM load windows: load start is the first sample
with GPUTL above 0 after the window's first idle sample. Means cover load start
through the end of the window minus 45 s. Request rate is completed requests
(last progress line in the `.stdout`) divided by seconds from load start to the
end of the 600 s window. Every response is 256 output tokens (`--ignore-eos`).

| Scenario | Load start s | Load s | Completed | Req/s | GPUTL % | SMACT % | TENSO % | Power W | GPUTL / SMACT |
|---|---|---|---|---|---|---|---|---|---|
| r1_vllm_rate_0.2 | 10 | 590 | 118 | 0.20 | 26.6 | 17.7 | 0.6 | 202 | 1.50x |
| r1_vllm_rate_2 | 11 | 589 | 1,184 | 2.01 | 96.2 | 64.3 | 3.1 | 433 | 1.50x |
| r1_vllm_saturated | 117 | 483 | 12,103 | 25.06 | 100.0 | 81.5 | 28.7 | 621 | 1.23x |
| r2_vllm_rate_0.2 | 10 | 590 | 118 | 0.20 | 27.7 | 17.7 | 0.6 | 204 | 1.56x |
| r2_vllm_rate_2 | 11 | 589 | 1,184 | 2.01 | 96.6 | 64.3 | 3.1 | 432 | 1.50x |
| r2_vllm_saturated | 117 | 483 | 12,156 | 25.17 | 100.0 | 81.7 | 28.7 | 620 | 1.22x |

Check on the method: for the rate_0.2 and rate_2 windows, where traffic started
before the 45 s trim, the load-start means are within 0.2 points of the
registered GPUTL and SMACT.

In r1, GPUTL reads 96.0 at 2 req/s (registered) and 100.0 from load start at
saturation, with SMACT 81.5. The completed request rates are 2.01 req/s over
589 s and 25.06 req/s over 483 s, 12.5x apart. At 0.2 req/s (118 requests over
590 s) the GPU completed requests at 0.8% of the saturated rate while GPUTL read
26.7 (registered), 27% of the saturated load-start reading. The saturated
GPUTL/SMACT ratio from load start is 1.23x in r1 and 1.22x in r2, inside the
registered 1.1x to 1.6x range.

## Limits

One H100 80GB (DCGM reports "NVIDIA H100 80GB HBM3") on Lambda. One serving
model, Qwen2.5-7B-Instruct, with synthetic random prompts. One training model,
Qwen2.5-0.5B, on wikitext-2. The untuned training configuration was constructed
for this test (fp32, padding to 512, batch 4, per-step CPU tokenization), and no
claim is made about how common it is. Single GPU, no multi-GPU traffic.

The 2026-09-04 Tesla T4 measurement in the repository README used a tiny
repeated kernel and does not generalize to these loads.
