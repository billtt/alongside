"""Predict the next observable behavior at a genuine transition in Smit (2023)."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np


SOURCE = "https://doi.org/10.6084/m9.figshare.23605842.v2"
DATA_MD5 = "fe800437c8897a22c3df0f3adbcdc8c6"
GROUPS = {
    "lie": ("Inactive_Lying.Crouch", "Inactive_Lying.Down", "Inactive_Lying.Resting",
            "Inactive_Lying.Sleeping"),
    "sit": ("Inactive_Sitting.Down", "Inactive_Sitting.Stationary", "Inactive_Sitting.Up"),
    "stand": ("Inactive_Standing.Stationary", "Inactive_Standing.Up"),
    "move": ("Active_Walking", "Active_Trotting"),
    "groom": ("Maintenance_Grooming",),
}
LABELS = tuple(GROUPS)
K = len(LABELS)
HIDDEN = 8
REGULARIZATION = 0.002
# Seconds are recorded at 1 Hz. Use fixed bins and four prior examples per
# context to keep the count model usable for previously unseen triples.
DURATION_CUTS = (2, 8, 32)
PRIOR_COUNT = 4
CLOCK_CUTS = (2, 8, 32, 128, 512)


def load_transitions(path):
    import pyreadr

    if hashlib.md5(path.read_bytes()).hexdigest() != DATA_MD5:
        raise ValueError("Expected anno_data.RDATA from Figshare v2. Check the download.")
    frame = pyreadr.read_r(str(path))["longanno"].sort_values(["Cat_id", "Timestamp"])
    flags = frame.drop(columns=["Cat_id", "Timestamp", "Pen"])
    current = np.full(len(frame), -1, dtype=int)
    # Other activity, occlusion, and simultaneous annotations break observable history.
    single_flag = flags.sum(axis=1).to_numpy() == 1
    for index, fields in enumerate(GROUPS.values()):
        in_group = flags[list(fields)].sum(axis=1).to_numpy() > 0
        current[single_flag & in_group] = index
    frame = frame.assign(label=current)
    if frame.duplicated(["Cat_id", "Timestamp"]).any():
        raise ValueError("Duplicate cat and timestamp in this version")
    examples = []
    segment_count = 0
    clocks = {}
    for cat, rows in frame.groupby("Cat_id", observed=True):
        # At each age count seconds for which the *following* second is observed,
        # then count how many such pairs have different states.
        exposure = np.zeros((K, len(CLOCK_CUTS) + 1), dtype=int)
        exits = np.zeros_like(exposure)
        seconds = rows.Timestamp.to_numpy(dtype="datetime64[s]").astype(np.int64)
        labels = rows.label.to_numpy()
        # Start a new chunk at every time gap or invalid observation. Invalid chunks
        # are skipped, including one-second ambiguous or missing behavior labels.
        boundary = (np.diff(seconds) != 1) | (labels[1:] < 0) | (labels[:-1] < 0)
        for chunk in np.split(labels, np.flatnonzero(boundary) + 1):
            if chunk[0] < 0:
                continue
            segment_count += 1
            starts = np.r_[0, np.flatnonzero(np.diff(chunk)) + 1]
            bouts = chunk[starts]
            ends = np.r_[starts[1:], len(chunk)]
            for i in range(1, len(bouts)):
                ended = i + 1 < len(bouts)
                duration = ends[i] - starts[i]
                last_observed_age = duration if ended else duration - 1
                bins = np.digitize(np.arange(1, last_observed_age + 1), CLOCK_CUTS)
                exposure[bouts[i]] += np.bincount(bins, minlength=exposure.shape[1])
                if ended:
                    exits[bouts[i], bins[-1]] += 1
            # First bout has unknown onset. Last bout has no observed exit.
            for i in range(1, len(bouts) - 1):
                examples.append((str(cat), bouts[i - 1], bouts[i],
                                 starts[i + 1] - starts[i], bouts[i + 1]))
        clocks[str(cat)] = np.stack((exposure, exits))
    counts = {"raw_rows": len(frame), "selected_seconds": int((current >= 0).sum()),
              "visible_chunks": segment_count, "observed_switches_used": len(examples),
              "source_out_of_sight_flags": int(flags.Other_Outofsight.sum())}
    return examples, counts, clocks


def rates(clock):
    exposure, exits = clock
    constant = (exits.sum(axis=1, keepdims=True) + 1) / (exposure.sum(axis=1, keepdims=True) + 2)
    by_age = (exits + PRIOR_COUNT * constant) / (exposure + PRIOR_COUNT)
    return constant, by_age


def clock_nll(clock, hazards):
    exposure, exits = clock
    return float(-(exits * np.log(hazards) + (exposure - exits) * np.log1p(-hazards)).sum()
                 / exposure.sum())


def features(previous, current, seconds):
    return np.column_stack([np.eye(K)[previous], np.eye(K)[current], np.log1p(seconds) / 4])


def distribution(logits, current):
    logits = np.array(logits, copy=True)
    logits[np.arange(len(current)), current] = -np.inf
    weights = np.exp(logits - logits.max(axis=1, keepdims=True))
    return weights / weights.sum(axis=1, keepdims=True)


def fit(previous, current, seconds, target):
    from scipy.optimize import minimize

    x = features(previous, current, seconds)
    rng = np.random.default_rng(67)
    dims = [(x.shape[1], HIDDEN), (HIDDEN,), (HIDDEN, K), (K,)]
    cuts = np.cumsum([np.prod(shape) for shape in dims])[:-1]

    def unpack(vector):
        return [part.reshape(shape) for part, shape in zip(np.split(vector, cuts), dims)]

    def objective(vector):
        w, b, v, c = unpack(vector)
        hidden = np.tanh(x @ w + b)
        probs = distribution(hidden @ v + c, current)
        loss = -np.log(probs[np.arange(len(x)), target]).mean()
        loss += REGULARIZATION * ((w * w).sum() + (v * v).sum()) / 2
        probs[np.arange(len(x)), target] -= 1
        probs /= len(x)
        dh = (probs @ v.T) * (1 - hidden ** 2)
        grads = [x.T @ dh + REGULARIZATION * w, dh.sum(axis=0),
                 hidden.T @ probs + REGULARIZATION * v, probs.sum(axis=0)]
        return loss, np.concatenate([g.ravel() for g in grads])

    initial = [rng.normal(0, 0.2, shape) if len(shape) == 2 else np.zeros(shape)
               for shape in dims]
    result = minimize(objective, np.concatenate([v.ravel() for v in initial]),
                      jac=True, method="L-BFGS-B", options={"maxiter": 500})
    if not result.success:
        raise RuntimeError(result.message)
    transitions = np.ones((K, K))
    np.add.at(transitions, (current, target), 1)
    marginal = np.bincount(target, minlength=K) + 1
    history = np.zeros((K, K, K))
    np.add.at(history, (previous, current, target), 1)
    timed = np.zeros((K, K, len(DURATION_CUTS) + 1, K))
    bins = np.digitize(seconds, DURATION_CUTS)
    np.add.at(timed, (previous, current, bins, target), 1)
    return {"weights": [w.tolist() for w in unpack(result.x)],
            "transition_counts_smoothed": transitions.tolist(),
            "next_counts_smoothed": marginal.tolist(),
            "history_counts": history.tolist(), "timed_counts": timed.tolist()}


def predict(model, previous, current, seconds):
    w, b, v, c = map(np.asarray, model["weights"])
    x = features(previous, current, seconds)
    counts = np.asarray(model["transition_counts_smoothed"])
    marginal = np.tile(model["next_counts_smoothed"], (len(x), 1))
    markov = distribution(np.log(counts[current]), current)
    history = np.asarray(model["history_counts"])[previous, current] + PRIOR_COUNT * markov
    history /= history.sum(axis=1, keepdims=True)
    bins = np.digitize(seconds, DURATION_CUTS)
    timed = np.asarray(model["timed_counts"])[previous, current, bins] + PRIOR_COUNT * history
    return {"frequency": distribution(np.log(marginal), current),
            "markov": markov, "timed_counts": timed / timed.sum(axis=1, keepdims=True),
            "network": distribution(np.tanh(x @ w + b) @ v + c, current)}


def train(args):
    examples, stats, clocks = load_transitions(args.data)
    cats = np.array([row[0] for row in examples])
    total_clock = np.sum(list(clocks.values()), axis=0)
    previous, current, seconds, target = np.asarray([row[1:] for row in examples]).T
    log_losses = {}
    hits = {}
    clock_scores = []
    for cat in np.unique(cats):
        valid = cats == cat
        model = fit(previous[~valid], current[~valid], seconds[~valid], target[~valid])
        clock_scores.append([clock_nll(clocks[cat], h) for h in rates(total_clock - clocks[cat])])
        estimates = predict(model, previous[valid], current[valid], seconds[valid])
        for name, probs in estimates.items():
            observed = target[valid]
            loss = -np.log(probs[np.arange(len(observed)), observed])
            log_losses.setdefault(name, []).append(loss)
            hits.setdefault(name, []).append(probs.argmax(axis=1) == observed)
    stats["held_out_cats"] = len(np.unique(cats))
    stats["clock_seconds_with_known_next_second"] = int(total_clock[0].sum())
    stats["clock_equal_cat_nll"] = dict(zip(("per_state", "per_state_and_age"),
                                             np.mean(clock_scores, axis=0).tolist()))
    stats["leave_one_cat_out"] = {
        name: {"event_weighted_nll": float(np.mean(np.concatenate(losses))),
               "event_weighted_top1": float(np.mean(np.concatenate(hits[name]))),
               "equal_cat_nll": float(np.mean([x.mean() for x in losses])),
               "equal_cat_top1": float(np.mean([x.mean() for x in hits[name]]))}
        for name, losses in log_losses.items()
    }
    model = fit(previous, current, seconds, target)
    model.update({"format": 1, "labels": LABELS, "training_data": SOURCE,
                  "attribution": "Michelle Smit (2023), CC BY 4.0",
                  "exit_probability_by_age": rates(total_clock)[1].tolist(),
                  "clock_age_cuts_seconds": CLOCK_CUTS,
                  "use": "Next behavior at a known switch and a separate 1 Hz exit clock."})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(model, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(stats, indent=2))


def read_model(path):
    model = json.loads(path.read_text(encoding="utf-8"))
    if model["format"] != 1 or tuple(model["labels"]) != LABELS:
        raise ValueError("Incompatible model format or behavioral vocabulary")
    return model


def export_app(args):
    model = read_model(args.model)
    keys = ("format", "labels", "weights", "clock_age_cuts_seconds", "exit_probability_by_age",
            "training_data", "attribution")
    result = {key: model[key] for key in keys}
    result["license_url"] = "https://creativecommons.org/licenses/by/4.0/"
    result["derivation"] = "Five merged activity labels; fitted tanh network and empirical exit rates."
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")


def infer(args):
    model = read_model(args.model)
    if args.previous == args.current or args.seconds < 1:
        raise ValueError("Use distinct previous and current bouts and a positive duration")
    previous, current = (np.array([LABELS.index(x)]) for x in (args.previous, args.current))
    prediction = predict(model, previous, current, np.array([args.seconds]))
    print(json.dumps(dict(zip(LABELS, prediction[args.method][0])), indent=2))


def rollout(args):
    model = read_model(args.model)
    if args.previous == args.current or args.seconds < 1:
        raise ValueError("Use distinct states and a positive simulation horizon")
    previous, current = (LABELS.index(state) for state in (args.previous, args.current))
    rng = np.random.default_rng(args.seed)
    start = 0
    trajectory = []
    for end in range(1, args.seconds + 1):
        age = end - start
        terminal = end == args.seconds
        age_bin = np.digitize(age, model["clock_age_cuts_seconds"])
        if not terminal and rng.random() >= model["exit_probability_by_age"][current][age_bin]:
            continue
        trajectory.append({"start": start, "end": end, "behavior": LABELS[current],
                           "end_reason": "horizon" if terminal else "switch"})
        if not terminal:
            probs = predict(model, np.array([previous]), np.array([current]), np.array([age]))
            previous, current = current, int(rng.choice(K, p=probs["network"][0]))
            start = end
    print(json.dumps(trajectory, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    training = commands.add_parser("train")
    training.add_argument("data", type=Path, help="Smit (2023), anno_data.RDATA v2")
    training.add_argument("--output", required=True, type=Path)
    training.set_defaults(run=train)
    export = commands.add_parser("export-app", help="Export the observed-cat network and rest clock for Swift")
    export.add_argument("model", type=Path)
    export.add_argument("output", type=Path)
    export.set_defaults(run=export_app)
    inference = commands.add_parser("next", help="Known exit from current bout")
    inference.add_argument("model", type=Path)
    inference.add_argument("--previous", required=True, choices=LABELS)
    inference.add_argument("--current", required=True, choices=LABELS)
    inference.add_argument("--seconds", required=True, type=int, help="Duration of current bout")
    inference.add_argument("--method", choices=["network", "timed_counts", "markov", "frequency"],
                           default="network")
    inference.set_defaults(run=infer)
    demo = commands.add_parser("rollout", help="Sample an offline trajectory, in seconds")
    demo.add_argument("model", type=Path)
    demo.add_argument("--previous", choices=LABELS, default="move")
    demo.add_argument("--current", choices=LABELS, default="sit")
    demo.add_argument("--seconds", type=int, default=120)
    demo.add_argument("--seed", type=int, default=67)
    demo.set_defaults(run=rollout)
    arguments = parser.parse_args()
    arguments.run(arguments)
