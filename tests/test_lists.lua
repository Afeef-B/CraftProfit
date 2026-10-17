local Mock = require("wow_mock")

local REALM = "Icecrown-Alliance"
local CLOTH, CLOTH_NAME = 33470, "Frostweave Cloth"
local BOLT, BOLT_NAME = 41510, "Bolt of Frostweave"
local BAG, BAG_NAME = 41599, "Frostweave Bag"
local GLACIAL, GLACIAL_NAME = 41600, "Glacial Bag"
local THREAD, THREAD_NAME = 38426, "Eternium Thread"

local function setup()
  Mock.reset()
  local ns = Mock.load({
    "Util.lua", "Style.lua", "Profit.lua", "Prices.lua", "Recipes.lua", "Scanner.lua", "Listings.lua", "Lists.lua",
  })
  local db = { cut = 0.05 }
  ns.db = db
  ns.Prices.SetDB(db, REALM)
  ns.Recipes.SetDB({})
  ns.Lists.SetDB(db)
  return ns, ns.Lists, db
end

local function count(ns, event)
  local n = { n = 0 }
  ns.On(event, function() n.n = n.n + 1 end)
  return n
end

return {
  materials_ready_and_scratch = function(T)
    local ns = setup()
    local recipes = ns.Recipes.All()
    recipes[BAG] = { name = BAG_NAME, made = 1, reagents = {
      { id = BOLT, name = BOLT_NAME, count = 2 }, { id = THREAD, name = THREAD_NAME, count = 1 } } }
    recipes[BOLT] = { name = BOLT_NAME, made = 1, reagents = { { id = CLOTH, name = CLOTH_NAME, count = 5 } } }
    Mock.bags[0] = { [1] = { id = BOLT, name = BOLT_NAME, count = 2 } }

    ns.Recipes.SetDepth(BAG, "ready")
    local list = ns.Lists.Materials(BAG, 3)
    T.eq(#list, 2)
    T.eq(list[1].id, BOLT)
    T.eq(list[1].need, 6)
    T.eq(list[1].have, 2)
    T.eq(list[2].id, THREAD)
    T.eq(list[2].need, 3)

    ns.Recipes.SetDepth(BAG, "scratch")
    list = ns.Lists.Materials(BAG, 3)
    T.eq(#list, 2)
    T.eq(list[1].id, CLOTH)
    T.eq(list[1].need, 30)
    T.eq(list[2].id, THREAD)
    T.eq(list[2].need, 3)
  end,

  scratch_rounds_whole_crafts = function(T)
    local ns = setup()
    local recipes = ns.Recipes.All()
    -- a bag takes 3 bolts; one craft of bolts makes 2 bolts from 5 cloth
    recipes[BAG] = { name = BAG_NAME, made = 1, reagents = { { id = BOLT, name = BOLT_NAME, count = 3 } } }
    recipes[BOLT] = { name = BOLT_NAME, made = 2, reagents = { { id = CLOTH, name = CLOTH_NAME, count = 5 } } }
    ns.Recipes.SetDepth(BAG, "scratch")
    local list = ns.Lists.Materials(BAG, 1)
    T.eq(list[1].id, CLOTH)
    T.eq(list[1].need, 10, "3 bolts take 2 whole bolt crafts: 10 cloth")
  end,

  auto_lists_follow_tracked_recipes = function(T)
    local ns, L = setup()
    ns.Recipes.All()[GLACIAL] = { name = GLACIAL_NAME, made = 1, reagents = { { id = CLOTH, name = CLOTH_NAME, count = 5 } } }
    T.eq(#L.All(), 0)
    ns.Recipes.SetTracked(GLACIAL, true)
    local all = L.All()
    T.eq(#all, 1)
    T.eq(all[1].key, "auto:" .. GLACIAL)
    T.eq(all[1].name, "Glacial Bag materials")
    T.eq(all[1].auto, true)
    ns.Recipes.SetTracked(GLACIAL, false)
    T.eq(#L.All(), 0)
  end,

  auto_lines_need_materials_times_crafts = function(T)
    local ns, L = setup()
    ns.Recipes.All()[GLACIAL] = { name = GLACIAL_NAME, made = 1, reagents = { { id = CLOTH, name = CLOTH_NAME, count = 5 } } }
    ns.Recipes.SetTracked(GLACIAL, true)
    Mock.bags[0] = { [1] = { id = CLOTH, name = CLOTH_NAME, count = 4 } }
    local lines = L.Lines("auto:" .. GLACIAL, 3)
    T.eq(#lines, 1)
    T.eq(lines[1].id, CLOTH)
    T.eq(lines[1].name, CLOTH_NAME)
    T.eq(lines[1].need, 15)
    T.eq(lines[1].have, 4)
    T.eq(#L.Lines("auto:" .. GLACIAL), 1, "crafts default to 1")
    T.eq(L.Lines("auto:" .. GLACIAL)[1].need, 5)
  end,

  own_lists_persist = function(T)
    local ns, L, db = setup()
    local changed = count(ns, "LISTS_CHANGED")
    T.eq(L.Create("Cloth run"), true)
    T.eq(db.lists[1].name, "Cloth run")
    T.eq(changed.n, 1)
    local ok, err = L.Create("Cloth run")
    T.eq(ok, false); T.eq(err, "exists")
    ok, err = L.Create("  ")
    T.eq(ok, false); T.eq(err, "empty")
    T.eq(L.Add("Cloth run", CLOTH, CLOTH_NAME), true)
    T.eq(db.lists[1].items[1].id, CLOTH)
    ok, err = L.Add("Cloth run", CLOTH, CLOTH_NAME)
    T.eq(ok, false); T.eq(err, "already")
    ok, err = L.Add("Nope", CLOTH, CLOTH_NAME)
    T.eq(ok, false); T.eq(err, "no-list")
    local all = L.All()
    T.eq(all[#all].key, "own:Cloth run"); T.eq(all[#all].auto, false)
    L.Remove("Cloth run", CLOTH)
    T.eq(#db.lists[1].items, 0)
    L.Delete("Cloth run")
    T.eq(#db.lists, 0)
    T.eq(changed.n, 4, "create, add, remove, delete")
    -- names are trimmed and cut to 40 characters
    T.eq(L.Create("  " .. string.rep("x", 50) .. " "), true)
    T.eq(db.lists[1].name, string.rep("x", 40))
  end,

  own_list_keeps_names = function(T)
    local _, L = setup()
    L.Create("Cloth run")
    T.eq(L.Add("Cloth run", THREAD, THREAD_NAME), true)
    local line = L.Lines("own:Cloth run")[1]
    T.eq(line.id, THREAD)
    T.eq(line.name, THREAD_NAME, "not in the item cache: the name it was added with")
    T.eq(line.need, nil)
    T.eq(line.have, 0)
    -- without a name: the item cache
    Mock.items[CLOTH] = { name = CLOTH_NAME }
    L.Add("Cloth run", CLOTH)
    T.eq(L.Lines("own:Cloth run")[2].name, CLOTH_NAME)
  end,

  lines_show_cheapest_and_age = function(T)
    local ns, L = setup()
    L.Create("Cloth run")
    L.Add("Cloth run", CLOTH, CLOTH_NAME)
    L.Add("Cloth run", THREAD, THREAD_NAME)
    ns.Prices.SetAH(CLOTH, 900, 2, Mock.now - 120)
    local lines = L.Lines("own:Cloth run")
    T.eq(lines[1].unit, 900)
    T.eq(lines[1].age, 120)
    T.eq(lines[2].unit, nil)
    T.eq(lines[2].age, nil)
    T.eq(#L.Lines("own:Missing"), 0)
    T.eq(#L.Lines("auto:123"), 0)
  end,
}
