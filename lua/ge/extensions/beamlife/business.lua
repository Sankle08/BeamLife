-- BeamLife Business: shops and companies the player buys for passive income.
-- Every business earns once per in-game day. Each one has its own income pattern (steady, weekend
-- rush, weekly rent, volatile sales, a cut of the player's own freight routes...), can be upgraded
-- twice, and either fills its cash box for the player to collect or pays a manager to bank it.
-- Reading order: catalog, state, income model, daily closing, buying and managing, UI state, hooks.
local M = {}
M.dependencies = {"beamlife_core"}

-- Config ------------------------------------------------------------------------------------------

local APP = "business"
local LEVEL_INCOME = {1, 1.5, 2.1}
local LEVEL_UPKEEP = {1, 1.3, 1.7}
local UPGRADE_COST = {0.5, 1.0}          -- share of the base price, for level 2 and level 3
local MANAGER_CUT = 0.15
local CASH_BOX_DAYS = 5                  -- an unmanaged cash box stops filling after this many days
local SELL_FACTOR = 0.7
local EX_EMPLOYEE_SHIFTS = 10
local EX_EMPLOYEE_DISCOUNT = 0.15
local MAX_CATCH_UP_DAYS = 7
local LOG_DAYS = 7

local MODEL_LABELS = {
  steady = "Steady income every day",
  weekend = "Busy from Friday to Sunday",
  weather = "Swings a lot from day to day",
  traffic = "Earns more on weekdays",
  skill = "Earns more as your work level grows",
  rent = "Rent: paid all at once on Monday",
  freight = "Steady, plus 8% of every freight route you drive",
  volatile = "High risk: great days and losing days",
  fleet = "Steady, plus 12% of every Interstate route you drive",
}

-- gross and upkeep are dollars per in-game day at level 1; job links a WorkDay job for the discount.
local CATALOG = {
  {id = "carwash", name = "Car Wash", price = 60000, gross = 2100, upkeep = 420, model = "weather", level = 1,
    desc = "Entry-level business. Cheap to run, but it lives on good days."},
  {id = "snack", name = "Snack Bar", price = 85000, gross = 3100, upkeep = 700, model = "weekend", level = 2, job = "kitchen",
    desc = "Packed on weekends."},
  {id = "parking", name = "Parking Lot", price = 110000, gross = 3300, upkeep = 350, model = "steady", level = 2,
    desc = "Low upkeep and predictable income."},
  {id = "market", name = "Corner Market", price = 140000, gross = 4900, upkeep = 1100, model = "steady", level = 3, job = "stock_clerk",
    desc = "Constant neighbourhood trade."},
  {id = "workshop", name = "Repair Shop", price = 260000, gross = 8600, upkeep = 2100, model = "skill", level = 4, job = "mechanic_helper",
    desc = "The more experienced the owner, the more customers show up."},
  {id = "gas", name = "Gas Station", price = 320000, gross = 10800, upkeep = 3000, model = "traffic", level = 5, job = "gas_attendant",
    desc = "Lives on weekday traffic."},
  {id = "kitnets", name = "Apartment Block", price = 380000, gross = 9800, upkeep = 1200, model = "rent", level = 5,
    desc = "Rental property. Pays weekly and sometimes has an empty unit."},
  {id = "depot", name = "Logistics Warehouse", price = 480000, gross = 11000, upkeep = 3200, model = "freight", level = 6, job = "warehouse",
    desc = "Storage, with a cut of your own freight routes."},
  {id = "dealer", name = "Used Car Lot", price = 750000, gross = 24000, upkeep = 8000, model = "volatile", level = 7, job = "dealer",
    desc = "High margins, good months and bad months."},
  {id = "carrier", name = "Trucking Company", price = 1200000, gross = 34000, upkeep = 11000, model = "fleet", level = 8, routes = 20,
    desc = "The top of the chain. Needs 20 finished routes with Interstate Freight."},
}

-- State -------------------------------------------------------------------------------------------

local state = {owned = {}, totalEarned = 0}
local catalogById = {}
for _, entry in ipairs(CATALOG) do catalogById[entry.id] = entry end

local function core() return beamlife_core end

local function guard(name, fn)
  return function(...)
    local ok, result = xpcall(fn, debug.traceback, ...)
    if not ok then log("E", "beamlife", name .. ": " .. tostring(result)) return nil end
    return result
  end
end

-- Income model ------------------------------------------------------------------------------------

-- The share of the usual gross a business makes on one day. The same day always gives the same result.
local function dayFactor(entry, day)
  local random = core().rng(core().hash(entry.id .. ":" .. day))
  local weekday = core().dateInfo(day).weekday
  local noise = 0.92 + random() * 0.16
  local model = entry.model
  if model == "weekend" then return (weekday >= 5 and 1.35 or 0.85) * noise end
  if model == "weather" then return 0.45 + random() * 1.1 end
  if model == "traffic" then return (weekday <= 5 and 1.1 or 0.8) * noise end
  if model == "skill" then return math.min(1.6, 0.8 + 0.06 * core().level()) * noise end
  if model == "rent" then return 0.7 + random() * 0.3 end
  if model == "volatile" then return 0.3 + random() * 1.7 end
  return noise
end

local function investedIn(entry, owned)
  local total = owned.paid or entry.price
  for level = 2, owned.level or 1 do total = total + entry.price * UPGRADE_COST[level - 1] end
  return total
end

local function cashCap(entry, owned)
  return entry.gross * LEVEL_INCOME[owned.level or 1] * CASH_BOX_DAYS
end

-- Typical profit per day, shown to the player before buying and on the dashboard.
local function expectedNet(entry, level, manager)
  local gross = entry.gross * LEVEL_INCOME[level]
  if entry.model == "weekend" then gross = gross * (0.85 * 4 + 1.35 * 3) / 7 end
  if entry.model == "traffic" then gross = gross * (1.1 * 5 + 0.8 * 2) / 7 end
  if entry.model == "rent" then gross = gross * 0.85 end
  if entry.model == "skill" then gross = gross * math.min(1.6, 0.8 + 0.06 * core().level()) end
  if manager then gross = gross * (1 - MANAGER_CUT) end
  return math.floor(gross - entry.upkeep * LEVEL_UPKEEP[level])
end

-- Puts money into the business: straight to the wallet with a manager, otherwise into the cash box.
local function deposit(entry, owned, amount, label)
  if amount == 0 then return end
  owned.earned = (owned.earned or 0) + amount
  state.totalEarned = state.totalEarned + amount
  if owned.manager then
    if amount > 0 then
      core().pay(amount, entry.name .. ": " .. label, {"gameplay", "reward", "beamlife", "business"})
    else
      core().fine(-amount, entry.name .. ": daily loss")
    end
    return
  end
  owned.balance = math.min(cashCap(entry, owned), (owned.balance or 0) + amount)
end

-- Daily closing -----------------------------------------------------------------------------------

local function closeDay(entry, owned, day)
  local level = owned.level or 1
  local gross = entry.gross * LEVEL_INCOME[level] * dayFactor(entry, day)
  local upkeep = entry.upkeep * LEVEL_UPKEEP[level]
  if owned.manager then gross = gross * (1 - MANAGER_CUT) end
  local net
  if entry.model == "rent" then
    -- Rent builds up during the week and is released on Monday; upkeep is paid every day.
    owned.rentPool = (owned.rentPool or 0) + gross
    net = -upkeep
    if core().dateInfo(day).weekday == 1 then
      net = net + owned.rentPool
      owned.rentPool = 0
    end
  else
    net = gross - upkeep
  end
  net = math.floor(net)
  owned.log = owned.log or {}
  owned.log[#owned.log + 1] = net
  while #owned.log > LOG_DAYS do table.remove(owned.log, 1) end
  owned.lastNet = net
  deposit(entry, owned, net, "daily profit")
end

-- Buying and managing -----------------------------------------------------------------------------

local function reply(ok, message)
  core().changed(APP)
  return {ok = ok, message = message}
end

local function discountFor(entry)
  if entry.job and beamlife_jobs and beamlife_jobs.shiftsWorked(entry.job) >= EX_EMPLOYEE_SHIFTS then
    return EX_EMPLOYEE_DISCOUNT
  end
  return 0
end

local function priceFor(entry)
  return math.floor(entry.price * (1 - discountFor(entry)))
end

local function lockReason(entry)
  if core().level() < entry.level then return "Needs work level " .. entry.level end
  if entry.routes and (not beamlife_freight or beamlife_freight.routesDone("heavy") < entry.routes) then
    return string.format("Needs %d routes with Interstate Freight", entry.routes)
  end
  return nil
end

function M.buy(id)
  local entry = catalogById[id]
  if not entry then return reply(false, "Business not found.") end
  if state.owned[id] then return reply(false, "You already own this business.") end
  local locked = lockReason(entry)
  if locked then return reply(false, locked .. ".") end
  local price = priceFor(entry)
  if not core().charge(price, "Purchase: " .. entry.name, {"buying", "beamlife", "business"}) then
    return reply(false, string.format("You are $%d short.", price - math.floor(core().money())))
  end
  state.owned[id] = {level = 1, boughtDay = core().now().day, balance = 0, manager = false, paid = price, earned = 0, log = {}}
  core().addXp(60, "businesses")
  core().requestSave("businessBought")
  return reply(true, entry.name .. " is yours. It closes its first day tomorrow.")
end

function M.sell(id)
  local entry, owned = catalogById[id], state.owned[id]
  if not entry or not owned then return reply(false, "You do not own this business.") end
  local value = math.floor(investedIn(entry, owned) * SELL_FACTOR + math.max(0, owned.balance or 0))
  state.owned[id] = nil
  core().pay(value, "Sale: " .. entry.name, {"selling", "beamlife", "business"})
  core().requestSave("businessSold")
  return reply(true, string.format("%s sold for $%d.", entry.name, value))
end

function M.upgrade(id)
  local entry, owned = catalogById[id], state.owned[id]
  if not entry or not owned then return reply(false, "You do not own this business.") end
  local level = owned.level or 1
  if level >= #LEVEL_INCOME then return reply(false, "This business is already at the top level.") end
  local cost = math.floor(entry.price * UPGRADE_COST[level])
  if not core().charge(cost, "Upgrade: " .. entry.name, {"buying", "beamlife", "business"}) then
    return reply(false, string.format("You are $%d short for the upgrade.", cost - math.floor(core().money())))
  end
  owned.level = level + 1
  core().requestSave("businessUpgraded")
  return reply(true, string.format("%s upgraded to level %d.", entry.name, owned.level))
end

function M.collect(id)
  local total = 0
  for ownedId, owned in pairs(state.owned) do
    local entry = catalogById[ownedId]
    if entry and (id == nil or id == ownedId) and (owned.balance or 0) > 0 then
      local amount = math.floor(owned.balance)
      owned.balance = owned.balance - amount
      core().pay(amount, entry.name .. ": cash collected", {"gameplay", "reward", "beamlife", "business"})
      total = total + amount
    end
  end
  if total <= 0 then return reply(false, "Nothing to collect.") end
  core().requestSave("businessCollected")
  return reply(true, string.format("$%d collected.", total))
end

function M.setManager(id, enabled)
  local entry, owned = catalogById[id], state.owned[id]
  if not entry or not owned then return reply(false, "You do not own this business.") end
  owned.manager = enabled == true
  if owned.manager and (owned.balance or 0) > 0 then M.collect(id) end
  return reply(true, owned.manager
    and "Manager hired: keeps 15% of the revenue and banks the profit every day."
    or "Manager let go: the profit stays in the cash box until you collect it.")
end

-- UI state ----------------------------------------------------------------------------------------

function M.getState()
  local owned, market = {}, {}
  local dailyTotal, boxTotal = 0, 0
  for _, entry in ipairs(CATALOG) do
    local mine = state.owned[entry.id]
    if mine then
      local level = mine.level or 1
      local expected = expectedNet(entry, level, mine.manager)
      dailyTotal = dailyTotal + expected
      boxTotal = boxTotal + math.max(0, mine.balance or 0)
      owned[#owned + 1] = {
        id = entry.id, name = entry.name, model = MODEL_LABELS[entry.model], level = level, maxLevel = #LEVEL_INCOME,
        balance = math.floor(mine.balance or 0), cap = math.floor(cashCap(entry, mine)),
        full = (mine.balance or 0) >= cashCap(entry, mine) - 1,
        manager = mine.manager == true, lastNet = mine.lastNet, expected = expected, log = mine.log or {},
        earned = math.floor(mine.earned or 0), rentPool = entry.model == "rent" and math.floor(mine.rentPool or 0) or nil,
        upgradeCost = level < #LEVEL_INCOME and math.floor(entry.price * UPGRADE_COST[level]) or nil,
        upgradeNet = level < #LEVEL_INCOME and expectedNet(entry, level + 1, mine.manager) or nil,
        sellValue = math.floor(investedIn(entry, mine) * SELL_FACTOR + math.max(0, mine.balance or 0)),
      }
    else
      local discount = discountFor(entry)
      local locked = lockReason(entry)
      local price = priceFor(entry)
      local net = expectedNet(entry, 1, false)
      market[#market + 1] = {
        id = entry.id, name = entry.name, desc = entry.desc, model = MODEL_LABELS[entry.model],
        price = price, fullPrice = entry.price, discount = math.floor(discount * 100 + 0.5),
        expected = net, payback = net > 0 and math.ceil(price / net) or nil,
        locked = locked ~= nil, reason = locked, affordable = core().money() >= price,
      }
    end
  end
  return {
    money = math.floor(core().money()), owned = owned, market = market,
    dailyTotal = dailyTotal, boxTotal = math.floor(boxTotal), totalEarned = math.floor(state.totalEarned),
    managerCut = math.floor(MANAGER_CUT * 100), cashBoxDays = CASH_BOX_DAYS,
    exShifts = EX_EMPLOYEE_SHIFTS, level = core().level(),
  }
end

-- Hooks -------------------------------------------------------------------------------------------

M.onCareerActivated = guard("business.onCareerActivated", function()
  local data = beamlife_core.loadFile("business") or {}
  state = {owned = {}, totalEarned = tonumber(data.totalEarned) or 0}
  for id, owned in pairs(type(data.owned) == "table" and data.owned or {}) do
    if catalogById[id] and type(owned) == "table" then
      owned.level = core().clamp(math.floor(tonumber(owned.level) or 1), 1, #LEVEL_INCOME)
      owned.balance = tonumber(owned.balance) or 0
      owned.log = type(owned.log) == "table" and owned.log or {}
      state.owned[id] = owned
    end
  end
end)

M.onOverhaulSaveCurrentProfile = guard("business.save", function(savePath, _, writer)
  beamlife_core.saveFile(savePath, "business", state, writer)
end)

M.onBeamlifeNewDay = guard("business.newDay", function(day, previous)
  if not next(state.owned) then return end
  local fullBoxes = {}
  for closing = math.max(previous + 1, day - MAX_CATCH_UP_DAYS + 1), day do
    for id, owned in pairs(state.owned) do
      local entry = catalogById[id]
      if entry and closing > (owned.boughtDay or 0) then
        closeDay(entry, owned, closing)
        if not owned.manager and (owned.balance or 0) >= cashCap(entry, owned) - 1 then fullBoxes[entry.name] = true end
      end
    end
  end
  for name in pairs(fullBoxes) do
    core().notify("beamlife.business", "Cash box full", name .. " stopped earning. Collect the cash in the Business app.")
  end
  core().changed(APP)
end)

-- Freight-linked businesses take a cut of the routes the player drives himself.
M.onBeamlifeRouteCompleted = guard("business.route", function(carrierId, pay)
  local depot, carrier = state.owned.depot, state.owned.carrier
  if depot then
    deposit(catalogById.depot, depot, math.floor(pay * 0.08 * LEVEL_INCOME[depot.level or 1]), "freight cut")
  end
  if carrier and carrierId == "heavy" then
    deposit(catalogById.carrier, carrier, math.floor(pay * 0.12 * LEVEL_INCOME[carrier.level or 1]), "freight cut")
  end
end)

return M
