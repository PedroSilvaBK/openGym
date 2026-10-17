import { describe, expect, it } from 'vitest'
import { restAfterSet, watchSnapshot } from './watch-snapshot.js'

const reps = (n, done = 0, extra = {}) => Array.from({ length: n }, (_, k) => ({ w: 60, r: 8, done: k < done, ...extra }))
const base = over => ({ unit: 'kg', restSec: 90, routines: [], week: {}, dayPlan: {}, queue: null, ...over })
const nameOf = e => e.name

describe('restAfterSet', () => {
  it('is the exercise rest between sets, or the default when it has none', () => {
    const entries = [{ id: 'a', target: { restSec: 120 }, sets: reps(3, 1) }, { id: 'b', sets: reps(2) }]
    expect(restAfterSet(entries, 0, 1, 90)).toBe(120)
    expect(restAfterSet(entries, 1, 0, 90)).toBe(90)
  })

  it('still rests after the last set of an exercise when another one follows', () => {
    const entries = [{ id: 'a', sets: reps(2, 1) }, { id: 'b', sets: reps(2) }]
    expect(restAfterSet(entries, 0, 1, 90)).toBe(90)
  })

  it('is nothing after the very last set of the session', () => {
    const entries = [{ id: 'a', sets: reps(2, 2) }, { id: 'b', sets: reps(2, 1) }]
    expect(restAfterSet(entries, 1, 1, 90)).toBe(0)
  })

  it('is nothing mid-round in a superset, and the rest once the round closes', () => {
    const entries = [
      { id: 'a', sg: 'g', sets: reps(3) },
      { id: 'b', sg: 'g', sets: reps(3) },
    ]
    expect(restAfterSet(entries, 0, 0, 90)).toBe(0)
    const afterA = [{ ...entries[0], sets: reps(3, 1) }, entries[1]]
    expect(restAfterSet(afterA, 1, 0, 90)).toBe(90)
  })

  it('follows the rest timer switched off', () => {
    expect(restAfterSet([{ id: 'a', sets: reps(3) }], 0, 0, 0)).toBe(0)
  })
})

describe('watchSnapshot', () => {
  it('idle: today first, every routine to pick from, nothing running', () => {
    const S = base({ routines: [{ id: 'r1', name: 'Push' }, { id: 'r2', name: 'Pull' }], week: { 5: ['r2'] } })
    const snap = watchSnapshot(S, null, { nameOf, today: '2026-10-16' })   // a Friday
    expect(snap.today).toEqual({ ids: ['r2'], name: 'Pull' })
    expect(snap.routines).toEqual([{ id: 'r1', name: 'Push' }, { id: 'r2', name: 'Pull' }])
    expect(snap.active).toBe(null)
    expect(snap.rest).toBe(null)
  })

  it('live: the next set with its target and the rest it will earn', () => {
    const S = base({
      active: {
        id: 'w1', name: 'Full Body C', start: 1000, cur: 0,
        entries: [
          { id: 'squat', name: 'Squat', target: { restSec: 180 }, sets: reps(3, 1) },
          { id: 'row', name: 'Row', sets: reps(2) },
        ],
      },
    })
    const snap = watchSnapshot(S, null, { nameOf })
    expect(snap.active).toMatchObject({ id: 'w1', name: 'Full Body C', start: 1000, done: 1, total: 5 })
    expect(snap.active.next).toMatchObject({ idx: 0, i: 1, exId: 'squat', exercise: 'Squat', set: 2, sets: 3, mode: 'reps', reps: 8, w: 60, restAfter: 180 })
  })

  it('a past workout being logged is not a session the watch follows', () => {
    const S = base({ active: { id: 'w1', start: 1000, backfill: { durationMin: 60 }, entries: [{ id: 'a', sets: reps(1) }] } })
    expect(watchSnapshot(S, null, { nameOf }).active).toBe(null)
  })

  it('a timed hold carries its seconds; a running rest its end', () => {
    const S = base({ active: { id: 'w1', start: 1000, cur: 0, entries: [{ id: 'plank', name: 'Plank', mode: 'time', sets: [{ sec: 45, w: 0, done: false }] }] } })
    const snap = watchSnapshot(S, { left: 60, total: 90, endsAt: 5000, forIdx: 0 }, { nameOf })
    expect(snap.active.next).toMatchObject({ mode: 'time', sec: 45, restAfter: 0 })
    expect(snap.rest).toEqual({ endsAt: 5000, total: 90, paused: false, left: 0, kind: 'rest' })
    expect(watchSnapshot(S, { left: 60, total: 90, endsAt: 5000, paused: true }, { nameOf }).rest.left).toBe(60)
  })

  it('a rest that already ran out is not sent', () => {
    expect(watchSnapshot(base({}), { left: 0, total: 90, endsAt: 5000, ready: true }).rest).toBe(null)
  })
})
