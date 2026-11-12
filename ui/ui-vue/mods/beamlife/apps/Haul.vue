<template>
  <BlApp
    title="Haulr" :subtitle="state ? `Driving: ${state.vehicle}` : ''" accent="#0d9488"
    icon="/ui/ui-vue/mods/beamlife/tiles/heavy.svg" :help="HELP.haul"
    :tabs="tabs" v-model:tab="tab" :wide="wide" :loading="!state" :notice="notice" @toggle-wide="toggleWide">
    <template v-if="state">
      <div class="bl-seg bl-seg--full">
        <button type="button" :class="{ on: carrier === 'heavy' }" @click="pick('heavy')">Interstate Freight</button>
        <button type="button" :class="{ on: carrier === 'medium' }" @click="pick('medium')">QuickPack</button>
      </div>

      <ActiveRun v-if="state.active" :run="state.active" @cancel="act('beamlife_freight.cancel', carrier)" />
      <div v-else-if="state.busy" class="bl-banner">You are on another task. Finish or cancel it first.</div>
      <div v-else-if="!state.eligible" class="bl-banner">{{ state.reason }}</div>

      <div class="bl-row">
        <span class="bl-sub">Reputation {{ state.rep.level }}/{{ state.rep.max }}<template v-if="state.rep.payBonus"> · +{{ state.rep.payBonus }}% pay</template></span>
        <span v-if="state.contract" class="bl-pill bl-pill--accent">
          {{ state.contract.title }}: {{ state.contract.done }}/{{ state.contract.quota }} this week
        </span>
      </div>
      <div class="bl-meter"><span :style="{ width: `${Math.round(state.rep.progress * 100)}%` }"></span></div>

      <template v-if="tab === 'routes'">
        <div v-if="!routes.length" class="bl-empty">No routes right now. New ones in {{ gameHours(state.refreshIn) }}.</div>
        <div class="bl-grid">
          <div v-for="route in routes" :key="route.id" class="bl-card">
            <div class="bl-row bl-row--top">
              <div class="bl-grow">
                <div class="bl-title">{{ route.cargo }}</div>
                <div class="bl-sub">{{ route.km }} km · loading {{ distance(route.toStart) }} away</div>
              </div>
              <div class="bl-money">{{ money(route.pay) }}</div>
            </div>
            <div class="bl-route">
              <div class="bl-route__stop"><span class="bl-route__dot"></span><span>{{ route.from }}</span></div>
              <div v-for="(stop, index) in list(route.stops)" :key="index" class="bl-route__stop">
                <span class="bl-route__dot bl-route__dot--end"></span><span>{{ stop }}</span>
              </div>
            </div>
            <button
              type="button" class="bl-btn bl-btn--main bl-btn--block"
              :disabled="!state.eligible || !!state.active || state.busy || working"
              @click="act('beamlife_freight.accept', carrier, route.id)">Accept</button>
          </div>
        </div>
      </template>

      <template v-else>
        <div class="bl-grid">
          <div
            v-for="position in positions" :key="position.id" class="bl-card"
            :class="{ 'bl-card--accent': position.current, 'bl-card--muted': position.locked }">
            <div class="bl-row bl-row--top">
              <div class="bl-grow">
                <div class="bl-title">{{ position.title }}</div>
                <div class="bl-sub">{{ position.desc }}</div>
              </div>
              <span v-if="position.current" class="bl-pill bl-pill--accent">Your job</span>
            </div>
            <div class="bl-facts">
              <span><b>{{ position.quota }}</b> routes a week</span>
              <span><b>{{ money(position.bonus) }}</b> weekly bonus</span>
              <span><b>+{{ position.payBonus }}%</b> per route</span>
            </div>
            <span v-if="position.locked" class="bl-pill bl-pill--warn">Needs reputation {{ position.rep }}</span>
            <button
              v-if="position.current" type="button" class="bl-btn bl-btn--danger"
              @click="act('beamlife_freight.leavePosition', carrier)">Leave</button>
            <button
              v-else type="button" class="bl-btn bl-btn--main" :disabled="position.locked || working"
              @click="act('beamlife_freight.takePosition', carrier, position.id)">Take this job</button>
          </div>
        </div>
      </template>
    </template>
  </BlApp>
</template>

<script setup>
// Haulr: both freight carriers in one app. The switch at the top picks the carrier; "Routes" is its
// board, best paid first, and "Jobs" lists the positions it offers.
import { computed, ref } from "vue"
import BlApp from "../kit/BlApp.vue"
import ActiveRun from "../kit/ActiveRun.vue"
import { useBeamlifeApp } from "../kit/useApp.js"
import { lua, list, money, distance, gameHours } from "../kit/bridge.js"
import { HELP } from "../kit/help.js"

defineProps({ app: { type: Object, default: null }, callLua: { type: Function, default: null } })

const CARRIER_KEY = "beamlife.carrier"
function savedCarrier() {
  try {
    return localStorage.getItem(CARRIER_KEY) === "medium" ? "medium" : "heavy"
  } catch {
    return "heavy"
  }
}

const carrier = ref(savedCarrier())
const { state, notice, working, wide, act, refresh, toggleWide } = useBeamlifeApp(
  "freight", () => lua("beamlife_freight.getState", carrier.value))
const tab = ref("routes")
const routes = computed(() => [...list(state.value?.routes)].sort((a, b) => b.pay - a.pay))
const positions = computed(() => list(state.value?.positions))
const tabs = computed(() => [
  { id: "routes", label: "Routes", badge: routes.value.length || null },
  { id: "positions", label: "Jobs", badge: positions.value.filter(position => !position.locked && !position.current).length || null },
])

function pick(id) {
  carrier.value = id
  try {
    localStorage.setItem(CARRIER_KEY, id)
  } catch { /* the choice simply does not persist */ }
  refresh()
}
</script>

<style scoped>
.bl-seg--full { display: flex; }
.bl-seg--full button { flex: 1 1 0; }
</style>
