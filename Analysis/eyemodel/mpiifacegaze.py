"""Reader for MPIIFaceGaze (Zhang, Sugano, Fritz, Bulling, CVPRW 2017).

Direct download, no registration, CC BY-NC-SA 4.0, cite the paper. Fifteen participants
recorded on their own laptops over months, about 45,000 frames with:

    pXX/pXX.txt           one line per frame, 28 fields:
        1      image path relative to pXX/
        2-3    gaze target on screen, pixels
        4-15   six facial landmarks (x, y): four eye corners, two mouth corners
        16-18  head rotation, Rodrigues vector, camera coordinates
        19-21  head translation, mm
        22-24  face centre, 3D camera coordinates, mm
        25-27  gaze target, 3D camera coordinates, mm
        28     which eye the evaluation subset used
    pXX/Calibration/      Camera.mat, monitorPose.mat, screenSize.mat

Unlike GazeCapture this carries head pose, so the label this project needs, the eyes'
rotation within the head, follows directly: gaze direction from the face centre to the
target, minus the head's forward direction, both as ratios in the display frame.

Camera coordinates are OpenCV's: x right in the image, y down, z away from the camera
towards the person. The display frame is X to the participant's right, Y up, Z from the
participant towards the screen. Image-right is the participant's left, so u = dx/dz and
v = dy/dz come out with the right signs without any explicit flip.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np


@dataclass(frozen=True)
class FaceFrame:
    subject: str
    path: Path
    left_eye: tuple[float, float, float, float]   # image pixels, participant's left eye
    right_eye: tuple[float, float, float, float]
    head_ratios: tuple[float, float]              # head forward direction, u and v
    gaze_ratios: tuple[float, float]              # true gaze direction, u and v
    distance_mm: float

    @property
    def eye_in_head(self) -> tuple[float, float]:
        return (self.gaze_ratios[0] - self.head_ratios[0], self.gaze_ratios[1] - self.head_ratios[1])


def rodrigues(rvec: np.ndarray) -> np.ndarray:
    theta = np.linalg.norm(rvec)
    if theta < 1e-12:
        return np.eye(3)
    k = rvec / theta
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + np.sin(theta) * K + (1 - np.cos(theta)) * (K @ K)


def ratios(direction: np.ndarray) -> tuple[float, float]:
    """dx/dz and dy/dz of a direction in OpenCV camera coordinates that points from the
    person towards the camera, so dz < 0. The division by a negative dz is what turns
    image-left into the participant's right and image-down into up."""
    dx, dy, dz = direction
    if dz >= -1e-9:
        raise ValueError("direction must point towards the camera")
    return float(dx / dz), float(dy / dz)


def eye_box(outer: np.ndarray, inner: np.ndarray, aspect: float = 0.6) -> tuple[float, float, float, float]:
    """A box from two eye corners: width the corner distance, height a fixed fraction."""
    width = float(np.linalg.norm(outer - inner))
    centre = (outer + inner) / 2
    height = width * aspect
    return (float(centre[0] - width / 2), float(centre[1] - height / 2), width, height)


def head_forward(rvec: np.ndarray) -> np.ndarray:
    """The face model's forward axis in camera coordinates, pointing towards the camera.

    The sign convention of the generic face model is not something to assume; the axis is
    taken with whichever sign points towards the camera, which for a person facing their
    own screen is the only physical possibility.
    """
    axis = rodrigues(rvec) @ np.array([0.0, 0.0, 1.0])
    return axis if axis[2] < 0 else -axis


def parse_line(subject: str, root: Path, line: str) -> FaceFrame | None:
    fields = line.split()
    if len(fields) < 27:
        return None
    values = np.array([float(x) for x in fields[1:27]])
    landmarks = values[2:14].reshape(6, 2)
    rvec = values[14:17]
    face_centre = values[20:23]
    target = values[23:26]
    gaze = target - face_centre
    try:
        gaze_ratios = ratios(gaze)
        head_ratios = ratios(head_forward(rvec))
    except ValueError:
        return None
    # Landmark order: participant's left eye outer, inner; right eye inner, outer (the
    # dataset lists the four eye corners left to right in the image), then mouth corners.
    left_eye = eye_box(landmarks[0], landmarks[1])
    right_eye = eye_box(landmarks[3], landmarks[2])
    return FaceFrame(
        subject=subject, path=root / fields[0],
        left_eye=left_eye, right_eye=right_eye,
        head_ratios=head_ratios, gaze_ratios=gaze_ratios,
        distance_mm=float(np.linalg.norm(face_centre)),
    )


def read_subject(folder: str | Path) -> list[FaceFrame]:
    folder = Path(folder)
    annotation = folder / f"{folder.name}.txt"
    frames = []
    with open(annotation) as f:
        for line in f:
            frame = parse_line(folder.name, folder, line)
            if frame is not None:
                frames.append(frame)
    return frames


def read_dataset(root: str | Path, limit: int | None = None) -> list[FaceFrame]:
    root = Path(root)
    subjects = sorted(p for p in root.iterdir() if p.is_dir() and p.name.startswith("p") and (p / f"{p.name}.txt").exists())
    frames: list[FaceFrame] = []
    for subject in subjects[:limit]:
        frames.extend(read_subject(subject))
    return frames
