#!/usr/bin/env python3
"""Judge a trained eye-in-head network the way the on-device readouts were judged.

    python3 -m eyemodel.evaluate --root ~/Datasets/MPIIFaceGaze/MPIIFaceGaze --weights model.pt --subjects p14

For each held-out subject and each axis: correlation between predicted and true eye-in-head
ratios, the slope of a straight-line fit (the gain), the error in degrees, and the error
after a per-person linear correction fitted on half of that person's frames and tested on
the other half, which is what our on-device calibration would do on top of the network.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from eyemodel import mpiifacegaze as mf  # noqa: E402
from eyemodel.dataset import FaceGazeEyes  # noqa: E402
from eyemodel.model import EyeInHeadNet  # noqa: E402
from eyemodel.train import degrees_error, device  # noqa: E402


def predict(model, frames, dev, batch=256):
    loader = DataLoader(FaceGazeEyes(frames), batch_size=batch, num_workers=4)
    preds, labels = [], []
    model.eval()
    with torch.no_grad():
        for left, right, aux, label in loader:
            preds.append(model(left.to(dev), right.to(dev), aux.to(dev)).cpu())
            labels.append(label)
    return torch.cat(preds).numpy(), torch.cat(labels).numpy()


def personal_correction(pred, truth, seed=0):
    """Per-person affine correction fitted on half the frames, judged on the other half."""
    rng = np.random.default_rng(seed)
    idx = rng.permutation(len(pred))
    fit, test = idx[: len(idx) // 2], idx[len(idx) // 2:]
    X = np.column_stack([np.ones(len(fit)), pred[fit]])
    bu = np.linalg.lstsq(X, truth[fit, 0], rcond=None)[0]
    bv = np.linalg.lstsq(X, truth[fit, 1], rcond=None)[0]
    Xt = np.column_stack([np.ones(len(test)), pred[test]])
    corrected = np.column_stack([Xt @ bu, Xt @ bv])
    return degrees_error(torch.from_numpy(corrected), torch.from_numpy(truth[test])).mean().item()


def report(pred, truth, label):
    rows = []
    for axis, name in enumerate(("horizontal", "vertical")):
        r = np.corrcoef(pred[:, axis], truth[:, axis])[0, 1]
        gain = np.polyfit(truth[:, axis], pred[:, axis], 1)[0]
        rows.append(f"{name}: r {r:+.3f} gain {gain:.2f}")
    deg = degrees_error(torch.from_numpy(pred), torch.from_numpy(truth)).mean().item()
    print(f"  {label}: {' | '.join(rows)} | error {deg:.2f}° | after personal correction {personal_correction(pred, truth):.2f}°")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--weights", required=True)
    ap.add_argument("--subjects", default="p14")
    args = ap.parse_args()
    dev = device()
    model = EyeInHeadNet(aux_features=FaceGazeEyes.AUX_FEATURES).to(dev)
    model.load_state_dict(torch.load(args.weights, map_location=dev))
    for subject in args.subjects.split(","):
        frames = mf.read_subject(Path(args.root) / subject)
        pred, truth = predict(model, frames, dev)
        report(pred, truth, f"{subject} ({len(frames)} frames)")
        # The trivial baseline: predict the training-set mean. What "learned nothing" looks like.
        baseline = np.tile(truth.mean(0), (len(truth), 1))
        print(f"    baseline, constant prediction: error {degrees_error(torch.from_numpy(baseline), torch.from_numpy(truth)).mean().item():.2f}°")


if __name__ == "__main__":
    main()
