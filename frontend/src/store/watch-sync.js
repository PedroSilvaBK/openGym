// Keeps the Apple Watch in step with the session (lib/watch.js), in the iOS app only: main.jsx
// imports this behind MOBILE, so the web bundle never carries it.
import { useStore } from './useStore.js'
import { useUI } from './useUI.js'
import { todayISO, exerciseNameText } from '../lib/format.js'
import { exOr } from '../lib/exercises.js'
import { liveSession } from '../lib/rest-alert.js'
import { watchSnapshot } from '../lib/watch-snapshot.js'
import { onRecordingArrived, onWatchNudge, pullWatchEvents, queueWatchTick, resendWatchSnapshot, sendWatchSnapshot, startWatchApp, uploadRecordings } from '../lib/watch.js'
import { remoteAuth } from '../lib/api.js'

const nameOf = e => exerciseNameText(exOr(e?.id))

let timer = null
const push = () => {
  clearTimeout(timer)
  timer = setTimeout(() => {
    sendWatchSnapshot(watchSnapshot(useStore.getState().S, useUI.getState().timer, { nameOf, today: todayISO() }))
  }, 250)
}

// The session whose start the watch asked for: the watch is already running it, so the phone does
// not open the watch app for it again.
let fromWatch = false
let liveKey = null
const followSession = S => {
  const live = liveSession(S?.active)
  const key = live ? String(live.workoutStart) : ''
  if (key === liveKey) return
  const started = liveKey !== null && key && !liveKey
  liveKey = key
  if (started && !fromWatch) startWatchApp()
  fromWatch = false
}

const goToWorkout = () => {
  if (!location.hash.startsWith('#/workout')) location.hash = '#/workout'
}

// Resolves once the event has taken effect (lib/watch.js pullWatchEvents acks it then).
async function onEvent(ev) {
  if (!ev) return
  const S = useStore.getState().S
  switch (ev.type) {
    case 'start': {
      if (S.active) return
      fromWatch = true
      const { beginWorkout } = await import('../sheets.jsx')
      beginWorkout(Array.isArray(ev.ids) ? ev.ids : [], null)
      return
    }
    case 'setDone':
      // No session (finished meanwhile): nothing to tick. Otherwise ticking belongs to the workout
      // screen (Workout.jsx bindWatchTicks), which takes the queue once it is up.
      if (!S.active) return
      goToWorkout()
      return queueWatchTick(ev)
    case 'skipRest':
      useUI.getState().stopRest()
      return
    case 'finish': {
      if (!S.active) return
      goToWorkout()
      const { finishWorkout } = await import('../sheets.jsx')
      finishWorkout()
      return
    }
  }
}

useStore.subscribe((s, prev) => {
  if (s.S !== prev.S) { followSession(s.S); push() }
})
useUI.subscribe((s, prev) => { if (s.timer !== prev.timer) push() })
followSession(useStore.getState().S)
// The recordings this phone holds go to the paired server when it takes them (/api/config
// `recordings`, an instance with RECORDINGS=1). Without a server, or with one that does not, they
// stay here for Settings → Watch recordings → Share. `fresh` asks the server again (Settings).
export async function syncRecordings({ fresh = false } = {}) {
  const auth = remoteAuth()
  if (!auth) return null
  const st = useStore.getState()
  const config = fresh ? await st.refreshConfig() : await st.loadConfig()
  const chunkBytes = config?.recordings?.chunkBytes
  if (!chunkBytes) return null
  return uploadRecordings(auth, chunkBytes)
}

const pull = () => pullWatchEvents(onEvent)
onWatchNudge(pull)
// Back in front: what the wrist did meanwhile, and a snapshot the watch may have missed.
document.addEventListener('visibilitychange', () => { if (!document.hidden) { pull(); resendWatchSnapshot(); push(); syncRecordings().catch(() => {}) } })
onRecordingArrived(() => { syncRecordings().catch(() => {}) })
pull()
push()
// Once the app has had time to boot and restore the pairing.
setTimeout(() => { syncRecordings().catch(() => {}) }, 5000)
