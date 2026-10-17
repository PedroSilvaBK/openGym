# Set detection — training data

The goal: the Apple Watch notices that a set has ended and marks it done by itself. That needs a
model, and a model needs examples. This folder is where the examples are read (and, later, where
the detector is built and trained).

## Collecting

1. On the watch, open openGym and switch on **Record motion** (bottom of the start list).
2. Train as usual. Every set now has two taps — **Start** when you begin, **Done** when you rack
   the weight (a double-tap does either on Series 9 and later). A red **REC** shows it is on.
   Forgot Start? **Done without start** still logs the set; that set just has no start label.
3. When the workout ends, the watch sends the recording to the iPhone.
4. **Phone paired with a server that has `RECORDINGS=1`** in its `.env`: the phone uploads it there
   by itself and keeps no copy. It lands in the server's data folder as
   `data/recordings/<your profile id>/opengym-YYYYMMDD-HHMMSS.{motion,json}` — read them there, or
   copy that folder to your Mac (`scp -r server:/path/to/openGym/data/recordings/<id> ml/recordings`).
   Settings → Data → **Watch recordings** shows how many are on the server and any still waiting.
5. **No server, or one without `RECORDINGS=1`:** Settings → Data → **Watch recordings** → **Share**
   → AirDrop to your Mac, or Save to Files. Put them in `ml/recordings/` (git-ignored).

Nothing leaves your own devices and server.

## The files

Two per workout, same name:

| File | What |
|---|---|
| `opengym-YYYYMMDD-HHMMSS.motion` | 100 rows per second of 14 little-endian `float32`: `t`, user acceleration `ax ay az` (g, gravity removed), gravity `gx gy gz` (g), rotation rate `rx ry rz` (rad/s), attitude quaternion `qx qy qz qw`. `t` is seconds since the recording started. |
| `opengym-YYYYMMDD-HHMMSS.json` | The manifest: columns, start and end (epoch ms), the device and which wrist, the session, `heartRate` as `[t, bpm]` pairs, and `events` — the labels. |

Labels in `events`: `setStart` and `setEnd` (exercise, its catalogue id `exId`, set number, the
target reps/weight/seconds, whether the set was started on the watch), and `restSkip`. Each has `t`
(seconds, same clock as the motion) and `at` (epoch ms). A `setEnd`'s `at` is exactly the time
openGym stores on the logged set, so the reps and weight you actually logged can be joined from an
openGym backup export (Settings → Data → Export).

Roughly 20 MB per hour of training.

## Reading

```
python3 -m pip install numpy
python3 ml/read_recording.py ml/recordings/*.json
```

prints each workout and its labelled sets. `load()` gives you the arrays to work with.

## What makes good data

- Many sessions beat long ones: 15–30 workouts across your usual exercises.
- Mark Start when the first rep begins and Done when the last one ends — not when you sit down.
- Wear the watch the same way you always do; the manifest records the wrist.
- Exercises where the wrist barely moves (leg press, leg extension, calf raises) will be hard for
  any detector. Record them anyway: knowing where it fails is useful too.
