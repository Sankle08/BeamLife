-- BeamLife core: shared services for the BeamLife career layer.
-- Clock and calendar, map places, wallet, professional level, the generic "run" engine
-- (drive to A, wait, drive to B) and the HUD status line. Every other BeamLife module uses this one.
-- Reading order: config, state, helpers, calendar, wallet, places, vehicle class, runs, HUD, saves, hooks.
local M = {}

require("overhaul/lib/save/store").registerKeys({
  {key = "beamlife.data", owner = "beamlife_core", files = {"career/beamlife/*.json"}, phase = "profile", required = false},
})

-- Config ------------------------------------------------------------------------------------------

local LOG_TAG = "beamlife"
local SAVE_SUBDIR = "/career/beamlife"
local MINUTES_PER_DAY = 1440
-- Day 0 of a career is Monday, 9 August. Day 4 is therefore Friday, 13 August.
local EPOCH_DAY_OF_YEAR = 220
local EPOCH_YEAR = 2021
local MONTH_LENGTHS = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
local MONTHS_SHORT = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
local WEEKDAYS = {"Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"}
local WEEKDAYS_SHORT = {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}
local TICK_SECONDS = 1
local ARRIVE_SPEED = 2.5

-- Words in a facility id or name that tell what kind of place it is.
local KIND_WORDS = {
  {kind = "food", words = {"restaurant", "diner", "cafe", "pizza", "burger", "food", "bakery", "grill", "sushi", "taco", "deli", "bar"}},
  {kind = "gas", words = {"gas", "fuel", "petrol"}},
  {kind = "dealer", words = {"motors", "motor company", "auto sales", "dealership", "vehicle sales"}},
  {kind = "mechanic", words = {"mechanic", "garage", "auto", "tire", "tyre", "parts", "repair", "body shop", "tuning", "dyno", "exhaust", "engine works"}},
  {kind = "hospital", words = {"hospital", "clinic", "medical"}},
  {kind = "warehouse", words = {"warehouse", "logistic", "depot", "port", "dock", "freight", "distribution", "storage", "industr", "factory", "quarry", "yard", "terminal", "construction", "refinery", "sorting", "hub", "rent-a-box", "pier"}},
  {kind = "office", words = {"office", "bank", "hotel", "tower", "police", "fire", "city hall", "studio", "school", "station", "news", "skyscraper"}},
  {kind = "shop", words = {"store", "shop", "mart", "market", "mall", "boutique", "supermarket", "retail", "salon", "jewel", "gift", "nails", "cleaning"}},
  {kind = "home", words = {"house", "suburb", "residen", "apartment", "cabin", "townhouse"}},
}

-- State -------------------------------------------------------------------------------------------

local profile = {xp = 0, stats = {}}
local places, placesLevel, placesById
local run
local claimedBy
local tickTimer = 0
local lastHudKey
local lastDay
local fallbackDay = 0
local lastFallbackMinute
local markers = {}

-- Helpers -----------------------------------------------------------------------------------------

local function logError(where, problem)
  log("E", LOG_TAG, tostring(where) .. ": " .. tostring(problem))
end

-- Wraps a hook so one failing BeamLife feature never stops a career activation or a save.
function M.safe(name, fn)
  return function(...)
    local ok, a, b, c = xpcall(fn, debug.traceback, ...)
    if not ok then
      logError(name, a)
      return nil
    end
    return a, b, c
  end
end

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c = pcall(fn, ...)
  if ok then return a, b, c end
  return nil
end
M.try = try

function M.clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end

function M.round(value, step)
  step = step or 1
  return math.floor(value / step + 0.5) * step
end

-- Small deterministic generator, so offers stay the same until their seed changes.
function M.rng(seed)
  local value = math.floor(tonumber(seed) or 1) % 2147483647
  if value <= 0 then value = value + 2147483646 end
  return function(low, high)
    value = (value * 48271) % 2147483647
    local unit = (value - 1) / 2147483646
    if low and high then return low + math.floor(unit * (high - low + 1)) end
    return unit
  end
end

function M.hash(text)
  local value = 5381
  text = tostring(text or "")
  for index = 1, #text do
    value = (value * 33 + text:byte(index)) % 2147483647
  end
  return value
end

function M.isCareerActive()
  return overhaul_career_career ~= nil and overhaul_career_career.isActive() == true
end

-- Calendar ----------------------------------------------------------------------------------------

local function engineMinute()
  local tod = scenetree and scenetree.tod
  local time = tod and tod.time or 0
  return math.floor((((tonumber(time) or 0) + 0.5) % 1) * MINUTES_PER_DAY + 0.5) % MINUTES_PER_DAY
end

-- {day, minute, abs}: the weather clock when it is ready, otherwise the sky's own time of day.
function M.now()
  local state = try(require("overhaul/lib/world/calendar").get)
  if type(state) == "table" and state.ready then
    local day = math.max(0, math.floor(tonumber(state.dayIndex) or 0))
    local minute = M.clamp(math.floor(tonumber(state.minuteOfDay) or 0), 0, MINUTES_PER_DAY - 1)
    return {day = day, minute = minute, abs = day * MINUTES_PER_DAY + minute, ready = true}
  end
  local minute = engineMinute()
  if lastFallbackMinute and minute + 720 < lastFallbackMinute then fallbackDay = fallbackDay + 1 end
  lastFallbackMinute = minute
  return {day = fallbackDay, minute = minute, abs = fallbackDay * MINUTES_PER_DAY + minute, ready = false}
end

function M.dateInfo(day)
  day = math.max(0, math.floor(tonumber(day) or 0))
  local total = EPOCH_DAY_OF_YEAR + day
  local year = EPOCH_YEAR + math.floor(total / 365)
  local dayOfYear = total % 365
  local month = 1
  while dayOfYear >= MONTH_LENGTHS[month] do
    dayOfYear = dayOfYear - MONTH_LENGTHS[month]
    month = month + 1
  end
  local weekday = (day % 7) + 1
  return {
    day = day, weekday = weekday, weekdayName = WEEKDAYS[weekday], weekdayShort = WEEKDAYS_SHORT[weekday],
    dayOfMonth = dayOfYear + 1, month = month, monthShort = MONTHS_SHORT[month], year = year,
    label = string.format("%s, %s %d", WEEKDAYS_SHORT[weekday], MONTHS_SHORT[month], dayOfYear + 1),
    longLabel = string.format("%s, %s %d", WEEKDAYS[weekday], MONTHS_SHORT[month], dayOfYear + 1),
  }
end

function M.weekdayName(weekday, short)
  return (short and WEEKDAYS_SHORT or WEEKDAYS)[weekday] or "?"
end

function M.formatClock(minute)
  minute = math.floor(tonumber(minute) or 0) % MINUTES_PER_DAY
  local hours, minutes = math.floor(minute / 60), minute % 60
  local twelve = hours % 12
  return string.format("%d:%02d %s", twelve == 0 and 12 or twelve, minutes, hours < 12 and "AM" or "PM")
end

function M.formatHour(hour)
  return M.formatClock((tonumber(hour) or 0) * 60)
end

-- Moves the world clock forward. Returns false when another weather mod owns the clock.
function M.advanceMinutes(minutes)
  minutes = math.max(0, math.floor(tonumber(minutes) or 0))
  if minutes == 0 then return true end
  local weather = overhaul_world_weather
  local moved = false
  while minutes > 0 do
    local step = math.min(minutes, MINUTES_PER_DAY - 1)
    local target = (M.now().minute + step) % MINUTES_PER_DAY
    local engineTime = ((target / MINUTES_PER_DAY) + 0.5) % 1
    local ok = weather and weather.sleepTo and try(weather.sleepTo, engineTime) == true
    if not ok then
      -- No weather clock: write the sky directly and count the day ourselves.
      if scenetree and scenetree.tod then
        if target < M.now().minute then fallbackDay = fallbackDay + 1 end
        scenetree.tod.time = engineTime
        lastFallbackMinute = target
        ok = true
      end
    end
    if not ok then return moved end
    moved = true
    minutes = minutes - step
  end
  return true
end

-- Wallet and professional level --------------------------------------------------------------------

function M.money()
  local attributes = overhaul_career_economy_playerAttributes
  return attributes and tonumber(try(attributes.getAttributeValue, "money")) or 0
end

local function post(amount, label, tags)
  local attributes = overhaul_career_economy_playerAttributes
  if not attributes or not attributes.addAttributes then return false end
  -- The category groups BeamLife income and spending together in the Overhaul's Wallet app.
  local ok, problem = pcall(attributes.addAttributes, {money = amount}, {label = label, tags = tags, category = "activity:beamlife"})
  if not ok then logError("wallet", problem) end
  return ok
end

function M.pay(amount, label, tags)
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then return false end
  return post(amount, label or "BeamLife", tags or {"gameplay", "reward", "beamlife"})
end

function M.charge(amount, label, tags)
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then return true end
  if M.money() < amount then return false end
  return post(-amount, label or "BeamLife", tags or {"buying", "beamlife"})
end

-- A fine or fee that may leave the wallet negative.
function M.fine(amount, label)
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then return true end
  return post(-amount, label or "BeamLife", {"fine", "beamlife"})
end

function M.addXp(amount, statKey)
  profile.xp = math.max(0, (profile.xp or 0) + (tonumber(amount) or 0))
  if statKey then profile.stats[statKey] = (profile.stats[statKey] or 0) + 1 end
end

function M.level()
  return math.floor(math.sqrt((profile.xp or 0) / 120))
end

function M.getProfile()
  local level = M.level()
  local floor, ceiling = level * level * 120, (level + 1) * (level + 1) * 120
  return {
    xp = math.floor(profile.xp or 0), level = level, stats = profile.stats,
    progress = M.clamp(((profile.xp or 0) - floor) / (ceiling - floor), 0, 1),
    nextLevelXp = ceiling,
  }
end

function M.stat(key)
  return profile.stats[key] or 0
end

-- Player and vehicle --------------------------------------------------------------------------------

function M.playerVehicleId()
  local id = be and be:getPlayerVehicleID(0)
  if id and id >= 0 then return id end
  return nil
end

function M.playerPosition()
  local veh = getPlayerVehicle(0)
  return veh and veh:getPosition() or nil
end

function M.speedOf(vehId)
  if not vehId then return 0 end
  local vx, vy, vz = be:getObjectVelocityXYZ(vehId)
  vx, vy, vz = tonumber(vx) or 0, tonumber(vy) or 0, tonumber(vz) or 0
  return math.sqrt(vx * vx + vy * vy + vz * vz)
end

function M.playerSpeed()
  return M.speedOf(M.playerVehicleId())
end

function M.isWalking()
  return gameplay_walk ~= nil and try(gameplay_walk.isWalking) == true
end

-- Metres from the player. FAR (a finite number, safe to send to the UI) when there is no player.
M.FAR = 9999999
function M.distanceTo(pos)
  local player = M.playerPosition()
  if not player or not pos then return M.FAR end
  return player:distance(pos)
end

-- What the player is driving: semi, truck, van, pickup or car, and whether a trailer is coupled.
function M.vehicleClass()
  local id = M.playerVehicleId()
  if not id or M.isWalking() then return {class = "none", hasTrailer = false, label = "On foot"} end
  local details = try(core_vehicles.getVehicleDetails, id) or {}
  local model = details.model or {}
  local key = details.current and details.current.key or ""
  local body = tostring(model["Body Style"] or ""):lower()
  local class = "car"
  if key == "us_semi" or body:find("semi", 1, true) then class = "semi"
  elseif key == "md_series" or body:find("box truck", 1, true) or body:find("cabover", 1, true) then class = "truck"
  elseif body:find("van", 1, true) then class = "van"
  elseif body:find("pickup", 1, true) or body:find("ute", 1, true) then class = "pickup"
  elseif model.Type == "Truck" and body == "" then class = "truck" end
  local hasTrailer = false
  if core_trailerRespawn and core_trailerRespawn.getTrailerData then
    local data = try(core_trailerRespawn.getTrailerData)
    hasTrailer = type(data) == "table" and data[id] ~= nil
  end
  local labels = {semi = "Semi truck", truck = "Truck", van = "Van", pickup = "Pickup", car = "Car"}
  return {class = class, hasTrailer = hasTrailer, label = labels[class] .. (hasTrailer and " + trailer" or ""), model = key}
end

-- Places ------------------------------------------------------------------------------------------

local function translated(text)
  if type(text) ~= "string" or text == "" then return nil end
  if text:find("%.") and not text:find(" ", 1, true) and type(_tr) == "function" then
    local ok, value = pcall(_tr, text, text)
    if ok and type(value) == "string" and value ~= "" then return value end
  end
  return text
end

local function kindOf(id, name, fallback)
  local text = (tostring(id) .. " " .. tostring(name)):lower()
  for _, entry in ipairs(KIND_WORDS) do
    for _, word in ipairs(entry.words) do
      if text:find(word, 1, true) then return entry.kind end
    end
  end
  return fallback or "other"
end

local function toVec(value)
  if not value then return nil end
  if type(value) == "table" and value.x == nil and value[1] then return vec3(value[1], value[2], value[3]) end
  return vec3(value)
end

local function addPlace(list, seen, id, name, pos, kind)
  if not pos or seen[id] then return end
  seen[id] = true
  list[#list + 1] = {id = id, name = translated(name) or id, pos = pos, kind = kind}
end

-- A facility names one sites file or a list of them; the spot is in the first file that has it.
local function sitePosition(sitesManager, sitesFile, spotName)
  if type(spotName) ~= "string" then return nil end
  local files = type(sitesFile) == "table" and sitesFile or {sitesFile}
  for _, file in ipairs(files) do
    if type(file) == "string" then
      local sites = try(sitesManager.loadSites, file)
      local spot = sites and sites.parkingSpots and sites.parkingSpots.byName and sites.parkingSpots.byName[spotName]
      if spot and spot.pos and not spot.missing then return toVec(spot.pos) end
    end
  end
  return nil
end

local function buildPlaces(level)
  local list, seen = {}, {}
  local facilities = overhaul_world_facilities
  if not facilities then return list end
  local sitesManager = try(require("overhaul/lib/world/sitesManager").sitesManager)
  if not sitesManager then return list end

  for _, facility in ipairs(try(facilities.getFacilitiesByType, "deliveryProvider", level) or {}) do
    for _, access in ipairs(facility.manualAccessPoints or {}) do
      local pos = sitePosition(sitesManager, facility.sitesFile, access.psName)
      if pos then
        addPlace(list, seen, "dp_" .. tostring(facility.id), facility.name, pos, kindOf(facility.id, facility.name, "other"))
        break
      end
    end
  end
  for _, garage in ipairs(try(facilities.getFacilitiesByType, "garage", level) or {}) do
    local spots = try(facilities.getParkingSpotsForFacility, garage)
    local spot = spots and spots[1]
    if spot and spot.pos then
      addPlace(list, seen, "gar_" .. tostring(garage.id), garage.name, toVec(spot.pos), "home")
    end
  end
  for _, station in ipairs(try(facilities.getFacilitiesByType, "gasStation", level) or {}) do
    local pos = try(facilities.getAverageDoorPositionForFacility, station)
    if pos then addPlace(list, seen, "gas_" .. tostring(station.id), station.name, toVec(pos), "gas") end
  end
  for _, dealer in ipairs(try(facilities.getFacilitiesByType, "dealership", level) or {}) do
    local pos = try(facilities.getAverageDoorPositionForFacility, dealer)
    if pos then addPlace(list, seen, "dlr_" .. tostring(dealer.id), dealer.name, toVec(pos), "dealer") end
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

function M.places()
  local level = getCurrentLevelIdentifier()
  if not level then return {} end
  if not places or placesLevel ~= level or #places == 0 then
    local ok, list = pcall(buildPlaces, level)
    if not ok then
      logError("places", list)
      list = {}
    end
    places, placesLevel, placesById = list, level, {}
    for _, place in ipairs(list) do placesById[place.id] = place end
    log("I", LOG_TAG, string.format("Found %d places on %s", #list, level))
  end
  return places
end

function M.place(id)
  M.places()
  return placesById and placesById[id] or nil
end

function M.placesOfKinds(kinds)
  local wanted, out = {}, {}
  for _, kind in ipairs(kinds or {}) do wanted[kind] = true end
  for _, place in ipairs(M.places()) do
    if wanted[place.kind] then out[#out + 1] = place end
  end
  return out
end

-- A place for a seed: the same seed always gives the same place on the same map.
function M.pickPlace(kinds, seed, avoid)
  local pool = kinds and M.placesOfKinds(kinds) or {}
  if #pool == 0 then pool = M.places() end
  if #pool == 0 then return nil end
  local random = M.rng(seed)
  for _ = 1, 12 do
    local place = pool[random(1, #pool)]
    if not avoid or not avoid[place.id] then return place end
  end
  return pool[random(1, #pool)]
end

-- Driving distance in metres; falls back to twice the straight line when no road path exists.
function M.routeDistance(from, to)
  if not from or not to then return 0 end
  local straight = from:distance(to)
  local ok, length = pcall(function()
    local startRoad = map.findClosestRoad(from)
    local endRoad = map.findClosestRoad(to)
    if not startRoad or not endRoad then return nil end
    local path = map.getPath(startRoad, endRoad)
    local nodes = map.getMap().nodes
    if not path or #path < 2 then return nil end
    local total, previous = 0, from
    for _, name in ipairs(path) do
      local node = nodes[name]
      if node then
        total = total + previous:distance(node.pos)
        previous = node.pos
      end
    end
    return total + previous:distance(to)
  end)
  if ok and type(length) == "number" and length > 0 then return math.max(length, straight) end
  return straight * 1.6
end

function M.setRoute(pos)
  if not pos or not core_groundMarkers then return end
  try(core_groundMarkers.setPath, pos, {clearPathOnReachingTarget = false})
end

function M.clearRoute()
  if core_groundMarkers then try(core_groundMarkers.setPath, nil) end
end

function M.setMarker(id, pos, radius, color)
  markers[id] = pos and {pos = pos, radius = radius or 8, color = color or {0.25, 0.75, 1}} or nil
end

-- Messages ----------------------------------------------------------------------------------------

function M.toast(title, message, kind)
  guihooks.trigger("toastrMsg", {type = kind or "info", title = title, msg = message})
end

function M.message(text, seconds)
  if type(ui_message) == "function" then ui_message(text, seconds or 5, "beamlife") end
end

-- A phone notification when the phone layout is available, otherwise a toast.
function M.notify(channel, title, message, meta)
  local layout = try(require("overhaul/lib/phone/layoutOwner").get)
  local sent = false
  if layout and layout.fireNotification then
    sent = try(layout.fireNotification, channel, {
      title = title, message = message, meta = meta, kind = "info", ttl = 8, source = "BeamLife",
      sound = {soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open"},
    }) == true
  end
  if not sent then M.toast(title, message) end
end

-- Tells the open phone app that its data changed.
function M.changed(app)
  guihooks.trigger("beamlifeChanged", {app = app})
end

-- Runs --------------------------------------------------------------------------------------------
-- A run is a list of stops. A stop is done when its subject (the player's vehicle, or another
-- vehicle such as a towed car) rests inside the stop radius for the stop's dwell time.

local function finishRun()
  local finished = run
  run = nil
  M.clearRoute()
  M.setMarker("run", nil)
  local nowAbs = M.now().abs
  local info = {
    late = finished.timeLimit ~= nil and (finished.elapsed or 0) > finished.timeLimit,
    minutes = nowAbs - finished.started, seconds = finished.elapsed or 0,
  }
  if finished.onFinish then
    local ok, problem = pcall(finished.onFinish, info)
    if not ok then logError("run finish", problem) end
  end
  M.changed(finished.owner)
end

local function nextStop()
  run.index = run.index + 1
  run.dwellLeft = nil
  local stop = run.steps[run.index]
  if not stop then
    finishRun()
    return
  end
  M.setRoute(stop.pos)
  M.setMarker("run", stop.pos, stop.radius or 12)
  M.message(stop.label, 7)
  M.changed(run.owner)
end

function M.isBusy()
  return run ~= nil or claimedBy ~= nil
end

function M.busyOwner()
  return run and run.owner or claimedBy
end

-- An activity that is not a list of stops (a street race, a rev battle) claims the player instead.
function M.claim(owner)
  if run or (claimedBy and claimedBy ~= owner) then return false end
  claimedBy = owner
  return true
end

function M.release(owner)
  if claimedBy == owner then claimedBy = nil end
end

function M.startRun(spec)
  if run or claimedBy then return false, "Finish or cancel your current task first." end
  if type(spec) ~= "table" or type(spec.steps) ~= "table" or #spec.steps == 0 then return false, "Invalid task." end
  run = spec
  run.index = 0
  run.elapsed = 0
  run.started = M.now().abs
  nextStop()
  return true
end

function M.cancelRun(reason)
  if not run then return false end
  local cancelled = run
  run = nil
  M.clearRoute()
  M.setMarker("run", nil)
  if cancelled.onCancel then
    local ok, problem = pcall(cancelled.onCancel, reason)
    if not ok then logError("run cancel", problem) end
  end
  M.changed(cancelled.owner)
  return true
end

function M.runState()
  if not run then return nil end
  local stop = run.steps[run.index]
  if not stop then return nil end
  return {
    owner = run.owner, title = run.title, step = run.index, steps = #run.steps, label = stop.label,
    distance = run.distance and math.floor(run.distance) or nil,
    waiting = run.dwellLeft ~= nil, dwellLeft = run.dwellLeft and math.ceil(run.dwellLeft) or nil,
    secondsLeft = run.timeLimit and math.floor(run.timeLimit - (run.elapsed or 0)) or nil,
  }
end

local function updateRun(dt)
  local stop = run.steps[run.index]
  if not stop then return end
  run.elapsed = (run.elapsed or 0) + dt
  local subjectPos
  if stop.subjectId then
    local subject = getObjectByID(stop.subjectId)
    if not subject then
      M.message("The task vehicle is gone. Task cancelled.", 6)
      M.cancelRun("subjectLost")
      return
    end
    subjectPos = subject:getPosition()
  else
    subjectPos = M.playerPosition()
  end
  if not subjectPos then return end
  run.distance = subjectPos:distance(stop.pos)
  if run.distance <= (stop.radius or 12) and M.playerSpeed() <= ARRIVE_SPEED then
    if run.dwellLeft == nil then
      run.dwellLeft = stop.dwell or 3
      if stop.dwellLabel then M.message(stop.dwellLabel, math.max(3, run.dwellLeft)) end
    end
    run.dwellLeft = run.dwellLeft - dt
    if run.dwellLeft <= 0 then
      if run.onStep then
        local ok, problem = pcall(run.onStep, run.index)
        if not ok then logError("run step", problem) end
      end
      if run then nextStop() end
    end
  elseif run.dwellLeft ~= nil then
    run.dwellLeft = nil
  end
end

-- HUD ---------------------------------------------------------------------------------------------

local hudProviders = {}

-- A module can add one short line to the HUD bar (for example "Shift at 8:00 AM").
function M.setHudProvider(id, fn)
  hudProviders[id] = fn
end

-- The speed limit of the road under the player in m/s, rounded to the nearest posted value
-- (5 km/h steps); nil off-road or when traffic is not tracking the player.
function M.speedLimit()
  local id = M.playerVehicleId()
  if not id or not gameplay_traffic or not gameplay_traffic.getTrafficData then return nil end
  local data = try(gameplay_traffic.getTrafficData)
  local vehicle = data and data[id]
  local limit = vehicle and vehicle.tracking and tonumber(vehicle.tracking.speedLimit)
  if not limit or limit <= 1 or limit > 90 then return nil end
  return M.round(limit, 0.1)
end

function M.getHudState()
  local now = M.now()
  local date = M.dateInfo(now.day)
  local notes = {}
  for id, fn in pairs(hudProviders) do
    local ok, note = pcall(fn, now, date)
    if ok and type(note) == "string" and note ~= "" then notes[#notes + 1] = {id = id, text = note} end
  end
  table.sort(notes, function(a, b) return a.id < b.id end)
  return {
    active = M.isCareerActive(),
    time = M.formatClock(now.minute), minute = now.minute, day = now.day,
    date = date.label, weekday = date.weekdayName, dayOfMonth = date.dayOfMonth, month = date.monthShort,
    run = M.runState(), notes = notes, speedLimit = M.speedLimit(),
    phoneOpen = overhaul_phone_phone ~= nil and try(overhaul_phone_phone.isPhoneOpen) == true,
  }
end

local function pushHud(force)
  local state = M.getHudState()
  local runState = state.run
  local key = table.concat({
    tostring(state.minute), tostring(state.day), tostring(state.phoneOpen), tostring(#state.notes), tostring(state.speedLimit),
    runState and (tostring(runState.step) .. ":" .. tostring(runState.distance) .. ":" .. tostring(runState.dwellLeft)) or "-",
  }, "|")
  if not force and key == lastHudKey then return end
  lastHudKey = key
  guihooks.trigger("beamlifeHud", state)
end

function M.requestHud()
  lastHudKey = nil
  pushHud(true)
  return true
end

function M.openPhone()
  if overhaul_phone_phone and overhaul_phone_phone.togglePhone then
    try(overhaul_phone_phone.togglePhone)
  end
  return true
end

-- Saves -------------------------------------------------------------------------------------------

local function currentSavePath()
  local saveSystem = overhaul_career_saveSystem
  if not saveSystem or not saveSystem.getCurrentProfile then return nil end
  local ok, _, path = pcall(saveSystem.getCurrentProfile)
  if ok and type(path) == "string" and path ~= "" then return path end
  return nil
end

function M.loadFile(name)
  local path = currentSavePath()
  if not path then return nil end
  local file = path .. SAVE_SUBDIR .. "/" .. name .. ".json"
  if not FS:fileExists(file) then return nil end
  local ok, data = pcall(jsonReadFile, file)
  if ok and type(data) == "table" then return data end
  return nil
end

function M.saveFile(savePath, name, data, writer)
  if type(savePath) ~= "string" or type(data) ~= "table" then return false end
  local saveSystem = overhaul_career_saveSystem
  if not saveSystem then return false end
  writer = writer or saveSystem.getSaveWriter()
  local dir = savePath .. SAVE_SUBDIR
  if not writer.exists(dir) then writer.mkdir(dir) end
  saveSystem.jsonWriteFileSafe(dir .. "/" .. name .. ".json", data, true)
  return true
end

-- Asks the career to save soon (after a purchase, a payment or a finished job).
function M.requestSave(reason)
  try(require("overhaul/lib/save/store").request, "beamlife:" .. tostring(reason or "change"))
end

-- Hooks -------------------------------------------------------------------------------------------

local function loadProfile()
  local data = M.loadFile("profile") or {}
  profile = {xp = tonumber(data.xp) or 0, stats = type(data.stats) == "table" and data.stats or {}}
  fallbackDay = tonumber(data.fallbackDay) or 0
  lastFallbackMinute = nil
  lastDay = nil
  run = nil
  claimedBy = nil
  markers = {}
  places = nil
end

local function tick()
  local now = M.now()
  if lastDay == nil then
    lastDay = now.day
  elseif now.day ~= lastDay then
    local previous = lastDay
    lastDay = now.day
    -- Sleeping or travelling can skip more than one day; every module catches up from `previous`.
    extensions.hook("onBeamlifeNewDay", now.day, previous)
  end
  extensions.hook("onBeamlifeTick", now)
  pushHud(false)
end

M.onCareerActivated = M.safe("core.onCareerActivated", loadProfile)

M.onOverhaulActive = M.safe("core.onOverhaulActive", function(active)
  if active then
    lastHudKey = nil
  else
    if run then M.cancelRun("careerStopped") end
    guihooks.trigger("beamlifeHud", {active = false})
  end
end)

M.onOverhaulSaveCurrentProfile = M.safe("core.save", function(savePath, _, writer)
  M.saveFile(savePath, "profile", {xp = profile.xp, stats = profile.stats, fallbackDay = fallbackDay}, writer)
end)

M.onClientEndMission = M.safe("core.onClientEndMission", function()
  places = nil
  if run then M.cancelRun("levelChanged") end
end)

M.onUpdate = M.safe("core.onUpdate", function(dtReal, dtSim)
  if not M.isCareerActive() then return end
  if run then updateRun(dtSim or 0) end
  tickTimer = tickTimer + (dtReal or 0)
  if tickTimer >= TICK_SECONDS then
    tickTimer = 0
    tick()
  end
end)

M.onPreRender = function()
  if not next(markers) or not debugDrawer then return end
  for _, marker in pairs(markers) do
    local color = marker.color
    local top = vec3(marker.pos.x, marker.pos.y, marker.pos.z + 14)
    debugDrawer:drawCylinder(marker.pos, top, 0.35, ColorF(color[1], color[2], color[3], 0.55))
    debugDrawer:drawSphere(marker.pos, marker.radius, ColorF(color[1], color[2], color[3], 0.12))
  end
end

M.onExtensionUnloaded = function()
  if run then pcall(M.cancelRun, "unloaded") end
  markers = {}
  hudProviders = {}
  guihooks.trigger("beamlifeHud", {active = false})
end

return M
