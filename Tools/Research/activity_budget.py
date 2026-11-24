"""Compare group and individual weekly activity budgets from Smit's home-cat study.

    python3 Tools/Research/activity_budget.py --download
    python3 Tools/Research/activity_budget.py /path/to/Weekly_Data.csv

Michelle Smit, Weekly data cats for home trial (2023), v2, CC BY 4.0.
https://doi.org/10.6084/m9.figshare.24848292.v2
"""

import argparse
import csv
import hashlib
import io
import statistics
import subprocess
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path


FILE_URL = "https://ndownloader.figshare.com/files/43720347"
SHA256 = "f340b5620f651b65e37dc0fabb3abcb633262edf6ef007e8f2b496a5490eb484"
BEHAVIORS = ("Active", "Lying", "Sitting", "Standing", "Grooming", "Littering", "Eating", "Scratching")


@dataclass
class Cat:
    owner: str
    summer: tuple
    winter: tuple


def parse(data):
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError("Expected the original Weekly_Data.csv from Figshare v2.")
    observations = defaultdict(dict)
    for row in csv.DictReader(io.StringIO(data.decode("utf-8-sig"))):
        counts = [int(row[name]) for name in BEHAVIORS]
        total = int(row["Total"])
        assert sum(counts) == total
        pair = observations[row["Owner"], row["Cat_id"]]
        season = row["Season"].lower()
        assert season not in pair
        pair[season] = tuple(count / total for count in counts)
    return [Cat(owner, **pair) for (owner, _), pair in observations.items()]


def population(cats):
    return tuple(map(statistics.mean, zip(*(cat.winter for cat in cats))))


def error(cat, group, weight):
    predicted = ((1 - weight) * base + weight * own for base, own in zip(group, cat.summer))
    return 0.5 * sum(abs(a - b) for a, b in zip(predicted, cat.winter))


def fit_weight(training):
    # Inner household splits select how much to trust the individual's summer week.
    pairs = [(cat, population([other for other in training if other.owner != cat.owner]))
             for cat in training]
    weights = [step / 20 for step in range(21)]
    return min(weights, key=lambda w: sum(error(cat, group, w) for cat, group in pairs))


def evaluate(cats):
    errors = defaultdict(list)
    weights = []
    for owner in sorted({cat.owner for cat in cats}):
        training = [cat for cat in cats if cat.owner != owner]
        group = population(training)
        weight = fit_weight(training)
        weights.append(weight)
        for cat in cats:
            if cat.owner == owner:
                for label, w in (("group only", 0), ("own summer only", 1), ("blend", weight)):
                    errors[label].append(error(cat, group, w))

    print(f"{len(cats)} paired cats, {len(weights)} households, eight observed behaviors")
    print("Mean measured winter time share (equal weight per cat)")
    for name, fraction in zip(BEHAVIORS, population(cats)):
        print(f"  {name:<12} {fraction:>7.2%}")
    print("Predict winter distribution; mean total variation distance (lower is better)")
    for label, values in errors.items():
        print(f"  {label:<16} {statistics.mean(values):.4f}")
    print(f"Summer weights selected in training folds: {min(weights):.2f}..{max(weights):.2f}")
    wins = sum(blend < group for blend, group in zip(errors["blend"], errors["group only"]))
    print(f"Blend improves over group for {wins}/{len(cats)} cats")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("csv", type=Path, nargs="?")
    source.add_argument("--download", action="store_true", help="read the verified 15 KB CSV from Figshare")
    args = parser.parse_args()
    if args.download:
        original = subprocess.check_output(["curl", "-fsSL", "--max-time", "30", FILE_URL])
    else:
        original = args.csv.read_bytes()
    evaluate(parse(original))
