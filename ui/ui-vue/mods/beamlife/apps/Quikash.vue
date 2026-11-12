<template>
  <BlApp
    title="Quikash" :subtitle="state ? `Driving: ${state.vehicle}` : ''" accent="#f59e0b"
    icon="/ui/ui-vue/mods/beamlife/tiles/gigs.svg" :help="HELP.quikash"
    :wide="wide" :loading="!state" :notice="notice" @toggle-wide="toggleWide">
    <template v-if="state">
      <ActiveRun v-if="state.active" :run="state.active" @cancel="act('beamlife_gigs.cancel')" />
      <div v-else-if="state.busy" class="bl-banner">You are on another task. Finish or cancel it first.</div>

      <div class="bl-row">
        <div class="bl-section">Jobs right now</div>
        <span class="bl-sub">new in {{ gameHours(state.refreshIn) }}</span>
      </div>
      <div v-if="!offers.length" class="bl-empty">Nothing right now. Check back later.</div>
      <div class="bl-grid">
        <div v-for="offer in offers" :key="offer.id" class="bl-card" :class="{ 'bl-card--muted': !offer.eligible }">
          <div class="bl-row bl-row--top">
            <div class="bl-grow">
              <div class="bl-title">{{ offer.title }}</div>
              <div class="bl-sub">{{ offer.km }} km · starts {{ distance(offer.toStart) }} away</div>
            </div>
            <div class="bl-money">{{ money(offer.pay) }}</div>
          </div>
          <div class="bl-route">
            <div class="bl-route__stop"><span class="bl-route__dot"></span><span>{{ offer.from }}</span></div>
            <div class="bl-route__stop"><span class="bl-route__dot bl-route__dot--end"></span><span>{{ offer.to }}</span></div>
          </div>
          <span v-if="offer.reason" class="bl-pill bl-pill--warn">{{ offer.reason }}</span>
          <button
            type="button" class="bl-btn bl-btn--main bl-btn--block"
            :disabled="!offer.eligible || !!state.active || state.busy || working"
            @click="act('beamlife_gigs.accept', offer.id)">Accept</button>
        </div>
      </div>
    </template>
  </BlApp>
</template>

<script setup>
// Quikash: one-off jobs paid on the spot, best paid first. The board changes every three in-game hours.
import { computed } from "vue"
import BlApp from "../kit/BlApp.vue"
import ActiveRun from "../kit/ActiveRun.vue"
import { useBeamlifeApp } from "../kit/useApp.js"
import { lua, list, money, distance, gameHours } from "../kit/bridge.js"
import { HELP } from "../kit/help.js"

defineProps({ app: { type: Object, default: null }, callLua: { type: Function, default: null } })

const { state, notice, working, wide, act, toggleWide } = useBeamlifeApp("gigs", () => lua("beamlife_gigs.getState"))
const offers = computed(() => [...list(state.value?.offers)].sort((a, b) => (b.eligible - a.eligible) || (b.pay - a.pay)))
</script>
