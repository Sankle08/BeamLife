-- BeamLife performance options: the phone's Performance screen reads and changes them here.
-- The values live in the Overhaul's player settings (gameplay/overhaul/settings/beamlife*.json), so
-- they are kept across careers and also show up in the Overhaul Manager. The Overhaul files that
-- spawn traffic, parked cars, meet cars and the phone map read them directly; this module only
-- pushes a change through to the systems that do not look again on their own.
local M = {}
M.dependencies = {"beamlife_core"}

local APP = "performance"
local AUTOSAVE_KEY = "autosaveIntervalMinutes"

-- What each choice means, in the order the screen shows it.
local OPTIONS = {
  {key = "beamlifeTrafficDensity", title = "Traffic", hint = "Moving AI cars. The biggest effect on FPS.",
    choices = {{value = "game", label = "Game"}, {value = "medium", label = "Medium"}, {value = "low", label = "Low"}}},
  {key = "beamlifeParkedCars", title = "Parked cars", hint = "Cars parked along the streets.",
    choices = {{value = "game", label = "Game"}, {value = "few", label = "Few"}, {value = "none", label = "None"}}},
  {key = "beamlifeMeetCrowd", title = "Car meet crowd", hint = "Applies from the next meet you join.",
    choices = {{value = "full", label = "Full"}, {value = "small", label = "Small"}}},
  {key = "beamlifePoliceBackup", title = "Police backup", hint = "Extra units in a long pursuit.",
    choices = {{value = 3, label = "3"}, {value = 2, label = "2"}, {value = 1, label = "1"}, {value = 0, label = "None"}}},
  {key = "beamlifeCalmWeather", title = "Calm weather", hint = "No rain days and no morning fog.",
    choices = {{value = false, label = "Off"}, {value = true, label = "On"}}},
  {key = "beamlifeMapSaver", title = "Phone map saver", hint = "Slower updates, no terrain picture.",
    choices = {{value = false, label = "Off"}, {value = true, label = "On"}}},
  {key = "beamlifeAppSaver", title = "App refresh saver", hint = "Apps refresh every 8 s instead of 3 s.",
    choices = {{value = false, label = "Off"}, {value = true, label = "On"}}},
  {key = AUTOSAVE_KEY, title = "Autosave every", hint = "Fewer autosaves, fewer short hitches.",
    choices = {{value = 5, label = "5 min"}, {value = 10, label = "10 min"}, {value = 15, label = "15 min"}, {value = 30, label = "30 min"}}},
}

local PRESETS = {
  quality = {beamlifeTrafficDensity = "game", beamlifeParkedCars = "game", beamlifeMeetCrowd = "full", beamlifePoliceBackup = 3,
    beamlifeCalmWeather = false, beamlifeMapSaver = false, beamlifeAppSaver = false, [AUTOSAVE_KEY] = 5},
  balanced = {beamlifeTrafficDensity = "medium", beamlifeParkedCars = "few", beamlifeMeetCrowd = "full", beamlifePoliceBackup = 2,
    beamlifeCalmWeather = false, beamlifeMapSaver = false, beamlifeAppSaver = false, [AUTOSAVE_KEY] = 10},
  performance = {beamlifeTrafficDensity = "low", beamlifeParkedCars = "few", beamlifeMeetCrowd = "small", beamlifePoliceBackup = 1,
    beamlifeCalmWeather = true, beamlifeMapSaver = true, beamlifeAppSaver = true, [AUTOSAVE_KEY] = 15},
}

local function settingsOwner()
  return rawget(_G, "overhaul_shell_settings")
end

local function value(key)
  local owner = settingsOwner()
  return owner and owner.getSetting(key)
end

local function weatherOwner()
  return rawget(_G, "overhaul_world_weather")
end

-- Pushes the current values to the systems that only read them when they start.
function M.apply()
  local driving = rawget(_G, "overhaul_career_police_playerDriving")
  if driving and driving.onSettingsChanged then pcall(driving.onSettingsChanged) end
  local weather = weatherOwner()
  if weather and weather.setSetting then
    local calm = value("beamlifeCalmWeather") == true
    pcall(weather.setSetting, "allowRainyDays", not calm)
    pcall(weather.setSetting, "morningFog", not calm)
  end
  beamlife_core.changed(APP)
  return true
end

local function presetMatching()
  for name, values in pairs(PRESETS) do
    local same = true
    for key, wanted in pairs(values) do
      if value(key) ~= wanted then
        same = false
        break
      end
    end
    if same then return name end
  end
  return nil
end

function M.getState()
  local options = {}
  for _, option in ipairs(OPTIONS) do
    local current = value(option.key)
    if current ~= nil then
      options[#options + 1] = {key = option.key, title = option.title, hint = option.hint, choices = option.choices, value = current}
    end
  end
  return {options = options, preset = presetMatching(), available = settingsOwner() ~= nil}
end

function M.set(key, newValue)
  local owner = settingsOwner()
  if not owner then return {ok = false, message = "Settings are not available right now."} end
  local known = false
  for _, option in ipairs(OPTIONS) do
    if option.key == key then known = true end
  end
  if not known then return {ok = false, message = "Unknown option."} end
  local ok = owner.setSetting(key, newValue)
  -- setSetting runs the option's own onChange; the rest is read live, so only the screen needs telling.
  beamlife_core.changed(APP)
  return {ok = ok == true, message = ok and nil or "That value was not accepted."}
end

function M.preset(name)
  local owner = settingsOwner()
  local values = PRESETS[name]
  if not owner or not values then return {ok = false, message = "Unknown preset."} end
  local ok = owner.setSettings(values)
  M.apply()
  local labels = {quality = "Quality", balanced = "Balanced", performance = "Performance"}
  return {ok = ok == true, message = ok and (labels[name] .. " preset applied.") or "The preset could not be saved."}
end

-- Pursuit backup and the meet crowd are read by other BeamLife and Overhaul code through these.
function M.policeBackupLimit()
  return tonumber(value("beamlifePoliceBackup")) or 3
end

M.onCareerActivated = function()
  local ok, problem = pcall(M.apply)
  if not ok then log("E", "beamlife", "perf.apply: " .. tostring(problem)) end
end

return M
