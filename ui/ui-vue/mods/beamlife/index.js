// BeamLife UI entry point. The phone apps are found through their manifests
// (gameplay/overhaul/phone/apps/beamlife-*.json); the only thing mounted here is the HUD bar,
// which has to live in the main app so it can follow the router and the phone shell.
import { getComponent } from "@/services/uiMods"

const HUD_FILE = "/ui/ui-vue/mods/beamlife/hud/BeamlifeHud.vue"
const HOST_ID = "beamlife-hud-host"

let hostEl = null
let generation = 0

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

async function waitForMainApp(timeoutMs = 60000) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    if (window.Vue && window.bngVue?.app?._context && window.vueRouter) return true
    await sleep(50)
  }
  return false
}

function unmount() {
  if (hostEl && window.Vue?.render) {
    try {
      window.Vue.render(null, hostEl)
    } catch (error) {
      console.warn("[beamlife] HUD unmount failed", error)
    }
  }
  hostEl?.remove()
  hostEl = null
}

export async function onLoad() {
  const mine = ++generation
  try {
    if (!(await waitForMainApp()) || mine !== generation) return
    let data = await getComponent(HUD_FILE, false, true)
    if (!data?.compiled && typeof data?.compile === "function") data = await data.compile()
    if (mine !== generation) return
    if (data?.error || !data?.component) {
      console.error("[beamlife] HUD failed to compile", data?.error, data?.errorObj)
      return
    }
    unmount()
    hostEl = document.createElement("div")
    hostEl.id = HOST_ID
    document.body.appendChild(hostEl)
    const vnode = window.Vue.createVNode(data.component)
    vnode.appContext = window.bngVue.app._context
    window.Vue.render(vnode, hostEl)
  } catch (error) {
    console.error("[beamlife] HUD failed to mount", error)
  }
}

export async function onUnload() {
  generation++
  unmount()
}
