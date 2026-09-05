"""GazeCapture frames as training tensors."""
from __future__ import annotations

import numpy as np
import torch
from PIL import Image
from torch.utils.data import Dataset

from . import gazecapture as gc

CROP = 64
# A first stand-in for eye position: reading distance in centimetres, refined later by a
# face fitter. The direction label is only as good as this; see the plan document.
NOMINAL_DISTANCE_CM = 35.0


def frame_aux(frame: gc.Frame, image_size: tuple[int, int]) -> np.ndarray:
    """Face box centre and size relative to the image: a proxy for head position and
    distance, the same idea as iTracker's face grid but continuous."""
    w, h = image_size
    x, y, fw, fh = frame.face
    return np.array([(x + fw / 2) / w - 0.5, (y + fh / 2) / h - 0.5, fw / w, fh / h], dtype=np.float32)


def frame_label(frame: gc.Frame) -> np.ndarray:
    u, v = gc.direction_ratios(frame.target_cm, (0.0, 0.0, -NOMINAL_DISTANCE_CM))
    return np.array([u, v], dtype=np.float32)


def _to_tensor(a: np.ndarray) -> torch.Tensor:
    return torch.from_numpy(a.astype(np.float32) / 255.0).unsqueeze(0)


class GazeCaptureEyes(Dataset):
    """GazeCapture frames. Label: gaze ratios from a nominal eye position; aux: face box."""

    def __init__(self, frames: list[gc.Frame], crop: int = CROP):
        self.frames = frames
        self.crop = crop

    def __len__(self) -> int:
        return len(self.frames)

    def __getitem__(self, i: int):
        frame = self.frames[i]
        with Image.open(frame.path) as im:
            grey = np.asarray(im.convert("L"))
        return (
            _to_tensor(gc.crop(grey, frame.left_eye, self.crop)),
            _to_tensor(gc.crop(grey, frame.right_eye, self.crop)),
            torch.from_numpy(frame_aux(frame, (grey.shape[1], grey.shape[0]))),
            torch.from_numpy(frame_label(frame)),
        )


def _jitter(box, rng, fraction: float):
    """Shift and rescale an eye box by a small random fraction of its width, so the
    network cannot rely on the landmark detector placing the eye at the exact same pixel."""
    x, y, w, h = box
    dx, dy = rng.uniform(-fraction, fraction, 2) * w
    scale = 1 + rng.uniform(-fraction, fraction)
    return (x + dx - w * (scale - 1) / 2, y + dy - h * (scale - 1) / 2, w * scale, h * scale)


def _photometric(a: np.ndarray, rng) -> np.ndarray:
    """Brightness and contrast, the two things that differ most between a laptop in an
    office and a phone in a living room."""
    contrast = rng.uniform(0.7, 1.3)
    brightness = rng.uniform(-25, 25)
    return np.clip((a.astype(np.float32) - 128) * contrast + 128 + brightness, 0, 255)


class FaceGazeEyes(Dataset):
    """MPIIFaceGaze frames. Label: the eyes' rotation within the head, exactly the quantity
    the device needs; aux: the head's forward direction, exactly what ARKit supplies.

    With ``augment`` the crops are jittered and their brightness and contrast varied, for
    training only. Labels are never changed: a shift of the crop does not move the eye
    within the head."""

    AUX_FEATURES = 2

    def __init__(self, frames, crop: int = CROP, augment: bool = False, seed: int = 0):
        self.frames = frames
        self.crop = crop
        self.augment = augment
        self.rng = np.random.default_rng(seed)

    def __len__(self) -> int:
        return len(self.frames)

    def __getitem__(self, i: int):
        frame = self.frames[i]
        with Image.open(frame.path) as im:
            grey = np.asarray(im.convert("L"))
        left_box, right_box = frame.left_eye, frame.right_eye
        if self.augment:
            left_box, right_box = _jitter(left_box, self.rng, 0.08), _jitter(right_box, self.rng, 0.08)
        left = gc.crop(grey, left_box, self.crop)
        right = gc.crop(grey, right_box, self.crop)
        if self.augment:
            left, right = _photometric(left, self.rng), _photometric(right, self.rng)
        return (
            _to_tensor(left),
            _to_tensor(right),
            torch.tensor(frame.head_ratios, dtype=torch.float32),
            torch.tensor(frame.eye_in_head, dtype=torch.float32),
        )
