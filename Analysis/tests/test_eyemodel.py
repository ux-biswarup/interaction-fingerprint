import sys
from pathlib import Path

import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from eyemodel.model import EyeInHeadNet, parameter_count  # noqa: E402
from eyemodel.train import degrees_error  # noqa: E402


def test_network_is_small_and_learns_a_synthetic_direction():
    torch.manual_seed(0)
    model = EyeInHeadNet(aux_features=4)
    assert parameter_count(model) < 400_000  # comfortably 60 Hz on the Neural Engine

    # Synthetic eyes: a bright pupil whose horizontal position encodes u and vertical v.
    def sample(n):
        u = torch.rand(n) * 0.4 - 0.2
        v = torch.rand(n) * 0.4 - 0.2
        left = torch.zeros(n, 1, 64, 64)
        for i in range(n):
            cx, cy = int(32 + u[i] * 100), int(32 + v[i] * 100)
            left[i, 0, max(cy - 3, 0):cy + 3, max(cx - 3, 0):cx + 3] = 1.0
        return left, left.clone(), torch.zeros(n, 4), torch.stack([u, v], 1)

    left, right, aux, label = sample(256)
    optimiser = torch.optim.Adam(model.parameters(), lr=3e-3)
    for _ in range(90):
        pred = model(left, right, aux)
        loss = ((pred - label) ** 2).mean()
        optimiser.zero_grad()
        loss.backward()
        optimiser.step()
    tl, tr, ta, tlabel = sample(128)
    with torch.no_grad():
        err = degrees_error(model(tl, tr, ta), tlabel).mean().item()
    assert err < 3.0, f"synthetic held-out error {err:.2f} degrees"


def test_degrees_error_is_zero_for_identical_directions_and_grows_with_angle():
    a = torch.tensor([[0.0, 0.0], [0.1, 0.0]])
    # float32 puts the cosine a hair under one; acos of that is a few hundredths of a degree.
    assert degrees_error(a, a).max().item() < 0.1
    b = torch.tensor([[0.0, 0.0], [0.0, 0.0]])
    e = degrees_error(a, b)
    assert abs(e[1].item() - 5.71) < 0.05  # atan(0.1)
