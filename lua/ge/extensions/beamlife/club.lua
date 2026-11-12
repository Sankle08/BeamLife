-- BeamLife R2F Club: the car scene. A small one-time fee makes the player a member; from then on
-- he can check in at the weekly meets, enter rev battles ("ronco") at a meet, and take night races
-- on the open road against a rival. Everything feeds a club reputation with levels and prizes.
-- Reading order: config, state, reputation, meets, rev battle, night race, UI state, hooks.
local M = {}
M.dependencies = {"beamlife_core"}

-- Config ------------------------------------------------------------------------------------------

local APP = "club"
local MEMBERSHIP_FEE = 750
local REP_PER_LEVEL = 60
local MAX_LEVEL = 10
local LEVEL_PRIZE = 400
local TITLES = {[0] = "Rookie", "Member", "Regular", "Familiar Face", "Respected", "Standout", "Name", "Veteran", "Idol", "Legend", "R2F Legend"}

local MEETS = {
  {weekday = 3, start = 20, hours = 3, name = "Midweek Cruise"},
  {weekday = 5, start = 19, hours = 5, name = "Friday Meet"},
  {weekday = 6, start = 19, hours = 6, name = "R2F Saturday"},
}
local MEET_KINDS = {"food", "gas", "shop"}
local MEET_RADIUS = 60
local CHECKIN_SECONDS = 20
local CHECKIN_REP = 15
local RAFFLE_CHANCE = 0.2

local REV_SECONDS = 8
local REV_SAMPLE_INTERVAL = 0.2
local REV_BAND = {0.80, 0.95}
local REV_PER_MEET = 3
local REV_TIERS = {
  {id = "amador", name = "Street Rev", bet = 200, level = 0, rivals = 88},
  {id = "forte", name = "Loud Rev", bet = 600, level = 2, rivals = 94},
  {id = "monstro", name = "Monster Rev", bet = 2000, level = 4, rivals = 100},
}

local NIGHT_START, NIGHT_END = 21 * 60, 5 * 60
local RACE_MIN_METERS, RACE_MAX_METERS = 1800, 6500
local FINISH_RADIUS = 35
local COUNTDOWN_SECONDS = 4
local RIVAL_CLEANUP_SECONDS = 15
local RACE_TIERS = {
  {id = "bairro", name = "Back Street Run", bet = 300, level = 0, speed = 26, aggression = 0.75, models = {"covet", "pessima", "legran"}},
  {id = "rodovia", name = "Highway Run", bet = 1000, level = 2, speed = 33, aggression = 0.9, models = {"etk800", "sunburst2", "vivace"}},
  {id = "rei", name = "Highway King", bet = 3000, level = 4, speed = 40, aggression = 1.0, models = {"scintilla", "bolide", "sbr"}},
}

-- State -------------------------------------------------------------------------------------------

local state = {member = false, rep = 0, stats = {}}
local rev
local race
local checkinTimer = 0
local rivalCleanup
local lastResult

local function core() return beamlife_core end

local function guard(name, fn)
  return function(...)
    local ok, result = xpcall(fn, debug.traceback, ...)
    if not ok then log("E", "beamlife", name .. ": " .. tostring(result)) return nil end
    return result
  end
end

local function bump(key, amount)
  state.stats[key] = (state.stats[key] or 0) + (amount or 1)
end

local function closePhone()
  if overhaul_phone_phone and overhaul_phone_phone.closePhone then core().try(overhaul_phone_phone.closePhone) end
end

-- Reputation --------------------------------------------------------------------------------------

local function levelOf(rep)
  return math.min(MAX_LEVEL, math.floor(math.sqrt(math.max(0, rep) / REP_PER_LEVEL)))
end

local function addRep(amount)
  local before = levelOf(state.rep)
  state.rep = math.max(0, state.rep + amount)
  local after = levelOf(state.rep)
  if after > before then
    local prize = LEVEL_PRIZE * after
    core().pay(prize, "R2F Club: level prize", {"gameplay", "reward", "beamlife", "club"})
    core().notify("beamlife.club", "R2F Club", string.format("You are now %s (level %d). Prize: $%d.", TITLES[after], after, prize))
  end
end

local function tierById(tiers, id)
  for _, tier in ipairs(tiers) do
    if tier.id == id then return tier end
  end
  return nil
end

-- Meets -------------------------------------------------------------------------------------------

local function meetPlace(day, meet)
  local level = getCurrentLevelIdentifier() or "level"
  return core().pickPlace(MEET_KINDS, core().hash(level .. ":meet:" .. math.floor(day / 7) .. ":" .. meet.weekday))
end

-- The meet running right now, if any. A meet that passes midnight still belongs to the day it started.
local function activeMeet(now)
  for _, offset in ipairs({0, 1}) do
    local day = now.day - offset
    if day >= 0 then
      local weekday = core().dateInfo(day).weekday
      for _, meet in ipairs(MEETS) do
        if meet.weekday == weekday then
          local minute = now.minute + offset * 1440
          if minute >= meet.start * 60 and minute < (meet.start + meet.hours) * 60 then
            return meet, day, meetPlace(day, meet)
          end
        end
      end
    end
  end
  return nil
end

local function upcomingMeets(now)
  local list = {}
  for ahead = 0, 7 do
    local day = now.day + ahead
    local date = core().dateInfo(day)
    for _, meet in ipairs(MEETS) do
      if meet.weekday == date.weekday and (ahead > 0 or now.minute < (meet.start + meet.hours) * 60) and #list < 3 then
        local place = meetPlace(day, meet)
        list[#list + 1] = {
          name = meet.name, day = date.label, time = core().formatHour(meet.start) .. " to " .. core().formatHour((meet.start + meet.hours) % 24),
          place = place and place.name or "To be announced", today = ahead == 0,
        }
      end
    end
  end
  return list
end

local function atMeet(now)
  local meet, day, place = activeMeet(now)
  if not meet or not place then return nil end
  if core().distanceTo(place.pos) > MEET_RADIUS then return nil end
  return meet, day, place
end

local function checkIn(meet, day)
  state.lastCheckinDay = day
  state.revToday = 0
  bump("meets")
  addRep(CHECKIN_REP)
  local text = meet.name .. ": checked in (+" .. CHECKIN_REP .. " reputation)."
  if math.random() < RAFFLE_CHANCE then
    local prize = core().round(200 + math.random() * 1800, 50)
    core().pay(prize, "R2F Club: meet raffle", {"gameplay", "reward", "beamlife", "club"})
    text = text .. string.format(" You won the raffle: $%d!", prize)
  end
  core().message(text, 8)
  core().changed(APP)
  core().requestSave("meet")
end

-- Rev battle --------------------------------------------------------------------------------------

local function requestRevSample()
  local id = rev.vehicleId
  local vehicle = getObjectByID(id)
  if not vehicle then return end
  vehicle:queueLuaCommand(string.format([[
    local engine = powertrain and powertrain.getDevice and powertrain.getDevice('mainEngine')
    local rpm = electrics and electrics.values and electrics.values.rpm or 0
    obj:queueGameEngineLua(string.format('if beamlife_club then beamlife_club.onRevSample(%d, %%.1f, %%.1f, %%.1f) end',
      rpm, engine and engine.maxRPM or -1, engine and engine.maxTorque or -1))
  ]], id))
end

function M.onRevSample(vehicleId, rpm, maxRpm, torque)
  if not rev or rev.vehicleId ~= vehicleId then return end
  if maxRpm <= 0 then
    rev.noEngine = true
    return
  end
  rev.maxRpm, rev.torque = maxRpm, math.max(rev.torque or 0, torque)
  local ratio = rpm / maxRpm
  rev.samples = rev.samples + 1
  rev.peak = math.max(rev.peak, math.min(1, ratio))
  if ratio >= REV_BAND[1] and ratio <= REV_BAND[2] then rev.inBand = rev.inBand + 1 end
end

local function finishRev()
  local session = rev
  rev = nil
  core().release(APP)
  if session.noEngine or session.samples == 0 then
    core().pay(session.tier.bet, "R2F Club: entry fee refunded", {"gameplay", "reward", "beamlife", "club"})
    lastResult = {kind = "rev", won = false, text = "Your car has no combustion engine to rev. Entry fee refunded."}
    core().message(lastResult.text, 7)
    core().changed(APP)
    return
  end
  local powerKw = math.max(30, session.torque * session.maxRpm * 0.75 / 9549)
  local precision = session.inBand / session.samples
  local decibels = 62 + 14 * math.log10(powerKw) + 6 * precision + 2 * session.peak
  local place = 1
  local rivals = {}
  for index = 1, 3 do
    rivals[index] = session.tier.rivals + (math.random() - 0.5) * 6
    if rivals[index] > decibels then place = place + 1 end
  end
  local prize = place == 1 and session.tier.bet * 2.2 or (place == 2 and session.tier.bet * 1.2 or 0)
  prize = math.floor(prize)
  if prize > 0 then core().pay(prize, "R2F Club: rev battle", {"gameplay", "reward", "beamlife", "club"}) end
  bump("revs")
  if place == 1 then bump("revWins") end
  addRep(place == 1 and 25 or 10)
  lastResult = {
    kind = "rev", won = place == 1, place = place, decibels = core().round(decibels, 0.1),
    precision = math.floor(precision * 100 + 0.5), prize = prize,
    text = string.format("%.1f dB, %d%% in the band: place %d%s", decibels, math.floor(precision * 100 + 0.5), place,
      prize > 0 and string.format(", prize $%d.", prize) or ". No prize this time."),
  }
  core().message("Rev battle: " .. lastResult.text, 9)
  core().changed(APP)
  core().requestSave("rev")
end

function M.startRev(tierId)
  local tier = tierById(REV_TIERS, tierId)
  if not state.member then return {ok = false, message = "Join the club first."} end
  if not tier then return {ok = false, message = "Unknown class."} end
  if levelOf(state.rep) < tier.level then return {ok = false, message = "Needs level " .. tier.level .. " in the club."} end
  local now = core().now()
  local meet, day = atMeet(now)
  if not meet then return {ok = false, message = "Rev battles happen at meets. Go to the meet while it is on."} end
  if state.lastCheckinDay ~= day then checkIn(meet, day) end
  if (state.revToday or 0) >= REV_PER_MEET then
    return {ok = false, message = "You already entered " .. REV_PER_MEET .. " times at this meet."}
  end
  local vehicleId = core().playerVehicleId()
  if not vehicleId or core().isWalking() then return {ok = false, message = "You need to be in your car."} end
  if not core().claim(APP) then return {ok = false, message = "Finish your current task first."} end
  if not core().charge(tier.bet, "R2F Club: rev battle entry", {"buying", "beamlife", "club"}) then
    core().release(APP)
    return {ok = false, message = "Not enough money for the entry fee of $" .. tier.bet .. "."}
  end
  state.revToday = (state.revToday or 0) + 1
  rev = {tier = tier, vehicleId = vehicleId, time = 0, sampleTimer = 0, samples = 0, inBand = 0, peak = 0}
  closePhone()
  core().message(string.format("Rev battle on! Hold the revs between %d%% and %d%% of the limit for %d seconds.",
    REV_BAND[1] * 100, REV_BAND[2] * 100, REV_SECONDS), REV_SECONDS)
  return {ok = true, message = "Go!"}
end

-- Night race --------------------------------------------------------------------------------------

local function isNight(minute)
  return minute >= NIGHT_START or minute < NIGHT_END
end

local function pickDestination(playerPos)
  local candidates = {}
  for _, place in ipairs(core().places()) do
    local straight = place.pos:distance(playerPos)
    if straight >= RACE_MIN_METERS and straight <= RACE_MAX_METERS then candidates[#candidates + 1] = place end
  end
  if #candidates == 0 then return nil end
  return candidates[math.random(#candidates)]
end

local function removeRival()
  if rivalCleanup and rivalCleanup.id then
    local rival = getObjectByID(rivalCleanup.id)
    if rival then rival:delete() end
  end
  rivalCleanup = nil
end

local function spawnRival(tier, player, destination)
  local direction = player:getDirectionVector()
  local up = player:getDirectionVectorUp()
  local right = direction:cross(up)
  local pos = player:getPosition() + right * 4.5
  local model = tier.models[math.random(#tier.models)]
  local rival = core_vehicles.spawnNewVehicle(model, {
    pos = pos, rot = quatFromDir(direction, up), autoEnterVehicle = false, autoFlip = true,
  })
  if not rival then return nil end
  rival.playerUsable = false
  rival:queueLuaCommand("electrics.setLightsState(2)")
  rival:queueLuaCommand("if ai and ai.setMode then ai.setMode('stop') end")
  -- The route is handed over as road nodes, the same way the game's own AI racers receive theirs.
  local startRoad = map.findClosestRoad(pos)
  local endRoad = map.findClosestRoad(destination)
  local path = startRoad and endRoad and map.getPath(startRoad, endRoad)
  if not path or #path < 2 then
    rival:delete()
    return nil
  end
  return rival:getID(), path
end

local function launchRival()
  local rival = race.rivalId and getObjectByID(race.rivalId)
  if not rival or not race.rivalPath then return end
  rival:queueLuaCommand("input.event('parkingbrake', 0, 1)")
  rival:queueLuaCommand(string.format([[
    if ai and ai.driveUsingPath then
      ai.setAvoidCars('on')
      ai.driveUsingPath({wpTargetList = %s, avoidCars = 'on', driveInLane = 'off', aggression = %.2f, noOfLaps = 1})
    end
  ]], serialize(race.rivalPath), race.tier.aggression))
end

local function endRace(won, text)
  local finished = race
  race = nil
  core().release(APP)
  core().clearRoute()
  core().setMarker("race", nil)
  if finished.rivalId then rivalCleanup = {id = finished.rivalId, at = os.clock() + RIVAL_CLEANUP_SECONDS} end
  local prize = 0
  bump("races")
  if won then
    prize = finished.tier.bet * 2
    core().pay(prize, "R2F Club: race won", {"gameplay", "reward", "beamlife", "club"})
    bump("raceWins")
    addRep(40)
  else
    addRep(12)
  end
  lastResult = {kind = "race", won = won, prize = prize, seconds = math.floor(finished.time), text = text}
  core().message(text .. (won and string.format(" You take $%d.", prize) or " The rival keeps the bet."), 9)
  core().changed(APP)
  core().requestSave("race")
end

function M.startRace(tierId)
  local tier = tierById(RACE_TIERS, tierId)
  if not state.member then return {ok = false, message = "Join the club first."} end
  if not tier then return {ok = false, message = "Unknown class."} end
  if levelOf(state.rep) < tier.level then return {ok = false, message = "Needs level " .. tier.level .. " in the club."} end
  if not isNight(core().now().minute) then return {ok = false, message = "Races are at night only, from 9 PM to 5 AM." } end
  local player = getPlayerVehicle(0)
  if not player or core().isWalking() then return {ok = false, message = "You need to be in your car."} end
  local destination = pickDestination(player:getPosition())
  if not destination then return {ok = false, message = "No good route from here. Try another part of town."} end
  if not core().claim(APP) then return {ok = false, message = "Finish your current task first."} end
  if not core().charge(tier.bet, "R2F Club: race bet", {"buying", "beamlife", "club"}) then
    core().release(APP)
    return {ok = false, message = "Not enough money for the bet of $" .. tier.bet .. "."}
  end
  removeRival()
  local meters = core().routeDistance(player:getPosition(), destination.pos)
  race = {
    tier = tier, vehicleId = player:getID(), destination = destination, meters = meters,
    ghostTime = meters / tier.speed, countdown = COUNTDOWN_SECONDS, time = 0, lastCount = COUNTDOWN_SECONDS + 1,
  }
  local ok, rivalId, path = pcall(spawnRival, tier, player, destination.pos)
  if ok and rivalId then
    race.rivalId, race.rivalPath = rivalId, path
  else
    log("W", "beamlife", "Race rival unavailable, racing the clock: " .. tostring(rivalId))
  end
  core().setRoute(destination.pos)
  core().setMarker("race", destination.pos, FINISH_RADIUS, {1, 0.35, 0.2})
  closePhone()
  core().message(string.format("%s to %s (%.1f km). Get ready!", tier.name, destination.name, meters / 1000), 5)
  return {ok = true, message = "Race set. Starting in a moment."}
end

function M.cancelRace()
  if not race then return {ok = false, message = "No race in progress."} end
  endRace(false, "You quit the race.")
  return {ok = true, message = "Race abandoned."}
end

local function updateRace(dt)
  if core().playerVehicleId() ~= race.vehicleId then
    endRace(false, "You left the car and lost the race.")
    return
  end
  if race.countdown > 0 then
    race.countdown = race.countdown - dt
    local count = math.ceil(race.countdown)
    if count ~= race.lastCount then
      race.lastCount = count
      if count > 0 then
        core().message(tostring(count) .. "...", 1)
      else
        core().message("GO!", 2)
        launchRival()
      end
    end
    return
  end
  race.time = race.time + dt
  local playerPos = core().playerPosition()
  if playerPos and playerPos:distance(race.destination.pos) <= FINISH_RADIUS then
    endRace(true, string.format("You won the race in %d:%02d!", math.floor(race.time / 60), math.floor(race.time % 60)))
    return
  end
  local rival = race.rivalId and getObjectByID(race.rivalId)
  local rivalArrived = rival and rival:getPosition():distance(race.destination.pos) <= FINISH_RADIUS
  -- Without a rival on the road the bet is against his time; a stuck rival still finishes on the clock.
  local clockLimit = rival and race.ghostTime * 1.25 or race.ghostTime
  if rivalArrived or race.time >= clockLimit then
    endRace(false, "The rival got there first.")
  end
end

-- Membership --------------------------------------------------------------------------------------

function M.join()
  if state.member then return {ok = false, message = "You are already a member."} end
  if not core().charge(MEMBERSHIP_FEE, "R2F Club: joining fee", {"buying", "beamlife", "club"}) then
    return {ok = false, message = "You are $" .. (MEMBERSHIP_FEE - math.floor(core().money())) .. " short for the joining fee."}
  end
  state.member = true
  state.joinedDay = core().now().day
  core().changed(APP)
  core().requestSave("clubJoined")
  return {ok = true, message = "Welcome to R2F Club!"}
end

function M.navigateToMeet()
  local now = core().now()
  local meet, day, place = activeMeet(now)
  if not place then
    for ahead = 0, 7 do
      local date = core().dateInfo(now.day + ahead)
      for _, candidate in ipairs(MEETS) do
        if not place and candidate.weekday == date.weekday then place = meetPlace(now.day + ahead, candidate) end
      end
    end
  end
  if not place then return {ok = false, message = "No meets on this map."} end
  core().setRoute(place.pos)
  return {ok = true, message = "Route set to " .. place.name .. "."}
end

-- UI state ----------------------------------------------------------------------------------------

function M.getState()
  local now = core().now()
  local level = levelOf(state.rep)
  local floor, ceiling = level * level * REP_PER_LEVEL, (level + 1) * (level + 1) * REP_PER_LEVEL
  local meet, day, place = activeMeet(now)
  local here = meet and place and core().distanceTo(place.pos) <= MEET_RADIUS
  local function tiers(list)
    local out = {}
    for _, tier in ipairs(list) do
      out[#out + 1] = {id = tier.id, name = tier.name, bet = tier.bet, level = tier.level, locked = level < tier.level}
    end
    return out
  end
  return {
    member = state.member, fee = MEMBERSHIP_FEE, money = math.floor(core().money()),
    rep = {level = level, title = TITLES[level], points = math.floor(state.rep), max = MAX_LEVEL,
      progress = level >= MAX_LEVEL and 1 or core().clamp((state.rep - floor) / (ceiling - floor), 0, 1)},
    meet = meet and {
      name = meet.name, place = place and place.name or "?", here = here == true,
      distance = place and math.floor(core().distanceTo(place.pos)) or nil,
      checkedIn = state.lastCheckinDay == day,
      revLeft = REV_PER_MEET - (state.lastCheckinDay == day and (state.revToday or 0) or 0),
    } or nil,
    upcoming = upcomingMeets(now),
    revTiers = tiers(REV_TIERS), raceTiers = tiers(RACE_TIERS),
    isNight = isNight(now.minute), time = core().formatClock(now.minute),
    racing = race and {tier = race.tier.name, destination = race.destination.name, km = core().round(race.meters / 1000, 0.1),
      seconds = math.floor(race.time), hasRival = race.rivalId ~= nil} or nil,
    revving = rev ~= nil, busy = core().isBusy() and core().busyOwner() ~= APP,
    stats = state.stats, lastResult = lastResult,
  }
end

-- Hooks -------------------------------------------------------------------------------------------

M.onCareerActivated = guard("club.onCareerActivated", function()
  local data = beamlife_core.loadFile("club") or {}
  state = {
    member = data.member == true, rep = tonumber(data.rep) or 0, stats = type(data.stats) == "table" and data.stats or {},
    lastCheckinDay = tonumber(data.lastCheckinDay), revToday = tonumber(data.revToday) or 0, joinedDay = tonumber(data.joinedDay),
  }
  rev, race, lastResult, checkinTimer = nil, nil, nil, 0
  beamlife_core.setHudProvider("club", function(now)
    if not state.member then return nil end
    local meet, _, place = activeMeet(now)
    if meet and place then return meet.name .. " at " .. place.name end
    return nil
  end)
end)

M.onOverhaulSaveCurrentProfile = guard("club.save", function(savePath, _, writer)
  beamlife_core.saveFile(savePath, "club", state, writer)
end)

M.onBeamlifeTick = guard("club.tick", function(now)
  if rivalCleanup and not race and os.clock() > rivalCleanup.at then removeRival() end
  if not state.member or rev or race then return end
  local meet, day = atMeet(now)
  if meet and state.lastCheckinDay ~= day and core().playerSpeed() < 2 then
    checkinTimer = checkinTimer + 1
    if checkinTimer >= CHECKIN_SECONDS then
      checkinTimer = 0
      checkIn(meet, day)
    end
  else
    checkinTimer = 0
  end
end)

M.onUpdate = guard("club.update", function(dtReal, dtSim)
  dtSim = dtSim or 0
  if race then updateRace(dtSim) end
  if rev then
    rev.time = rev.time + dtSim
    rev.sampleTimer = rev.sampleTimer + dtSim
    if rev.sampleTimer >= REV_SAMPLE_INTERVAL then
      rev.sampleTimer = 0
      requestRevSample()
    end
    if rev.time >= REV_SECONDS then finishRev() end
  end
end)

M.onClientEndMission = function()
  if race then
    race = nil
    if beamlife_core then beamlife_core.release(APP) end
  end
  if rev then
    rev = nil
    if beamlife_core then beamlife_core.release(APP) end
  end
  rivalCleanup = nil
end

M.onExtensionUnloaded = function()
  pcall(removeRival)
  if race and race.rivalId then
    local rival = getObjectByID(race.rivalId)
    if rival then rival:delete() end
  end
end

return M
