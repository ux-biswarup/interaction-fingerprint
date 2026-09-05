#!/usr/bin/env python3
"""Train the eye-in-head network on GazeCapture.

    python3 -m eyemodel.train --root /path/to/GazeCapture --epochs 5 --limit 50

Subjects, not frames, are held out: the dataset's own train/val/test split is by person,
and a network that has seen a person's eyes in training says nothing about a new one.
Reports held-out error in degrees, which is what the calibration on device will receive.
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import torch
from torch import nn
from torch.utils.data import DataLoader

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from eyemodel import gazecapture as gc  # noqa: E402
from eyemodel.dataset import GazeCaptureEyes  # noqa: E402
from eyemodel.model import EyeInHeadNet, parameter_count  # noqa: E402


def device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def degrees_error(pred: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    """Angle between two gaze directions given as ratios, in degrees."""
    a = torch.cat([pred, torch.ones_like(pred[:, :1])], dim=1)
    b = torch.cat([target, torch.ones_like(target[:, :1])], dim=1)
    cos = (a * b).sum(1) / (a.norm(dim=1) * b.norm(dim=1))
    return torch.rad2deg(torch.acos(cos.clamp(-1, 1)))


def run_epoch(model, loader, optimiser, dev, train: bool) -> tuple[float, float]:
    model.train(train)
    loss_fn = nn.SmoothL1Loss(beta=0.02)
    total, count, deg = 0.0, 0, 0.0
    with torch.set_grad_enabled(train):
        for left, right, aux, label in loader:
            left, right, aux, label = (t.to(dev) for t in (left, right, aux, label))
            pred = model(left, right, aux)
            loss = loss_fn(pred, label)
            if train:
                optimiser.zero_grad()
                loss.backward()
                optimiser.step()
            total += loss.item() * len(label)
            deg += degrees_error(pred, label).sum().item()
            count += len(label)
    return total / max(count, 1), deg / max(count, 1)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, help="GazeCapture root with numbered subject folders")
    ap.add_argument("--epochs", type=int, default=5)
    ap.add_argument("--limit", type=int, default=None, help="subjects to read, for a quick run")
    ap.add_argument("--batch", type=int, default=128)
    ap.add_argument("--out", default="eyemodel.pt")
    args = ap.parse_args()

    frames = gc.read_dataset(args.root, limit=args.limit)
    train = [f for f in frames if f.split == "train"]
    val = [f for f in frames if f.split in ("val", "test")]
    print(f"frames: {len(frames)}  train {len(train)}  held-out {len(val)}  subjects {len({f.subject for f in frames})}")

    dev = device()
    model = EyeInHeadNet(aux_features=4).to(dev)
    print(f"device {dev}, parameters {parameter_count(model):,}")
    optimiser = torch.optim.AdamW(model.parameters(), lr=1e-3, weight_decay=1e-4)
    loaders = {
        "train": DataLoader(GazeCaptureEyes(train), batch_size=args.batch, shuffle=True, num_workers=4),
        "val": DataLoader(GazeCaptureEyes(val), batch_size=args.batch, num_workers=4),
    }
    for epoch in range(args.epochs):
        tl, td = run_epoch(model, loaders["train"], optimiser, dev, train=True)
        vl, vd = run_epoch(model, loaders["val"], optimiser, dev, train=False)
        print(f"epoch {epoch + 1}: train loss {tl:.4f} ({td:.2f}°)  held-out loss {vl:.4f} ({vd:.2f}°)")
    torch.save(model.state_dict(), args.out)
    print(f"saved {args.out}")


if __name__ == "__main__":
    main()
