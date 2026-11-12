<template>
  <BlApp
    title="DashTube" :subtitle="state ? `${compact(state.channel.subscribers)} subscribers · ${money(state.channel.earned)} earned` : ''"
    accent="#dc2626" icon="/ui/ui-vue/mods/beamlife/tiles/dashtube.svg" :help="HELP.dashtube"
    :tabs="tabs" v-model:tab="tab" :wide="wide" :loading="!state" :notice="notice" @toggle-wide="toggleWide">
    <template v-if="state">
      <div v-if="state.recording" class="bl-card bl-card--accent">
        <div class="bl-row">
          <div class="bl-title"><span class="dt-rec"></span> Recording pursuit</div>
          <span class="bl-pill bl-pill--bad">{{ clock(state.recordingSeconds) }}</span>
        </div>
      </div>

      <div v-if="!shown.length" class="bl-empty">
        {{ tab === "drafts" ? "No recordings. The dashcam saves every police pursuit by itself." : "Nothing published yet." }}
      </div>
      <div class="bl-grid">
        <div v-for="clip in shown" :key="clip.id" class="bl-card">
          <div class="dt-thumb" aria-hidden="true">
            <span class="dt-thumb__play"></span>
            <span class="dt-thumb__time">{{ clock(clip.seconds) }}</span>
            <span class="dt-thumb__speed">{{ clip.topSpeed }} km/h</span>
          </div>
          <div class="bl-row bl-row--top">
            <div class="bl-grow">
              <div class="bl-title">{{ titleOf(clip) }}</div>
              <div class="bl-sub">{{ clip.date }} · {{ clip.km }} km · {{ clip.units }} units</div>
            </div>
            <span class="bl-pill" :class="clip.outcome === 'evaded' ? 'bl-pill--good' : 'bl-pill--bad'">
              {{ clip.outcome === "evaded" ? "Got away" : "Busted" }}
            </span>
          </div>
          <template v-if="clip.published">
            <div class="bl-row bl-row--wrap">
              <span class="bl-pill">{{ compact(clip.views) }} views</span>
              <span class="bl-pill bl-pill--good">{{ money(clip.earned) }}</span>
              <span v-if="clip.stillEarning" class="bl-pill">still earning</span>
            </div>
          </template>
          <template v-else>
            <div class="bl-sub">Should make {{ money(clip.estimate * 0.6) }} to {{ money(clip.estimate * 1.6) }}.</div>
            <div class="bl-btns">
              <button type="button" class="bl-btn bl-btn--main" :disabled="working" @click="act('beamlife_dashcam.publish', clip.id)">Publish</button>
              <button type="button" class="bl-btn bl-btn--danger" :disabled="working" @click="act('beamlife_dashcam.delete', clip.id)">Delete</button>
            </div>
          </template>
        </div>
      </div>
    </template>
  </BlApp>
</template>

<script setup>
// DashTube: the dashcam's pursuit recordings and the player's channel. A clip has no playable
// video; its card shows what the chase was, and publishing it pays over the following days.
import { computed, ref } from "vue"
import BlApp from "../kit/BlApp.vue"
import { useBeamlifeApp } from "../kit/useApp.js"
import { lua, list, money, clock, compact } from "../kit/bridge.js"
import { HELP } from "../kit/help.js"

defineProps({ app: { type: Object, default: null }, callLua: { type: Function, default: null } })

const { state, notice, working, wide, act, toggleWide } = useBeamlifeApp("dashcam", () => lua("beamlife_dashcam.getState"))
const tab = ref("drafts")
const clips = computed(() => list(state.value?.clips))
const drafts = computed(() => clips.value.filter(clip => !clip.published))
const published = computed(() => clips.value.filter(clip => clip.published))
const shown = computed(() => (tab.value === "drafts" ? drafts.value : published.value))
const tabs = computed(() => [
  { id: "drafts", label: "Recordings", badge: drafts.value.length || null },
  { id: "published", label: "Published" },
])

function titleOf(clip) {
  if (clip.outcome !== "evaded") return `Tried to run at ${clip.topSpeed} km/h. It went badly`
  if (clip.level >= 3) return `Insane escape: ${clip.units} police units on my tail`
  if (clip.topSpeed >= 200) return `${clip.topSpeed} km/h with the police behind me`
  return `Lost the police in ${clock(clip.seconds)}`
}
</script>

<style scoped>
.dt-rec { display: inline-block; width: 0.7em; height: 0.7em; margin-right: 0.3em; border-radius: 50%; background: var(--bl-bad); }
.dt-thumb {
  position: relative; height: 6em; border-radius: 0.5em; overflow: hidden;
  background: linear-gradient(to top, rgba(0, 0, 0, 0.75), rgba(0, 0, 0, 0) 55%), #253044;
}
.dt-thumb__play {
  position: absolute; left: 50%; top: 50%; width: 0; height: 0; transform: translate(-35%, -50%);
  border-left: 1.3em solid rgba(255, 255, 255, 0.45); border-top: 0.85em solid transparent; border-bottom: 0.85em solid transparent;
}
.dt-thumb__time, .dt-thumb__speed {
  position: absolute; bottom: 0.4em; padding: 0.05em 0.45em; border-radius: 0.3em; background: rgba(0, 0, 0, 0.7);
  font-size: 0.82em; font-weight: 800;
}
.dt-thumb__time { right: 0.5em; }
.dt-thumb__speed { left: 0.5em; color: var(--bl-warn); }
</style>
