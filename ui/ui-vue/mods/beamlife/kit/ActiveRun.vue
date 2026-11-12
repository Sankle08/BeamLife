<template>
  <div class="bl-card bl-card--accent">
    <div class="bl-row bl-row--top">
      <div class="bl-grow">
        <div class="bl-sub">In progress · stop {{ run.step }} of {{ run.steps }}</div>
        <div class="bl-title">{{ run.label }}</div>
      </div>
      <div v-if="run.pay" class="bl-money">{{ money(run.pay) }}</div>
    </div>
    <div class="bl-facts">
      <span v-if="run.waiting">stay parked for <b>{{ run.dwellLeft }} s</b></span>
      <span v-else-if="run.distance != null"><b>{{ distance(run.distance) }}</b> to go</span>
      <span v-if="run.secondsLeft != null" :class="{ 'bl-late': run.secondsLeft <= 0 }">
        time left <b>{{ run.secondsLeft > 0 ? clock(run.secondsLeft) : "late" }}</b>
      </span>
    </div>
    <button type="button" class="bl-btn bl-btn--danger" @click="confirm">
      {{ armed ? "Press again to cancel" : "Cancel" }}
    </button>
  </div>
</template>

<script setup>
// The task the player is driving right now: where to go, how far, how long is left.
import { ref } from "vue"
import { money, distance, clock } from "./bridge.js"

defineProps({ run: { type: Object, required: true } })
const emit = defineEmits(["cancel"])
const armed = ref(false)

// Cancelling takes two presses, so a slip of the thumb does not throw a job away.
function confirm() {
  if (!armed.value) {
    armed.value = true
    return
  }
  armed.value = false
  emit("cancel")
}
</script>

<style scoped>
.bl-late b { color: var(--bl-bad); }
</style>
