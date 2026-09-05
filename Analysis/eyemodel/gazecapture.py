"""Reader for the GazeCapture dataset (Krafka et al., CVPR 2016).

Each subject is a numbered folder:

    frames/            sequentially numbered JPEG frames
    frames.json        frame file names
    appleFace.json     face box per frame: X, Y, W, H in pixels, IsValid
    appleLeftEye.json  eye box per frame, relative to the face box; "left" is the
    appleRightEye.json subject's own left, which appears on the right of the image
    dotInfo.json       the target: XPts/YPts in iOS points, XCam/YCam in centimetres
                       relative to the camera, DotNum, Time
    screen.json        H, W in points and Orientation 1..4
    info.json          Dataset split (train/val/test), device name, frame counts

The label we want is the gaze direction relative to the camera, which is what XCam/YCam
give once the eye's position is known. The dataset has no head pose and no depth, so the
eye-in-head decomposition this project uses on device cannot be reproduced from the labels
alone; see the plan document for how that is handled.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np

PORTRAIT = 1
PORTRAIT_UPSIDE_DOWN = 2
LANDSCAPE_HOME_RIGHT = 3
LANDSCAPE_HOME_LEFT = 4


@dataclass(frozen=True)
class Frame:
    subject: str
    index: int
    path: Path
    face: tuple[float, float, float, float]
    left_eye: tuple[float, float, float, float]
    right_eye: tuple[float, float, float, float]
    target_cm: tuple[float, float]
    target_points: tuple[float, float]
    orientation: int
    split: str
    device: str


def _load(folder: Path, name: str):
    with open(folder / name) as f:
        return json.load(f)


def _box(record: dict, i: int) -> tuple[float, float, float, float]:
    return (float(record["X"][i]), float(record["Y"][i]), float(record["W"][i]), float(record["H"][i]))


def read_subject(folder: str | Path, portrait_only: bool = True) -> list[Frame]:
    """Every frame of one subject that has a valid face and both eyes.

    Eye boxes in the files are relative to the face box; they are returned in image
    pixels. Frames are dropped when any detection is missing. By default only portrait
    frames are kept, because the phone in this project is portrait only and the target
    convention differs by orientation.
    """
    folder = Path(folder)
    names = _load(folder, "frames.json")
    face = _load(folder, "appleFace.json")
    left = _load(folder, "appleLeftEye.json")
    right = _load(folder, "appleRightEye.json")
    dots = _load(folder, "dotInfo.json")
    screen = _load(folder, "screen.json")
    info = _load(folder, "info.json")
    split = str(info.get("Dataset", "unknown"))
    device = str(info.get("DeviceName", "unknown"))

    frames: list[Frame] = []
    for i, name in enumerate(names):
        if not (face["IsValid"][i] and left["IsValid"][i] and right["IsValid"][i]):
            continue
        orientation = int(screen["Orientation"][i])
        if portrait_only and orientation != PORTRAIT:
            continue
        fx, fy, fw, fh = _box(face, i)
        lx, ly, lw, lh = _box(left, i)
        rx, ry, rw, rh = _box(right, i)
        frames.append(Frame(
            subject=folder.name, index=i, path=folder / "frames" / name,
            face=(fx, fy, fw, fh),
            left_eye=(fx + lx, fy + ly, lw, lh),
            right_eye=(fx + rx, fy + ry, rw, rh),
            target_cm=(float(dots["XCam"][i]), float(dots["YCam"][i])),
            target_points=(float(dots["XPts"][i]), float(dots["YPts"][i])),
            orientation=orientation, split=split, device=device,
        ))
    return frames


def read_dataset(root: str | Path, portrait_only: bool = True, limit: int | None = None) -> list[Frame]:
    """All subjects under ``root``, in numeric order."""
    root = Path(root)
    subjects = sorted((p for p in root.iterdir() if p.is_dir() and p.name.isdigit()), key=lambda p: int(p.name))
    frames: list[Frame] = []
    for subject in subjects[:limit]:
        frames.extend(read_subject(subject, portrait_only))
    return frames


def crop(image: np.ndarray, box: tuple[float, float, float, float], size: int = 64, pad: float = 0.25) -> np.ndarray:
    """A square crop around ``box`` widened by ``pad`` on each side, resized to ``size``.

    Square around the box centre so an eye is never stretched; padding so the eyelids
    and corners, which carry direction information, are inside the crop. Pure numpy so
    the same arithmetic can be checked against the on-device crop.
    """
    from PIL import Image  # local import keeps numpy-only callers free of the dependency

    x, y, w, h = box
    side = max(w, h) * (1 + 2 * pad)
    cx, cy = x + w / 2, y + h / 2
    left, top = cx - side / 2, cy - side / 2
    pil = Image.fromarray(image)
    region = pil.crop((int(round(left)), int(round(top)), int(round(left + side)), int(round(top + side))))
    return np.asarray(region.resize((size, size), Image.BILINEAR))


def direction_ratios(target_cm: tuple[float, float], eye_cm: tuple[float, float, float]) -> tuple[float, float]:
    """The gaze ratios dx/dz, dy/dz the target demands, in the display frame this project
    uses: X to the participant's right, Y up, the participant at negative Z.

    GazeCapture's XCam/YCam are centimetres relative to the camera in the *camera's* view
    of the screen plane, so the horizontal axis is mirrored relative to the participant.
    ``eye_cm`` is the eye position relative to the camera in the same display frame, which
    the dataset does not provide and must be estimated (a face fitter, or a constant
    reading distance as a first approximation).
    """
    tx, ty = -target_cm[0], target_cm[1]
    ex, ey, ez = eye_cm
    dz = -ez
    if dz <= 0:
        raise ValueError("eye must be in front of the display")
    return (tx - ex) / dz, (ty - ey) / dz
