<template>
  <BlApp
    title="R2F Club" :subtitle="state?.member ? `${state.rep.title} · level ${state.rep.level}` : 'The car scene'" accent="#e11d48"
    icon="/ui/ui-vue/mods/beamlife/tiles/club.svg" :help="HELP.club"
    :tabs="state?.member ? tabs : []" v-model:tab="tab" :wide="wide" :loading="!state" :notice="notice" @toggle-wide="toggleWide">
    <template v-if="state">
      <template v-if="!state.member">
        <div class="bl-card">
          <div class="bl-title">Join R2F Club</div>
          <div class="bl-text">Weekly meets, rev battles and night races. One fee, paid once.</div>
          <button type="button" class="bl-btn bl-btn--main bl-btn--block" :disabled="working || state.money < state.fee" @click="act('beamlife_club.join')">
            {{ state.money < state.fee ? `Costs ${money(state.fee)}` : `Join for ${money(state.fee)}` }}
          </button>
        </div>
        <div class="bl-section">Next meets</div>
        <MeetList :meets="upcoming" />
      </template>

      <template v-else>
        <div class="bl-meter"><span :style="{ width: `${Math.round(state.rep.progress * 100)}%` }"></span></div>
        <div v-if="state.lastResult" class="bl-card" :class="{ 'bl-card--accent': state.lastResult.won }">
          <div class="bl-sub">Last result</div>
          <div class="bl-text">{{ state.lastResult.text }}</div>
        </div>
        <div v-if="state.busy" class="bl-banner">You are on another task. Finish or cancel it first.</div>

        <template v-if="tab === 'meets'">
          <div v-if="state.meet" class="bl-card bl-card--accent">
            <div class="bl-row bl-row--top">
              <div class="bl-grow">
                <div class="bl-title">{{ state.meet.name }} · on now</div>
                <div class="bl-sub">{{ state.meet.place }}</div>
              </div>
              <span v-if="state.meet.checkedIn" class="bl-pill bl-pill--good">Checked in</span>
              <span v-else-if="state.meet.here" class="bl-pill bl-pill--accent">Stay parked to check in</span>
              <span v-else class="bl-pill">{{ distance(state.meet.distance) }}</span>
            </div>
          </div>
          <MeetList :meets="upcoming" />
          <button type="button" class="bl-btn" @click="act('beamlife_club.navigateToMeet')">Route to the meet</button>
        </template>

        <template v-else-if="tab === 'rev'">
          <div v-if="!state.meet" class="bl-banner">Rev battles only run during a meet.</div>
          <div v-else-if="!state.meet.here" class="bl-banner">Go to {{ state.meet.place }} to enter.</div>
          <div v-else class="bl-sub">Hold 80-95% of the rev limit for 8 seconds. Entries left: {{ state.meet.revLeft }}</div>
          <div class="bl-grid">
            <div v-for="tier in revTiers" :key="tier.id" class="bl-card" :class="{ 'bl-card--muted': tier.locked }">
              <div class="bl-row">
                <div class="bl-title">{{ tier.name }}</div>
                <div class="bl-money">{{ money(tier.bet) }}</div>
              </div>
              <span v-if="tier.locked" class="bl-pill bl-pill--warn">Needs level {{ tier.level }}</span>
              <button type="button" class="bl-btn bl-btn--main" :disabled="tier.locked || !canRev || working" @click="act('beamlife_club.startRev', tier.id)">Enter</button>
            </div>
          </div>
        </template>

        <template v-else>
          <div v-if="state.racing" class="bl-card bl-card--accent">
            <div class="bl-title">{{ state.racing.tier }} · racing</div>
            <div class="bl-sub">Finish: {{ state.racing.destination }} · {{ state.racing.km }} km</div>
            <button type="button" class="bl-btn bl-btn--danger" @click="act('beamlife_club.cancelRace')">Quit race</button>
          </div>
          <div v-if="!state.isNight" class="bl-banner">It is {{ state.time }}. Races run from 9:00 PM to 5:00 AM.</div>
          <div v-else class="bl-sub">The race starts where you are. First to the finish takes double the bet.</div>
          <div class="bl-grid">
            <div v-for="tier in raceTiers" :key="tier.id" class="bl-card" :class="{ 'bl-card--muted': tier.locked }">
              <div class="bl-row">
                <div class="bl-title">{{ tier.name }}</div>
                <div class="bl-money">{{ money(tier.bet) }}</div>
              </div>
              <span v-if="tier.locked" class="bl-pill bl-pill--warn">Needs level {{ tier.level }}</span>
              <button type="button" class="bl-btn bl-btn--main" :disabled="tier.locked || !canRace || working" @click="act('beamlife_club.startRace', tier.id)">Bet and race</button>
            </div>
          </div>
        </template>
      </template>
    </template>
  </BlApp>
</template>

<script setup>
// R2F Club: membership, the meet calendar, rev battles and night races.
import { computed, ref } from "vue"
import BlApp from "../kit/BlApp.vue"
import MeetList from "../kit/MeetList.vue"
import { useBeamlifeApp } from "../kit/useApp.js"
import { lua, list, money, distance } from "../kit/bridge.js"
import { HELP } from "../kit/help.js"

defineProps({ app: { type: Object, default: null }, callLua: { type: Function, default: null } })

const { state, notice, working, wide, act, toggleWide } = useBeamlifeApp("club", () => lua("beamlife_club.getState"))
const tab = ref("meets")
const upcoming = computed(() => list(state.value?.upcoming))
const revTiers = computed(() => list(state.value?.revTiers))
const raceTiers = computed(() => list(state.value?.raceTiers))
const canRev = computed(() => {
  const current = state.value
  return !!current?.meet?.here && current.meet.revLeft > 0 && !current.busy && !current.revving && !current.racing
})
const canRace = computed(() => {
  const current = state.value
  return !!current?.isNight && !current.busy && !current.revving && !current.racing
})
const tabs = computed(() => [
  { id: "meets", label: "Meets", badge: state.value?.meet ? "!" : null },
  { id: "rev", label: "Rev battle" },
  { id: "race", label: "Night race" },
])
</script>
