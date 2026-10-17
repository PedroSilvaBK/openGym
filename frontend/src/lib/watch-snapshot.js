// What the Apple Watch app shows, as one plain object the phone sends it whenever it changes
// (lib/watch.js → ios/App/App/WatchPlugin.swift → WatchConnectivity applicationContext).
//
// Idle, it is the list to start from: today's planned session first, then every routine. During a
// live session it is the next set to do — the same one the hardware keys and the watch's Done
// would tick (workout-keys.js nextOpenSet) — with its target, and the rest that set will earn, so
// the watch can start counting it down the moment Done is pressed, before the phone (asleep in a
// pocket, its page frozen) has said a word. The phone's own rest, once it runs, replaces that guess.
import { nextOpenSet } from './workout-keys.js'
import { effectiveRoutineIds, modeOf, setsDoneActive, setUnitsTotal, supersetUnits, unitOf } from './history.js'
import { restSecFor, warmupRestSecFor, supersetFlowStep, nextUnfinishedUnit } from './supersetFlow.js'
import { pyramidRestFor } from './pyramid.js'
import { isWarmupRow } from './workout-model.js'
import { deriveSessionName } from './session-merge.js'
import { liveSession } from './rest-alert.js'

export const WATCH_SNAPSHOT_VERSION = 1

// The rest the set at (idx, i) will earn once ticked: what Workout.jsx toggle starts after it,
// for the common shapes. 0 when no rest follows (mid-round in a superset, the last set of the
// session, a rest timer switched off). A guess by design — see the top of this file.
export function restAfterSet(entries, idx, i, defaultRestSec) {
  const entry = entries?.[idx]
  if (!entry || !Array.isArray(entry.sets) || !entry.sets[i]) return 0
  // As if ticked: the unit's state right after this set.
  const after = entries.map((e, k) => (k !== idx ? e : { ...e, sets: e.sets.map((s, j) => (j === i ? { ...s, done: true } : s)) }))
  const units = supersetUnits(after)
  const unit = unitOf(units, idx)
  const unitDone = unit.every(k => after[k].sets.every(s => s.done))
  const nextUnit = unitDone ? nextUnfinishedUnit(after, units, idx) : null
  if (unitDone && !nextUnit) return 0
  if (nextUnit?.some(k => after[k].sets.some(s => isWarmupRow(s) && !s.done))) return 0
  if (unit.length > 1 && !unitDone) {
    const step = supersetFlowStep(after, unit, idx)
    if (!step?.roundDone) return 0
  }
  const sec = restSecFor(after, unit, defaultRestSec, { idx, sec: pyramidRestFor(entry.target, entry.sets, i) })
  return Math.max(0, Math.round(warmupRestSecFor(after[idx], i, sec) || 0))
}

// The set itself, in the fields the watch draws: reps × weight, a hold, or cardio minutes.
function setTarget(entry, i, side) {
  const set = entry.sets[i] || {}
  const mode = modeOf(entry)
  const row = side && set.sides ? { ...set, ...set.sides[side] } : set
  const num = v => (Number.isFinite(Number(v)) ? Number(v) : 0)
  return {
    mode,
    reps: num(row.r),
    w: num(row.w),
    sec: num(row.sec),
    min: num(row.min),
    warmup: isWarmupRow(set),
    side: side || null,
  }
}

export function watchSnapshot(S, timer, { nameOf = e => e?.id || '', today } = {}) {
  const routines = Array.isArray(S?.routines) ? S.routines : []
  const todayIds = today ? effectiveRoutineIds(S, today) : []
  const todayNames = todayIds.map(id => routines.find(r => r.id === id)?.name).filter(Boolean)
  const snap = {
    v: WATCH_SNAPSHOT_VERSION,
    unit: S?.unit === 'lb' ? 'lb' : 'kg',
    today: todayIds.length ? { ids: todayIds, name: deriveSessionName(todayNames) } : null,
    routines: routines.filter(r => r && r.id).map(r => ({ id: r.id, name: r.name || '' })),
    active: null,
    rest: null,
  }

  const live = liveSession(S?.active)
  if (live) {
    const A = S.active
    const entries = Array.isArray(A.entries) ? A.entries : []
    const next = nextOpenSet(entries, A.cur)
    snap.active = {
      id: A.id || '',
      name: live.workoutTitle,
      start: live.workoutStart,
      done: setsDoneActive(A),
      total: setUnitsTotal(entries),
      next: next ? {
        idx: next.idx,
        i: next.i,
        exId: entries[next.idx].id || '',
        exercise: nameOf(entries[next.idx]),
        set: next.i + 1,
        sets: entries[next.idx].sets.length,
        ...setTarget(entries[next.idx], next.i, next.side),
        restAfter: restAfterSet(entries, next.idx, next.i, S.restSec),
      } : null,
    }
  }

  if (timer && !timer.ready && timer.endsAt > 0) {
    snap.rest = {
      endsAt: timer.endsAt,
      total: Math.max(0, Math.round(timer.total || 0)),
      paused: !!timer.paused,
      // Only while held: a running rest is its end, and the seconds ticking down here would
      // otherwise send the watch a new snapshot every second.
      left: timer.paused ? Math.max(0, Math.round(timer.left || 0)) : 0,
      kind: timer.kind === 'switch' ? 'switch' : 'rest',
    }
  }
  return snap
}
