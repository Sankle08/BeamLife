<template>
  <div class="blmap" aria-label="Phone map">
    <div ref="screen" class="blmap__screen"></div>
    <span class="blmap__time">{{ time }}</span>
    <button type="button" class="blmap__close" aria-label="Hide the phone map" @click="$emit('close')">×</button>
  </div>
</template>

<script setup>
// The phone lying on its side as a navigation map. The map itself is the Overhaul's phone map
// (the one behind its Taxi app), so it shows the same roads and the player's arrow.
import { onMounted, onUnmounted, ref, watch } from "vue"
import { useMinimapStore } from "../../rls_career_overhaul/overhaul/modules/career/stores/minimapStore.js"

const props = defineProps({ time: { type: String, default: "" }, saver: { type: Boolean, default: false } })
defineEmits(["close"])

const store = useMinimapStore()
const screen = ref(null)
let view = null

// The map saver hides the terrain picture; only roads are drawn.
watch(() => props.saver, saver => { store.showTerrainImage = !saver }, { immediate: true })

onMounted(() => {
  store.acquire()
  view = store.mountMap(screen.value, { fit: "slice" })
})
onUnmounted(() => {
  store.showTerrainImage = true
  view?.dispose()
  store.release()
})
</script>

<style scoped>
.blmap {
  position: fixed; left: 1.2em; bottom: 1.2em; z-index: 900; width: 26em; max-width: 34vw; aspect-ratio: 16 / 9;
  padding: 0.35em; border-radius: 1.3em; background: linear-gradient(160deg, #2a2a2a, #050505);
  border: 1px solid rgba(120, 120, 120, 0.4); box-shadow: 0 6px 22px rgba(0, 0, 0, 0.55); font-size: 13px;
}
.blmap__screen { position: relative; width: 100%; height: 100%; border-radius: 1em; overflow: hidden; background: #1b1e25; }
.blmap__time {
  position: absolute; left: 1em; top: 0.75em; padding: 0.1em 0.5em; border-radius: 1em;
  background: rgba(0, 0, 0, 0.6); color: #fff; font-weight: 800; font-size: 0.9em;
}
.blmap__close {
  position: absolute; right: 0.8em; top: 0.65em; width: 1.6em; height: 1.6em; border: 0; border-radius: 50%;
  background: rgba(0, 0, 0, 0.6); color: #fff; font: inherit; font-weight: 800; cursor: pointer; pointer-events: auto;
}
</style>
