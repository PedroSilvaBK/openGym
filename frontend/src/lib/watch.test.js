import { describe, expect, it } from 'vitest'
import { bindWatchTicks, markWatchEventSeen, plistSafe, queueWatchTick, seenWatchEvent, watchTickTarget } from './watch.js'

const sets = (n, done = 0) => Array.from({ length: n }, (_, k) => ({ w: 60, r: 8, done: k < done }))

describe('watchTickTarget', () => {
  const entries = [{ id: 'a', sets: sets(3, 1) }, { id: 'b', sets: sets(2) }]

  it('ticks the set the watch named', () => {
    expect(watchTickTarget(entries, { activeId: 'w1', idx: 0, i: 1 }, 'w1', 0)).toEqual({ idx: 0, i: 1 })
  })

  it('ticks the next open set when the Done named none (made before the phone answered)', () => {
    expect(watchTickTarget(entries, { activeId: 'w1' }, 'w1', 0)).toEqual({ idx: 0, i: 1 })
  })

  it('moves on when the named set was already ticked on the phone', () => {
    expect(watchTickTarget(entries, { activeId: 'w1', idx: 0, i: 0 }, 'w1', 0)).toEqual({ idx: 0, i: 1 })
  })

  it('ticks nothing for another session, or with nothing left', () => {
    expect(watchTickTarget(entries, { activeId: 'old', idx: 0, i: 1 }, 'w1', 0)).toBe(null)
    expect(watchTickTarget([{ id: 'a', sets: sets(2, 2) }], { activeId: 'w1' }, 'w1', 0)).toBe(null)
  })

  it('names the side of a per-side set, left first', () => {
    const side = [{ id: 'lunge', sets: [{ done: false, sides: { L: { done: false }, R: { done: false } } }] }]
    expect(watchTickTarget(side, { activeId: 'w1', idx: 0, i: 0 }, 'w1', 0)).toEqual({ idx: 0, i: 0, side: 'L' })
  })
})

describe('plistSafe', () => {
  it('drops nulls, which a property list cannot carry', () => {
    expect(plistSafe({ a: null, b: { c: null, d: 1 }, e: [1] })).toEqual({ b: { d: 1 }, e: [1] })
  })
})

describe('the tick queue', () => {
  it('holds Done events until the workout screen takes them, in order', () => {
    const got = []
    queueWatchTick({ id: 1 })
    queueWatchTick({ id: 2 })
    const unbind = bindWatchTicks(ev => got.push(ev.id))
    queueWatchTick({ id: 3 })
    unbind()
    queueWatchTick({ id: 4 })
    expect(got).toEqual([1, 2, 3])
    bindWatchTicks(ev => got.push(ev.id))()
    expect(got).toEqual([1, 2, 3, 4])
  })

  it('resolves each Done once the screen has taken it', async () => {
    let taken = 0
    const done = queueWatchTick({ id: 5 })
    const unbind = bindWatchTicks(() => { taken++ })
    await done
    unbind()
    expect(taken).toBe(1)
  })

  it('remembers applied events across launches', () => {
    const store = new Map()
    globalThis.localStorage = { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, String(v)) }
    expect(seenWatchEvent('x')).toBe(false)
    markWatchEventSeen('x')
    expect(seenWatchEvent('x')).toBe(true)
    expect(JSON.parse(store.get('gym_watch_seen'))).toEqual(['x'])
    delete globalThis.localStorage
  })
})
