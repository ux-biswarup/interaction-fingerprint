#!/usr/bin/env python3
"""Convert a trained checkpoint to a Core ML package for the phone.

    python3 -m eyemodel.export_coreml --weights run.pt --out EyeInHead.mlpackage

Inputs are two 64x64 greyscale images, ``leftEye`` and ``rightEye``, scaled to 0...1 inside
the model so the app can hand over pixel buffers as they are, and ``head``, the head's
forward direction as two ratios. Output ``eyeInHead`` is two ratios in the same units. The
eye named ``leftEye`` is the one on the left of the camera image, the participant's right,
matching how the training crops were labelled.

The converted model is checked against the PyTorch one on random inputs before it is
written, so a conversion that silently changed the arithmetic cannot reach the device.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from eyemodel.dataset import CROP, FaceGazeEyes  # noqa: E402
from eyemodel.model import EyeInHeadNet  # noqa: E402


class Wrapped(torch.nn.Module):
    """Positional inputs in a fixed order for tracing."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, left, right, head):
        return self.model(left, right, head)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", required=True)
    ap.add_argument("--out", default="EyeInHead.mlpackage")
    args = ap.parse_args()

    model = EyeInHeadNet(aux_features=FaceGazeEyes.AUX_FEATURES)
    model.load_state_dict(torch.load(args.weights, map_location="cpu"))
    model.eval()
    wrapped = Wrapped(model).eval()

    left = torch.rand(1, 1, CROP, CROP)
    right = torch.rand(1, 1, CROP, CROP)
    head = torch.tensor([[0.05, -0.1]])
    traced = torch.jit.trace(wrapped, (left, right, head))

    package = ct.convert(
        traced,
        inputs=[
            ct.ImageType(name="leftEye", shape=(1, 1, CROP, CROP), color_layout=ct.colorlayout.GRAYSCALE, scale=1 / 255.0),
            ct.ImageType(name="rightEye", shape=(1, 1, CROP, CROP), color_layout=ct.colorlayout.GRAYSCALE, scale=1 / 255.0),
            ct.TensorType(name="head", shape=(1, 2), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="eyeInHead")],
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
        convert_to="mlprogram",
    )
    package.author = "Interaction Fingerprint"
    package.short_description = "Eye rotation within the head from two eye crops and the head direction."

    # Verify against PyTorch on the same inputs, fed as 8-bit images the way the app will.
    from PIL import Image
    l8 = (left[0, 0].numpy() * 255).astype(np.uint8)
    r8 = (right[0, 0].numpy() * 255).astype(np.uint8)
    got = package.predict({"leftEye": Image.fromarray(l8, "L"), "rightEye": Image.fromarray(r8, "L"), "head": head.numpy()})["eyeInHead"]
    with torch.no_grad():
        want = wrapped(torch.from_numpy(l8.astype(np.float32) / 255).view(1, 1, CROP, CROP),
                       torch.from_numpy(r8.astype(np.float32) / 255).view(1, 1, CROP, CROP), head).numpy()
    diff = float(np.abs(np.asarray(got) - want).max())
    print(f"max difference Core ML vs PyTorch: {diff:.5f}")
    if diff > 1e-3:
        sys.exit("conversion changed the arithmetic; not saving")
    package.save(args.out)
    print(f"saved {args.out}")


if __name__ == "__main__":
    main()
