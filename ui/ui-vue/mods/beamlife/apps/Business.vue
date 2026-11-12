<template>
  <BlApp
    title="Business" :subtitle="state ? `About ${money(state.dailyTotal)} a day` : ''" accent="#7c3aed"
    icon="/ui/ui-vue/mods/beamlife/tiles/business.svg" :help="HELP.business"
    :tabs="tabs" v-model:tab="tab" :wide="wide" :loading="!state" :notice="notice" @toggle-wide="toggleWide">
    <template v-if="state">
      <template v-if="tab === 'mine'">
        <div v-if="!owned.length" class="bl-empty">You do not own a business yet. See what is for sale.</div>
        <button
          v-if="state.boxTotal > 0" type="button" class="bl-btn bl-btn--main" :disabled="working"
          @click="act('beamlife_business.collect')">Collect all · {{ money(state.boxTotal) }}</button>
        <div class="bl-grid">
          <div v-for="item in owned" :key="item.id" class="bl-card" :class="{ 'bl-card--accent': item.full }">
            <div class="bl-row bl-row--top">
              <div class="bl-grow">
                <div class="bl-title">{{ item.name }} <span class="bl-pill">level {{ item.level }}/{{ item.maxLevel }}</span></div>
                <div class="bl-sub">{{ item.model }}</div>
              </div>
              <div class="bl-money" :class="{ 'bl-money--bad': item.expected < 0 }">{{ money(item.expected) }}/day</div>
            </div>
            <template v-if="!item.manager">
              <div class="bl-row">
                <span class="bl-sub">Cash box {{ money(item.balance) }} of {{ money(item.cap) }}</span>
                <span v-if="item.full" class="bl-pill bl-pill--warn">Full</span>
              </div>
              <div class="bl-meter"><span :style="{ width: `${Math.min(100, Math.max(0, Math.round(item.balance / item.cap * 100)))}%` }"></span></div>
            </template>
            <span v-else class="bl-pill bl-pill--good">Manager banks the profit daily</span>
            <div class="bl-btns">
              <button
                v-if="!item.manager" type="button" class="bl-btn bl-btn--main" :disabled="item.balance <= 0 || working"
                @click="act('beamlife_business.collect', item.id)">Collect</button>
              <button type="button" class="bl-btn" :disabled="working" @click="act('beamlife_business.setManager', item.id, !item.manager)">
                {{ item.manager ? "Fire manager" : `Hire manager (${state.managerCut}%)` }}
              </button>
              <button
                v-if="item.upgradeCost" type="button" class="bl-btn" :disabled="working || state.money < item.upgradeCost"
                @click="act('beamlife_business.upgrade', item.id)">Upgrade {{ money(item.upgradeCost) }}</button>
              <button type="button" class="bl-btn bl-btn--danger" @click="confirmSell(item)">
                {{ selling === item.id ? `Sell for ${money(item.sellValue)}?` : "Sell" }}
              </button>
            </div>
          </div>
        </div>
      </template>

      <template v-else>
        <div class="bl-sub">Balance {{ money(state.money) }}</div>
        <div class="bl-grid">
          <div v-for="item in market" :key="item.id" class="bl-card" :class="{ 'bl-card--muted': item.locked }">
            <div class="bl-row bl-row--top">
              <div class="bl-grow">
                <div class="bl-title">{{ item.name }}</div>
                <div class="bl-sub">{{ item.model }}</div>
              </div>
              <div class="bl-money">{{ money(item.price) }}</div>
            </div>
            <div class="bl-row bl-row--wrap">
              <span class="bl-pill">about {{ money(item.expected) }} a day</span>
              <span v-if="item.payback" class="bl-pill">pays back in {{ item.payback }} days</span>
              <span v-if="item.discount" class="bl-pill bl-pill--good">Former employee: -{{ item.discount }}%</span>
              <span v-if="item.reason" class="bl-pill bl-pill--warn">{{ item.reason }}</span>
            </div>
            <button
              type="button" class="bl-btn bl-btn--main bl-btn--block" :disabled="item.locked || !item.affordable || working"
              @click="act('beamlife_business.buy', item.id)">{{ item.affordable || item.locked ? "Buy" : "Not enough money" }}</button>
          </div>
        </div>
      </template>
    </template>
  </BlApp>
</template>

<script setup>
// Business: the shops and companies the player owns, and the ones for sale.
import { computed, ref } from "vue"
import BlApp from "../kit/BlApp.vue"
import { useBeamlifeApp } from "../kit/useApp.js"
import { lua, list, money } from "../kit/bridge.js"
import { HELP } from "../kit/help.js"

defineProps({ app: { type: Object, default: null }, callLua: { type: Function, default: null } })

const { state, notice, working, wide, act, toggleWide } = useBeamlifeApp("business", () => lua("beamlife_business.getState"))
const tab = ref("mine")
const selling = ref(null)
const owned = computed(() => list(state.value?.owned))
const market = computed(() => list(state.value?.market))
const tabs = computed(() => [
  { id: "mine", label: "Mine", badge: owned.value.length || null },
  { id: "market", label: "For sale" },
])

// Selling takes two presses of the same button.
async function confirmSell(item) {
  if (selling.value !== item.id) {
    selling.value = item.id
    return
  }
  selling.value = null
  await act("beamlife_business.sell", item.id)
}
</script>
