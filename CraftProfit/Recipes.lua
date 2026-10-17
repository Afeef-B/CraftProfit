-- Learns recipes from the open profession window and keeps the tracked list.
local addonName, ns = ...

local Util = ns.Util

ns.Recipes = {}
local Recipes = ns.Recipes

local store

function Recipes.SetDB(chardb)
  chardb.recipes = chardb.recipes or {}
  chardb.tracked = chardb.tracked or {}
  chardb.depth = chardb.depth or {}
  store = chardb
end

-- Returns productID, recipe for profession row i, or nil when the row is a
-- header, not an item (enchants), or a reagent isn't in the item cache yet.
local function readRow(i)
  local recipeName, kind = GetTradeSkillInfo(i)
  if not recipeName or kind == "header" then return nil end

  local link = GetTradeSkillItemLink(i)
  local id = Util.ItemIDFromLink(link)
  if not id then return nil end

  local reagents = {}
  for j = 1, GetTradeSkillNumReagents(i) do
    local name, _, count = GetTradeSkillReagentInfo(i, j)
    local reagentID = Util.ItemIDFromLink(GetTradeSkillReagentItemLink(i, j))
    if not reagentID or not name then return nil end
    reagents[#reagents + 1] = { id = reagentID, name = name, count = count }
  end

  local minMade, maxMade = GetTradeSkillNumMade(i)
  minMade = minMade or 1
  return id, {
    name = Util.ItemNameFromLink(link) or recipeName,
    made = (minMade + (maxMade or minMade)) / 2,
    reagents = reagents,
    profession = (GetTradeSkillLine()),
  }
end

local function sameRecipe(a, b)
  if not a or a.name ~= b.name or a.made ~= b.made or #a.reagents ~= #b.reagents then
    return false
  end
  for i, r in ipairs(b.reagents) do
    local o = a.reagents[i]
    if o.id ~= r.id or o.count ~= r.count then return false end
  end
  return true
end

-- Reads row i into the store. Returns productID (or nil), changed.
local function readAndStore(i)
  local id, recipe = readRow(i)
  if not id then return nil, false end
  if sameRecipe(store.recipes[id], recipe) then return id, false end
  store.recipes[id] = recipe
  return id, true
end

-- Merges every readable recipe into the store; never removes any, so
-- recipes hidden by collapsed headers or filters are kept. Reading every
-- row at once is slow on the 3.3.5 client, so event handlers must not call
-- this: they read the selected row and leave the rest to the background scan.
function Recipes.ReadTradeSkill()
  if IsTradeSkillLinked() then return 0 end
  local learned, changed = 0, false
  for i = 1, GetNumTradeSkills() do
    local id, rowChanged = readAndStore(i)
    if id then learned = learned + 1 end
    if rowChanged then changed = true end
  end
  if changed then ns.Fire("RECIPES_CHANGED") end
  return learned
end

-- The recipe selected in the profession window: one row, cheap.
-- silent: don't fire RECIPES_CHANGED (used by /cp diag to separate steps).
function Recipes.ReadSelected(silent)
  if IsTradeSkillLinked() then return nil end
  local index = GetTradeSkillSelectionIndex()
  if not index or index < 1 then return nil end
  local id, changed = readAndStore(index)
  if changed and not silent then ns.Fire("RECIPES_CHANGED") end
  return id
end

-- The profession window. While it opens, Blizzard (and skins like ElvUI)
-- rebuild it over many TRADE_SKILL_UPDATEs; touching it during that burst
-- hung the 3.3.5 client for one user, while the same work done seconds later
-- was fine. So nothing happens until the window has been quiet for SETTLE
-- seconds; then PROFESSION_READY fires.
local SETTLE = 1.5
local window = { state = "closed" } -- closed | opening | ready

function Recipes.WindowOpened()
  window.state, window.quiet, window.updates = "opening", 0, 0
end

function Recipes.WindowClosed()
  window.state = "closed"
  Recipes.StopBackgroundScan()
end

function Recipes.NoteUpdate()
  window.updates = (window.updates or 0) + 1
  if window.state == "opening" then window.quiet = 0 end
end

function Recipes.IsReady()
  return window.state == "ready"
end

-- For /cp status: state, seconds without updates, updates since opening.
function Recipes.WindowStatus()
  return window.state, window.quiet or 0, window.updates or 0
end

-- Background scan: one row per frame. Runs once per profession per session,
-- again only when the number of rows changes (e.g. a newly learned recipe).
local ROWS_PER_TICK = 1
local scan = { state = "idle" }  -- idle | scanning
local scannedRows = {}           -- profession -> row count of the last full scan

function Recipes.StartBackgroundScan()
  if IsTradeSkillLinked() then return end
  local profession, rows = (GetTradeSkillLine()), GetNumTradeSkills()
  if scannedRows[profession] == rows then return end
  scan.state, scan.nextRow, scan.changed = "scanning", 1, false
  scan.profession, scan.rows = profession, rows
  Util.Diag("background scan started: " .. rows .. " rows")
end

function Recipes.StopBackgroundScan()
  scan.state = "idle"
end

local function scanTick()
  local total = GetNumTradeSkills()
  local last = math.min(total, scan.nextRow + ROWS_PER_TICK - 1)
  for i = scan.nextRow, last do
    local _, changed = readAndStore(i)
    if changed then scan.changed = true end
  end
  scan.nextRow = last + 1
  if last % 100 == 0 then Util.Diag("background scan row " .. last .. "/" .. total) end
  if scan.nextRow > total then
    scannedRows[scan.profession] = scan.rows
    scan.state = "idle"
    Util.Diag("background scan finished")
    if scan.changed then ns.Fire("RECIPES_CHANGED") end
  end
end

function Recipes.Tick(elapsed)
  if window.state == "opening" then
    window.quiet = window.quiet + elapsed
    if window.quiet >= SETTLE then
      window.state = "ready"
      ns.Fire("PROFESSION_READY")
    end
  elseif scan.state == "scanning" then
    scanTick()
  end
end

function Recipes.Get(id)
  return store.recipes[id]
end

function Recipes.All()
  return store.recipes
end

-- id and its own spelling for a recipe product or reagent name (any case),
-- or nil.
function Recipes.IdByName(name)
  local wanted = tostring(name or ""):lower()
  for id, recipe in pairs(store.recipes) do
    if recipe.name:lower() == wanted then return id, recipe.name end
    for _, reagent in ipairs(recipe.reagents) do
      if reagent.name:lower() == wanted then return reagent.id, reagent.name end
    end
  end
  return nil
end

function Recipes.SelectedProductID()
  local index = GetTradeSkillSelectionIndex()
  if not index or index < 1 then return nil end
  return Util.ItemIDFromLink(GetTradeSkillItemLink(index))
end

function Recipes.IsTracked(id)
  return store.tracked[id] == true
end

function Recipes.SetTracked(id, on)
  store.tracked[id] = on and true or nil
  ns.Fire("TRACKING_CHANGED", id, on and true or false)
end

function Recipes.TrackedIDs()
  local ids = {}
  for id in pairs(store.tracked) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

-- How a tracked craft is costed: "ready" (default) buys the direct materials
-- as they are; "scratch" also considers crafting every material we can make.
function Recipes.Depth(id)
  return store.depth[id] == "scratch" and "scratch" or "ready"
end

function Recipes.SetDepth(id, depth)
  store.depth[id] = depth == "scratch" and "scratch" or nil
  ns.Fire("TRACKING_CHANGED", id, true)
end

-- Everything a scan needs to price the tracked crafts: the products and
-- their materials, plus, for crafts costed "from scratch", the materials of
-- any material we can craft ourselves.
function Recipes.ScanList()
  local list, listed, expanded = {}, {}, {}
  local function add(id, name)
    if listed[id] then return end
    listed[id] = true
    name = name or GetItemInfo(id)
    if name then list[#list + 1] = { id = id, name = name } end
  end
  -- Everything id is made from, all the way down.
  local function addTree(id)
    if expanded[id] then return end
    expanded[id] = true
    local recipe = store.recipes[id]
    if not recipe then return end
    for _, reagent in ipairs(recipe.reagents) do
      add(reagent.id, reagent.name)
      addTree(reagent.id)
    end
  end
  for _, id in ipairs(Recipes.TrackedIDs()) do
    local recipe = store.recipes[id]
    add(id, recipe and recipe.name)
    if Recipes.Depth(id) == "scratch" then
      addTree(id)
    elseif recipe then
      for _, reagent in ipairs(recipe.reagents) do add(reagent.id, reagent.name) end
    end
  end
  return list
end
