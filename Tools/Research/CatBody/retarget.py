"""Fit one measured cat stride and evaluate the next stride in the same recording."""
import argparse
from pathlib import Path
from xml.etree import ElementTree
from zipfile import ZipFile

import numpy as np
from scipy.signal import find_peaks

from gait import GaitNetwork, PERIOD, simulate


def read_trial(path):
    """Read the numeric Markers3D_CL12 table of Rahmati et al., Supplement 4."""
    ns = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
    with ZipFile(path) as workbook:
        strings = ["".join(item.itertext()) for item in ElementTree.fromstring(
            workbook.read("xl/sharedStrings.xml"))]
        root = ElementTree.fromstring(workbook.read("xl/worksheets/sheet3.xml"))
    rows = root.find(ns + "sheetData")
    names = [strings[int(cell.findtext(ns + "v"))] for cell in rows[0]]
    if len(set(names)) != len(names) or any(len(row) != len(names) for row in rows[1:]):
        raise ValueError("Expected the complete Markers3D_CL12 table in Supplement 4")
    matrix = np.array([[float(cell.findtext(ns + "v")) for cell in row] for row in rows[1:]])
    return dict(zip(names, matrix.T))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workbook", type=Path, help="TJP-603-447-s001.xlsx (Supplement 4)")
    args = parser.parse_args()
    values = read_trial(args.workbook)
    # Two successive full strides, aligned at the left foretoe's swing apex.
    peaks, _ = find_peaks(values["LFT:Z"], distance=40, prominence=.013)
    if len(peaks) != 3:
        raise ValueError("Expected three left foretoe swing peaks in this trial")
    first, second, third = peaks
    train, test = slice(first, second), slice(second, third)
    time = values["Time,s"]
    source_period = time[second] - time[first]
    hip_x = (values["RHIP:X"] + values["LHIP:X"]) / 2
    stride = hip_x[second] - hip_x[first]

    # Fore- and hindleg horizontal targets are relative to their respective sockets.
    # Vertical targets track toe lift above the stance marker's baseline height.
    correspondence = (("RFT", "RSHL"), ("LFT", "LSHL"), ("RHT", "RHIP"), ("LHT", "LHIP"))
    targets = []
    for paw, socket in correspondence:
        local_x = values[paw + ":X"] - values[socket + ":X"]
        x = local_x - np.mean(local_x[train])
        z = values[paw + ":Z"] - np.percentile(values[paw + ":Z"][train], 5)
        targets.append(np.column_stack((x, z)))
    targets = np.stack(targets, axis=1)

    def phases(start, end):
        return (time[start:end] - time[start]) / (time[end] - time[start])

    speed = .22
    train_phase = phases(first, second)
    samples = train_phase, np.full(len(train_phase), speed), targets[train].reshape(len(train_phase), 8)
    net = GaitNetwork(141, samples)
    print(f"source train/test frames = {second-first}/{third-second}; "
          f"train period = {source_period:.3f} s; hip advance = {stride:.3f} m")
    for label, segment, phase in (("fit", train, train_phase), ("next stride", test, phases(second, third))):
        estimate = np.array([net(p, speed) for p in phase])
        error = np.linalg.norm(estimate - targets[segment], axis=2)
        print(f"{label} mean toe target error = {1000*np.mean(error):.2f} mm")
    for label, scale in (("recorded horizontal excursion", 1.), ("desktop stride", speed*PERIOD/stride)):
        def predict(phase, command):
            return net(phase, command) * np.array([scale, 1])
        runs = [simulate(predict, 0, .9, speed, phase) for phase in (0, .25, .5, .75)]
        print(f"{label} (x scale {scale:.3f}): mean speed {np.mean([r.distance for r in runs])/6:.3f} m/s, "
              f"slip {1000*np.mean([r.slip for r in runs]):.2f} mm/s, "
              f"torso/head contacts {sum(r.fell for r in runs)}/{len(runs)}")


if __name__ == "__main__":
    main()
