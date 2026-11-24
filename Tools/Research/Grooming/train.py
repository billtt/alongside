"""Fit a conditional model of co-groomed regions from observed time shares."""
import argparse
import csv
import hashlib
import itertools
import json
import re
import zipfile
from pathlib import Path
from xml.etree import ElementTree

import numpy as np
from scipy.optimize import minimize
from scipy.special import logsumexp

DOI = "https://doi.org/10.17632/x5c38ztg9m.1"
SHA256 = "3b3506e6f85aa463cefe0954d7e742c6fea8ead2ff2f98ddd37d9ea53603046f"
REGIONS = ["paw_face", "chest", "shoulder_flank", "hind_paw"]
# These are disjoint, explicitly named target columns in the authors' table.
TARGET_COLUMNS = [("J", "K", "L", "M", "N", "O", "T"), ("Q",), ("R", "V"), ("Y",)]
K, HIDDEN = len(REGIONS), 6


def read_bouts(path):
    if hashlib.sha256(path.read_bytes()).hexdigest() != SHA256:
        raise ValueError("Expected the original Mendeley v1 workbook.")
    ns = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
    with zipfile.ZipFile(path) as book:
        strings = ["".join(node.itertext()) for node in ElementTree.fromstring(book.read("xl/sharedStrings.xml"))]
        sheet = ElementTree.fromstring(book.read("xl/worksheets/sheet1.xml"))
    cats, shares, included, bout_ids = [], [], [], set()
    for row in sheet.iter(ns + "row"):
        cells = {}
        for cell in row.findall(ns + "c"):
            value = cell.findtext(ns + "v")
            if value is not None:
                column = re.fullmatch(r"([A-Z]+)[0-9]+", cell.get("r")).group(1)
                cells[column] = strings[int(value)] if cell.get("t") == "s" else value
        if not cells.get("D", "").isdigit():
            continue
        if cells["D"] in bout_ids:
            raise ValueError("Duplicate bout ID")
        bout_ids.add(cells["D"])
        sites = np.array([sum(float(cells[col]) for col in columns) for columns in TARGET_COLUMNS])
        if sites.sum() > 0:
            cats.append("mendeley/" + cells["A"])
            shares.append(sites / sites.sum())
            included.append(sites.sum())
    print(f"{len(bout_ids)} bouts; {len(shares)} with drawable sites; {len(set(cats))} held-out cat groups; "
          f"mean drawable time share {np.mean(included):.2f}%")
    return np.array(cats), np.array(shares)

def add_observations(paths, cats, shares):
    """Accept measured, per-bout seconds. Group the same animal across recordings."""
    seen, added, extra = set(), [], []
    for path in paths:
        with path.open(newline="", encoding="utf-8-sig") as stream:
            rows = csv.DictReader(stream)
            required = ["cohort", "cat_id", "bout_id"] + [s + "_seconds" for s in REGIONS]
            if not set(required).issubset(rows.fieldnames or []):
                raise ValueError(f"{path}: expected columns {required}")
            for row in rows:
                cohort, cat, bout = (row[name].strip() for name in required[:3])
                if not all((cohort, cat, bout)) or cohort == "mendeley" or "/" in cohort or "/" in cat:
                    raise ValueError(f"{path}, line {rows.line_num}: use stable, nonempty local IDs")
                key = (cohort, cat, bout)
                if key in seen:
                    raise ValueError(f"{path}, line {rows.line_num}: duplicate bout")
                seen.add(key)
                seconds = np.array([float(row[name]) for name in required[3:]])
                if not np.isfinite(seconds).all() or (seconds < 0).any() or seconds.sum() <= 0:
                    raise ValueError(f"{path}, line {rows.line_num}: invalid drawable seconds")
                added.append(cohort + "/" + cat)
                extra.append(seconds / seconds.sum())
    if extra:
        print(f"adding {len(extra)} local bouts across {len(set(added))} cats")
        return np.r_[cats, np.array(added)], np.vstack([shares, extra])
    return cats, shares


def moments(cats, shares):
    """Exact expected labels, no pseudoreplicated random pairs. Cats have equal weight."""
    importance = np.array([1 / np.sum(cats == cat) for cat in cats]) / len(set(cats))
    features, masses = [], []
    for n in range(3):
        for sites in itertools.combinations_with_replacement(range(K), n):
            count = np.bincount(np.array(sites, dtype=int), minlength=K)
            chance = np.prod(shares[:, sites], axis=1)
            if len(set(sites)) == 2:
                chance *= 2  # group the two possible orders of these unordered observations
            masses.append((importance * chance) @ shares / 3)
            features.append(count / 2)
    return np.array(features), np.array(masses)


def train(x, masses):
    shapes = [(K, HIDDEN), (HIDDEN,), (HIDDEN, K), (K,)]
    offsets = np.cumsum([np.prod(s) for s in shapes])[:-1]

    def unpack(vector):
        return [p.reshape(s) for p, s in zip(np.split(vector, offsets), shapes)]

    def objective(vector):
        w, b, v, c = unpack(vector)
        h = np.tanh(x @ w + b)
        z = h @ v + c
        logged = z - logsumexp(z, axis=1, keepdims=True)
        err = masses.sum(axis=1, keepdims=True) * np.exp(logged) - masses
        dh = (err @ v.T) * (1 - h*h)
        ridge = 0.0003
        loss = -(masses * logged).sum() + ridge * ((w*w).sum() + (v*v).sum()) / 2
        grads = [x.T @ dh + ridge*w, dh.sum(axis=0), h.T @ err + ridge*v, err.sum(axis=0)]
        return loss, np.concatenate([g.ravel() for g in grads])

    rng = np.random.default_rng(2411)
    initial = [rng.normal(0, 0.2, shape) if len(shape) == 2 else np.zeros(shape) for shape in shapes]
    result = minimize(objective, np.concatenate([p.ravel() for p in initial]), jac=True,
                      method="L-BFGS-B", options={"maxiter": 600})
    if not result.success:
        raise RuntimeError(result.message)
    return unpack(result.x)


def predict(weights, x):
    w, b, v, c = weights
    scores = np.tanh(x @ w + b) @ v + c
    return np.exp(scores - logsumexp(scores, axis=1, keepdims=True))


def run(path, output, additional):
    cats, shares = read_bouts(path)
    cats, shares = add_observations(additional, cats, shares)
    results = []
    for cat in sorted(set(cats)):
        held = cats == cat
        x, masses = moments(cats[~held], shares[~held])
        _, targets = moments(cats[held], shares[held])
        # Once at least one site has been observed, predict another draw.
        population = masses[0] / masses[0].sum()
        network = predict(train(x, masses), x)
        conditional = masses + 0.001 * population
        conditional /= conditional.sum(axis=1, keepdims=True)
        def loss(p):
            return -(targets[1:] * np.log(p)).sum() / targets[1:].sum()
        results.append([loss(population), loss(conditional[1:]), loss(network[1:])])
    mean = np.array(results).mean(axis=0)
    print("conditional cross-entropy (equal weight per held-out cat): population %.4f, "
          "smoothed co-occurrence table %.4f, neural %.4f" % tuple(mean))
    x, masses = moments(cats, shares)
    weights = train(x, masses)
    artifact = {"schema": "dada-grooming-time-share-v1", "regions": REGIONS,
                "weights": [v.tolist() for v in weights],
                "source": DOI, "attribution": "Manuela Schmidt (2025), Organization of Grooming in Domestic Cats 2025, v1",
                "license": "https://creativecommons.org/licenses/by/4.0/",
                "derivation": "Fitted on unordered within-bout proportions of four groups of observable targets."}
    artifact["observations"] = {"bouts": len(shares), "cats": len(set(cats)),
                                "additional_file_sha256": [hashlib.sha256(p.read_bytes()).hexdigest() for p in additional]}
    artifact["checks"] = []
    for history in [[], [0, 0], [3, 3]]:
        x = np.bincount(np.array(history, dtype=int), minlength=K)[None, :] / 2
        probabilities = predict(weights, x)[0]
        artifact["checks"].append({"history": [REGIONS[i] for i in history], "probabilities": probabilities.tolist()})
        print(f"history {history}: {probabilities.round(6)}")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(artifact, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workbook", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--additional", type=Path, action="append", default=[],
                        help="CSV of measured seconds per drawable region; may be repeated")
    args = parser.parse_args()
    run(args.workbook, args.output, args.additional)
