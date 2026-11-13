<template>
  <BlApp
    title="Performance" subtitle="Lighter game, same world" accent="#16a34a"
    icon="/ui/ui-vue/mods/beamlife/tiles/performance.svg" :help="HELP.performance"
    :wide="wide" :loading="!state" :notice="notice" @toggle-wide="toggleWide">
    <template v-if="state">
      <div v-if="!state.available" class="bl-banner">Settings are not available right now.</div>

      <div class="bl-section">Presets</div>
      <div class="bl-seg bl-seg--full">
        <button
          v-for="preset in PRESETS" :key="preset.id" type="button" :class="{ on: state.preset === preset.id }"
          :disabled="working" @click="act('beamlife_perf.preset', preset.id)">{{ preset.label }}</button>
      </div>
      <div class="bl-sub">{{ state.preset ? presetHint : "Custom: your own mix of the options below." }}</div>

      <div class="bl-section">Options</div>
      <div class="bl-grid">
        <div v-for="option in options" :key="option.key" class="bl-card">
          <div class="bl-title">{{ option.title }}</div>
          <div class="bl-sub">{{ option.hint }}</div>
          <div class="bl-seg bl-seg--full">
            <button
              v-for="choice in list(option.choices)" :key="String(choice.value)" type="button"
              :class="{ on: choice.value === option.value }" :disabled="working"
              @click="act('beamlife_perf.set', option.key, choice.value)">{{ choice.label }}</button>
          </div>
        </div>
      </div>
    </template>
  </BlApp>
</template>

<script setup>
// Performance: switches that make the game lighter without taking anything away from the drive.
// A preset sets them all at once; each one can still be changed on its own afterwards.
import { computed } from "vue"
import BlApp from "../kit/BlApp.vue"
import { useBeamlifeApp } from "../kit/useApp.js"
import { lua, list } from "../kit/bridge.js"
import { HELP } from "../kit/help.js"

defineProps({ app: { type: Object, default: null }, callLua: { type: Function, default: null } })

const PRESETS = [
  { id: "quality", label: "Quality", hint: "Everything as the game and the Overhaul set it." },
  { id: "balanced", label: "Balanced", hint: "Fewer AI and parked cars; the rest unchanged." },
  { id: "performance", label: "Performance", hint: "Light traffic, small crowds, calm weather, savers on." },
]

const { state, notice, working, wide, act, toggleWide } = useBeamlifeApp("performance", () => lua("beamlife_perf.getState"))
const options = computed(() => list(state.value?.options))
const presetHint = computed(() => PRESETS.find(preset => preset.id === state.value?.preset)?.hint || "")
</script>

<style scoped>
.bl-seg--full { display: flex; flex-wrap: wrap; }
.bl-seg--full button { flex: 1 1 0; min-width: 4.5em; }
</style>
