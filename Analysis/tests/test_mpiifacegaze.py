import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from eyemodel import mpiifacegaze as mf  # noqa: E402


def test_ratios_turn_image_left_into_the_participants_right_and_image_down_into_up():
    # A gaze from the face towards a target to the image-left and above (y down) of the camera.
    u, v = mf.ratios(np.array([-50.0, -20.0, -400.0]))
    assert u == pytest.approx(0.125) and v == pytest.approx(0.05)
    with pytest.raises(ValueError):
        mf.ratios(np.array([0.0, 0.0, 1.0]))


def test_head_forward_points_towards_the_camera_whatever_the_model_convention():
    forward = mf.head_forward(np.zeros(3))
    assert forward[2] < 0
    turned = mf.head_forward(np.array([0.0, 0.3, 0.0]))
    assert turned[2] < 0 and abs(np.linalg.norm(turned) - 1) < 1e-9


def test_parse_line_builds_eye_boxes_and_eye_in_head_label(tmp_path):
    fields = ["day01/0001.jpg", "640", "300"]
    landmarks = [300, 240, 340, 242, 400, 242, 440, 240, 330, 320, 410, 320]
    fields += [str(x) for x in landmarks]
    fields += ["0", "0", "0"]              # head rotation: identity
    fields += ["0", "0", "500"]            # head translation
    fields += ["0", "-20", "500"]          # face centre, mm
    fields += ["-100", "-120", "0"]        # gaze target on the screen plane
    fields += ["left"]
    frame = mf.parse_line("p00", tmp_path, " ".join(fields))
    assert frame is not None
    assert frame.left_eye[2] == pytest.approx(np.hypot(40, 2))
    # Identity head rotation: forward is (0,0,-1), head ratios are zero, so eye-in-head equals gaze.
    assert frame.head_ratios == (0.0, 0.0)
    u, v = frame.gaze_ratios
    assert u == pytest.approx(-100 / -500) and v == pytest.approx(-100 / -500)
    assert frame.eye_in_head == frame.gaze_ratios
    assert frame.distance_mm == pytest.approx(np.hypot(20, 500))
