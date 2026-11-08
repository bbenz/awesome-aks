"""Representative GPU training workload for the AKS GPU profiling demo.

Trains a small GPT-style Transformer on synthetic tokens (no dataset download)
in repeating phases so GPU memory and utilization patterns are easy to spot in
Inspektor Gadget metrics (managed Prometheus) and CUDA memory profiles (Pyroscope):

  baseline         batch 8
  oversized_batch  batch 32 (more activation memory)
  logits_leak      batch 16, keeps a slice of every step's logits on the GPU
                   "for metrics" - the slice is a view, so the whole logits
                   tensor stays alive until it is released
  dataloader_stall batch 16 with a simulated CPU-bound input pipeline (GPU idles)
  rightsized       batch 16 after releasing the leak and emptying the cache
"""
import json
import os
import subprocess
import time

import torch
import torch.nn as nn
import torch.nn.functional as F

DURATION = int(os.environ.get("DURATION_SECONDS", "900"))
PHASE_SECONDS = int(os.environ.get("PHASE_SECONDS", "45"))
SEQ = int(os.environ.get("SEQ_LEN", "512"))
VOCAB = int(os.environ.get("VOCAB", "16000"))
D_MODEL = int(os.environ.get("D_MODEL", "768"))
LAYERS = int(os.environ.get("LAYERS", "8"))
HEADS = int(os.environ.get("HEADS", "12"))
LEAK_MAX_FRACTION = float(os.environ.get("LEAK_MAX_FRACTION", "0.75"))
GIB = 2**30


def log(**kw):
    kw["ts"] = round(time.time(), 1)
    print(json.dumps(kw), flush=True)


class TinyGPT(nn.Module):
    def __init__(self):
        super().__init__()
        self.tok = nn.Embedding(VOCAB, D_MODEL)
        self.pos = nn.Embedding(SEQ, D_MODEL)
        layer = nn.TransformerEncoderLayer(
            D_MODEL, HEADS, 4 * D_MODEL, dropout=0.0, activation="gelu",
            batch_first=True, norm_first=True)
        self.blocks = nn.TransformerEncoder(layer, LAYERS, enable_nested_tensor=False)
        self.head = nn.Linear(D_MODEL, VOCAB, bias=False)
        self.register_buffer(
            "mask", nn.Transformer.generate_square_subsequent_mask(SEQ), persistent=False)

    def forward(self, x):
        h = self.tok(x) + self.pos(torch.arange(x.size(1), device=x.device))
        h = self.blocks(h, mask=self.mask, is_causal=True)
        return self.head(h)


def train_step(model, opt, scaler, batch, keep=None):
    x = torch.randint(0, VOCAB, (batch, SEQ), device="cuda")
    y = torch.roll(x, -1, dims=1)
    with torch.autocast("cuda", dtype=torch.float16):
        logits = model(x)
    loss = F.cross_entropy(logits.float().view(-1, VOCAB), y.view(-1))
    opt.zero_grad(set_to_none=True)
    scaler.scale(loss).backward()
    scaler.step(opt)
    scaler.update()
    if keep is not None:
        keep.append(logits.detach()[:, -64:, :])
    return loss


def run_phase(name, model, opt, scaler, batch, total_mem, stall_s=0.0, leak=False):
    torch.cuda.synchronize()
    torch.cuda.reset_peak_memory_stats()
    keep = [] if leak else None
    steps, start, loss = 0, time.time(), None
    status = "ok"
    try:
        while time.time() - start < PHASE_SECONDS:
            if stall_s:
                time.sleep(stall_s)
            loss = train_step(model, opt, scaler, batch, keep)
            steps += 1
            if leak and torch.cuda.memory_allocated() > LEAK_MAX_FRACTION * total_mem:
                status = "leak_capped"
                break
        torch.cuda.synchronize()
    except torch.cuda.OutOfMemoryError:
        status = "oom"
    elapsed = time.time() - start
    log(event="phase", phase=name, batch=batch, seq=SEQ, steps=steps,
        seconds=round(elapsed, 1),
        step_ms=round(1000 * elapsed / max(steps, 1), 1),
        tokens_per_s=round(steps * batch * SEQ / elapsed, 1),
        peak_alloc_gib=round(torch.cuda.max_memory_allocated() / GIB, 2),
        peak_reserved_gib=round(torch.cuda.max_memory_reserved() / GIB, 2),
        retained_logits_steps=len(keep) if keep is not None else 0,
        loss=round(float(loss), 3) if loss is not None else None, status=status)
    if keep is not None:
        keep.clear()
    torch.cuda.empty_cache()


def main():
    props = torch.cuda.get_device_properties(0)
    try:
        smi = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,driver_version,memory.total",
             "--format=csv,noheader"], capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception as exc:  # nvidia-smi is optional in the container
        smi = f"unavailable: {exc}"
    model = TinyGPT().cuda()
    params = sum(p.numel() for p in model.parameters())
    log(event="env", torch=torch.__version__, cuda_runtime=torch.version.cuda,
        cudnn=torch.backends.cudnn.version(), gpu=props.name,
        gpu_total_gib=round(props.total_memory / GIB, 2), nvidia_smi=smi,
        model_params_millions=round(params / 1e6, 1), duration_s=DURATION,
        phase_s=PHASE_SECONDS)
    opt = torch.optim.AdamW(model.parameters(), lr=3e-4)
    scaler = torch.amp.GradScaler("cuda")
    phases = [
        ("baseline", dict(batch=8)),
        ("oversized_batch", dict(batch=32)),
        ("logits_leak", dict(batch=16, leak=True)),
        ("dataloader_stall", dict(batch=16, stall_s=0.25)),
        ("rightsized", dict(batch=16)),
    ]
    t0, cycle = time.time(), 0
    while time.time() - t0 < DURATION:
        cycle += 1
        for name, kw in phases:
            if time.time() - t0 >= DURATION:
                break
            run_phase(name, model, opt, scaler, total_mem=props.total_memory, **kw)
        log(event="cycle_done", cycle=cycle, elapsed_s=round(time.time() - t0, 1))
    log(event="done", cycles=cycle, elapsed_s=round(time.time() - t0, 1))


if __name__ == "__main__":
    main()
