<template>
  <BlApp
    title="WorkDay" :subtitle="state ? `${state.date} · ${state.time}` : ''" accent="#2563eb"
    icon="/ui/ui-vue/mods/beamlife/tiles/jobs.svg" :help="HELP.jobs"
    :tabs="tabs" v-model:tab="tab" :wide="wide" :loading="!state" :notice="notice" @toggle-wide="toggleWide">
    <template v-if="state">
      <template v-if="tab === 'mine'">
        <div v-if="!jobs.length" class="bl-empty">No job yet. Look under Openings.</div>
        <div class="bl-grid">
          <div v-for="job in jobs" :key="job.id" class="bl-card" :class="{ 'bl-card--accent': job.status === 'open' }">
            <div class="bl-row bl-row--top">
              <div class="bl-grow">
                <div class="bl-title">{{ job.title }}</div>
                <div class="bl-sub">{{ job.company }} · {{ job.schedule }}</div>
              </div>
              <div class="bl-money">${{ job.wage }}/h</div>
            </div>
            <div class="bl-row bl-row--wrap">
              <span class="bl-pill" :class="statusClass(job.status)">{{ job.statusText }}</span>
              <span v-if="job.atWork" class="bl-pill bl-pill--good">You are here</span>
              <span v-else-if="job.distance != null" class="bl-pill">{{ distance(job.distance) }} away</span>
              <span v-if="job.misses" class="bl-pill bl-pill--bad">{{ job.misses }}/{{ job.maxMisses }} missed</span>
            </div>
            <div class="bl-row bl-row--wrap">
              <span class="bl-sub">
                <template v-if="job.payMode === 'weekly'">Payslip {{ money(job.accrued) }} · </template>
                <template v-if="job.nextRaiseIn">raise in {{ job.nextRaiseIn }} shifts</template>
              </span>
              <div class="bl-seg">
                <button type="button" :class="{ on: job.payMode === 'daily' }" @click="act('beamlife_jobs.setPayMode', job.id, 'daily')">Daily</button>
                <button type="button" :class="{ on: job.payMode === 'weekly' }" @click="act('beamlife_jobs.setPayMode', job.id, 'weekly')">Weekly +{{ state.weeklyBonus }}%</button>
              </div>
            </div>
            <div class="bl-btns">
              <button type="button" class="bl-btn bl-btn--main" :disabled="!job.canClockIn || working" @click="act('beamlife_jobs.clockIn', job.id)">Clock in</button>
              <button type="button" class="bl-btn" @click="act('beamlife_jobs.navigate', job.id)">Route</button>
              <button type="button" class="bl-btn bl-btn--danger" @click="confirmQuit(job)">{{ quitting === job.id ? "Press again" : "Quit" }}</button>
            </div>
          </div>
        </div>
      </template>

      <template v-else>
        <div class="bl-row">
          <span class="bl-sub">Work level {{ state.profile.level }}</span>
          <span class="bl-sub">{{ state.profile.xp }} / {{ state.profile.nextLevelXp }} XP</span>
        </div>
        <div class="bl-meter"><span :style="{ width: `${Math.round(state.profile.progress * 100)}%` }"></span></div>
        <div class="bl-grid">
          <div v-for="offer in offers" :key="offer.id" class="bl-card" :class="{ 'bl-card--muted': offer.locked }">
            <div class="bl-row bl-row--top">
              <div class="bl-grow">
                <div class="bl-title">{{ offer.title }}</div>
                <div class="bl-sub">{{ offer.company }} · {{ offer.schedule }}</div>
              </div>
              <div class="bl-money">${{ offer.wage }}/h</div>
            </div>
            <div class="bl-text">{{ offer.desc }}</div>
            <div class="bl-row bl-row--wrap">
              <span class="bl-pill">about {{ money(offer.weekly) }} a week</span>
              <span v-if="offer.lockReason" class="bl-pill bl-pill--warn">{{ offer.lockReason }}</span>
            </div>
            <button type="button" class="bl-btn bl-btn--main bl-btn--block" :disabled="offer.locked || working" @click="act('beamlife_jobs.apply', offer.id, 'daily')">Take this job</button>
          </div>
        </div>
      </template>
    </template>
  </BlApp>
</template>

<script setup>
// WorkDay: regular jobs with a timetable. "My jobs" shows today's shift and the clock-in button;
// "Openings" lists what the map's employers are hiring for, best paid first.
import { computed, ref } from "vue"
import BlApp from "../kit/BlApp.vue"
import { useBeamlifeApp } from "../kit/useApp.js"
import { lua, list, money, distance } from "../kit/bridge.js"
import { HELP } from "../kit/help.js"

defineProps({ app: { type: Object, default: null }, callLua: { type: Function, default: null } })

const { state, notice, working, wide, act, toggleWide } = useBeamlifeApp("jobs", () => lua("beamlife_jobs.getState"))
const tab = ref("mine")
const quitting = ref(null)

const jobs = computed(() => list(state.value?.jobs))
const offers = computed(() => [...list(state.value?.offers)].sort((a, b) => (a.locked - b.locked) || (b.wage - a.wage)))
const tabs = computed(() => [
  { id: "mine", label: "My jobs", badge: jobs.value.filter(job => job.status === "open").length || null },
  { id: "offers", label: "Openings" },
])

function statusClass(status) {
  if (status === "open") return "bl-pill--accent"
  if (status === "done") return "bl-pill--good"
  if (status === "lost") return "bl-pill--bad"
  return ""
}

// Quitting takes two presses of the same button.
async function confirmQuit(job) {
  if (quitting.value !== job.id) {
    quitting.value = job.id
    return
  }
  quitting.value = null
  await act("beamlife_jobs.quit", job.id)
}
</script>
