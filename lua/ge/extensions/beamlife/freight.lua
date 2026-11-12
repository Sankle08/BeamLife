-- BeamLife freight: two fictional carriers that hire the player with his own vehicle.
--   Rodovia Transportes: long hauls for tractor units with a coupled trailer, or rigid trucks.
--   Ligeiro Pack: multi-drop rounds for vans, pickups and small trucks.
-- Each carrier keeps a reputation, offers routes on a board and makes job proposals ("vagas")
-- with a weekly quota and a weekly bonus as the reputation grows.
-- Reading order: carriers, state, reputation, route offers, running a route, positions, week change, UI, hooks.
local M = {}
M.dependencies = {"beamlife_core"}

-- Config ------------------------------------------------------------------------------------------

local REFRESH_MINUTES = 240
local OFFER_COUNT = 5
local AVERAGE_SPEED = 12
local ON_TIME_BONUS = 0.10
local LATE_FACTOR = 0.75
local REP_PER_LEVEL = 40
local MAX_REP_LEVEL = 6
local REP_PAY_STEP = 0.06
local MISSED_QUOTA_REP = 15

local CARRIERS = {
  heavy = {
    id = "heavy", app = "freight", name = "Interstate Freight",
    requirement = "A semi truck with a trailer hooked up, or a rigid truck.",
    from = {"warehouse"}, to = {"warehouse", "shop", "gas", "mechanic", "dealer"},
    minStops = 1, maxStops = 2, dwell = 35, minLeg = 900,
    cargos = {
      {name = "Beverage pallets", base = 420, perKm = 270, rep = 0},
      {name = "Building materials", base = 460, perKm = 290, rep = 1},
      {name = "Steel coils", base = 560, perKm = 330, rep = 2},
      {name = "Refrigerated goods", base = 640, perKm = 370, rep = 3},
      {name = "Fuel", base = 780, perKm = 430, rep = 4},
      {name = "Oversize load", base = 980, perKm = 520, rep = 5},
    },
    positions = {
      {id = "agregado", title = "Owner-Operator", rep = 0, quota = 3, bonus = 1300, payMult = 1.05,
        desc = "You bring the truck, Interstate brings the load."},
      {id = "linha", title = "Line Driver", rep = 2, quota = 6, bonus = 3800, payMult = 1.12,
        desc = "A regular line through the week, first pick of the better loads."},
      {id = "master", title = "Master Hauler", rep = 4, quota = 9, bonus = 8500, payMult = 1.20,
        desc = "Special loads and the biggest bonus in the house."},
    },
  },
  medium = {
    id = "medium", app = "freight", name = "QuickPack",
    requirement = "A van, pickup or light truck (or a car with a trailer).",
    from = {"warehouse", "shop"}, to = {"home", "shop", "food", "office", "mechanic", "hospital"},
    minStops = 2, maxStops = 4, dwell = 12, minLeg = 300,
    cargos = {
      {name = "Online orders", base = 170, perKm = 125, rep = 0},
      {name = "Car parts", base = 190, perKm = 135, rep = 1},
      {name = "Appliances", base = 230, perKm = 150, rep = 2},
      {name = "Furniture", base = 270, perKm = 165, rep = 3},
      {name = "Medical equipment", base = 330, perKm = 190, rep = 4},
    },
    positions = {
      {id = "parceiro", title = "Partner Courier", rep = 0, quota = 4, bonus = 520, payMult = 1.05,
        desc = "Casual rounds with a light weekly quota."},
      {id = "fixo", title = "Staff Courier", rep = 2, quota = 8, bonus = 1600, payMult = 1.12,
        desc = "A regular neighbourhood round with a weekly bonus when you meet the quota."},
      {id = "lider", title = "Route Leader", rep = 4, quota = 12, bonus = 3600, payMult = 1.20,
        desc = "The biggest and best paid rounds."},
    },
  },
}

-- State -------------------------------------------------------------------------------------------

local state = {}
local offers = {}
local offersKey = {}
local active

local function core() return beamlife_core end

local function guard(name, fn)
  return function(...)
    local ok, result = xpcall(fn, debug.traceback, ...)
    if not ok then log("E", "beamlife", name .. ": " .. tostring(result)) return nil end
    return result
  end
end

local function carrierState(id)
  if not state[id] then
    state[id] = {rep = 0, routes = 0, earned = 0, taken = {}, window = -1, proposed = {}}
  end
  return state[id]
end

-- Reputation --------------------------------------------------------------------------------------

local function repLevel(id)
  return math.min(MAX_REP_LEVEL, math.floor(math.sqrt(carrierState(id).rep / REP_PER_LEVEL)))
end

local function positionOf(carrier)
  local contract = carrierState(carrier.id).contract
  if not contract then return nil end
  for _, position in ipairs(carrier.positions) do
    if position.id == contract.position then return position end
  end
  return nil
end

local function payMultiplier(carrier)
  local position = positionOf(carrier)
  return (1 + REP_PAY_STEP * repLevel(carrier.id)) * (position and position.payMult or 1)
end

-- The carrier calls when the reputation opens a better position than the current one.
local function proposePositions(carrier)
  local data = carrierState(carrier.id)
  local level = repLevel(carrier.id)
  local current = positionOf(carrier)
  for _, position in ipairs(carrier.positions) do
    if level >= position.rep and not data.proposed[position.id] and (not current or position.rep > current.rep) then
      data.proposed[position.id] = true
      core().notify("beamlife." .. carrier.app, carrier.name,
        string.format("Job offer: %s. Quota of %d routes a week, $%d bonus.", position.title, position.quota, position.bonus))
    end
  end
end

-- Route offers ------------------------------------------------------------------------------------

local function availableCargos(carrier)
  local level, out = repLevel(carrier.id), {}
  for _, cargo in ipairs(carrier.cargos) do
    if cargo.rep <= level then out[#out + 1] = cargo end
  end
  return out
end

local function buildOffer(carrier, index, window, level)
  local random = core().rng(core().hash(level .. ":" .. carrier.id .. ":" .. window .. ":" .. index))
  local cargos = availableCargos(carrier)
  -- Newer cargo types show up more often, so progress is felt on the board.
  local cargo = cargos[math.max(1, #cargos - random(0, math.min(2, #cargos - 1)))]
  local from = core().pickPlace(carrier.from, random(1, 1000000))
  if not from then return nil end
  local used = {[from.id] = true}
  local stops, meters, previous = {}, 0, from.pos
  for _ = 1, random(carrier.minStops, carrier.maxStops) do
    local stop
    for _ = 1, 6 do
      stop = core().pickPlace(carrier.to, random(1, 1000000), used)
      if stop and not used[stop.id] and stop.pos:distance(previous) >= carrier.minLeg then break end
      stop = nil
    end
    if stop then
      used[stop.id] = true
      meters = meters + core().routeDistance(previous, stop.pos)
      previous = stop.pos
      stops[#stops + 1] = stop
    end
  end
  if #stops == 0 then return nil end
  return {
    id = string.format("%d-%d", window, index), cargo = cargo, from = from, stops = stops, meters = meters,
    variation = 0.92 + random() * 0.2, units = random(2, 9) * (carrier.id == "heavy" and 2 or 3),
  }
end

local function refreshOffers(carrier)
  local level = getCurrentLevelIdentifier()
  if not level then
    offers[carrier.id] = {}
    return
  end
  local data = carrierState(carrier.id)
  local window = math.floor(core().now().abs / REFRESH_MINUTES)
  local key = level .. ":" .. window .. ":" .. repLevel(carrier.id)
  if offersKey[carrier.id] == key then return end
  offersKey[carrier.id] = key
  if data.window ~= window then
    data.window = window
    data.taken = {}
  end
  local list = {}
  for index = 1, OFFER_COUNT + 4 do
    if #list >= OFFER_COUNT then break end
    local offer = buildOffer(carrier, index, window, level)
    if offer then list[#list + 1] = offer end
  end
  offers[carrier.id] = list
end

local function payOf(carrier, offer)
  local raw = (offer.cargo.base + offer.cargo.perKm * offer.meters / 1000) * offer.variation
  return core().round(raw * payMultiplier(carrier), 10)
end

local function eligibility(carrier)
  local vehicle = core().vehicleClass()
  if vehicle.class == "none" then return false, "You need to be in your vehicle." end
  if carrier.id == "heavy" then
    if vehicle.class == "semi" and vehicle.hasTrailer then return true end
    if vehicle.class == "truck" then return true end
    if vehicle.class == "semi" then return false, "Hook a trailer to your semi truck." end
    return false, carrier.requirement
  end
  if vehicle.class == "van" or vehicle.class == "pickup" or vehicle.class == "truck" then return true end
  if vehicle.class == "car" and vehicle.hasTrailer then return true end
  return false, carrier.requirement
end

-- Running a route ---------------------------------------------------------------------------------

local function finishRoute(info)
  local route = active
  active = nil
  if not route then return end
  local carrier = CARRIERS[route.carrier]
  local data = carrierState(carrier.id)
  local pay = route.pay
  local note
  if info.late then
    pay = core().round(pay * LATE_FACTOR, 10)
    note = "Late delivery: reduced pay."
  else
    pay = core().round(pay * (1 + ON_TIME_BONUS), 10)
    note = "On time: punctuality bonus."
  end
  core().pay(pay, carrier.name .. ": " .. route.cargo, {"gameplay", "reward", "beamlife", "freight"})
  core().addXp(22 + math.min(40, route.km * 4), "routes")
  data.routes = data.routes + 1
  data.earned = data.earned + pay
  data.rep = data.rep + (info.late and 4 or 10) + math.min(12, math.floor(route.km))
  if data.contract then data.contract.done = (data.contract.done or 0) + 1 end
  core().message(string.format("%s: route done, $%d. %s", carrier.name, pay, note), 8)
  proposePositions(carrier)
  extensions.hook("onBeamlifeRouteCompleted", carrier.id, pay)
  core().requestSave("route")
end

function M.accept(carrierId, routeId)
  local carrier = CARRIERS[carrierId]
  if not carrier then return {ok = false, message = "Unknown carrier."} end
  refreshOffers(carrier)
  if core().isBusy() then return {ok = false, message = "Finish or cancel your current task first."} end
  local data = carrierState(carrierId)
  local offer
  for _, candidate in ipairs(offers[carrierId] or {}) do
    if candidate.id == routeId and not data.taken[routeId] then offer = candidate end
  end
  if not offer then return {ok = false, message = "This route is no longer available."} end
  local ok, reason = eligibility(carrier)
  if not ok then return {ok = false, message = reason} end

  local steps = {{
    pos = offer.from.pos, radius = 16, dwell = carrier.dwell,
    label = "Load at " .. offer.from.name .. ".", dwellLabel = "Loading " .. offer.cargo.name .. "...",
  }}
  for index, stop in ipairs(offer.stops) do
    steps[#steps + 1] = {
      pos = stop.pos, radius = 16, dwell = carrier.dwell,
      label = string.format("Drop %d of %d: %s.", index, #offer.stops, stop.name), dwellLabel = "Unloading...",
    }
  end
  local toPickup = core().distanceTo(offer.from.pos) * 1.4
  local limit = (offer.meters + toPickup) / AVERAGE_SPEED + carrier.dwell * #steps + 240

  active = {carrier = carrierId, cargo = offer.cargo.name, pay = payOf(carrier, offer), km = offer.meters / 1000}
  local started, problem = core().startRun({
    owner = carrier.app, title = carrier.name .. " · " .. offer.cargo.name, steps = steps, timeLimit = limit,
    onFinish = finishRoute, onCancel = function() active = nil end,
  })
  if not started then
    active = nil
    return {ok = false, message = problem}
  end
  data.taken[routeId] = true
  if overhaul_phone_phone and overhaul_phone_phone.closePhone then core().try(overhaul_phone_phone.closePhone) end
  return {ok = true, message = "Route accepted. Go load up."}
end

function M.cancel(carrierId)
  local carrier = CARRIERS[carrierId]
  if not carrier or core().busyOwner() ~= carrier.app or not active or active.carrier ~= carrierId then
    return {ok = false, message = "No route in progress."}
  end
  core().cancelRun("player")
  -- Dropping a load costs a little reputation.
  local data = carrierState(carrierId)
  data.rep = math.max(0, data.rep - 5)
  return {ok = true, message = "Route cancelled. The carrier is not pleased."}
end

-- Positions ---------------------------------------------------------------------------------------

function M.takePosition(carrierId, positionId)
  local carrier = CARRIERS[carrierId]
  if not carrier then return {ok = false, message = "Unknown carrier."} end
  local data = carrierState(carrierId)
  for _, position in ipairs(carrier.positions) do
    if position.id == positionId then
      if repLevel(carrierId) < position.rep then
        return {ok = false, message = "Needs reputation " .. position.rep .. " with " .. carrier.name .. "."}
      end
      data.contract = {position = positionId, week = math.floor(core().now().day / 7), done = 0}
      data.proposed[positionId] = true
      core().changed(carrier.app)
      core().requestSave("position")
      return {ok = true, message = string.format("Job taken: %s. Quota of %d routes a week.", position.title, position.quota)}
    end
  end
  return {ok = false, message = "Job not found."}
end

function M.leavePosition(carrierId)
  local carrier = CARRIERS[carrierId]
  if not carrier then return {ok = false, message = "Unknown carrier."} end
  carrierState(carrierId).contract = nil
  core().changed(carrier.app)
  return {ok = true, message = "You left the job. Single routes are still available."}
end

-- Week change -------------------------------------------------------------------------------------

local function settleWeek(carrier, week)
  local data = carrierState(carrier.id)
  local contract = data.contract
  if not contract or contract.week == week then return end
  local position = positionOf(carrier)
  if position then
    if (contract.done or 0) >= position.quota then
      core().pay(position.bonus, carrier.name .. ": weekly bonus", {"gameplay", "reward", "beamlife", "salary"})
      data.rep = data.rep + 12
      core().notify("beamlife." .. carrier.app, carrier.name,
        string.format("Weekly quota met (%d/%d). Bonus of $%d paid.", contract.done, position.quota, position.bonus))
    else
      data.rep = math.max(0, data.rep - MISSED_QUOTA_REP)
      core().notify("beamlife." .. carrier.app, carrier.name,
        string.format("Weekly quota missed (%d/%d). No bonus this time.", contract.done or 0, position.quota))
    end
  end
  contract.week, contract.done = week, 0
  proposePositions(carrier)
end

-- UI state ----------------------------------------------------------------------------------------

function M.getState(carrierId)
  local carrier = CARRIERS[carrierId]
  if not carrier then return {error = "Unknown carrier."} end
  refreshOffers(carrier)
  local data = carrierState(carrierId)
  local ok, reason = eligibility(carrier)
  local routes = {}
  for _, offer in ipairs(offers[carrierId] or {}) do
    if not data.taken[offer.id] then
      local names = {}
      for _, stop in ipairs(offer.stops) do names[#names + 1] = stop.name end
      routes[#routes + 1] = {
        id = offer.id, cargo = offer.cargo.name, units = offer.units, from = offer.from.name, stops = names,
        km = core().round(offer.meters / 1000, 0.1), pay = payOf(carrier, offer),
        toStart = math.floor(core().distanceTo(offer.from.pos)),
      }
    end
  end
  local level = repLevel(carrierId)
  local positions = {}
  local current = positionOf(carrier)
  for _, position in ipairs(carrier.positions) do
    positions[#positions + 1] = {
      id = position.id, title = position.title, desc = position.desc, quota = position.quota, bonus = position.bonus,
      payBonus = math.floor((position.payMult - 1) * 100 + 0.5), rep = position.rep,
      locked = level < position.rep, current = current ~= nil and current.id == position.id,
    }
  end
  local nextCargo
  for _, cargo in ipairs(carrier.cargos) do
    if cargo.rep > level then
      nextCargo = {name = cargo.name, rep = cargo.rep}
      break
    end
  end
  local floor = level * level * REP_PER_LEVEL
  local ceiling = (level + 1) * (level + 1) * REP_PER_LEVEL
  local date = core().dateInfo(core().now().day)
  local mine = core().busyOwner() == carrier.app and active ~= nil and active.carrier == carrier.id
  local run = mine and core().runState() or nil
  if run then run.pay = active.pay end
  return {
    id = carrier.id, name = carrier.name, requirement = carrier.requirement,
    vehicle = core().vehicleClass().label, eligible = ok, reason = reason,
    routes = routes, active = run, busy = core().isBusy() and not mine,
    rep = {level = level, max = MAX_REP_LEVEL, progress = level >= MAX_REP_LEVEL and 1 or core().clamp((data.rep - floor) / (ceiling - floor), 0, 1),
      payBonus = math.floor(REP_PAY_STEP * level * 100 + 0.5)},
    positions = positions,
    contract = current and {title = current.title, quota = current.quota, done = data.contract.done or 0, bonus = current.bonus,
      daysLeft = 8 - date.weekday} or nil,
    nextCargo = nextCargo, totalRoutes = data.routes, totalEarned = math.floor(data.earned),
    refreshIn = REFRESH_MINUTES - (core().now().abs % REFRESH_MINUTES),
  }
end

-- Routes finished for a carrier, ever. The Business app reads it.
function M.routesDone(carrierId)
  return carrierState(carrierId).routes
end

-- Hooks -------------------------------------------------------------------------------------------

M.onCareerActivated = guard("freight.onCareerActivated", function()
  local data = beamlife_core.loadFile("freight") or {}
  state = {}
  for id in pairs(CARRIERS) do
    local saved = type(data[id]) == "table" and data[id] or {}
    state[id] = {
      rep = tonumber(saved.rep) or 0, routes = tonumber(saved.routes) or 0, earned = tonumber(saved.earned) or 0,
      taken = type(saved.taken) == "table" and saved.taken or {}, window = tonumber(saved.window) or -1,
      proposed = type(saved.proposed) == "table" and saved.proposed or {},
      contract = type(saved.contract) == "table" and saved.contract.position and saved.contract or nil,
    }
  end
  offers, offersKey, active = {}, {}, nil
end)

M.onOverhaulSaveCurrentProfile = guard("freight.save", function(savePath, _, writer)
  beamlife_core.saveFile(savePath, "freight", state, writer)
end)

M.onBeamlifeNewDay = guard("freight.newDay", function(day)
  local week = math.floor(day / 7)
  for _, carrier in pairs(CARRIERS) do
    settleWeek(carrier, week)
    core().changed(carrier.app)
  end
end)

M.onClientEndMission = function()
  offers, offersKey = {}, {}
end

return M
