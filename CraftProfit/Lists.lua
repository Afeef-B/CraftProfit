-- Shopping lists for CP Buy: one automatic list per tracked recipe (its
-- materials for a number of crafts) plus the player's own lists of items.
-- The player's lists live in CraftProfitDB.lists; no widgets here.
local addonName, ns = ...

local ceil = math.ceil

ns.Lists = {}
local Lists = ns.Lists

local MAX_NAME = 40

local db

local function changed()
  ns.Fire("LISTS_CHANGED")
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- db.lists = { { name, items = { { id, name }, ... } }, ... } in creation order.
function Lists.SetDB(savedDB)
  db = savedDB
  db.lists = db.lists or {}
end

local function find(name)
  for i, list in ipairs(db.lists) do
    if list.name == name then return list, i end
  end
end

-- What `crafts` crafts of recipeId take, as { id, name, need, have }. A
-- from-scratch recipe lists the materials of the materials it can craft.
function Lists.Materials(recipeId, crafts)
  local list, index = {}, {}
  local scratch = ns.Recipes.Depth(recipeId) == "scratch"

  local function add(id, name, qty)
    local entry = index[id]
    if not entry then
      entry = { id = id, name = name, need = 0 }
      index[id] = entry
      list[#list + 1] = entry
    end
    entry.need = entry.need + qty
  end

  -- qty crafts of recipe `id`
  local function expand(id, qty, visiting)
    local recipe = ns.Recipes.Get(id)
    visiting[id] = true
    for _, reagent in ipairs(recipe.reagents) do
      local amount = reagent.count * qty
      local sub = scratch and ns.Recipes.Get(reagent.id)
      if sub and not visiting[reagent.id] then
        -- whole crafts: 3 bolts from a recipe that makes 2 take 2 crafts
        expand(reagent.id, ceil(amount / (sub.made or 1) - 1e-9), visiting)
      else
        add(reagent.id, reagent.name, amount)
      end
    end
    visiting[id] = nil
  end

  if not ns.Recipes.Get(recipeId) then return list end
  expand(recipeId, crafts or 1, {})
  for _, entry in ipairs(list) do
    entry.need = ceil(entry.need - 1e-9)
    entry.have = GetItemCount(entry.id)
  end
  return list
end

-- { { key, name, auto } }: the automatic lists ("auto:<recipe id>") first,
-- then the player's ("own:<name>").
function Lists.All()
  local all = {}
  for _, id in ipairs(ns.Recipes.TrackedIDs()) do
    local recipe = ns.Recipes.Get(id)
    if recipe then
      all[#all + 1] = { key = "auto:" .. id, name = recipe.name .. " materials", auto = true }
    end
  end
  for _, list in ipairs(db.lists) do
    all[#all + 1] = { key = "own:" .. list.name, name = list.name, auto = false }
  end
  return all
end

-- true and the name as stored (trimmed, at most 40 characters), or false and
-- "empty" | "exists".
function Lists.Create(name)
  name = trim(name):sub(1, MAX_NAME)
  if name == "" then return false, "empty" end
  if find(name) then return false, "exists" end
  db.lists[#db.lists + 1] = { name = name, items = {} }
  changed()
  return true, name
end

function Lists.Delete(name)
  local _, i = find(name)
  if not i then return end
  table.remove(db.lists, i)
  changed()
end

-- ok, or false and "no-list" | "already". The name is kept with the item: the
-- client may not have it cached the next time the list is shown.
function Lists.Add(name, id, itemName)
  local list = find(name)
  if not list then return false, "no-list" end
  for _, item in ipairs(list.items) do
    if item.id == id then return false, "already" end
  end
  list.items[#list.items + 1] = { id = id, name = itemName or GetItemInfo(id) or ("item " .. id) }
  changed()
  return true
end

function Lists.Remove(name, id)
  local list = find(name)
  if not list then return end
  for i, item in ipairs(list.items) do
    if item.id == id then
      table.remove(list.items, i)
      changed()
      return
    end
  end
end

-- One line per item of the list `key`: { id, name, have, need, unit, age }.
-- need only for an automatic list (its materials x crafts); unit and age from
-- the price database (nil when never scanned).
function Lists.Lines(key, crafts)
  local lines = {}
  local recipeId = tonumber((key or ""):match("^auto:(%d+)$"))
  local ownName = (key or ""):match("^own:(.+)$")
  if recipeId then
    if ns.Recipes.Get(recipeId) and ns.Recipes.IsTracked(recipeId) then
      for _, m in ipairs(Lists.Materials(recipeId, crafts or 1)) do
        lines[#lines + 1] = { id = m.id, name = m.name, need = m.need, have = m.have }
      end
    end
  elseif ownName then
    local list = find(ownName)
    for _, item in ipairs(list and list.items or {}) do
      lines[#lines + 1] = { id = item.id, name = item.name, have = GetItemCount(item.id) }
    end
  end
  local now = ns.Now()
  for _, line in ipairs(lines) do
    local unit, t = ns.Prices.GetAH(line.id)
    line.unit = unit
    line.age = t and (now - t) or nil
  end
  return lines
end
