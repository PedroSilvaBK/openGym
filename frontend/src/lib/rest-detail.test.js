import { describe, expect, it } from 'vitest'
import { restDetail } from './rest-detail.js'

const set = done => ({ done })
const nameOf = e => e.name

describe('restDetail', () => {
  it('names the next open set of the exercise the rest belongs to', () => {
    const entries = [
      { id: 'a', name: 'Bench Press', sets: [set(true), set(true), set(false), set(false)] },
      { id: 'b', name: 'Row', sets: [set(false)] },
    ]
    expect(restDetail(entries, 0, nameOf)).toBe('Bench Press · 3/4')
  })

  it('moves on to the next exercise once this one is finished', () => {
    const entries = [
      { id: 'a', name: 'Bench Press', sets: [set(true), set(true)] },
      { id: 'b', name: 'Row', sets: [set(false), set(false), set(false)] },
    ]
    expect(restDetail(entries, 0, nameOf)).toBe('Row · 1/3')
  })

  it('says which side comes next on a per-side set', () => {
    const entries = [{ id: 'a', name: 'Lunge', sets: [{ done: false, sides: { L: { done: true }, R: { done: false } } }] }]
    expect(restDetail(entries, 0, nameOf)).toBe('Lunge · 1/1 R')
  })

  it('is empty when nothing is left, and the count alone without a name', () => {
    expect(restDetail([{ id: 'a', sets: [set(true)] }], 0, nameOf)).toBe('')
    expect(restDetail([], 0, nameOf)).toBe('')
    expect(restDetail([{ id: 'a', sets: [set(false), set(false)] }], 0)).toBe('1/2')
  })
})
