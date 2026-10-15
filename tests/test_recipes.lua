local Mock = require("wow_mock")

local BAG, BOLT, CLOTH, THREAD, NET = 41599, 41510, 33470, 38426, 41509

local function load(chardb)
  Mock.reset()
  local ns = Mock.load({ "Util.lua", "Profit.lua", "Prices.lua", "Recipes.lua" })
  ns.Recipes.SetDB(chardb or {})
  return ns, ns.Recipes
end

local function bagRow(extra)
  local row = {
    name = "Frostweave Bag", id = BAG,
    reagents = {
      { id = BOLT, name = "Bolt of Frostweave", count = 6 },
      { id = THREAD, name = "Eternium Thread", count = 1 },
    },
  }
  for k, v in pairs(extra or {}) do row[k] = v end
  return row
end

local function boltRow()
  return { name = "Bolt of Frostweave", id = BOLT, reagents = { { id = CLOTH, name = "Frostweave Cloth", count = 5 } } }
end

return {
  reads_recipes_skips_headers = function(T)
    local _, R = load()
    Mock.trade.rows = { { type = "header", name = "Bags" }, bagRow() }
    T.eq(R.ReadTradeSkill(), 1)
    local bag = R.Get(BAG)
    T.ok(bag, "bag learned")
    T.eq(bag.name, "Frostweave Bag")
    T.eq(bag.made, 1)
    T.eq(bag.profession, "Tailoring")
    T.eq(#bag.reagents, 2)
    T.eq(bag.reagents[1].id, BOLT)
    T.eq(bag.reagents[1].name, "Bolt of Frostweave")
    T.eq(bag.reagents[1].count, 6)
  end,

  uses_item_name_from_link = function(T)
    local _, R = load()
    Mock.trade.rows = { bagRow({ recipeName = "Pattern: Big Bag" }) }
    R.ReadTradeSkill()
    T.eq(R.Get(BAG).name, "Frostweave Bag")
  end,

  made_is_average = function(T)
    local _, R = load()
    Mock.trade.rows = { bagRow({ min = 1, max = 3 }) }
    R.ReadTradeSkill()
    T.eq(R.Get(BAG).made, 2)
  end,

  skips_uncached_reagent_link = function(T)
    local _, R = load()
    local row = bagRow()
    row.reagents[2].uncached = true
    Mock.trade.rows = { row }
    T.eq(R.ReadTradeSkill(), 0)
    T.eq(R.Get(BAG), nil)
    row.reagents[2].uncached = nil
    T.eq(R.ReadTradeSkill(), 1)
    T.ok(R.Get(BAG))
  end,

  merge_keeps_old_recipes = function(T)
    local _, R = load()
    Mock.trade.rows = { bagRow() }
    R.ReadTradeSkill()
    Mock.trade.rows = { boltRow() }
    R.ReadTradeSkill()
    T.ok(R.Get(BAG), "bag kept")
    T.ok(R.Get(BOLT), "bolt added")
  end,

  linked_tradeskill_ignored = function(T)
    local _, R = load()
    Mock.trade.linked = 1
    Mock.trade.rows = { bagRow() }
    T.eq(R.ReadTradeSkill(), 0)
    T.eq(R.Get(BAG), nil)
  end,

  enchant_link_skipped = function(T)
    local _, R = load()
    Mock.trade.rows = { { name = "Enchant Ring", link = "|cffffd000|Henchant:7418|h[Enchant Ring]|h|r", reagents = {} } }
    T.eq(R.ReadTradeSkill(), 0)
  end,

  fires_recipes_changed_only_on_change = function(T)
    local ns, R = load()
    local fired = 0
    ns.On("RECIPES_CHANGED", function() fired = fired + 1 end)
    Mock.trade.rows = { bagRow() }
    R.ReadTradeSkill()
    R.ReadTradeSkill()
    T.eq(fired, 1)
  end,

  tracking_roundtrip_fires_event = function(T)
    local chardb = {}
    local ns, R = load(chardb)
    local got
    ns.On("TRACKING_CHANGED", function(id, on) got = { id, on } end)
    R.SetTracked(BAG, true)
    T.eq(R.IsTracked(BAG), true)
    T.eq(chardb.tracked[BAG], true)
    T.eq(got[1], BAG); T.eq(got[2], true)
    R.SetTracked(NET, true)
    local ids = R.TrackedIDs()
    T.eq(#ids, 2); T.eq(ids[1], NET); T.eq(ids[2], BAG)
    R.SetTracked(BAG, false)
    T.eq(R.IsTracked(BAG), false)
    T.eq(chardb.tracked[BAG], nil)
  end,

  selected_product_id = function(T)
    local _, R = load()
    Mock.trade.rows = { { type = "header", name = "Bags" }, bagRow() }
    Mock.trade.selected = 2
    T.eq(R.SelectedProductID(), BAG)
    Mock.trade.selected = 1
    T.eq(R.SelectedProductID(), nil)
    Mock.trade.selected = 0
    T.eq(R.SelectedProductID(), nil)
  end,

  scan_list_recurses_and_dedupes = function(T)
    local _, R = load()
    Mock.trade.rows = {
      bagRow(), boltRow(),
      { name = "Frostweave Net", id = NET, reagents = { { id = THREAD, name = "Eternium Thread", count = 2 } } },
    }
    R.ReadTradeSkill()
    R.SetTracked(BAG, true)
    R.SetTracked(NET, true)
    local list = R.ScanList()
    local seen = {}
    for _, item in ipairs(list) do
      T.ok(not seen[item.id], "duplicate " .. item.id)
      seen[item.id] = item.name
    end
    T.eq(#list, 5)
    T.eq(seen[BAG], "Frostweave Bag")
    T.eq(seen[BOLT], "Bolt of Frostweave")
    T.eq(seen[CLOTH], "Frostweave Cloth")
    T.eq(seen[THREAD], "Eternium Thread")
    T.eq(seen[NET], "Frostweave Net")
  end,
}
