"""Fit eye movement rates to Humphrey et al. (2020), Table S1, from the original XLSX."""
import argparse
import hashlib
import json
import math
import re
import statistics
from pathlib import Path
from xml.etree import ElementTree as ET
from zipfile import ZipFile

DATA = "https://mdpi-res.com/d_attachment/animals/animals-10-02256/article_deploy/animals-10-02256-s001.xlsx"
DIGEST = "bf31eecd2957c521ad813b50e67c7111e0babaa44da6f385b795838d1db7033d"
KINDS = ["halfBlink", "narrow", "close"]
TRIAL_SECONDS = 60


def read_trials(path):
    if hashlib.sha256(path.read_bytes()).hexdigest() != DIGEST:
        raise ValueError("Expected the published Table S1 workbook. See README.")
    with ZipFile(path) as book:
        sheet = ET.fromstring(book.read("xl/worksheets/sheet1.xml"))
    cats = []
    for row in sheet.findall(".//{*}row"):
        if int(row.get("r")) < 7:
            continue
        cells = {re.sub(r"\d+$", "", cell.get("r")): cell.findtext("{*}v") for cell in row}
        conditions = []
        for counts, times in [("BCD", "FGH"), ("JKL", "NOP")]:
            conditions.append(([int(cells[c]) for c in counts], [float(cells[c]) for c in times]))
        cats.append(conditions)
    return cats


def fit(cats, conditional):
    rates = []
    durations = []
    for condition in range(2):
        trials = [cat[condition] for cat in cats] if conditional else [trial for cat in cats for trial in cat]
        # Independent Poisson counts per minute per movement, with a half-count prior.
        rates.append([(sum(n[i] for n, _ in trials) + 0.5) / (len(trials) + 0.5) for i in range(3)])
        durations.append([statistics.median(t[i] / n[i] for n, t in trials if n[i]) for i in range(3)])
    return rates, durations


def leave_one_cat_out(cats, conditional):
    losses = []
    for held, cat in enumerate(cats):
        rates, _ = fit(cats[:held] + cats[held + 1:], conditional)
        losses.append(sum(mu - n * math.log(mu) + math.lgamma(n + 1)
                          for condition, (counts, _) in enumerate(cat)
                          for mu, n in zip(rates[condition], counts)) / 6)
    return statistics.mean(losses)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("table", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    cats = read_trials(args.table)
    rates, durations = fit(cats, True)
    model = {"schema": "cat-eye-events-1", "conditions": ["neutral", "slowBlink"], "movements": KINDS,
             "perMinute": rates, "seconds": durations, "cats": len(cats), "trialSeconds": TRIAL_SECONDS,
             "source": DATA, "authors": "Tasmin Humphrey, Faye Stringer, Leanne Proops and Karen McComb (2020)",
             "license": "CC BY 4.0", "sha256": DIGEST}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(model, indent=2) + "\n")
    print(f"{len(cats)} cats x 2 trials. Held-out Poisson NLL per count: "
          f"conditional {leave_one_cat_out(cats, True):.4f}, pooled {leave_one_cat_out(cats, False):.4f}.")


if __name__ == "__main__":
    main()
