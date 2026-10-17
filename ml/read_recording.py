#!/usr/bin/env python3
"""Read an openGym Apple Watch recording (frontend/ios/App/Watch/SensorRecorder.swift).

Each workout is two files with the same name:
  <name>.motion  rows of 14 little-endian float32, no header (columns in the manifest)
  <name>.json    the manifest: start time, labels ("events"), heart rate, session

    python3 ml/read_recording.py recordings/opengym-20261017-181500.json

prints a summary and every labelled set. As a module:

    from read_recording import load
    rec = load("recordings/opengym-20261017-181500.json")
    rec.motion["ax"]        # numpy array per column, rec.motion["t"] in seconds from the start
    for s in rec.sets:      # one per Done, with its Start when it was marked
        window = rec.slice(s["start_t"], s["end_t"])

Needs numpy only.
"""
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np


@dataclass
class Recording:
    manifest: dict
    motion: dict  # column name -> np.ndarray
    sets: list = field(default_factory=list)

    @property
    def rate(self) -> float:
        return float(self.manifest.get("rate", 100))

    def slice(self, t0: float, t1: float) -> dict:
        """The motion between two times (seconds from the start), every column."""
        t = self.motion["t"]
        m = (t >= t0) & (t <= t1)
        return {k: v[m] for k, v in self.motion.items()}


def _pair_sets(events: list) -> list:
    """A setEnd with the setStart that opened it (if the set was started on the watch)."""
    sets, open_start = [], None
    for ev in events:
        if ev.get("type") == "setStart":
            open_start = ev
        elif ev.get("type") == "setEnd":
            start = open_start if ev.get("started") and open_start else None
            sets.append({
                "exercise": ev.get("exercise"), "exId": ev.get("exId"), "set": ev.get("set"),
                "sets": ev.get("sets"), "mode": ev.get("mode"), "reps": ev.get("reps"), "w": ev.get("w"),
                "warmup": ev.get("warmup"), "side": ev.get("side") or None,
                "start_t": start["t"] if start else None, "end_t": ev["t"],
                # The same value the phone stores on the logged set (set.at): joins this label to
                # the reps and weight actually logged, from an openGym backup export.
                "at": ev.get("at"),
            })
            open_start = None
    return sets


def load(manifest_path) -> Recording:
    manifest_path = Path(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("format") != "opengym-watch-motion":
        raise ValueError(f"{manifest_path}: not an openGym watch recording")
    columns = manifest["columns"]
    raw = np.fromfile(manifest_path.with_suffix(".motion"), dtype=np.dtype(manifest.get("dtype", "<f4")))
    raw = raw[: len(raw) - len(raw) % len(columns)].reshape(-1, len(columns))
    motion = {name: raw[:, i] for i, name in enumerate(columns)}
    return Recording(manifest, motion, _pair_sets(manifest.get("events", [])))


def main(paths) -> None:
    for p in paths:
        rec = load(p)
        m, t = rec.manifest, rec.motion["t"]
        dur = float(t[-1]) if len(t) else 0.0
        print(f"{Path(p).name}: {m.get('session', {}).get('name') or 'session'} · {len(t)} rows "
              f"({dur / 60:.1f} min at {rec.rate:g} Hz) · {len(rec.sets)} sets · "
              f"{len(m.get('heartRate', []))} heart-rate samples · {m.get('device', {}).get('model', '?')}")
        for s in rec.sets:
            span = f"{s['start_t']:7.1f}–{s['end_t']:7.1f}s" if s["start_t"] is not None else f"      ?–{s['end_t']:7.1f}s"
            print(f"  {span}  {s['exercise']} set {s['set']}/{s['sets']}"
                  f"{' warm-up' if s['warmup'] else ''}  target {s['reps']:g} × {s['w']:g}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
