// The Apple Watch, from the page's side (iOS app only; ios/App/App/WatchPlugin.swift).
//
// The phone stays the source of truth. It sends the watch a snapshot of the session
// (watch-snapshot.js) whenever that changes, and takes what was done on the wrist as events:
//   start    { ids }                         start that session (or freestyle) here too
//   setDone  { id, activeId, at, idx?, i?, restSec, restEndsAt }
//                                            tick a set; the watch already started its rest
//   skipRest                                 end the running rest
//   finish                                   finish the workout (the usual confirm if sets are left)
// A Done can be made with the phone locked and its page frozen: the native side has already put
// the rest on the lock screen, and the events wait on disk, in order, until the page has applied
// them (pullWatchEvents → ack), so an app that iOS ends while suspended loses none.
import { MOBILE, isIOS } from './mobile.js'
import { nextOpenSet } from './workout-keys.js'

// Which set a Done from the watch ticks. The first Done after a snapshot names its set (idx, i);
// one made before the phone answered does not, and ticks the next open set, as the hardware keys
// do. A named set already done (ticked on the phone meanwhile) also falls through to the next open
// one: every Done on the wrist is one set logged. Another session's Done ticks nothing.
export function watchTickTarget(entries, ev, activeId, cur) {
  if (!ev || !Array.isArray(entries) || !entries.length) return null
  if (ev.activeId && activeId && ev.activeId !== activeId) return null
  const next = nextOpenSet(entries, cur)
  const named = Number.isInteger(ev.idx) && Number.isInteger(ev.i) ? entries[ev.idx]?.sets?.[ev.i] : null
  if (named && !named.done) {
    const side = next && next.idx === ev.idx && next.i === ev.i ? next.side : undefined
    return side ? { idx: ev.idx, i: ev.i, side } : { idx: ev.idx, i: ev.i }
  }
  if (!next) return null
  return next.side ? { idx: next.idx, i: next.i, side: next.side } : { idx: next.idx, i: next.i }
}

// WatchConnectivity carries property lists, which have no null.
export const plistSafe = value => JSON.parse(JSON.stringify(value, (_, v) => (v === null ? undefined : v)))

// Registered once, carried in an object (a Capacitor proxy answers `then`, see rest-alert.js).
let pluginP = null
const watchPlugin = () => pluginP || (pluginP = (async () => {
  if (!(await isIOS())) return null
  const { registerPlugin } = await import('@capacitor/core')
  return { Watch: registerPlugin('Watch') }
})().catch(() => null))

let lastSent = ''
export function sendWatchSnapshot(snapshot) {
  if (!MOBILE) return
  const body = plistSafe(snapshot)
  const key = JSON.stringify(body)
  if (key === lastSent) return
  lastSent = key
  watchPlugin().then(p => p && p.Watch.update({ snapshot: body })).catch(() => { lastSent = '' })
}

// The snapshot again even if nothing changed: a watch that was out of reach may have missed it.
export function resendWatchSnapshot() { lastSent = '' }

export async function watchStatus() {
  if (!MOBILE) return null
  try {
    const p = await watchPlugin()
    return p ? await p.Watch.status() : null
  } catch { return null }
}

// A session started on the phone opens the watch app with its workout running.
export async function startWatchApp() {
  const status = await watchStatus()
  if (!status?.paired || !status?.installed) return false
  try {
    const p = await watchPlugin()
    return !!(await p.Watch.startWatchApp())?.started
  } catch { return false }
}

// Training data recorded on the watch (Watch/SensorRecorder.swift), kept on this phone until
// shared: [{ name, uri, bytes, at }], or null off the iOS app.
export async function listRecordings() {
  try {
    const p = await watchPlugin()
    if (!p) return null
    const { files = [] } = (await p.Watch.recordings()) || {}
    return files
  } catch { return null }
}

export async function deleteRecordings() {
  const p = await watchPlugin()
  if (p) await p.Watch.deleteRecordings()
}

// To the paired server (api/recordings.js), natively and in chunks (RecordingUploader.swift).
// `auth` is api.js remoteAuth(); `chunkBytes` what the server's /api/config offers. Resolves
// { uploaded, remaining, error }, or null off the iOS app.
export async function uploadRecordings(auth, chunkBytes) {
  if (!auth) return null
  try {
    const p = await watchPlugin()
    return p ? await p.Watch.uploadRecordings({ base: auth.base, headers: auth.headers, chunkBytes }) : null
  } catch { return null }
}

// A recording arrived from the watch.
export function onRecordingArrived(cb) {
  if (!MOBILE) return
  watchPlugin().then(p => p && p.Watch.addListener('recording', () => cb())).catch(() => {})
}

// Through the share sheet: AirDrop to a Mac, Save to Files, … Each recording is two files.
export async function shareRecordings(files) {
  if (!files?.length) return
  const { Share } = await import('@capacitor/share')
  await Share.share({ files: files.map(f => f.uri) })
}

// Something new is waiting: the native side nudges, the page pulls (pullWatchEvents).
export function onWatchNudge(cb) {
  if (!MOBILE) return
  watchPlugin().then(p => p && p.Watch.addListener('watch', () => cb())).catch(() => {})
}

// Events already applied, by id, kept across launches: one applied but not yet taken off the
// native queue when the app was ended comes round again, and must not tick a second set.
export const WATCH_SEEN_KEY = 'gym_watch_seen'
const readSeen = () => { try { return JSON.parse(localStorage.getItem(WATCH_SEEN_KEY) || '[]') } catch { return [] } }
export const seenWatchEvent = id => !!id && readSeen().includes(id)
export function markWatchEventSeen(id) {
  if (!id) return
  const seen = readSeen().filter(x => x !== id)
  seen.push(id)
  try { localStorage.setItem(WATCH_SEEN_KEY, JSON.stringify(seen.slice(-200))) } catch { /* best effort */ }
}

// Applies what is waiting, in order, each once. `apply(ev)` resolves when the event has really
// taken effect (a Done once the workout screen ticked it); only then is it marked and taken off
// the native queue. One still being applied is not started again by the next pull.
const inFlight = new Set()
let pulling = null
export function pullWatchEvents(apply) {
  if (!MOBILE) return Promise.resolve()
  if (pulling) return pulling.then(() => pullWatchEvents(apply))
  pulling = (async () => {
    const p = await watchPlugin()
    if (!p) return
    const { events = [] } = (await p.Watch.pending()) || {}
    const done = []
    for (const ev of events) {
      const id = ev?.id
      if (!id || seenWatchEvent(id)) { if (id) done.push(id); continue }
      if (inFlight.has(id)) continue
      inFlight.add(id)
      Promise.resolve(apply(ev))
        .then(() => { markWatchEventSeen(id); return p.Watch.ack({ ids: [id] }) })
        .catch(() => {})
        .finally(() => inFlight.delete(id))
    }
    if (done.length) await p.Watch.ack({ ids: done })
  })().catch(() => {}).finally(() => { pulling = null })
  return pulling
}

// Done from the wrist, waiting for the workout screen, which owns ticking (Workout.jsx toggle).
// Resolves once the screen has taken it.
const ticks = []
let tickHandler = null
export function queueWatchTick(ev) {
  return new Promise(resolve => {
    ticks.push({ ev, resolve })
    drain()
  })
}
export function bindWatchTicks(handler) {
  tickHandler = handler
  drain()
  return () => { if (tickHandler === handler) tickHandler = null }
}
export const watchTicksWaiting = () => ticks.length > 0
function drain() {
  while (tickHandler && ticks.length) {
    const { ev, resolve } = ticks.shift()
    try { tickHandler(ev) } catch { /* one bad event does not hold back the rest */ }
    resolve()
  }
}
