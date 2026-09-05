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


class FaceGazeEyes(Dataset):
    """MPIIFaceGaze frames. Label: the eyes' rotation within the head, exactly the quantity
    the device needs; aux: the head's forward direction, exactly what ARKit supplies."""

    AUX_FEATURES = 2

    def __init__(self, frames, crop: int = CROP):
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
            torch.tensor(frame.head_ratios, dtype=torch.float32),
            torch.tensor(frame.eye_in_head, dtype=torch.float32),
        )
