// Calls into the BeamLife Lua modules and small formatting helpers shared by every BeamLife screen.

function toLua(value) {
  if (value === null || value === undefined) return "nil"
  if (typeof value === "number") return Number.isFinite(value) ? String(value) : "nil"
  if (typeof value === "boolean") return value ? "true" : "false"
  return JSON.stringify(String(value))
}

// lua("beamlife_jobs.apply", "kitchen", "weekly") resolves with what the Lua function returned,
// or undefined when the module is not loaded (outside a career).
export function lua(path, ...args) {
  const api = window.bngApi
  if (!api?.engineLua) return Promise.resolve(undefined)
  const [root, method] = String(path).split(".")
  const expression =
    `(function() local m = rawget(_G, ${JSON.stringify(root)})` +
    ` if type(m) ~= "table" then return nil end` +
    ` local f = m[${JSON.stringify(method)}]` +
    ` if type(f) ~= "function" then return nil end` +
    ` return f(${args.map(toLua).join(", ")}) end)()`
  return new Promise(resolve => api.engineLua(expression, resolve))
}

// Lua sends an empty list as an empty object.
export function list(value) {
  if (Array.isArray(value)) return value
  if (value && typeof value === "object") return Object.values(value)
  return []
}

export function money(value) {
  const amount = Math.round(Number(value) || 0)
  return (amount < 0 ? "-$" : "$") + Math.abs(amount).toLocaleString("en-US")
}

export function distance(meters) {
  const value = Number(meters)
  if (!Number.isFinite(value)) return ""
  return value >= 1000 ? `${(value / 1000).toFixed(1)} km` : `${Math.round(value / 10) * 10} m`
}

export function clock(seconds) {
  const total = Math.max(0, Math.round(Number(seconds) || 0))
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`
}

export function gameHours(minutes) {
  const total = Math.max(0, Math.round(Number(minutes) || 0))
  return total >= 60 ? `${Math.floor(total / 60)}h${String(total % 60).padStart(2, "0")}` : `${total} min`
}

export function compact(value) {
  const amount = Number(value) || 0
  if (amount >= 1e6) return `${(amount / 1e6).toFixed(1)}M`
  if (amount >= 1e3) return `${(amount / 1e3).toFixed(1)}K`
  return String(Math.round(amount))
}
