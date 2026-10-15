-- Learns recipes from the open profession window and keeps the tracked list.
local addonName, ns = ...

local Util = ns.Util

ns.Recipes = {}
local Recipes = ns.Recipes

local store

function Recipes.SetDB(chardb)
  chardb.recipes = chardb.recipes or {}
  chardb.tracked = chardb.tracked or {}
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

-- Merges every readable recipe into the store; never removes any, so
-- recipes hidden by collapsed headers or filters are kept.
function Recipes.ReadTradeSkill()
  if IsTradeSkillLinked() then return 0 end
  local learned, changed = 0, false
  for i = 1, GetNumTradeSkills() do
    local id, recipe = readRow(i)
    if id then
      learned = learned + 1
      if not sameRecipe(store.recipes[id], recipe) then
        store.recipes[id] = recipe
        changed = true
      end
    end
  end
  if changed then ns.Fire("RECIPES_CHANGED") end
  return learned
end

function Recipes.Get(id)
  return store.recipes[id]
end

function Recipes.All()
  return store.recipes
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

-- Everything a scan needs to price the tracked crafts: the products, their
-- materials, and the materials of any material we can craft ourselves.
function Recipes.ScanList()
  local list, seen = {}, {}
  local function add(id, name)
    if seen[id] then return end
    seen[id] = true
    name = name or GetItemInfo(id)
    if name then list[#list + 1] = { id = id, name = name } end
    local recipe = store.recipes[id]
    if recipe then
      for _, reagent in ipairs(recipe.reagents) do add(reagent.id, reagent.name) end
    end
  end
  for _, id in ipairs(Recipes.TrackedIDs()) do
    local recipe = store.recipes[id]
    add(id, recipe and recipe.name)
  end
  return list
end
