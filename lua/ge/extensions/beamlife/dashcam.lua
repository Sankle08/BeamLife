-- BeamLife law and DashTube.
--   Law: the police ignore mild speeding, but running a red light, hitting someone and leaving,
--   or driving against traffic starts a pursuit. A long pursuit calls in more and bigger units.
--   DashTube: every pursuit is recorded by the dashcam. The clip can be published from the phone
--   and earns money over the next days, according to how long, fast and heavy the chase was.
-- Reading order: config, state, police tuning, reinforcements, recording, publishing, UI state, hooks.
local M = {}
M.dependencies = {"beamlife_core"}

-- Config ------------------------------------------------------------------------------------------

local APP = "dashcam"
local MIN_CLIP_SECONDS = 25
local MAX_CLIPS = 14
local MPS_TO_KMH = 3.6
local DOLLARS_PER_1000_VIEWS = 4
local VIEW_SCHEDULE = {0.20, 0.45, 0.25, 0.10}   -- at publishing, then on each of the next three days
local SUBSCRIBERS_PER_VIEW = 1 / 400
local ARRESTED_FACTOR = 0.6

-- Points each offence adds to the pursuit score for the player. A pursuit starts at 150.
local OFFENSE_SCORES = {
  speeding = 90, racing = 170, intersection = 200, hitTraffic = 200, wrongWay = 160, reckless = 200, hitPolice = 260,
}
local PURSUIT_VARS = {
  speedingOverSpeed = 9.7,             -- 35 km/h over the limit before speeding counts at all
  scoreLevels = {150, 1200, 4200},     -- level 2 after about three minutes on the run, level 3 after about ten
}
-- Seconds into a pursuit at which another unit joins, and the least pursuit level it brings.
local REINFORCEMENTS = {
  {after = 150, model = "fullsize", config = "police", level = 1, label = "Another unit joined the pursuit."},
  {after = 330, model = "roamer", config = "police", level = 2, label = "Backup: SUV unit on the way."},
  {after = 600, model = "van", config = "police", level = 3, label = "Heavy backup: tactical unit in the area."},
}
local REINFORCEMENT_CLEANUP_SECONDS = 60

-- State -------------------------------------------------------------------------------------------

local state = {clips = {}, subscribers = 0, views = 0, earned = 0, nextId = 1}
local recording
local reinforcementIds = {}
local cleanupAt

local function core() return beamlife_core end
local function police() return overhaul_integration_services_police end

local function guard(name, fn)
  return function(...)
    local ok, result = xpcall(fn, debug.traceback, ...)
    if not ok then log("E", "beamlife", name .. ": " .. tostring(result)) return nil end
    return result
  end
end

-- Police tuning -----------------------------------------------------------------------------------

local function applyPursuitVars()
  local service = police()
  if service and service.setPursuitVars then core().try(service.setPursuitVars, PURSUIT_VARS) end
end

-- Reinforcements ----------------------------------------------------------------------------------

local function removeReinforcements()
  for _, id in ipairs(reinforcementIds) do
    local vehicle = getObjectByID(id)
    if vehicle then
      if gameplay_traffic and gameplay_traffic.removeTraffic then pcall(gameplay_traffic.removeTraffic, id) end
      vehicle:delete()
    end
  end
  reinforcementIds = {}
  cleanupAt = nil
end

local function spawnReinforcement(spec, playerId)
  if not gameplay_traffic or gameplay_traffic.getState() ~= "on" or not gameplay_traffic_trafficUtils then return false end
  local player = getObjectByID(playerId)
  if not player then return false end
  local direction = player:getDirectionVector()
  -- Behind the player and out of sight, on the road he came from.
  local spawn = gameplay_traffic_trafficUtils.findSpawnPointOnRoute(player:getPosition(), -direction, 140, 420, 220, {pathRandomization = 0})
  if not spawn or not spawn.pos then return false end
  local facing = spawn.dir and -spawn.dir or direction
  local vehicle = core_vehicles.spawnNewVehicle(spec.model, {
    config = spec.config, pos = vec3(spawn.pos), rot = quatFromDir(facing, spawn.normal or vec3(0, 0, 1)),
    autoEnterVehicle = false,
  })
  if not vehicle then return false end
  local id = vehicle:getID()
  vehicle.playerUsable = false
  gameplay_traffic.insertTraffic(id, false, true)
  local traffic = gameplay_traffic.getTrafficData()[id]
  if traffic then traffic:setRole("police") end
  if overhaul_shell_extensionManager and overhaul_shell_extensionManager.applyOverrideAI then
    overhaul_shell_extensionManager.applyOverrideAI(id)
  end
  reinforcementIds[#reinforcementIds + 1] = id
  return true
end

local function escalate(playerId)
  -- The Performance screen limits how many extra units may join.
  local limit = beamlife_perf and beamlife_perf.policeBackupLimit() or #REINFORCEMENTS
  if recording.stage >= limit then return end
  local spec = REINFORCEMENTS[recording.stage + 1]
  if not spec or recording.seconds < spec.after then return end
  recording.stage = recording.stage + 1
  local ok, spawned = pcall(spawnReinforcement, spec, playerId)
  if not ok then log("W", "beamlife", "Reinforcement failed: " .. tostring(spawned)) end
  local service = police()
  local pursuit = service and core().try(service.getPursuitData, playerId)
  local level = math.max(spec.level, pursuit and pursuit.mode or 1)
  -- Setting the mode again also sends the new unit after the player.
  if service and service.setPursuitMode then core().try(service.setPursuitMode, level, playerId) end
  if ok and spawned then
    recording.reinforcements = recording.reinforcements + 1
    core().message(spec.label, 6)
  end
end

-- Recording ---------------------------------------------------------------------------------------

local function startRecording(playerId)
  cleanupAt = nil
  recording = {
    vehicleId = playerId, seconds = 0, topSpeed = 0, level = 1, units = 1, meters = 0, stage = 0, reinforcements = 0,
    lastPos = core().playerPosition(), vehicle = core().vehicleClass().label,
  }
end

local function sample(dt)
  local id = recording.vehicleId
  recording.seconds = recording.seconds + dt
  recording.topSpeed = math.max(recording.topSpeed, core().speedOf(id) * MPS_TO_KMH)
  local vehicle = getObjectByID(id)
  local pos = vehicle and vehicle:getPosition()
  if pos and recording.lastPos then recording.meters = recording.meters + pos:distance(recording.lastPos) end
  recording.lastPos = pos and vec3(pos) or recording.lastPos
  local service = police()
  local pursuit = service and core().try(service.getPursuitData, id)
  if pursuit then
    recording.level = math.max(recording.level, tonumber(pursuit.mode) or 0)
    recording.units = math.max(recording.units, tonumber(pursuit.policeCount) or 0)
    recording.hits = tonumber(pursuit.hitCount) or recording.hits
    recording.offenses = tonumber(pursuit.uniqueOffensesCount) or recording.offenses
  end
  escalate(id)
end

-- How watchable a chase is, in points. Long, fast, crowded and messy chases score higher.
local function clipScore(clip)
  local clamp = core().clamp
  local score = clamp(clip.seconds / 60, 0, 12)
    + clamp((clip.topSpeed - 80) / 25, 0, 8)
    + (clamp(clip.level, 1, 3) - 1) * 3
    + clamp(clip.units * 0.8, 0, 6)
    + clamp((clip.hits or 0) * 0.7, 0, 5)
    + clamp(clip.km * 0.3, 0, 4)
  if clip.outcome == "arrested" then score = score * ARRESTED_FACTOR end
  return score
end

local function stopRecording(outcome)
  local finished = recording
  recording = nil
  if #reinforcementIds > 0 then cleanupAt = os.clock() + REINFORCEMENT_CLEANUP_SECONDS end
  if not finished or not outcome or finished.seconds < MIN_CLIP_SECONDS then return end
  local now = core().now()
  local clip = {
    id = state.nextId, day = now.day, minute = now.minute, outcome = outcome,
    seconds = math.floor(finished.seconds), topSpeed = math.floor(finished.topSpeed), level = finished.level,
    units = math.max(finished.units, 1 + finished.reinforcements), hits = finished.hits or 0,
    offenses = finished.offenses or 1, km = core().round(finished.meters / 1000, 0.1), vehicle = finished.vehicle,
  }
  clip.score = core().round(clipScore(clip), 0.1)
  state.nextId = state.nextId + 1
  table.insert(state.clips, 1, clip)
  -- Unpublished clips beyond the limit are recorded over, oldest first.
  local unpublished = 0
  for index = #state.clips, 1, -1 do
    if not state.clips[index].published then unpublished = unpublished + 1 end
  end
  for index = #state.clips, 1, -1 do
    if unpublished <= MAX_CLIPS then break end
    if not state.clips[index].published then
      table.remove(state.clips, index)
      unpublished = unpublished - 1
    end
  end
  core().notify("beamlife.dashcam", "DashTube", string.format("Pursuit recorded: %d:%02d, top speed %d km/h. Publish it in the app.",
    math.floor(clip.seconds / 60), clip.seconds % 60, clip.topSpeed))
  core().changed(APP)
  core().requestSave("clip")
end

-- Publishing --------------------------------------------------------------------------------------

local function channelBoost()
  return math.min(2, 1 + state.subscribers / 5000)
end

local function payViews(clip, share)
  local views = math.floor(clip.totalViews * share)
  if views <= 0 then return 0 end
  local money = math.floor(views / 1000 * DOLLARS_PER_1000_VIEWS)
  clip.views = (clip.views or 0) + views
  clip.earned = (clip.earned or 0) + money
  state.views = state.views + views
  state.earned = state.earned + money
  state.subscribers = state.subscribers + math.floor(views * SUBSCRIBERS_PER_VIEW)
  if money > 0 then core().pay(money, "DashTube: ad revenue", {"gameplay", "reward", "beamlife", "dashtube"}) end
  return money
end

function M.publish(id)
  for _, clip in ipairs(state.clips) do
    if clip.id == id then
      if clip.published then return {ok = false, message = "This video is already live."} end
      local random = core().rng(core().hash("clip:" .. clip.id .. ":" .. clip.seconds))
      clip.totalViews = math.floor((clip.score ^ 1.6) * 900 * (0.6 + random()) * channelBoost())
      clip.published = true
      clip.publishedDay = core().now().day
      clip.stage = 1
      local money = payViews(clip, VIEW_SCHEDULE[1])
      core().addXp(8, "videos")
      core().changed(APP)
      core().requestSave("published")
      return {ok = true, message = string.format("Video is live! First hours: %d views, $%d.", clip.views or 0, money)}
    end
  end
  return {ok = false, message = "Video not found."}
end

function M.delete(id)
  for index, clip in ipairs(state.clips) do
    if clip.id == id then
      table.remove(state.clips, index)
      core().changed(APP)
      return {ok = true, message = "Video deleted."}
    end
  end
  return {ok = false, message = "Video not found."}
end

local function payDailyViews()
  local total = 0
  for _, clip in ipairs(state.clips) do
    if clip.published and (clip.stage or 1) < #VIEW_SCHEDULE then
      clip.stage = (clip.stage or 1) + 1
      total = total + payViews(clip, VIEW_SCHEDULE[clip.stage])
    end
  end
  if total > 0 then
    core().notify("beamlife.dashcam", "DashTube", string.format("Your videos made $%d today.", total))
    core().changed(APP)
  end
end

-- UI state ----------------------------------------------------------------------------------------

function M.getState()
  local clips = {}
  for _, clip in ipairs(state.clips) do
    local date = core().dateInfo(clip.day)
    clips[#clips + 1] = {
      id = clip.id, date = date.label, time = core().formatClock(clip.minute or 0), outcome = clip.outcome,
      seconds = clip.seconds, topSpeed = clip.topSpeed, level = clip.level, units = clip.units, hits = clip.hits,
      km = clip.km, vehicle = clip.vehicle, score = clip.score, published = clip.published == true,
      views = clip.views or 0, totalViews = clip.totalViews, earned = clip.earned or 0,
      stillEarning = clip.published == true and (clip.stage or 1) < #VIEW_SCHEDULE,
      -- What the clip would make today, before luck: shown as a range in the app.
      estimate = not clip.published and math.floor((clip.score ^ 1.6) * 900 * channelBoost() / 1000 * DOLLARS_PER_1000_VIEWS) or nil,
    }
  end
  return {
    clips = clips, recording = recording ~= nil, recordingSeconds = recording and math.floor(recording.seconds) or nil,
    channel = {subscribers = math.floor(state.subscribers), views = math.floor(state.views), earned = math.floor(state.earned),
      boost = math.floor((channelBoost() - 1) * 100 + 0.5)},
    maxClips = MAX_CLIPS, minSeconds = MIN_CLIP_SECONDS,
  }
end

-- Called by the Overhaul's own pursuit rewards, which this module replaces with publishable clips.
function M.replacesInstantFootageSale()
  return true
end

-- Hooks -------------------------------------------------------------------------------------------

M.onCareerActivated = guard("dashcam.onCareerActivated", function()
  local data = beamlife_core.loadFile("dashcam") or {}
  state = {
    clips = type(data.clips) == "table" and data.clips or {}, subscribers = tonumber(data.subscribers) or 0,
    views = tonumber(data.views) or 0, earned = tonumber(data.earned) or 0, nextId = tonumber(data.nextId) or 1,
  }
  recording = nil
  applyPursuitVars()
end)

M.onOverhaulSaveCurrentProfile = guard("dashcam.save", function(savePath, _, writer)
  beamlife_core.saveFile(savePath, "dashcam", state, writer)
end)

M.onTrafficStarted = guard("dashcam.trafficStarted", applyPursuitVars)
M.onOverhaulActive = guard("dashcam.active", function(active)
  if active then applyPursuitVars() else removeReinforcements() end
end)

-- The offence table is passed by reference and its score is added after this hook returns.
M.onPursuitOffense = guard("dashcam.offense", function(vehicleId, key, data)
  if vehicleId ~= core().playerVehicleId() or type(data) ~= "table" then return end
  if OFFENSE_SCORES[key] then data.score = OFFENSE_SCORES[key] end
end)

M.onPursuitAction = guard("dashcam.pursuit", function(vehicleId, action)
  if vehicleId ~= core().playerVehicleId() and not (recording and recording.vehicleId == vehicleId) then return end
  if overhaul_career_police_playerDriving and core().try(overhaul_career_police_playerDriving.getPlayerIsCop) == true then return end
  if action == "start" then
    if not recording then startRecording(vehicleId) end
  elseif action == "evade" then
    stopRecording("evaded")
  elseif action == "arrest" then
    stopRecording("arrested")
  elseif action == "reset" then
    stopRecording(nil)
  end
end)

M.onBeamlifeNewDay = guard("dashcam.newDay", payDailyViews)

M.onUpdate = guard("dashcam.update", function(dtReal, dtSim)
  if recording then sample(dtSim or 0) end
  if cleanupAt and not recording and os.clock() > cleanupAt then removeReinforcements() end
end)

M.onClientEndMission = function()
  recording = nil
  reinforcementIds = {}
  cleanupAt = nil
end

M.onExtensionUnloaded = function()
  pcall(removeReinforcements)
end

return M
