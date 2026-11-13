// State handling shared by the BeamLife phone apps: load the app's state from Lua, refresh it
// while the screen is open, run actions and show their answer, and tell the phone shell whether
// the app wants the large board.
import { inject, onMounted, onUnmounted, ref } from "vue"
import { useBridge } from "@/bridge"
import { lua } from "./bridge.js"

const WIDE_KEY = "beamlife.wide"
const REFRESH_MS = 3000
const SAVER_REFRESH_MS = 8000

// The Performance screen's "App refresh saver" reaches the UI through the HUD state.
function refreshDelay() {
  return window.__beamlifePerf?.appSaver ? SAVER_REFRESH_MS : REFRESH_MS
}
const NOTICE_MS = 4500

function readWide() {
  try {
    return localStorage.getItem(WIDE_KEY) !== "0"
  } catch {
    return true
  }
}

// appKeys: the names Lua uses in its "beamlifeChanged" event for this screen.
// load: () => Promise of the screen's state.
export function useBeamlifeApp(appKeys, load, options = {}) {
  const { events } = useBridge()
  const state = ref(null)
  const notice = ref(null)
  const working = ref(false)
  const wide = ref(readWide())
  const keys = Array.isArray(appKeys) ? appKeys : [appKeys]
  let timer = null
  let noticeTimer = null
  let alive = true

  async function refresh() {
    const data = await load()
    if (alive && data && typeof data === "object") state.value = data
  }

  function say(text, ok = true) {
    if (!text) return
    notice.value = { text, ok }
    clearTimeout(noticeTimer)
    noticeTimer = setTimeout(() => { notice.value = null }, NOTICE_MS)
  }

  async function act(path, ...args) {
    if (working.value) return null
    working.value = true
    try {
      const result = await lua(path, ...args)
      if (result?.message) say(result.message, result.ok !== false)
      await refresh()
      return result
    } finally {
      working.value = false
    }
  }

  function toggleWide() {
    wide.value = !wide.value
    try {
      localStorage.setItem(WIDE_KEY, wide.value ? "1" : "0")
    } catch { /* the preference simply does not persist */ }
  }

  function changed(payload) {
    if (!payload?.app || keys.includes(payload.app)) refresh()
  }

  // The phone shell reads these on every render, so the board follows the toggle at once.
  const shell = inject(Symbol.for("overhaul.phoneScreen"), null)
  const dispose = shell?.register({
    expanded: () => wide.value,
    onBack: () => (options.onBack ? options.onBack() : false),
  })

  onMounted(() => {
    events.on("beamlifeChanged", changed)
    refresh()
    const tick = () => {
      timer = setTimeout(async () => {
        await refresh()
        if (alive) tick()
      }, refreshDelay())
    }
    tick()
  })
  onUnmounted(() => {
    alive = false
    events.off("beamlifeChanged", changed)
    clearTimeout(timer)
    clearTimeout(noticeTimer)
    dispose?.()
  })

  return { state, notice, working, wide, refresh, act, say, toggleWide }
}
