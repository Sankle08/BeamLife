<template>
  <div class="bl-help" role="dialog" :aria-label="`How ${title} works`" @click.self="$emit('close')">
    <div class="bl-help__card">
      <div class="bl-help__art">
        <img v-if="icon" :src="icon" alt="" class="bl-help__icon">
        <span class="bl-help__step">{{ index + 1 }}</span>
      </div>
      <div class="bl-help__title">{{ page.title }}</div>
      <div class="bl-help__text">{{ page.text }}</div>
      <div class="bl-help__dots" aria-hidden="true">
        <span v-for="(item, dot) in pages" :key="dot" class="bl-help__dot" :class="{ 'bl-help__dot--on': dot === index }"></span>
      </div>
      <div class="bl-btns">
        <button type="button" class="bl-btn" :disabled="index === 0" @click="index--">Back</button>
        <button v-if="index < pages.length - 1" type="button" class="bl-btn bl-btn--main" @click="index++">Next</button>
        <button v-else type="button" class="bl-btn bl-btn--main" @click="$emit('close')">Got it</button>
      </div>
    </div>
  </div>
</template>

<script setup>
// The "?" guide of an app: a few pages, one idea per page, like the game's own intro cards.
import { computed, ref } from "vue"

const props = defineProps({
  title: { type: String, default: "" },
  icon: { type: String, default: "" },
  pages: { type: Array, required: true },
})
defineEmits(["close"])
const index = ref(0)
const page = computed(() => props.pages[index.value] || { title: "", text: "" })
</script>

<style scoped>
.bl-help {
  position: absolute; inset: 0; z-index: 30; display: grid; place-items: center; padding: 1em;
  background: rgba(8, 9, 12, 0.82);
}
.bl-help__card {
  width: 100%; max-width: 30em; display: flex; flex-direction: column; gap: 0.7em; padding: 1.1em;
  background: var(--bl-card); border: 1px solid var(--bl-line); border-radius: 0.9em;
}
.bl-help__art {
  position: relative; height: 7em; display: grid; place-items: center; border-radius: 0.6em;
  background: linear-gradient(135deg, var(--bl-accent), rgba(0, 0, 0, 0.2));
}
.bl-help__icon { width: 4.5em; height: 4.5em; border-radius: 1em; box-shadow: 0 6px 18px rgba(0, 0, 0, 0.45); }
.bl-help__step {
  position: absolute; left: 0.6em; top: 0.5em; width: 1.7em; height: 1.7em; display: grid; place-items: center;
  border-radius: 50%; background: rgba(0, 0, 0, 0.45); font-weight: 800;
}
.bl-help__title { font-size: 1.2em; font-weight: 800; }
.bl-help__text { color: #d5dae6; line-height: 1.45; min-height: 5.8em; }
.bl-help__dots { display: flex; justify-content: center; gap: 0.35em; }
.bl-help__dot { width: 0.45em; height: 0.45em; border-radius: 50%; background: var(--bl-card-2); }
.bl-help__dot--on { background: var(--bl-accent); }
</style>
