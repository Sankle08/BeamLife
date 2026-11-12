<template>
  <div class="bl-app" :class="{ 'bl-app--wide': wide }" :style="{ '--bl-accent': accent }">
    <header class="bl-head">
      <div class="bl-head__text">
        <div class="bl-head__title">{{ title }}</div>
        <div v-if="subtitle" class="bl-head__sub">{{ subtitle }}</div>
      </div>
      <div class="bl-head__side">
        <slot name="head" />
        <button v-if="help.length" type="button" class="bl-size" aria-label="How this app works" @click="helpOpen = true">?</button>
        <button
          type="button" class="bl-size"
          :aria-label="wide ? 'Use phone size' : 'Use large screen'"
          @click="$emit('toggle-wide')">
          <span class="bl-size__glyph" :class="{ 'bl-size__glyph--wide': wide }" aria-hidden="true"></span>
        </button>
      </div>
    </header>

    <nav v-if="tabs.length" class="bl-tabs">
      <button
        v-for="item in tabs" :key="item.id" type="button" class="bl-tab"
        :class="{ 'bl-tab--on': item.id === tab }" @click="$emit('update:tab', item.id)">
        {{ item.label }}<span v-if="item.badge" class="bl-tab__badge">{{ item.badge }}</span>
      </button>
    </nav>

    <div class="bl-body" v-bng-ui-nav-scroll>
      <div v-if="loading" class="bl-empty">Loading...</div>
      <slot v-else />
    </div>

    <HelpSheet v-if="helpOpen" :title="title" :icon="icon" :pages="help" @close="helpOpen = false" />

    <Transition name="bl-notice">
      <div v-if="notice" class="bl-notice" :class="{ 'bl-notice--bad': notice.ok === false }" role="status">
        {{ notice.text }}
      </div>
    </Transition>
  </div>
</template>

<script setup>
// The frame every BeamLife phone app shares: header, tabs, scrolling body and the action notice.
// Its unscoped styles are the BeamLife look (cards, rows, buttons, meters) the apps build with.
import { ref } from "vue"
import { vBngUiNavScroll } from "@/common/directives"
import HelpSheet from "./HelpSheet.vue"

defineProps({
  title: { type: String, required: true },
  subtitle: { type: String, default: "" },
  accent: { type: String, default: "#3b82f6" },
  tabs: { type: Array, default: () => [] },
  tab: { type: String, default: "" },
  wide: { type: Boolean, default: false },
  loading: { type: Boolean, default: false },
  notice: { type: Object, default: null },
  // Pages of the "?" guide: [{ title, text }]. No pages, no "?" button.
  help: { type: Array, default: () => [] },
  icon: { type: String, default: "" },
})
const helpOpen = ref(false)
defineEmits(["update:tab", "toggle-wide"])
</script>

<style>
.bl-app {
  --bl-accent: #3b82f6;
  --bl-bg: #12141a;
  --bl-card: #1c1f28;
  --bl-card-2: #252936;
  --bl-line: rgba(255, 255, 255, 0.09);
  --bl-text: #f2f4f8;
  --bl-dim: #9aa3b5;
  --bl-good: #4ade80;
  --bl-warn: #fbbf24;
  --bl-bad: #f87171;
  position: absolute;
  inset: 0;
  display: flex;
  flex-direction: column;
  box-sizing: border-box;
  padding-top: var(--phone-status-bar-height, 40px);
  background: var(--bl-bg);
  color: var(--bl-text);
  font-family: "Overpass", "Noto Sans", sans-serif;
  font-size: 13.5px;
  line-height: 1.35;
  overflow: hidden;
}
.bl-app * { box-sizing: border-box; }
.bl-app button { font: inherit; color: inherit; cursor: pointer; }

.bl-app--wide { font-size: 16px; }

.bl-head {
  flex: 0 0 auto;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.75em;
  padding: 0.7em 1em 0.75em;
  background: linear-gradient(135deg, var(--bl-accent), rgba(0, 0, 0, 0) 130%), var(--bl-card);
  border-bottom: 1px solid var(--bl-line);
}
.bl-head__text { min-width: 0; }
.bl-head__title { font-size: 1.3em; font-weight: 800; letter-spacing: 0.01em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.bl-head__sub { font-size: 0.86em; color: rgba(255, 255, 255, 0.82); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.bl-head__side { flex: 0 0 auto; display: flex; align-items: center; gap: 0.6em; }

.bl-size {
  width: 2.1em; height: 2.1em; display: grid; place-items: center; font-weight: 800;
  border: 1px solid rgba(255, 255, 255, 0.3); border-radius: 0.5em; background: rgba(0, 0, 0, 0.28);
}
.bl-size__glyph { width: 0.6em; height: 1em; border: 2px solid #fff; border-radius: 2px; }
.bl-size__glyph--wide { width: 1.15em; height: 0.75em; }

.bl-tabs {
  flex: 0 0 auto; display: flex; gap: 0.3em; padding: 0.45em 0.6em;
  background: var(--bl-card); border-bottom: 1px solid var(--bl-line);
}
.bl-tab {
  flex: 1 1 0; min-width: 0; padding: 0.5em 0.4em; border: 0; border-radius: 0.5em; background: transparent;
  color: var(--bl-dim); font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.bl-tab--on { background: var(--bl-card-2); color: var(--bl-text); box-shadow: inset 0 -2px 0 var(--bl-accent); }
.bl-tab__badge {
  display: inline-block; margin-left: 0.4em; min-width: 1.5em; padding: 0 0.35em; border-radius: 1em;
  background: var(--bl-accent); color: #fff; font-size: 0.8em; line-height: 1.5;
}

.bl-body { flex: 1 1 auto; min-height: 0; overflow-y: auto; padding: 0.75em; display: flex; flex-direction: column; gap: 0.65em; }
.bl-app--wide .bl-body { padding: 1em 1.25em; }

/* Cards in a column on the phone, in a grid on the large board. */
.bl-grid { display: grid; grid-template-columns: 1fr; gap: 0.65em; }
.bl-app--wide .bl-grid { grid-template-columns: repeat(auto-fill, minmax(21em, 1fr)); gap: 0.85em; }
.bl-app--wide .bl-grid--two { grid-template-columns: 1fr 1fr; }

.bl-card {
  display: flex; flex-direction: column; gap: 0.5em; padding: 0.8em 0.9em;
  background: var(--bl-card); border: 1px solid var(--bl-line); border-radius: 0.75em;
}
.bl-card--accent { border-color: var(--bl-accent); box-shadow: inset 3px 0 0 var(--bl-accent); }
.bl-card--muted { opacity: 0.62; }

.bl-row { display: flex; align-items: center; justify-content: space-between; gap: 0.6em; }
.bl-row--top { align-items: flex-start; }
.bl-row--wrap { flex-wrap: wrap; }
.bl-grow { flex: 1 1 auto; min-width: 0; }

.bl-title { font-size: 1.08em; font-weight: 800; }
.bl-sub { color: var(--bl-dim); font-size: 0.9em; }
.bl-text { color: #cfd5e2; font-size: 0.93em; }
.bl-money { font-weight: 800; font-size: 1.15em; color: var(--bl-good); white-space: nowrap; }
.bl-money--bad { color: var(--bl-bad); }
.bl-section { margin: 0.35em 0 0; font-size: 0.82em; font-weight: 800; letter-spacing: 0.08em; text-transform: uppercase; color: var(--bl-dim); }

.bl-pill {
  display: inline-flex; align-items: center; gap: 0.3em; padding: 0.15em 0.6em; border-radius: 1em;
  background: var(--bl-card-2); color: #d6dbe7; font-size: 0.82em; font-weight: 700; white-space: nowrap;
}
.bl-pill--good { background: rgba(74, 222, 128, 0.16); color: var(--bl-good); }
.bl-pill--warn { background: rgba(251, 191, 36, 0.16); color: var(--bl-warn); }
.bl-pill--bad { background: rgba(248, 113, 113, 0.16); color: var(--bl-bad); }
.bl-pill--accent { background: var(--bl-accent); color: #fff; }

.bl-facts { display: flex; flex-wrap: wrap; gap: 0.3em 1.1em; font-size: 0.9em; color: #cfd5e2; }
.bl-facts b { color: var(--bl-text); }

.bl-route { display: flex; flex-direction: column; gap: 0.2em; font-size: 0.93em; }
.bl-route__stop { display: flex; align-items: baseline; gap: 0.5em; min-width: 0; }
.bl-route__stop span:last-child { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.bl-route__dot { flex: 0 0 auto; width: 0.55em; height: 0.55em; border-radius: 50%; border: 2px solid var(--bl-accent); transform: translateY(-0.05em); }
.bl-route__dot--end { background: var(--bl-accent); }

.bl-btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 0.4em; padding: 0.55em 1em; min-height: 2.4em;
  border: 1px solid var(--bl-line); border-radius: 0.55em; background: var(--bl-card-2); font-weight: 800; white-space: nowrap;
}
.bl-btn--main { background: var(--bl-accent); border-color: transparent; color: #fff; }
.bl-btn--danger { background: rgba(248, 113, 113, 0.14); border-color: rgba(248, 113, 113, 0.4); color: var(--bl-bad); }
.bl-btn--block { width: 100%; }
.bl-btn:disabled { opacity: 0.45; cursor: default; }
.bl-btns { display: flex; flex-wrap: wrap; gap: 0.45em; }
.bl-btns > .bl-btn { flex: 1 1 auto; }

.bl-seg { display: inline-flex; padding: 0.15em; border-radius: 0.55em; background: var(--bl-card-2); }
.bl-seg button { padding: 0.35em 0.8em; border: 0; border-radius: 0.45em; background: transparent; color: var(--bl-dim); font-weight: 700; }
.bl-seg button.on { background: var(--bl-accent); color: #fff; }

.bl-meter { height: 0.45em; border-radius: 1em; background: var(--bl-card-2); overflow: hidden; }
.bl-meter > span { display: block; height: 100%; border-radius: 1em; background: var(--bl-accent); transition: width 0.3s ease; }

.bl-stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(6.5em, 1fr)); gap: 0.5em; }
.bl-stat { padding: 0.55em 0.7em; border-radius: 0.6em; background: var(--bl-card-2); }
.bl-stat__value { font-size: 1.2em; font-weight: 800; }
.bl-stat__label { font-size: 0.78em; color: var(--bl-dim); }

.bl-empty { margin: auto; padding: 2em 1em; text-align: center; color: var(--bl-dim); }
.bl-banner { padding: 0.6em 0.8em; border-radius: 0.6em; background: rgba(251, 191, 36, 0.12); color: var(--bl-warn); font-size: 0.92em; }

.bl-notice {
  position: absolute; left: 0.75em; right: 0.75em; bottom: 0.75em; padding: 0.7em 0.9em; border-radius: 0.65em;
  background: #14532d; border: 1px solid rgba(74, 222, 128, 0.5); color: #dcfce7; font-weight: 700;
  box-shadow: 0 6px 24px rgba(0, 0, 0, 0.5);
}
.bl-notice--bad { background: #5a1d1d; border-color: rgba(248, 113, 113, 0.55); color: #fee2e2; }
.bl-app--wide .bl-notice { left: 50%; right: auto; transform: translateX(-50%); min-width: 22em; max-width: 70%; text-align: center; }
.bl-notice-enter-active, .bl-notice-leave-active { transition: opacity 0.2s ease; }
.bl-notice-enter-from, .bl-notice-leave-to { opacity: 0; }
</style>
