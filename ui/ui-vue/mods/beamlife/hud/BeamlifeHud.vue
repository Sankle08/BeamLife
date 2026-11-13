<template>
  <template v-if="visible">
    <!-- The phone lying on its side, used as a navigation map. -->
    <component :is="mapComponent" v-if="mapOn && mapComponent" :time="hud.time" :saver="!!hud.mapSaver" @close="toggleMap" />

    <div class="blhud">
      <button
        v-if="limitText" type="button" class="blhud__limit"
        :aria-label="`Speed limit ${limitText} ${unit}. Click to change unit`" @click="toggleUnit">
        <span class="blhud__limit-value">{{ limitText }}</span>
        <span class="blhud__limit-unit">{{ unit }}</span>
      </button>
      <div class="blhud__phone">
        <button type="button" class="blhud__main" aria-label="Open the phone" @click="open">
          <span class="blhud__row">
            <span class="blhud__time">{{ hud.time }}</span>
            <span class="blhud__date">{{ hud.date }}</span>
          </span>
          <span v-if="line" class="blhud__line">{{ line }}</span>
        </button>
        <button type="button" class="blhud__map" :class="{ 'blhud__map--on': mapOn }" aria-label="Show or hide the phone map" @click="toggleMap">Map</button>
      </div>
    </div>
  </template>
</template>

<script setup>
// What stays on screen while driving: the top edge of the phone (time, date, current task; click
// to open the phone), the speed limit of the road (click to switch km/h and mph), and optionally
// the phone lying on its side as a navigation map.
import { computed, onMounted, onUnmounted, ref, shallowRef, watch } from "vue"
import { useRoute } from "vue-router"
import { useBridge } from "@/bridge"
import { getComponent } from "@/services/uiMods"
import { lua, list, distance, clock } from "../kit/bridge.js"

const MAP_KEY = "beamlife.hudMap"
const UNIT_KEY = "beamlife.speedUnit"
const MAP_FILE = "/ui/ui-vue/mods/beamlife/hud/PhoneMap.vue"

function saved(key, fallback) {
  try {
    return localStorage.getItem(key) ?? fallback
  } catch {
    return fallback
  }
}
function save(key, value) {
  try {
    localStorage.setItem(key, value)
  } catch { /* the preference simply does not persist */ }
}

const { events } = useBridge()
const route = useRoute()
const hud = ref({ active: false })
const shell = window[Symbol.for("overhaul.phoneShellState")]
const unit = ref(saved(UNIT_KEY, "km/h") === "mph" ? "mph" : "km/h")
const mapOn = ref(saved(MAP_KEY, "0") === "1")
const mapComponent = shallowRef(null)
let mapLoading = false

const visible = computed(() => {
  if (!hud.value.active || route.name !== "play") return false
  return !shell?.visible?.value
})

const line = computed(() => {
  const run = hud.value.run
  if (run) {
    if (run.waiting) return `${run.label} Wait ${run.dwellLeft} s.`
    const parts = [run.label]
    if (run.distance != null) parts.push(distance(run.distance))
    if (run.secondsLeft != null) parts.push(run.secondsLeft > 0 ? clock(run.secondsLeft) : "late")
    return parts.join(" · ")
  }
  return list(hud.value.notes)[0]?.text || ""
})

// Lua sends metres per second; signs are posted in steps of 5.
const limitText = computed(() => {
  const limit = Number(hud.value.speedLimit)
  if (!Number.isFinite(limit) || limit <= 0) return ""
  const value = unit.value === "mph" ? limit * 2.23694 : limit * 3.6
  return String(Math.round(value / 5) * 5)
})

function update(state) {
  if (!state || typeof state !== "object") return
  hud.value = state
  // The phone apps read the refresh preference from here (see kit/useApp.js).
  window.__beamlifePerf = { appSaver: state.appSaver === true, mapSaver: state.mapSaver === true }
}
function open() {
  lua("beamlife_core.openPhone")
}
function toggleUnit() {
  unit.value = unit.value === "mph" ? "km/h" : "mph"
  save(UNIT_KEY, unit.value)
}
function toggleMap() {
  mapOn.value = !mapOn.value
  save(MAP_KEY, mapOn.value ? "1" : "0")
}

// The map screen is compiled on first use and on its own, so a problem in it can only cost the
// map, never the clock bar.
async function loadMap() {
  if (mapComponent.value || mapLoading) return
  mapLoading = true
  try {
    let data = await getComponent(MAP_FILE, false, true)
    if (!data?.compiled && typeof data?.compile === "function") data = await data.compile()
    if (data?.error || !data?.component) throw data?.errorObj || new Error(String(data?.error || "no component"))
    mapComponent.value = data.component
  } catch (error) {
    console.error("[beamlife] phone map failed to load", error)
    mapOn.value = false
  } finally {
    mapLoading = false
  }
}

watch(mapOn, shown => { if (shown) loadMap() }, { immediate: true })

onMounted(() => {
  events.on("beamlifeHud", update)
  lua("beamlife_core.requestHud")
})
onUnmounted(() => events.off("beamlifeHud", update))
</script>

<style scoped>
.blhud {
  position: fixed; right: 2.4em; bottom: 0; z-index: 900; display: flex; align-items: flex-end; gap: 0.6em;
  font-family: "Overpass", "Noto Sans", sans-serif; font-size: 13px; color: #f2f4f8; pointer-events: none;
}
.blhud button { font: inherit; color: inherit; cursor: pointer; pointer-events: auto; }

.blhud__limit {
  width: 3.9em; height: 3.9em; margin-bottom: 0.5em; display: flex; flex-direction: column; align-items: center; justify-content: center;
  border: 0.32em solid #d92626; border-radius: 50%; background: #fff; color: #111; opacity: 0.9; line-height: 1;
}
.blhud__limit-value { font-size: 1.35em; font-weight: 800; }
.blhud__limit-unit { font-size: 0.62em; font-weight: 700; color: #444; }

.blhud__phone {
  display: flex; align-items: stretch; width: 19em; max-width: 44vw; opacity: 0.86;
  border: 1px solid rgba(140, 140, 140, 0.4); border-bottom: 0; border-radius: 1.2em 1.2em 0 0; overflow: hidden;
  background: linear-gradient(180deg, rgba(24, 26, 32, 0.92), rgba(10, 11, 14, 0.92));
}
.blhud__phone:hover { opacity: 1; }
.blhud__main { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; gap: 0.15em; padding: 0.5em 0.9em; border: 0; background: transparent; text-align: left; }
.blhud__row { display: flex; align-items: baseline; justify-content: space-between; gap: 1em; }
.blhud__time { font-weight: 800; font-size: 1.1em; white-space: nowrap; }
.blhud__date { color: rgba(255, 255, 255, 0.78); white-space: nowrap; }
.blhud__line { padding-top: 0.2em; border-top: 1px solid rgba(255, 255, 255, 0.12); color: #fcd34d; font-size: 0.92em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.blhud__map { flex: 0 0 auto; padding: 0 0.8em; border: 0; border-left: 1px solid rgba(255, 255, 255, 0.14); background: transparent; font-weight: 800; color: rgba(255, 255, 255, 0.75); }
.blhud__map--on { background: #2563eb; color: #fff; }
</style>
