"""Ray GPU job for the AKS GPU profiling demo.

The driver runs on the Ray head (CPU) node and launches one Ray task that needs a GPU, so it
lands on the T4 worker node. The task trains a small GPT-style Transformer on synthetic tokens in
repeating phases that create distinct GPU memory patterns for Inspektor Gadget and Pyroscope:

  baseline         batch 8
  oversized_batch  batch 32 (more activation memory)
  logits_leak      batch 16, keeps a slice of every step's logits on the GPU; the slice is a
                   view, so each step's whole logits tensor stays alive
  dataloader_stall batch 16 with a simulated CPU-bound input pipeline (GPU idles)
  rightsized       batch 16 after releasing the leak and emptying the cache

PyTorch is installed into the task's runtime environment on the GPU node only.
"""
import json
import os
import socket
import time

import ray

DURATION = int(os.environ.get("DURATION_SECONDS", "600"))
PHASE_SECONDS = int(os.environ.get("PHASE_SECONDS", "40"))
TORCH_REQUIREMENT = os.environ.get("TORCH_REQUIREMENT", "torch==2.5.1")


@ray.remote(num_gpus=1, num_cpus=1, runtime_env={"pip": [TORCH_REQUIREMENT]})
def train_tinygpt(duration, phase_seconds):
    import subprocess

    import torch
    import torch.nn as nn
    import torch.nn.functional as F

    seq, vocab, d_model, layers, heads = 512, 16000, 768, 8, 12
    gib = 2**30

    def log(**kw):
        kw["ts"] = round(time.time(), 1)
        print(json.dumps(kw), flush=True)

    class TinyGPT(nn.Module):
        def __init__(self):
            super().__init__()
            self.tok = nn.Embedding(vocab, d_model)
            self.pos = nn.Embedding(seq, d_model)
            layer = nn.TransformerEncoderLayer(
                d_model, heads, 4 * d_model, dropout=0.0, activation="gelu",
                batch_first=True, norm_first=True)
            self.blocks = nn.TransformerEncoder(layer, layers, enable_nested_tensor=False)
            self.head = nn.Linear(d_model, vocab, bias=False)
            self.register_buffer(
                "mask", nn.Transformer.generate_square_subsequent_mask(seq), persistent=False)

        def forward(self, x):
            h = self.tok(x) + self.pos(torch.arange(x.size(1), device=x.device))
            h = self.blocks(h, mask=self.mask, is_causal=True)
            return self.head(h)

    def train_step(model, opt, scaler, batch, keep=None):
        x = torch.randint(0, vocab, (batch, seq), device="cuda")
        y = torch.roll(x, -1, dims=1)
        with torch.autocast("cuda", dtype=torch.float16):
            logits = model(x)
        loss = F.cross_entropy(logits.float().view(-1, vocab), y.view(-1))
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
        steps, start, loss, status = 0, time.time(), None, "ok"
        try:
            while time.time() - start < phase_seconds:
                if stall_s:
                    time.sleep(stall_s)
                loss = train_step(model, opt, scaler, batch, keep)
                steps += 1
                if leak and torch.cuda.memory_allocated() > 0.75 * total_mem:
                    status = "leak_capped"
                    break
            torch.cuda.synchronize()
        except torch.cuda.OutOfMemoryError:
            status = "oom"
        elapsed = time.time() - start
        row = dict(event="phase", phase=name, batch=batch, seq=seq, steps=steps,
                   seconds=round(elapsed, 1), step_ms=round(1000 * elapsed / max(steps, 1), 1),
                   tokens_per_s=round(steps * batch * seq / elapsed, 1),
                   peak_alloc_gib=round(torch.cuda.max_memory_allocated() / gib, 2),
                   peak_reserved_gib=round(torch.cuda.max_memory_reserved() / gib, 2),
                   retained_logits_steps=len(keep) if keep is not None else 0,
                   loss=round(float(loss), 3) if loss is not None else None, status=status)
        log(**row)
        if keep is not None:
            keep.clear()
        torch.cuda.empty_cache()
        return row

    props = torch.cuda.get_device_properties(0)
    try:
        smi = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,driver_version,memory.total",
             "--format=csv,noheader"], capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception as exc:  # nvidia-smi isn't guaranteed in the container
        smi = f"unavailable: {exc}"
    model = TinyGPT().cuda()
    env = dict(event="env", host=socket.gethostname(), pid=os.getpid(), torch=torch.__version__,
               cuda_runtime=torch.version.cuda, cudnn=torch.backends.cudnn.version(),
               gpu=props.name, gpu_total_gib=round(props.total_memory / gib, 2), nvidia_smi=smi,
               model_params_millions=round(sum(p.numel() for p in model.parameters()) / 1e6, 1),
               duration_s=duration, phase_s=phase_seconds)
    log(**env)
    opt = torch.optim.AdamW(model.parameters(), lr=3e-4)
    scaler = torch.amp.GradScaler("cuda")
    phases = [
        ("baseline", dict(batch=8)),
        ("oversized_batch", dict(batch=32)),
        ("logits_leak", dict(batch=16, leak=True)),
        ("dataloader_stall", dict(batch=16, stall_s=0.25)),
        ("rightsized", dict(batch=16)),
    ]
    rows, t0, cycle = [], time.time(), 0
    while time.time() - t0 < duration:
        cycle += 1
        for name, kw in phases:
            if time.time() - t0 >= duration:
                break
            rows.append(run_phase(name, model, opt, scaler, total_mem=props.total_memory, **kw))
        log(event="cycle_done", cycle=cycle, elapsed_s=round(time.time() - t0, 1))
    log(event="done", cycles=cycle, elapsed_s=round(time.time() - t0, 1))
    # Plain JSON types only: the driver doesn't install torch, so it can't unpickle torch objects
    # such as torch.__version__ (a TorchVersion).
    return json.loads(json.dumps({"env": env, "phases": rows, "cycles": cycle}, default=str))


if __name__ == "__main__":
    ray.init()
    print(json.dumps({"event": "driver_start", "ray": ray.__version__, "host": socket.gethostname(),
                      "cluster_resources": ray.cluster_resources(), "ts": round(time.time(), 1)}),
          flush=True)
    start = time.time()
    result = ray.get(train_tinygpt.remote(DURATION, PHASE_SECONDS))
    print(json.dumps({"event": "driver_done", "seconds": round(time.time() - start, 1),
                      "cycles": result["cycles"], "gpu": result["env"]["gpu"],
                      "torch": result["env"]["torch"], "ts": round(time.time(), 1)}), flush=True)
