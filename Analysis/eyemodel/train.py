#!/usr/bin/env python3
"""Train the eye-in-head network.

    python3 -m eyemodel.train --root ~/Datasets/MPIIFaceGaze/MPIIFaceGaze --epochs 10
    python3 -m eyemodel.train --dataset gazecapture --root /path/to/GazeCapture --limit 50

Subjects, not frames, are held out: a network that has seen a person's eyes in training
says nothing about a new one. Reports held-out error in degrees, which is what the
calibration on device will receive.
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
from eyemodel import mpiifacegaze as mf  # noqa: E402
from eyemodel.dataset import FaceGazeEyes, GazeCaptureEyes  # noqa: E402
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
    ap.add_argument("--root", required=True, help="dataset root")
    ap.add_argument("--dataset", choices=("mpiifacegaze", "gazecapture"), default="mpiifacegaze")
    ap.add_argument("--holdout", default="p14", help="MPIIFaceGaze: comma-separated subjects to hold out")
    ap.add_argument("--epochs", type=int, default=5)
    ap.add_argument("--limit", type=int, default=None, help="subjects to read, for a quick run")
    ap.add_argument("--batch", type=int, default=128)
    ap.add_argument("--out", default="eyemodel.pt")
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--augment", action="store_true", help="jitter crops and vary brightness while training")
    args = ap.parse_args()

    if args.dataset == "gazecapture":
        frames = gc.read_dataset(args.root, limit=args.limit)
        train = [f for f in frames if f.split == "train"]
        val = [f for f in frames if f.split in ("val", "test")]
        make, aux = GazeCaptureEyes, 4
    else:
        frames = mf.read_dataset(args.root, limit=args.limit)
        held = set(args.holdout.split(","))
        train = [f for f in frames if f.subject not in held]
        val = [f for f in frames if f.subject in held]
        make, aux = FaceGazeEyes, FaceGazeEyes.AUX_FEATURES
    print(f"frames: {len(frames)}  train {len(train)}  held-out {len(val)}  subjects {len({f.subject for f in frames})}")

    dev = device()
    model = EyeInHeadNet(aux_features=aux).to(dev)
    print(f"device {dev}, parameters {parameter_count(model):,}")
    optimiser = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    # Cosine decay to a tenth of the starting rate: the last epochs settle rather than jump.
    schedule = torch.optim.lr_scheduler.CosineAnnealingLR(optimiser, T_max=args.epochs, eta_min=args.lr / 10)
    train_set = make(train, augment=args.augment) if args.dataset == "mpiifacegaze" else make(train)
    loaders = {
        "train": DataLoader(train_set, batch_size=args.batch, shuffle=True, num_workers=4),
        "val": DataLoader(make(val), batch_size=args.batch, num_workers=4),
    }
    best = float("inf")
    for epoch in range(args.epochs):
        tl, td = run_epoch(model, loaders["train"], optimiser, dev, train=True)
        vl, vd = run_epoch(model, loaders["val"], optimiser, dev, train=False)
        schedule.step()
        marker = ""
        if vd < best:
            best = vd
            torch.save(model.state_dict(), args.out)
            marker = "  saved"
        print(f"epoch {epoch + 1}: train loss {tl:.4f} ({td:.2f}°)  held-out loss {vl:.4f} ({vd:.2f}°){marker}", flush=True)
    print(f"best held-out {best:.2f}° -> {args.out}")


if __name__ == "__main__":
    main()
