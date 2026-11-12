<template>
  <div v-if="!meets.length" class="bl-empty">No meets on this map.</div>
  <div v-else class="bl-grid">
    <div v-for="(meet, index) in meets" :key="index" class="bl-card">
      <div class="bl-row bl-row--top">
        <div class="bl-grow">
          <div class="bl-title">{{ meet.name }}</div>
          <div class="bl-sub">{{ meet.place }} · {{ meet.time }}</div>
        </div>
        <span class="bl-pill" :class="{ 'bl-pill--accent': meet.today }">{{ meet.today ? "Today" : meet.day }}</span>
      </div>
    </div>
  </div>
</template>

<script setup>
// The club's next meets: name, place, day and hours.
defineProps({ meets: { type: Array, default: () => [] } })
</script>
