#!/usr/bin/env python3
"""Fine-tuning workload for telemetry capture. Two registered configurations.

untuned: per-step CPU tokenization, num_workers=0, fp32, padded to max length, batch 4
tuned:   pre-tokenized packed blocks, num_workers=8, pinned memory, bf16 autocast, batch 16
"""
import argparse
import json
import pathlib
import time

import torch
from datasets import load_dataset
from torch.utils.data import DataLoader, Dataset, TensorDataset
from transformers import AutoModelForCausalLM, AutoTokenizer


class RawText(Dataset):
    def __init__(self, texts):
        self.texts = texts

    def __len__(self):
        return len(self.texts)

    def __getitem__(self, i):
        return self.texts[i]


class UntunedCollate:
    """Tokenizes on the CPU at every step, padded to max length."""

    def __init__(self, tok, seq):
        self.tok = tok
        self.seq = seq

    def __call__(self, batch):
        enc = self.tok(
            batch, truncation=True, max_length=self.seq, padding="max_length", return_tensors="pt"
        )
        return enc["input_ids"], enc["attention_mask"]


def build_loader(mode, tok, texts, seq):
    if mode == "untuned":
        batch_size = 4
        loader = DataLoader(
            RawText(texts),
            batch_size=batch_size,
            shuffle=True,
            num_workers=0,
            collate_fn=UntunedCollate(tok, seq),
        )
        return loader, batch_size

    batch_size = 16
    ids = tok("\n\n".join(texts), return_tensors="pt")["input_ids"][0]
    usable = (ids.numel() // seq) * seq
    blocks = ids[:usable].view(-1, seq)
    loader = DataLoader(
        TensorDataset(blocks, torch.ones_like(blocks)),
        batch_size=batch_size,
        shuffle=True,
        num_workers=8,
        pin_memory=True,
        persistent_workers=True,
        drop_last=True,
    )
    return loader, batch_size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["untuned", "tuned"], required=True)
    ap.add_argument("--seconds", type=int, required=True)
    ap.add_argument("--model", default="Qwen/Qwen2.5-0.5B")
    ap.add_argument("--seq", type=int, default=512)
    ap.add_argument("--ready-file", required=True)
    args = ap.parse_args()

    torch.manual_seed(0)
    tok = AutoTokenizer.from_pretrained(args.model)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token

    texts = [
        t
        for t in load_dataset("Salesforce/wikitext", "wikitext-2-raw-v1", split="train")["text"]
        if t.strip()
    ]
    loader, batch_size = build_loader(args.mode, tok, texts, args.seq)

    dev = torch.device("cuda")
    model = AutoModelForCausalLM.from_pretrained(args.model, torch_dtype=torch.float32).to(dev)
    model.train()
    opt = torch.optim.AdamW(model.parameters(), lr=1e-5)
    use_bf16 = args.mode == "tuned"

    steps = 0
    tokens = 0
    t0 = None
    loss = None
    done = False
    while not done:
        for input_ids, attn in loader:
            if t0 is None:
                pathlib.Path(args.ready_file).touch()
                t0 = time.time()
            tokens += int(attn.sum())
            input_ids = input_ids.to(dev, non_blocking=True)
            attn = attn.to(dev, non_blocking=True)
            labels = input_ids.masked_fill(attn == 0, -100)
            with torch.autocast(device_type="cuda", dtype=torch.bfloat16, enabled=use_bf16):
                loss = model(input_ids=input_ids, attention_mask=attn, labels=labels).loss
            loss.backward()
            opt.step()
            opt.zero_grad(set_to_none=True)
            steps += 1
            if time.time() - t0 >= args.seconds:
                done = True
                break

    torch.cuda.synchronize()
    elapsed = time.time() - t0
    print(json.dumps({
        "mode": args.mode,
        "model": args.model,
        "batch_size": batch_size,
        "seq": args.seq,
        "steps": steps,
        "tokens": tokens,
        "seconds": round(elapsed, 1),
        "tokens_per_second": round(tokens / elapsed, 1),
        "final_loss": round(loss.item(), 4),
    }))


if __name__ == "__main__":
    main()
