"""The display geometry the app uses, reproduced exactly."""
from __future__ import annotations

import numpy as np

POINT_WIDTH = 393
POINT_HEIGHT = 852
DISPLAY_SCALE = 3
PIXELS_PER_INCH = 460  # every Face ID iPhone at 3x
METRES_PER_PIXEL = 0.0254 / PIXELS_PER_INCH
PHYSICAL_WIDTH = POINT_WIDTH * DISPLAY_SCALE * METRES_PER_PIXEL
PHYSICAL_HEIGHT = POINT_HEIGHT * DISPLAY_SCALE * METRES_PER_PIXEL
METRES_PER_POINT = PHYSICAL_WIDTH / POINT_WIDTH


def target_metres(tx, ty):
    """Normalised screen position, origin top left, to display-frame metres."""
    return (np.asarray(tx) - 0.5) * PHYSICAL_WIDTH, -(np.asarray(ty) * PHYSICAL_HEIGHT)


def normalised(hx, hy):
    """Display-frame metres back to normalised screen position."""
    return np.asarray(hx) / PHYSICAL_WIDTH + 0.5, -np.asarray(hy) / PHYSICAL_HEIGHT


def true_direction(frame):
    """The gaze ratios the target demanded, given where the eye was."""
    tx, ty = target_metres(frame["tx"].values, frame["ty"].values)
    return (tx - frame["eyeX"].values) / frame["distance"].values, (ty - frame["eyeY"].values) / frame["distance"].values


def points_error(px, py, tx, ty):
    return np.hypot((np.asarray(px) - tx) * POINT_WIDTH, (np.asarray(py) - ty) * POINT_HEIGHT)


def degrees(points, distance):
    return np.degrees(np.arctan(points * METRES_PER_POINT / distance))
