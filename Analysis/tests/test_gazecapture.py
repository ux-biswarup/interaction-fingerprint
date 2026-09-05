import json
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from eyemodel import gazecapture as gc  # noqa: E402


def make_subject(tmp_path: Path) -> Path:
    folder = tmp_path / "00042"
    (folder / "frames").mkdir(parents=True)
    n = 3
    json.dump([f"{i:05d}.jpg" for i in range(n)], open(folder / "frames.json", "w"))
    json.dump(dict(X=[100, 110, 0], Y=[200, 210, 0], W=[300, 300, 0], H=[300, 300, 0], IsValid=[1, 1, 0]), open(folder / "appleFace.json", "w"))
    json.dump(dict(X=[60, 60, 0], Y=[90, 90, 0], W=[70, 70, 0], H=[40, 40, 0], IsValid=[1, 1, 1]), open(folder / "appleLeftEye.json", "w"))
    json.dump(dict(X=[170, 170, 0], Y=[90, 90, 0], W=[70, 70, 0], H=[40, 40, 0], IsValid=[1, 0, 1]), open(folder / "appleRightEye.json", "w"))
    json.dump(dict(DotNum=[0, 0, 1], XPts=[100, 100, 200], YPts=[300, 300, 400], XCam=[1.5, 1.5, -2.0], YCam=[-4.0, -4.0, -8.0], Time=[0.1, 0.2, 0.1]), open(folder / "dotInfo.json", "w"))
    json.dump(dict(H=[667, 667, 667], W=[375, 375, 375], Orientation=[1, 1, 1]), open(folder / "screen.json", "w"))
    json.dump(dict(Dataset="train", DeviceName="iPhone 6", TotalFrames=n), open(folder / "info.json", "w"))
    return folder


def test_read_subject_keeps_only_fully_detected_frames_and_places_eyes_in_image_pixels(tmp_path):
    frames = gc.read_subject(make_subject(tmp_path))
    assert [f.index for f in frames] == [0]
    f = frames[0]
    assert f.face == (100, 200, 300, 300)
    assert f.left_eye == (160, 290, 70, 40)
    assert f.right_eye == (270, 290, 70, 40)
    assert f.target_cm == (1.5, -4.0)
    assert f.split == "train" and f.device == "iPhone 6" and f.orientation == gc.PORTRAIT


def test_read_dataset_orders_subjects_numerically(tmp_path):
    for name in ("10", "2"):
        make_subject(tmp_path / name).rename(tmp_path / f"tmp{name}")
    for name in ("10", "2"):
        (tmp_path / name).rmdir()
        (tmp_path / f"tmp{name}").rename(tmp_path / name)
    frames = gc.read_dataset(tmp_path)
    assert [f.subject for f in frames] == ["2", "10"]


def test_crop_is_square_padded_and_resized():
    image = np.zeros((600, 800, 3), dtype=np.uint8)
    image[290:330, 160:230] = 255  # the eye box region
    out = gc.crop(image, (160, 290, 70, 40), size=32, pad=0.25)
    assert out.shape == (32, 32, 3)
    # The eye fills the middle of the crop, and the padding around it is dark.
    assert out[16, 16].mean() > 200
    assert out[1, 1].mean() < 50


def test_direction_ratios_use_the_display_frame():
    # Target 1.5 cm to the camera's right is to the participant's left: negative X.
    u, v = gc.direction_ratios((1.5, -4.0), (0.0, -1.0, -35.0))
    assert u == pytest.approx(-1.5 / 35)
    assert v == pytest.approx((-4.0 + 1.0) / 35)
    with pytest.raises(ValueError):
        gc.direction_ratios((0, 0), (0, 0, 10))
