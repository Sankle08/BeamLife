-- BeamLife WorkDay: regular jobs with a timetable. Drive to the workplace, clock in, the shift
-- passes in a fade and the pay lands the same day or on the weekly payday.
-- Reading order: job catalog, state, schedule maths, hiring, clocking in, day change, UI state, hooks.
local M = {}
M.dependencies = {"beamlife_core"}

-- Config ------------------------------------------------------------------------------------------

local APP = "jobs"
local MAX_JOBS = 2
local EARLY_MINUTES = 60      -- how early the clock-in opens
local LATE_MINUTES = 120      -- how late the player may still start the shift
local WORK_RADIUS = 45
local WEEKLY_BONUS = 0.12     -- weekly pay earns a little more than daily pay
local PAYDAY_WEEKDAY = 6      -- weekly pay arrives when Saturday starts
local SHIFTS_PER_RAISE = 5
local RAISE_STEP = 0.08
local MAX_RAISES = 10
local MISSES_TO_FIRE = 3
local MISS_MEMORY_DAYS = 10
local FADE_SECONDS = 0.6

-- wage is per hour of shift; level is the professional level needed to be hired.
local TEMPLATES = {
  {id = "gas_attendant", title = "Gas Station Attendant", kinds = {"gas"}, start = 7, hours = 8, days = {1, 2, 3, 4, 5}, wage = 38, level = 0,
    desc = "Work the pumps and the till."},
  {id = "stock_clerk", title = "Stock Clerk", kinds = {"shop"}, start = 9, hours = 6, days = {1, 2, 3, 4, 5, 6}, wage = 36, level = 0,
    desc = "Stock shelves and receive deliveries."},
  {id = "kitchen", title = "Kitchen Hand", kinds = {"food"}, start = 17, hours = 6, days = {3, 4, 5, 6, 7}, wage = 42, level = 0,
    desc = "Evening shift in the kitchen, Wednesday to Sunday."},
  {id = "warehouse", title = "Warehouse Checker", kinds = {"warehouse"}, start = 6, hours = 8, days = {1, 2, 3, 4, 5}, wage = 46, level = 1,
    desc = "Check paperwork and sort loads in the warehouse."},
  {id = "night_guard", title = "Night Guard", kinds = {"warehouse", "office", "shop"}, start = 22, hours = 8, days = {2, 3, 4, 5, 6}, wage = 58, level = 1,
    desc = "Night rounds. The shift runs past midnight."},
  {id = "mechanic_helper", title = "Mechanic's Helper", kinds = {"mechanic"}, start = 8, hours = 8, days = {1, 2, 3, 4, 5}, wage = 52, level = 2,
    desc = "Oil changes, tyres and a hand for the mechanics."},
  {id = "office", title = "Office Assistant", kinds = {"office", "hospital"}, start = 9, hours = 8, days = {1, 2, 3, 4, 5}, wage = 62, level = 3,
    desc = "The classic nine to five."},
  {id = "yard", title = "Yard Operator", kinds = {"warehouse"}, start = 14, hours = 8, days = {1, 2, 3, 4, 5, 6}, wage = 66, level = 4,
    desc = "Move and line up trailers in the yard."},
  {id = "dealer", title = "Car Salesperson", kinds = {"dealer"}, start = 10, hours = 7, days = {2, 3, 4, 5, 6}, wage = 74, level = 5,
    desc = "Sales on the dealership floor."},
}

-- State -------------------------------------------------------------------------------------------

local state = {jobs = {}, history = {}}
local templatesById = {}
for _, template in ipairs(TEMPLATES) do templatesById[template.id] = template end
local pendingShift

-- A failing hook must never stop the career from activating or saving.
local function guard(name, fn)
  return function(...)
    local ok, result = xpcall(fn, debug.traceback, ...)
    if not ok then log("E", "beamlife", name .. ": " .. tostring(result)) return nil end
    return result
  end
end

-- Schedule maths ----------------------------------------------------------------------------------

local function core() return beamlife_core end

local function worksOn(template, weekday)
  for _, day in ipairs(template.days) do
    if day == weekday then return true end
  end
  return false
end

local function scheduleText(template)
  local first, last = template.days[1], template.days[#template.days]
  local contiguous = (last - first + 1) == #template.days
  local days
  if contiguous and #template.days > 1 then
    days = core().weekdayName(first, true) .. " to " .. core().weekdayName(last, true)
  else
    local names = {}
    for _, day in ipairs(template.days) do names[#names + 1] = core().weekdayName(day, true) end
    days = table.concat(names, ", ")
  end
  return string.format("%s · %s to %s", days, core().formatHour(template.start), core().formatHour((template.start + template.hours) % 24))
end

local function placeOf(template)
  local level = getCurrentLevelIdentifier() or "level"
  return core().pickPlace(template.kinds, core().hash(level .. ":" .. template.id))
end

local function raisesOf(job)
  return math.min(MAX_RAISES, math.floor((job.shifts or 0) / SHIFTS_PER_RAISE))
end

local function wageOf(template, job)
  local wage = template.wage * (1 + RAISE_STEP * (job and raisesOf(job) or 0))
  if job and job.payMode == "weekly" then wage = wage * (1 + WEEKLY_BONUS) end
  return wage
end

-- Two timetables clash when they share a weekday and their hours overlap (night shifts wrap).
local function clashes(a, b)
  local function intervals(template)
    local out = {}
    for _, day in ipairs(template.days) do
      local from = (day - 1) * 24 + template.start
      out[#out + 1] = {from, from + template.hours}
    end
    return out
  end
  for _, first in ipairs(intervals(a)) do
    for _, second in ipairs(intervals(b)) do
      for _, shift in ipairs({0, 168, -168}) do
        if first[1] < second[2] + shift and second[1] + shift < first[2] then return true end
      end
    end
  end
  return false
end

-- Where today's shift stands for one job.
local function shiftStatus(template, job, now)
  local date = core().dateInfo(now.day)
  local startMinute = template.start * 60
  local status = {workday = worksOn(template, date.weekday), startMinute = startMinute}
  if not status.workday then
    status.code, status.text = "off", "Day off"
  elseif job.lastWorkedDay == now.day then
    status.code, status.text = "done", "Today's shift done"
  elseif now.minute < startMinute - EARLY_MINUTES then
    local wait = startMinute - now.minute
    status.code = "upcoming"
    status.text = string.format("Shift at %s (in %dh%02d)", core().formatClock(startMinute), math.floor(wait / 60), wait % 60)
  elseif now.minute <= startMinute + LATE_MINUTES then
    status.code = "open"
    status.late = math.max(0, now.minute - startMinute)
    status.text = status.late > 0 and string.format("%d min late - you can still clock in", status.late) or "Clock-in open - go to the workplace"
  else
    status.code, status.text = "lost", "You missed today's shift"
  end
  return status
end

-- Hiring ------------------------------------------------------------------------------------------

local function reply(ok, message)
  core().changed(APP)
  return {ok = ok, message = message}
end

local function payOut(job, template, reason)
  local amount = math.floor(job.accrued or 0)
  if amount <= 0 then return 0 end
  job.accrued = 0
  core().pay(amount, string.format("%s: %s", reason, template.title), {"gameplay", "reward", "beamlife", "salary"})
  return amount
end

function M.apply(id, payMode)
  local template = templatesById[id]
  if not template then return reply(false, "Job not found.") end
  if state.jobs[id] then return reply(false, "You already work here.") end
  if tableSize(state.jobs) >= MAX_JOBS then return reply(false, "You already have " .. MAX_JOBS .. " jobs. Quit one of them first.") end
  if core().level() < template.level then return reply(false, "Needs work level " .. template.level .. ".") end
  if not placeOf(template) then return reply(false, "This job does not exist on this map.") end
  for otherId in pairs(state.jobs) do
    if clashes(template, templatesById[otherId]) then
      return reply(false, "The hours clash with your other job (" .. templatesById[otherId].title .. ").")
    end
  end
  state.jobs[id] = {
    hiredDay = core().now().day, payMode = payMode == "weekly" and "weekly" or "daily",
    shifts = state.history[id] or 0, accrued = 0, missedDays = {},
  }
  core().requestSave("hired")
  return reply(true, "Hired as " .. template.title .. ". " .. scheduleText(template))
end

function M.quit(id)
  local job, template = state.jobs[id], templatesById[id]
  if not job or not template then return reply(false, "You do not work here.") end
  local paid = payOut(job, template, "Final pay")
  state.jobs[id] = nil
  core().requestSave("quit")
  return reply(true, paid > 0 and string.format("You quit. Final pay: $%d.", paid) or "You quit.")
end

function M.setPayMode(id, payMode)
  local job, template = state.jobs[id], templatesById[id]
  if not job or not template then return reply(false, "You do not work here.") end
  payMode = payMode == "weekly" and "weekly" or "daily"
  if job.payMode == payMode then return reply(true, nil) end
  -- Switching to daily settles what the week already holds.
  if payMode == "daily" then payOut(job, template, "Wages") end
  job.payMode = payMode
  return reply(true, payMode == "weekly" and "Weekly pay: +12% per shift, paid on Saturday." or "Daily pay: paid at the end of each shift.")
end

function M.navigate(id)
  local template = templatesById[id]
  local place = template and placeOf(template)
  if not place then return reply(false, "Workplace not found on this map.") end
  core().setRoute(place.pos)
  return reply(true, "Route set to " .. place.name .. ".")
end

-- Clocking in -------------------------------------------------------------------------------------

local function finishShift()
  local shift = pendingShift
  if not shift or shift.done then return end
  shift.done = true
  local job, template = state.jobs[shift.id], templatesById[shift.id]
  if not job or not template then return end
  core().advanceMinutes(shift.minutes)
  job.shifts = (job.shifts or 0) + 1
  job.lastWorkedDay = shift.day
  state.history[shift.id] = job.shifts
  core().addXp(18 + shift.hours * 3, "shifts")
  local earned = math.floor(shift.pay)
  local text
  if job.payMode == "weekly" then
    job.accrued = (job.accrued or 0) + earned
    text = string.format("Shift done: +$%d on this week's payslip (total $%d).", earned, math.floor(job.accrued))
  else
    core().pay(earned, "Wages: " .. template.title, {"gameplay", "reward", "beamlife", "salary"})
    text = string.format("Shift done: $%d paid.", earned)
  end
  if job.shifts % SHIFTS_PER_RAISE == 0 and job.shifts <= SHIFTS_PER_RAISE * MAX_RAISES then
    text = text .. string.format(" Raise! Now $%d/h.", math.floor(wageOf(template, job)))
  end
  core().message(text, 8)
  core().requestSave("shift")
  core().changed(APP)
end

function M.clockIn(id)
  local job, template = state.jobs[id], templatesById[id]
  if not job or not template then return reply(false, "You do not work here.") end
  if pendingShift then return reply(false, "Shift in progress.") end
  if core().isBusy() then return reply(false, "Finish your current task before clocking in.") end
  local now = core().now()
  local status = shiftStatus(template, job, now)
  if status.code ~= "open" then return reply(false, status.text) end
  local place = placeOf(template)
  if not place then return reply(false, "Workplace not found on this map.") end
  if core().distanceTo(place.pos) > WORK_RADIUS then
    core().setRoute(place.pos)
    return reply(false, "You need to be at " .. place.name .. ". Route set.")
  end
  if core().playerSpeed() > 2 then return reply(false, "Stop the vehicle to clock in.") end

  local endMinute = status.startMinute + template.hours * 60
  local minutes = endMinute - now.minute
  local paidHours = math.min(template.hours, (endMinute - math.max(now.minute, status.startMinute)) / 60)
  pendingShift = {
    id = id, day = now.day, minutes = minutes, hours = paidHours, pay = paidHours * wageOf(template, job),
    deadline = os.clock() + 4,
  }
  if overhaul_phone_phone and overhaul_phone_phone.closePhone then core().try(overhaul_phone_phone.closePhone) end
  if ui_fadeScreen and ui_fadeScreen.start then
    ui_fadeScreen.start(FADE_SECONDS)
  else
    finishShift()
    pendingShift = nil
  end
  return {ok = true, message = string.format("Have a good shift! %.1f h.", paidHours)}
end

-- Day change --------------------------------------------------------------------------------------

local function recordMisses(day, previous)
  local first = math.max(previous, day - 7)
  for id, job in pairs(state.jobs) do
    local template = templatesById[id]
    for missedDay = first, day - 1 do
      if template and missedDay > job.hiredDay and job.lastWorkedDay ~= missedDay
          and worksOn(template, core().dateInfo(missedDay).weekday) then
        job.missedDays[#job.missedDays + 1] = missedDay
      end
    end
    local recent = {}
    for _, missedDay in ipairs(job.missedDays) do
      if missedDay > day - MISS_MEMORY_DAYS then recent[#recent + 1] = missedDay end
    end
    job.missedDays = recent
  end
end

local function fireAbsentees()
  for id, job in pairs(state.jobs) do
    local template = templatesById[id]
    if template and #job.missedDays >= MISSES_TO_FIRE then
      payOut(job, template, "Final pay")
      state.jobs[id] = nil
      core().notify("beamlife.jobs", "Fired", "Too many missed shifts. You lost your job as " .. template.title .. ".")
    elseif template and job.missedDays[#job.missedDays] == core().now().day - 1 then
      core().notify("beamlife.jobs", "Missed shift",
        string.format("%s: you missed yesterday's shift (%d of %d).", template.title, #job.missedDays, MISSES_TO_FIRE))
    end
  end
end

local function weeklyPayday(day, previous)
  for check = previous + 1, day do
    if core().dateInfo(check).weekday == PAYDAY_WEEKDAY then
      for id, job in pairs(state.jobs) do
        local template = templatesById[id]
        if template and job.payMode == "weekly" then
          local paid = payOut(job, template, "Weekly wages")
          if paid > 0 then
            core().notify("beamlife.jobs", "Weekly pay", string.format("%s paid $%d.", template.title, paid))
          end
        end
      end
      return
    end
  end
end

-- UI state ----------------------------------------------------------------------------------------

local function weeklyEstimate(template, job)
  return math.floor(wageOf(template, job) * template.hours * #template.days)
end

function M.getState()
  local now = core().now()
  local jobs, offers = {}, {}
  for _, template in ipairs(TEMPLATES) do
    local place = placeOf(template)
    local job = state.jobs[template.id]
    local distance = place and core().distanceTo(place.pos) or nil
    local base = {
      id = template.id, title = template.title, desc = template.desc, schedule = scheduleText(template),
      company = place and place.name or "Not available on this map", hours = template.hours,
      night = template.start >= 20 or template.start + template.hours > 24,
      distance = distance and distance < core().FAR and math.floor(distance) or nil,
    }
    if job then
      local status = shiftStatus(template, job, now)
      base.wage = math.floor(wageOf(template, job))
      base.payMode = job.payMode
      base.shifts = job.shifts or 0
      base.raises = raisesOf(job)
      base.nextRaiseIn = raisesOf(job) < MAX_RAISES and (SHIFTS_PER_RAISE - (job.shifts or 0) % SHIFTS_PER_RAISE) or nil
      base.accrued = math.floor(job.accrued or 0)
      base.misses = #job.missedDays
      base.maxMisses = MISSES_TO_FIRE
      base.status = status.code
      base.statusText = status.text
      base.atWork = distance ~= nil and distance <= WORK_RADIUS
      base.canClockIn = status.code == "open" and base.atWork and not pendingShift
      base.weekly = weeklyEstimate(template, job)
      jobs[#jobs + 1] = base
    else
      base.wage = template.wage
      base.weekly = weeklyEstimate(template, nil)
      base.level = template.level
      base.locked = core().level() < template.level or place == nil
      base.lockReason = place == nil and "No workplace on this map" or (core().level() < template.level and ("Work level " .. template.level) or nil)
      base.pastShifts = state.history[template.id] or 0
      offers[#offers + 1] = base
    end
  end
  return {
    time = core().formatClock(now.minute), date = core().dateInfo(now.day).longLabel,
    profile = core().getProfile(), jobs = jobs, offers = offers, maxJobs = MAX_JOBS,
    weeklyBonus = math.floor(WEEKLY_BONUS * 100), busy = core().isBusy(),
  }
end

-- Shifts worked at a kind of job, ever. The Business app uses it for the former-employee discount.
function M.shiftsWorked(id)
  return state.history[id] or 0
end

-- Hooks -------------------------------------------------------------------------------------------

local function hudNote(now)
  local best
  for id, job in pairs(state.jobs) do
    local template = templatesById[id]
    if template then
      local status = shiftStatus(template, job, now)
      if status.code == "open" then return template.title .. ": clock-in open" end
      if status.code == "upcoming" and (not best or status.startMinute < best.startMinute) then
        best = {startMinute = status.startMinute, text = template.title .. " to " .. core().formatClock(status.startMinute)}
      end
    end
  end
  return best and best.text or nil
end

M.onCareerActivated = guard("jobs.onCareerActivated", function()
  local data = beamlife_core.loadFile("jobs") or {}
  state = {jobs = {}, history = type(data.history) == "table" and data.history or {}}
  for id, job in pairs(type(data.jobs) == "table" and data.jobs or {}) do
    if templatesById[id] and type(job) == "table" then
      state.jobs[id] = {
        hiredDay = tonumber(job.hiredDay) or 0, payMode = job.payMode == "weekly" and "weekly" or "daily",
        shifts = tonumber(job.shifts) or 0, accrued = tonumber(job.accrued) or 0,
        lastWorkedDay = tonumber(job.lastWorkedDay), missedDays = type(job.missedDays) == "table" and job.missedDays or {},
      }
    end
  end
  pendingShift = nil
  beamlife_core.setHudProvider("jobs", hudNote)
end)

M.onOverhaulSaveCurrentProfile = guard("jobs.save", function(savePath, _, writer)
  beamlife_core.saveFile(savePath, "jobs", state, writer)
end)

M.onBeamlifeNewDay = guard("jobs.newDay", function(day, previous)
  recordMisses(day, previous)
  fireAbsentees()
  weeklyPayday(day, previous)
  core().changed(APP)
end)

M.onBeamlifeTick = guard("jobs.tick", function()
  if not pendingShift then return end
  if not pendingShift.done and os.clock() > pendingShift.deadline then
    -- The fade never reported back; finish the shift anyway.
    finishShift()
    if ui_fadeScreen and ui_fadeScreen.stop then ui_fadeScreen.stop(FADE_SECONDS) end
    pendingShift = nil
  elseif pendingShift.done and os.clock() > pendingShift.deadline + 6 then
    pendingShift = nil
  end
end)

M.onScreenFadeState = guard("jobs.fade", function(fadeState)
  if not pendingShift then return end
  if fadeState == 1 and not pendingShift.done then
    finishShift()
    if ui_fadeScreen and ui_fadeScreen.stop then ui_fadeScreen.stop(FADE_SECONDS) end
  elseif fadeState == 3 then
    pendingShift = nil
  end
end)

return M
