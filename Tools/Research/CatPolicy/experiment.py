"""Synthetic local experiment. Run with python3 -B Tools/Research/CatPolicy/experiment.py."""

import argparse
import hashlib
import json
import tempfile
from pathlib import Path

import numpy as np


SCHEMA = "synthetic-desktop-intents-v1"
FEATURES = ["recent_head_touch", "recent_sensitive_touch", "disturbance", "rest_drive",
            "elapsed_in_pose", "pointer_nearness"]
INTENTS = ["rest", "look", "groom", "withdraw"]
REST, LOOK, GROOM, WITHDRAW = range(4)


def scenes(rng, count):
    """Independent decision opportunities. Both touch flags refer to the same last event."""
    x = rng.random((count, len(FEATURES)))
    event = rng.choice(3, size=count, p=[0.5, 0.38, 0.12])
    x[:, 0] = event == 1
    x[:, 1] = event == 2
    return x


def gentle(x):
    return (x[:, 0] == 1) & (x[:, 2] < 0.45)


def softmax(scores):
    exp = np.exp(scores - scores.max(axis=1, keepdims=True))
    return exp / exp.sum(axis=1, keepdims=True)


def teacher(x, quiet_shift=0.0):
    """Invented distributions supply ground truth for this engineering test only."""
    head, sensitive, disturbance, tired, elapsed, near = x.T
    return softmax(np.column_stack([
        0.6 + 1.8 * tired - 1.2 * elapsed - 0.8 * head + quiet_shift * gentle(x),
        -0.4 + 2.2 * head + near - tired - 1.5 * head * disturbance,
        -0.7 + 1.8 * elapsed - head - sensitive - near,
        -1.9 + 3.3 * sensitive + 3.0 * disturbance * (head + sensitive),
    ]))


def draw(rng, probabilities):
    return (rng.random((len(probabilities), 1)) > probabilities.cumsum(axis=1)[:, :-1]).sum(axis=1)


def nll(probabilities, labels):
    return -np.log(probabilities[np.arange(len(labels)), labels]).mean()


def network(rng):
    return [rng.normal(0, 0.45, (6, 16)), np.zeros(16),
            rng.normal(0, 0.3, (16, 4)), np.zeros(4)]


def predict(weights, x):
    w1, b1, w2, b2 = weights
    return softmax(np.tanh(x @ w1 + b1) @ w2 + b2)


def fit(weights, x, labels, rng, epochs, rate):
    """Minibatch gradient descent on sampled categorical labels."""
    w1, b1, w2, b2 = weights
    for _ in range(epochs):
        order = rng.permutation(len(x))
        for start in range(0, len(x), 128):
            ix = order[start:start + 128]
            hidden = np.tanh(x[ix] @ w1 + b1)
            error = softmax(hidden @ w2 + b2)
            error[np.arange(len(ix)), labels[ix]] -= 1
            error /= len(ix)
            delta = (error @ w2.T) * (1 - hidden ** 2)
            w1 -= rate * x[ix].T @ delta
            b1 -= rate * delta.sum(axis=0)
            w2 -= rate * hidden.T @ error
            b2 -= rate * error.sum(axis=0)


def new_profile(base_hash):
    return {"schema": SCHEMA, "trained_against": base_hash, "look_votes": 0, "rest_votes": 0}


def personalize(base_p, x, profile):
    """Tilt only the look/rest odds in eligible contexts, preserving their total mass."""
    if profile["schema"] != SCHEMA:
        raise ValueError("Incompatible feature/action schema")
    odds = np.clip((2 + profile["look_votes"]) / (2 + profile["rest_votes"]), 0.2, 5.0)
    p = base_p.copy()
    ix = gentle(x)
    mass = p[ix, LOOK] + p[ix, REST]
    weighted_look = p[ix, LOOK] * odds
    p[ix, LOOK] = mass * weighted_look / (p[ix, REST] + weighted_look)
    p[ix, REST] = mass - p[ix, LOOK]
    return p


def feedback_log(base, contexts, profile, likes_look, rng):
    for row in contexts:
        x = row[None, :]
        intent = draw(rng, personalize(predict(base, x), x, profile))[0]
        if not gentle(x)[0] or intent not in (LOOK, REST) or rng.random() >= 0.5:
            continue  # No explicit answer counts as missing.
        preferred = (intent == LOOK) == likes_look
        approved = rng.random() < (0.8 if preferred else 0.2)
        # The simulated owners have symmetric binary preferences between the two options.
        look_vote = (intent == LOOK) == approved
        profile["look_votes" if look_vote else "rest_votes"] += 1


def assess(base, x, profile):
    base_p = predict(base, x)
    p = personalize(base_p, x, profile)
    ix = gentle(x)
    np.testing.assert_allclose(p.sum(axis=1), 1, atol=1e-12)
    np.testing.assert_array_equal(p[:, [GROOM, WITHDRAW]], base_p[:, [GROOM, WITHDRAW]])
    np.testing.assert_array_equal(p[~ix], base_p[~ix])
    np.testing.assert_allclose(p[ix, REST] + p[ix, LOOK], base_p[ix, REST] + base_p[ix, LOOK])
    # P(look | gentle scene, action in {look, rest}), where scenes are equally sampled.
    return p[ix, LOOK].sum() / (p[ix, LOOK].sum() + p[ix, REST].sum())


def save(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, sort_keys=True) + "\n")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save_base(path, weights):
    return save(path, {"schema": SCHEMA, "features": FEATURES, "intents": INTENTS,
                       "weights": [w.tolist() for w in weights]})


def load_base(path):
    data = json.loads(path.read_text())
    if (data["schema"], data["features"], data["intents"]) != (SCHEMA, FEATURES, INTENTS):
        raise ValueError("Incompatible feature/action schema")
    return [np.asarray(w) for w in data["weights"]]


def experiment(directory):
    train_rng = np.random.default_rng(430)
    test_rng = np.random.default_rng(431)
    x_train, x_test = scenes(train_rng, 8192), scenes(test_rng, 4096)
    y_train, y_test = draw(train_rng, teacher(x_train)), draw(test_rng, teacher(x_test))
    base = network(train_rng)
    fit(base, x_train, y_train, train_rng, epochs=60, rate=0.1)
    base_file = directory / "base-v1.json"
    base_hash = save_base(base_file, base)
    base = load_base(base_file)
    freq = np.bincount(y_train, minlength=4) / len(y_train)
    print(f"base parameters={sum(w.size for w in base)}  train={len(x_train)}  test={len(x_test)}")
    print(f"held-out NLL, nats: frequencies={-np.log(freq[y_test]).mean():.3f}  "
          f"network={nll(predict(base, x_test), y_test):.3f}")

    profiles = {"neutral": new_profile(base_hash)}
    profile_hashes = {}
    exposure = scenes(np.random.default_rng(432), 1500)
    for owner, likes_look in [("likes-look", True), ("likes-rest", False)]:
        profile = new_profile(base_hash)
        feedback_log(base, exposure, profile, likes_look, np.random.default_rng(433))
        path = directory / f"{owner}.json"
        profile_hashes[path] = save(path, profile)
        profiles[owner] = json.loads(path.read_text())
        print(f"{owner}: {profile['look_votes'] + profile['rest_votes']} explicit ratings / {len(exposure)} scenes")
    assert hashlib.sha256(base_file.read_bytes()).hexdigest() == base_hash
    for before, after in zip(load_base(base_file), base):
        np.testing.assert_array_equal(before, after)

    # Continue v1 from disk with a deliberately different synthetic observation distribution.
    v2 = load_base(base_file)
    upgrade_rng = np.random.default_rng(434)
    x_new = scenes(upgrade_rng, 8192)
    fit(v2, x_new, draw(upgrade_rng, teacher(x_new, quiet_shift=1.5)), upgrade_rng,
        epochs=45, rate=0.06)
    v2_file = directory / "base-v2.json"
    save_base(v2_file, v2)
    y_new_test = draw(np.random.default_rng(435), teacher(x_test, quiet_shift=1.5))
    print(f"shifted held-out NLL, nats: v1={nll(predict(base, x_test), y_new_test):.3f}  "
          f"v2={nll(predict(v2, x_test), y_new_test):.3f}")
    print(f"held-out gentle scenes={gentle(x_test).sum()}")
    for version, candidate in [("v1", load_base(base_file)), ("v2", load_base(v2_file))]:
        for owner, profile in profiles.items():
            print(f"{version}  {owner:10s}  P(look | gentle, look or rest)={assess(candidate, x_test, profile):.3f}")
    assert all(hashlib.sha256(p.read_bytes()).hexdigest() == h for p, h in profile_hashes.items())
    print("Verified identical v1 base and profile files across independent updates.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, help="Keep both base versions and both profiles here.")
    args = parser.parse_args()
    if args.output_dir:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        experiment(args.output_dir)
    else:
        with tempfile.TemporaryDirectory() as temp:
            experiment(Path(temp))
