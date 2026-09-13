# GPU telemetry lab

A reproducible AWS lab that demonstrates why `DCGM_FI_DEV_GPU_UTIL`, the metric
on almost every default GPU dashboard, is not a measure of GPU utilization.

Everything here is what produced the measurement published at
[nameplateanalytics.com/method](https://nameplateanalytics.com/method). The raw
sampler output from that run is in [`data/dcgm-session1.txt`](data/dcgm-session1.txt),
unedited.

---

## The result

Tesla T4 on a `g4dn.xlarge`, driver 595.91.07, `dcgmi dmon` sampling at 1 Hz,
242 samples, 2026-09-04.

| Workload | GPUTL<br>reported | SMACT<br>multiprocessors active | TENSO<br>tensor pipe active |
|---|---|---|---|
| 64-element add, launched in a loop | 20.0% | 0.2% | 0.0% |
| 4096² fp16 matmul | 100.0% | 98.1% | 87.8% |

The first row is the finding: **the reported number is one hundred times the
measured one.** The second row is the control. When the chip genuinely is
working, all three fields agree, which is how you know the instrument was sound
and the first row is not an artifact of the setup.

This is not a bug in anyone's dashboard. `DCGM_FI_DEV_GPU_UTIL` reports whether
a kernel was *resident* on the device during the sample window. It says nothing
about how much of the device that kernel used. A T4 has 40 streaming
multiprocessors; a 64-element add occupies one of them, and launched in a tight
loop it keeps something resident in almost every sample window.

### What this does not prove

One GPU model, two synthetic workloads chosen to bracket the range, one machine.
A T4 is not an H100 and the ratio on other hardware will differ. This
establishes that the metric *can* be wrong by two orders of magnitude and that
it fails silently. It does not establish that any particular cluster is wrong,
by how much, or on which workloads. The only way to know that is to instrument
the cluster and read it.

---

## Reproducing it

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
