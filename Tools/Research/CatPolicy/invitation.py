"""Fit the desktop invitation policy to a synthetic, versioned behavior design.

    python3 -B Tools/Research/CatPolicy/invitation.py /tmp/invitation-v1.json

Inputs are normalized dwell at the face, sideways lead speed, rest drive and recent
disturbance. Only gestures already recognized by InvitationGesture enter the model.
No human preference log or real cat response to a cursor was used in training.
"""
import argparse
import json
from pathlib import Path

import numpy as np

from experiment import fit, nll, predict


def examples(seed, count):
    rng = np.random.default_rng(seed)
    x = rng.uniform(size=(count, 4))
    dwell, speed, rest, disturbance = x.T
    # A quiet invitation at a moderate pace merits consideration. Repeated
    # disturbance makes a long dwell less persuasive. These are design targets.
    score = (1.05 + 1.20 * dwell + 0.68 * (1 - (2 * speed - 1) ** 2)
             - 1.25 * rest - 2.65 * disturbance - 0.90 * disturbance * dwell)
    wants_follow = rng.random(count) < 1 / (1 + np.exp(-score))
    return x, wants_follow.astype(int)


def main(output):
    x, y = examples(1701, 8192)
    test_x, test_y = examples(1702, 4096)
    rng = np.random.default_rng(1703)
    weights = [rng.normal(0, 0.45, (4, 8)), np.zeros(8),
               rng.normal(0, 0.3, (8, 2)), np.zeros(2)]
    fit(weights, x, y, rng, epochs=100, rate=0.09)
    test_loss = nll(predict(weights, test_x), test_y)
    frequencies = np.bincount(y) / len(y)
    baseline = -np.log(frequencies[test_y]).mean()
    data = {
        "schema": "desktop-invitation-v1",
        "features": ["face_dwell", "lead_speed", "rest_drive", "disturbance"],
        "intents": ["stay", "follow"],
        "weights": [layer.tolist() for layer in weights],
        "source": "Alongside simulated desktop invitation responses, invitation.py (seeds 1701..1703)",
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(data, indent=2) + "\n")
    print(f"synthetic scenes train={len(y)} holdout={len(test_y)}; "
          f"holdout NLL network={test_loss:.3f}, fixed frequency={baseline:.3f}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="Destination for trained weights")
    main(parser.parse_args().output)
