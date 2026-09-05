"""A small convolutional network for the eye-in-head direction.

Two eye crops in, two numbers out: the gaze direction ratios ``(u, v)`` the crops imply,
in the display frame. Deliberately small, a few million multiply-adds per frame, so that it
runs at 60 Hz on the iPhone 15's Neural Engine once converted to Core ML. Bigger networks
buy little here: the published phone results all sit near 2 cm whatever the backbone, and
the per-person calibration on top does the rest.
"""
from __future__ import annotations

import torch
from torch import nn


class EyeBranch(nn.Module):
    def __init__(self, channels: int = 1):
        super().__init__()
        self.net = nn.Sequential(
            nn.Conv2d(channels, 16, 5, padding=2), nn.ReLU(), nn.MaxPool2d(2),   # 64 -> 32
            nn.Conv2d(16, 32, 3, padding=1), nn.ReLU(), nn.MaxPool2d(2),         # 32 -> 16
            nn.Conv2d(32, 64, 3, padding=1), nn.ReLU(), nn.MaxPool2d(2),         # 16 -> 8
            nn.Conv2d(64, 64, 3, padding=1), nn.ReLU(), nn.AdaptiveAvgPool2d(2), # 8 -> 2
            nn.Flatten(),
        )

    def forward(self, x):
        return self.net(x)


class EyeInHeadNet(nn.Module):
    """Left and right eye crops, optional auxiliary features, to ``(u, v)``.

    ``aux`` carries whatever the caller knows that the crops do not: the head direction
    ratios from ARKit on device, or on GazeCapture the face box position and size, which
    stand in for head pose and distance. Its width is a constructor argument so the same
    network serves both.
    """

    def __init__(self, aux_features: int = 0, channels: int = 1):
        super().__init__()
        self.left = EyeBranch(channels)
        self.right = EyeBranch(channels)
        self.aux_features = aux_features
        width = 64 * 4 * 2 + aux_features
        self.head = nn.Sequential(
            nn.Linear(width, 128), nn.ReLU(),
            nn.Linear(128, 64), nn.ReLU(),
            nn.Linear(64, 2),
        )

    def forward(self, left: torch.Tensor, right: torch.Tensor, aux: torch.Tensor | None = None) -> torch.Tensor:
        features = [self.left(left), self.right(right)]
        if self.aux_features:
            if aux is None:
                raise ValueError("aux features expected")
            features.append(aux)
        return self.head(torch.cat(features, dim=1))


def parameter_count(model: nn.Module) -> int:
    return sum(p.numel() for p in model.parameters())
