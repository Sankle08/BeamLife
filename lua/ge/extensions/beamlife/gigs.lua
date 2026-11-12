-- BeamLife Bicos: quick one-off jobs. Carry an envelope, haul some boxes, bring a broken car on
-- your trailer, help a stranded driver. No contract, paid on the spot.
-- Reading order: gig kinds, state, offer generation, starting and finishing a gig, UI state, hooks.
local M = {}
M.dependencies = {"beamlife_core"}

-- Config ------------------------------------------------------------------------------------------

local APP = "gigs"
local OFFER_COUNT = 6
local REFRESH_MINUTES = 180          -- the board changes every three in-game hours
local MIN_TRIP_METERS = 350
local ON_TIME_BONUS = 0.15
local LATE_FACTOR = 0.7
local AVERAGE_SPEED = 11             -- m/s used for the time limit, on purpose forgiving
local TOW_MODELS = {"covet", "pessima", "legran", "midsize", "pigeon", "bluebuck", "etki", "moonhawk"}
local CARGO_CLASSES = {van = true, pickup = true, truck = true, semi = true}

-- base and perKm are dollars; dwell is seconds spent loading or unloading at each stop.
local KINDS = {
  courier = {title = "Document Run", base = 70, perKm = 60, dwell = 4, xp = 10, weight = 3,
    from = {"office", "shop", "hospital"}, to = {"office", "home", "shop"},
    desc = "A sealed envelope. Fits in any car."},
  errand = {title = "Shopping Run", base = 95, perKm = 62, dwell = 8, xp = 12, weight = 2,
    from = {"shop", "food"}, to = {"home"},
    desc = "Pick up an order at the shop and drop it at the customer's home."},
  boxes = {title = "Box Haul", base = 130, perKm = 92, dwell = 14, xp = 16, weight = 3, needsCargo = true,
    from = {"warehouse", "shop"}, to = {"shop", "home", "mechanic", "food"},
    desc = "Bulky boxes: needs a pickup, van or truck."},
  rescue = {title = "Roadside Help", base = 150, perKm = 55, dwell = 20, xp = 14, weight = 2, single = true,
    to = {"gas", "home", "shop", "food", "warehouse"},
    desc = "A stranded driver. Go there and help with fuel or a jump start."},
  tow = {title = "Tow Job", base = 260, perKm = 135, dwell = 3, xp = 24, weight = 2, tow = true,
    from = {"home", "shop", "food", "gas"}, to = {"mechanic", "dealer"},
    desc = "A broken-down car. Take it to the shop on your trailer, flatbed or tow hitch."},
}
local KIND_ORDER = {"courier", "errand", "boxes", "rescue", "tow"}

-- State -------------------------------------------------------------------------------------------

local state = {done = 0, earned = 0, taken = {}, window = -1}
local offers = {}
local offersKey
local active

local function core() return beamlife_core end

local function guard(name, fn)
  return function(...)
    local ok, result = xpcall(fn, debug.traceback, ...)
    if not ok then log("E", "beamlife", name .. ": " .. tostring(result)) return nil end
    return result
  end
end

-- Offer generation --------------------------------------------------------------------------------

local function pickKind(random)
  local total = 0
  for _, id in ipairs(KIND_ORDER) do total = total + KINDS[id].weight end
  local roll = random() * total
  for _, id in ipairs(KIND_ORDER) do
    roll = roll - KINDS[id].weight
    if roll <= 0 then return id end
  end
  return KIND_ORDER[1]
end

local function buildOffer(index, window, level)
  local random = core().rng(core().hash(level .. ":gig:" .. window .. ":" .. index))
  local kindId = pickKind(random)
  local kind = KINDS[kindId]
  local to = core().pickPlace(kind.to, random(1, 1000000))
  if not to then return nil end
  local from
  if not kind.single then
    for _ = 1, 6 do
      from = core().pickPlace(kind.from, random(1, 1000000), {[to.id] = true})
      if from and from.id ~= to.id and from.pos:distance(to.pos) >= MIN_TRIP_METERS then break end
      from = nil
    end
    if not from then return nil end
  end
  local meters = from and core().routeDistance(from.pos, to.pos) or nil
  return {
    id = string.format("%d-%d", window, index), kind = kindId, from = from, to = to, meters = meters,
    variation = 0.9 + random() * 0.25, boxes = random(4, 12),
  }
end

local function refreshOffers()
  local level = getCurrentLevelIdentifier()
  if not level then
    offers = {}
    return
  end
  local window = math.floor(core().now().abs / REFRESH_MINUTES)
  local key = level .. ":" .. window
  if key == offersKey then return end
  offersKey = key
  if state.window ~= window then
    state.window = window
    state.taken = {}
  end
  offers = {}
  for index = 1, OFFER_COUNT + 4 do
    if #offers >= OFFER_COUNT then break end
    local offer = buildOffer(index, window, level)
    if offer then offers[#offers + 1] = offer end
  end
end

-- A rescue has no pickup, so its distance is measured from wherever the player is now.
local function metersOf(offer)
  if offer.meters then return offer.meters end
  local player = core().playerPosition()
  return player and core().routeDistance(player, offer.to.pos) or 1500
end

local function payOf(offer)
  local kind = KINDS[offer.kind]
  return core().round((kind.base + kind.perKm * metersOf(offer) / 1000) * offer.variation, 5)
end

local function eligibility(offer)
  local kind = KINDS[offer.kind]
  local vehicle = core().vehicleClass()
  if vehicle.class == "none" then return false, "You need to be in a vehicle." end
  if kind.needsCargo and not CARGO_CLASSES[vehicle.class] and not vehicle.hasTrailer then
    return false, "Needs a pickup, van, truck or trailer."
  end
  return true
end

-- Starting and finishing --------------------------------------------------------------------------

local function removeTowCar()
  if active and active.towId then
    local car = getObjectByID(active.towId)
    if car then car:delete() end
    active.towId = nil
  end
end

local function spawnTowCar(place)
  local model = TOW_MODELS[math.random(#TOW_MODELS)]
  local ok, vehicle = pcall(core_vehicles.spawnNewVehicle, model, {
    pos = vec3(place.pos), rot = quat(0, 0, 0, 1), autoEnterVehicle = false, autoFlip = true,
  })
  if not ok or not vehicle then
    log("W", "beamlife", "Tow car failed to spawn: " .. tostring(vehicle))
    return nil
  end
  -- The customer's car does not run: it can only be towed, winched or pushed.
  vehicle.playerUsable = false
  vehicle:queueLuaCommand("electrics.setIgnitionLevel(0)")
  vehicle:queueLuaCommand("input.event('parkingbrake', 0, 1)")
  vehicle:queueLuaCommand("if controller and controller.mainController and controller.mainController.shiftToGearIndex then controller.mainController.shiftToGearIndex(0) end")
  return vehicle:getID()
end

local function finishGig(info)
  local gig = active
  active = nil
  if not gig then return end
  local pay = gig.pay
  local note
  if info.late then
    pay = core().round(pay * LATE_FACTOR, 5)
    note = "Late: reduced pay."
  else
    pay = core().round(pay * (1 + ON_TIME_BONUS), 5)
    note = "On time: tip included."
  end
  core().pay(pay, "Quikash: " .. gig.title, {"gameplay", "reward", "beamlife", "gig"})
  core().addXp(gig.xp, "gigs")
  state.done = state.done + 1
  state.earned = state.earned + pay
  if gig.towId then
    local car = getObjectByID(gig.towId)
    if car then car:delete() end
  end
  core().message(string.format("Job done: $%d. %s", pay, note), 8)
  core().requestSave("gig")
end

local function cancelGig()
  if active and active.towId then
    local car = getObjectByID(active.towId)
    if car then car:delete() end
  end
  active = nil
end

function M.accept(id)
  refreshOffers()
  if core().isBusy() then return {ok = false, message = "Finish or cancel your current task first."} end
  local offer
  for _, candidate in ipairs(offers) do
    if candidate.id == id and not state.taken[id] then offer = candidate end
  end
  if not offer then return {ok = false, message = "This job is no longer available."} end
  local ok, reason = eligibility(offer)
  if not ok then return {ok = false, message = reason} end

  local kind = KINDS[offer.kind]
  local meters = metersOf(offer)
  local gig = {title = kind.title, pay = payOf(offer), xp = kind.xp}
  local steps = {}
  if kind.tow then
    gig.towId = spawnTowCar(offer.from)
    if not gig.towId then return {ok = false, message = "The customer's car could not be set up. Try another job."} end
    steps[1] = {pos = offer.from.pos, radius = 30, dwell = 2, label = "Go to " .. offer.from.name .. " and hook the car to your trailer."}
    steps[2] = {pos = offer.to.pos, radius = 18, dwell = kind.dwell, subjectId = gig.towId,
      label = "Take the car to " .. offer.to.name .. ".", dwellLabel = "Handing over the car..."}
  elseif kind.single then
    steps[1] = {pos = offer.to.pos, radius = 14, dwell = kind.dwell,
      label = "Help needed at " .. offer.to.name .. ".", dwellLabel = "Helping the driver..."}
  else
    steps[1] = {pos = offer.from.pos, radius = 12, dwell = kind.dwell,
      label = "Pick up at " .. offer.from.name .. ".", dwellLabel = "Loading..."}
    steps[2] = {pos = offer.to.pos, radius = 12, dwell = kind.dwell,
      label = "Deliver to " .. offer.to.name .. ".", dwellLabel = "Unloading..."}
  end
  local toPickup = offer.from and core().distanceTo(offer.from.pos) * 1.4 or 0
  local limit = (meters + toPickup) / AVERAGE_SPEED + kind.dwell * #steps + 150
  if kind.tow then limit = limit * 1.5 + 240 end

  active = gig
  local started, problem = core().startRun({
    owner = APP, title = kind.title, steps = steps, timeLimit = limit,
    onFinish = finishGig, onCancel = cancelGig,
  })
  if not started then
    removeTowCar()
    active = nil
    return {ok = false, message = problem}
  end
  state.taken[id] = true
  if overhaul_phone_phone and overhaul_phone_phone.closePhone then core().try(overhaul_phone_phone.closePhone) end
  return {ok = true, message = "Job accepted. Follow the route."}
end

function M.cancel()
  if core().busyOwner() ~= APP then return {ok = false, message = "No job in progress."} end
  core().cancelRun("player")
  return {ok = true, message = "Job cancelled."}
end

-- UI state ----------------------------------------------------------------------------------------

function M.getState()
  refreshOffers()
  local list = {}
  for _, offer in ipairs(offers) do
    if not state.taken[offer.id] then
      local kind = KINDS[offer.kind]
      local ok, reason = eligibility(offer)
      local meters = metersOf(offer)
      list[#list + 1] = {
        id = offer.id, kind = offer.kind, title = kind.title, desc = kind.desc,
        from = offer.from and offer.from.name or "Your position", to = offer.to.name,
        km = core().round(meters / 1000, 0.1), pay = payOf(offer),
        detail = offer.kind == "boxes" and (offer.boxes .. " boxes") or nil,
        eligible = ok, reason = reason,
        toStart = offer.from and math.floor(core().distanceTo(offer.from.pos)) or math.floor(core().distanceTo(offer.to.pos)),
      }
    end
  end
  local now = core().now()
  local run = core().busyOwner() == APP and core().runState() or nil
  if run and active then run.pay = active.pay end
  return {
    offers = list, active = run, busy = core().isBusy() and core().busyOwner() ~= APP,
    vehicle = core().vehicleClass().label, done = state.done, earned = math.floor(state.earned),
    refreshIn = REFRESH_MINUTES - (now.abs % REFRESH_MINUTES),
    bonus = math.floor(ON_TIME_BONUS * 100),
  }
end

-- Hooks -------------------------------------------------------------------------------------------

M.onCareerActivated = guard("gigs.onCareerActivated", function()
  local data = beamlife_core.loadFile("gigs") or {}
  state = {
    done = tonumber(data.done) or 0, earned = tonumber(data.earned) or 0,
    taken = type(data.taken) == "table" and data.taken or {}, window = tonumber(data.window) or -1,
  }
  offers, offersKey, active = {}, nil, nil
end)

M.onOverhaulSaveCurrentProfile = guard("gigs.save", function(savePath, _, writer)
  beamlife_core.saveFile(savePath, "gigs", state, writer)
end)

M.onClientEndMission = function()
  offers, offersKey = {}, nil
end

M.onExtensionUnloaded = function()
  pcall(removeTowCar)
end

return M
