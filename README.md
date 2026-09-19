# GPU telemetry lab

Measurements of what `DCGM_FI_DEV_GPU_UTIL`, the metric on almost every default
GPU dashboard, does and does not tell you about the work a GPU is doing.

The current record is the H100 run of 2026-09-16 in [`h100/`](h100), published
at [nameplateanalytics.com/method](https://nameplateanalytics.com/method). The
first measurement, a Tesla T4 run of 2026-09-04, is kept below with its raw log
and the lab that produced it.

---

## H100 run, 2026-09-16

Protocol registered before the run in [`h100/PROTOCOL.md`](h100/PROTOCOL.md).
Registered table, post-hoc throughput and limits in
[`h100/RESULTS.md`](h100/RESULTS.md). Raw `dcgmi dmon` logs, benchmark and
training output, and environment captures in
[`h100/runs/telemetry-20260916T183702Z`](h100/runs/telemetry-20260916T183702Z).
Deviations in [`h100/DEVIATIONS.md`](h100/DEVIATIONS.md).

Two training configurations of the same model read the same utilization and did
very different amounts of work (registered DCGM means, post-hoc throughput):

| Configuration | GPUTL | SMACT | Power | Real tokens/s | Token slots/s |
|---|---|---|---|---|---|
| untuned: fp32, padded to 512, batch 4, per-step CPU tokenization | 99.5% | 90.0% | 577 W | 2,275.7 | 11,107 |
| tuned: bf16, packed 512-token blocks, batch 16, 8 loader workers | 99.3% | 87.6% | 597 W | 60,527.6 | 60,529 |

The tuned run processed 26.6x the real tokens per second (5.4x per token slot).
Neither GPUTL nor SMACT separates them. On the vLLM serving and training loads,
GPUTL ran 1.1x to 1.6x SMACT. A loaded but idle vLLM server read 0 on every
utilization field at 116 W, so idle is visible without the profiling fields.
The two repeats agree within 1.2 points on every percentage field and 2 W on
power.

Limits: one H100 80GB (DCGM reports H100 80GB HBM3) on Lambda. One serving
model (Qwen2.5-7B-Instruct) with synthetic random prompts. One 0.5B training
model on wikitext-2. The untuned configuration was constructed for the test,
and no claim is made about how common it is. Single GPU, no multi-GPU traffic.

---

## First measurement, 2026-09-04: Tesla T4

Tesla T4 on a `g4dn.xlarge`, driver 595.91.07, `dcgmi dmon` sampling at 1 Hz,
242 samples. The raw sampler output is in
[`data/dcgm-session1.txt`](data/dcgm-session1.txt), unedited.

| Workload | GPUTL<br>reported | SMACT<br>multiprocessors active | TENSO<br>tensor pipe active |
|---|---|---|---|
| 64-element add, launched in a loop | 20.0% | 0.2% | 0.0% |
| 4096² fp16 matmul | 100.0% | 98.1% | 87.8% |

The first row is a tiny kernel repeated in a tight loop, built to show the
failure mode: a T4 has 40 streaming multiprocessors, a 64-element add occupies
one of them, and something stays resident in almost every sample window. The
second row is the control. The first-row gap was specific to that kernel. On
the realistic H100 loads above, GPUTL ran 1.1x to 1.6x SMACT.

## Reproducing the T4 measurement

Cost is roughly $0.53/hour for the `g4dn.xlarge` in `us-east-1` at on-demand
rates, plus a little EBS. The stack builds an 8-hour auto-shutdown timer, a
budget alarm, IP-restricted SSH and IMDSv2, so an accidental overnight run is
bounded. Check current pricing before you build; these rates change.

```bash
# 1. 18 read-only checks: credentials, quotas, orphans from a previous run
export WORKING_ACCOUNT=<the account id this lab may touch>
export MGMT_ACCOUNT=<your org management account id>
./lab/preflight.sh

# 2. GPU quota, if you have never launched a G-family instance in this account
./lab/request-gpu-quota.sh

# 3. Build
cd lab
cp terraform.tfvars.example terraform.tfvars   # set your_ip_cidr and key name
terraform init && terraform apply

# 4. On the instance: run both workloads while sampling DCGM
./dcgm-demo.sh 90

# 5. Tear down, then confirm nothing survived
terraform destroy
./lab/cleanup-orphans.sh
```

`WORKING_ACCOUNT` and `MGMT_ACCOUNT` are unset by default. Setting them turns on
a guard that refuses to build in the wrong account, which is a mistake with real
cleanup attached to it.

### The sampling command

```
dcgmi dmon -e 203,1001,1002,1003,1004,1005 -d 1000
```

| Field | Name | What it reads |
|---|---|---|
| 203 | `DCGM_FI_DEV_GPU_UTIL` | was any kernel resident |
| 1001 | GRACT | graphics/compute engine active |
| 1002 | SMACT | fraction of SMs with work resident |
| 1003 | SMOCC | warp occupancy within those SMs |
| 1004 | TENSO | tensor pipe active |
| 1005 | DRAMA | memory bandwidth active |

Verify the field IDs on your own build with `dcgmi dmon -l`. They are stable in
practice but they are not guaranteed across DCGM versions.

The profiling fields (1001–1005) ship in the DCGM exporter and cost nothing to
turn on. The reason most clusters do not have them is not difficulty; it is that
nobody was asked the question that requires them.

---

## What is in here

```
cluster/
  collect-cluster-snapshot.sh                     three read-only kubectl reads, one JSON file
  rbac.yaml                                       list on nodes and pods, get on kube-system
lab/
  main.tf, variables.tf, versions.tf, budget.tf   the instance, SG, budget alarm
  user_data.sh.tftpl                              8-hour auto-shutdown timer
  terraform.tfvars.example                        copy to terraform.tfvars
  preflight.sh                                    18 read-only checks, no writes
  request-gpu-quota.sh                            G-family quota request helper
  dcgm-demo.sh                                    runs both phases while sampling
  watch-dcgm.sh                                   live view against dcgm-exporter
  gpu-workload.py                                 the two workloads
  cleanup-orphans.sh                              finds what destroy left behind
data/
  dcgm-session1.txt                               the raw 242-sample log
```

Resource names are `nameplate-lab`. Change them in `lab/main.tf` if that
collides with anything in your account.

## Safety notes

- `preflight.sh` performs no writes. Run it first, every time.
- `terraform.tfvars` is gitignored. Do not commit it, and do not commit state.
- SSH is restricted to a CIDR you supply. It does not default to `0.0.0.0/0`.
- The auto-shutdown timer is a backstop, not a substitute for `terraform destroy`.

## License

MIT. See [LICENSE](LICENSE).

---

Maintained by [Nameplate Analytics](https://nameplateanalytics.com), a
specialist practice measuring GPU cost attribution for teams running machine
learning on Kubernetes. Questions: kamk@nameplateanalytics.com
