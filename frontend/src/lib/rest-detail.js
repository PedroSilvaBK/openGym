// The line under the rest countdown in the iOS Live Activity: what comes after this rest, as
// "Bench Press · 3/5" (the exercise and the set's place in it). No words of its own, so there is
// nothing to translate. Reads the session the same way the hardware keys do (workout-keys.js
// nextOpenSet): the exercise the rest belongs to first, then the next one with work left.
import { nextOpenSet } from './workout-keys.js'

export function restDetail(entries, forIdx, nameOf) {
  const next = nextOpenSet(entries, forIdx)
  if (!next) return ''
  const sets = entries[next.idx]?.sets || []
  const name = typeof nameOf === 'function' ? nameOf(entries[next.idx]) : ''
  const side = next.side ? ` ${next.side}` : ''
  const where = `${next.i + 1}/${sets.length}${side}`
  return name ? `${name} · ${where}` : where
}
