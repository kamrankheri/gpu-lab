#!/usr/bin/env python3
"""
gpu-workload.py - demonstrate why DCGM_FI_DEV_GPU_UTIL is a bad waste metric.

Runs two phases against the same GPU:

  PHASE 1 "trivial"  a tiny kernel in a tight loop. Something is always
                     resident on the SMs, so GPU_UTIL reads high. Almost no
                     SMs are doing work and the tensor cores are idle.

  PHASE 2 "tensor"   large fp16 matmuls. GPU_UTIL reads about the same, but
                     SM_ACTIVE and PIPE_TENSOR_ACTIVE climb dramatically.

Watch ./watch-dcgm.sh in a second SSH session while this runs. The gap between
the two phases IS the product. A client's Grafana dashboard showing 90%
"GPU utilization" can be phase 1 all day long.

    python3 gpu-workload.py --phase trivial --seconds 90
    python3 gpu-workload.py --phase tensor  --seconds 90
    python3 gpu-workload.py --phase both    --seconds 90
"""

import argparse
import time

try:
    import torch
except ImportError:
    raise SystemExit(
        "torch not installed. Run:\n"
        "  pip3 install --break-system-packages torch --index-url https://download.pytorch.org/whl/cu121"
    )


def banner(text):
    print(f"\n{'=' * 60}\n  {text}\n{'=' * 60}", flush=True)


def trivial(seconds: int, dev):
    """
    Keep a kernel resident without doing meaningful work.

    A 64-element add launches thousands of times per second. The GPU is never
    idle, so the utilization sampler almost always catches a kernel running.
    One SM out of 40 is busy and the tensor cores never fire.
    """
    banner(f"PHASE 1: trivial kernel, {seconds}s")
    print("  expect: GPU_UTIL high, SM_ACTIVE near zero, TENSOR_ACTIVE zero")
    a = torch.ones(64, device=dev)
    b = torch.ones(64, device=dev)
    end = time.time() + seconds
    n = 0
    while time.time() < end:
        for _ in range(1000):
            a = a + b
        n += 1000
        a.fill_(1.0)
    torch.cuda.synchronize()
    print(f"  launched ~{n:,} kernels")


def tensor(seconds: int, dev):
    """
    Saturate the tensor cores with large fp16 matmuls.

    4096x4096 half-precision GEMM is what a T4's tensor cores exist for.
    """
    banner(f"PHASE 2: fp16 matmul, {seconds}s")
    print("  expect: GPU_UTIL similar, SM_ACTIVE high, TENSOR_ACTIVE high")
    n = 4096
    a = torch.randn(n, n, device=dev, dtype=torch.float16)
    b = torch.randn(n, n, device=dev, dtype=torch.float16)
    end = time.time() + seconds
    it = 0
    while time.time() < end:
        for _ in range(20):
            c = a @ b
        it += 20
    torch.cuda.synchronize()
    # 2*n^3 flops per matmul
    tflops = (2 * n**3 * it) / seconds / 1e12
    print(f"  {it:,} matmuls, ~{tflops:.1f} TFLOP/s")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--phase", choices=["trivial", "tensor", "both"], default="both")
    p.add_argument("--seconds", type=int, default=90)
    args = p.parse_args()

    if not torch.cuda.is_available():
        raise SystemExit("no CUDA device visible to torch")

    dev = torch.device("cuda:0")
    print(f"device: {torch.cuda.get_device_name(0)}")

    if args.phase in ("trivial", "both"):
        trivial(args.seconds, dev)
    if args.phase == "both":
        banner("30s idle gap so the two phases are separable in the metrics")
        time.sleep(30)
    if args.phase in ("tensor", "both"):
        tensor(args.seconds, dev)

    banner("done")
    print("  Compare the two phases in watch-dcgm.sh output.")
    print("  If GPU_UTIL looks the same in both, you have just seen why")
    print("  utilization dashboards do not detect GPU waste.")


if __name__ == "__main__":
    main()
