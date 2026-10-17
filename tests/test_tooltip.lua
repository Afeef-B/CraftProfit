local Mock = require("wow_mock")

local REALM = "Icecrown-Alliance"
local CLOTH, CLOTH_NAME = 33470, "Frostweave Cloth"
local BAG, BAG_NAME = 41599, "Frostweave Bag"
local THREAD, THREAD_NAME = 38426, "Eternium Thread"

local function setup()
  Mock.reset()
  Mock.installUI()
  local ns = Mock.load({
    "Util.lua", "Style.lua", "Profit.lua", "Prices.lua", "Recipes.lua", "Scanner.lua", "Listings.lua",
    "Lists.lua", "Tooltip.lua",
  })
  local db = { cut = 0.05 }
  ns.db = db
  ns.Prices.SetDB(db, REALM)
  ns.Recipes.SetDB({})
  ns.Tooltip.Install()
  Mock.items[CLOTH] = { name = CLOTH_NAME, maxStack = 20 }
  Mock.items[BAG] = { name = BAG_NAME }
  Mock.items[THREAD] = { name = THREAD_NAME }
  return ns
end

local function lines(prefix)
  local found = {}
  for _, line in ipairs(Mock.tooltip) do
    if line:sub(1, #prefix) == prefix then found[#found + 1] = line end
  end
  return found
end

return {
  price_and_age_line = function(T)
    local ns = setup()
    ns.Prices.SetAH(CLOTH, 900, 3, Mock.now - 7200)
    Mock.setTooltipItem(GameTooltip, CLOTH)
    local found = lines("CraftProfit AH:")
    T.eq(#found, 1)
    T.eq(found[1], "CraftProfit AH: " .. ns.Style.Money(900) .. " (2h ago)")
    Mock.clearTooltip(GameTooltip)
    ns.Prices.SetAH(CLOTH, 900, 3, Mock.now - 10)
    Mock.setTooltipItem(GameTooltip, CLOTH)
    T.eq(lines("CraftProfit AH:")[1], "CraftProfit AH: " .. ns.Style.Money(900) .. " (just now)")
  end,

  not_seen_yet = function(T)
    setup()
    Mock.setTooltipItem(GameTooltip, THREAD)
    T.eq(lines("CraftProfit AH:")[1], "CraftProfit AH: not seen yet")
    T.eq(#lines("Craft cost"), 0, "not a recipe")
  end,

  none_listed = function(T)
    local ns = setup()
    ns.Prices.SetAH(THREAD, nil, 0, Mock.now - 60)
    Mock.setTooltipItem(GameTooltip, THREAD)
    T.eq(lines("CraftProfit AH:")[1], "CraftProfit AH: none listed (1m ago)")
  end,

  craft_cost_for_a_recipe = function(T)
    local ns = setup()
    ns.Recipes.All()[BAG] = { name = BAG_NAME, made = 1, reagents = {
      { id = CLOTH, name = CLOTH_NAME, count = 5 }, { id = THREAD, name = THREAD_NAME, count = 1 } } }
    ns.Prices.SetAH(CLOTH, 900, 3, Mock.now)
    ns.Prices.SetAH(THREAD, 300, 3, Mock.now)
    Mock.setTooltipItem(GameTooltip, BAG)
    T.eq(lines("Craft cost:")[1], "Craft cost: " .. ns.Style.Money(4800) .. " (ready-made)")
    Mock.clearTooltip(GameTooltip)
    ns.Recipes.SetDepth(BAG, "scratch")
    Mock.setTooltipItem(GameTooltip, BAG)
    T.eq(lines("Craft cost:")[1], "Craft cost: " .. ns.Style.Money(4800) .. " (from scratch)")
    Mock.clearTooltip(GameTooltip)
    ns.Prices.SetAH(THREAD, nil, 0, Mock.now)
    Mock.setTooltipItem(GameTooltip, BAG)
    T.eq(lines("Craft cost:")[1], "Craft cost: missing prices")
  end,

  stack_total_for_a_bag_stack = function(T)
    local ns = setup()
    ns.Prices.SetAH(CLOTH, 900, 3, Mock.now)
    Mock.bags[0] = { [1] = { id = CLOTH, name = CLOTH_NAME, count = 20 }, [2] = { id = CLOTH, name = CLOTH_NAME, count = 1 } }
    GameTooltip:SetBagItem(0, 1)
    T.eq(#lines("CraftProfit AH:"), 1)
    T.eq(lines("x20:")[1], "x20: " .. ns.Style.Money(18000))
    Mock.clearTooltip(GameTooltip)
    GameTooltip:SetBagItem(0, 2)
    T.eq(#lines("x"), 0, "a single item has no stack line")
    T.eq(#lines("CraftProfit AH:"), 1)
  end,

  no_duplicates_on_double_set = function(T)
    local ns = setup()
    ns.Prices.SetAH(CLOTH, 900, 3, Mock.now)
    Mock.setTooltipItem(GameTooltip, CLOTH)
    Mock.setTooltipItem(GameTooltip, CLOTH)
    T.eq(#lines("CraftProfit AH:"), 1)
    Mock.clearTooltip(GameTooltip)
    Mock.setTooltipItem(GameTooltip, CLOTH)
    T.eq(#lines("CraftProfit AH:"), 1)
  end,

  item_ref_tooltip_too = function(T)
    local ns = setup()
    ns.Prices.SetAH(CLOTH, 900, 3, Mock.now)
    Mock.setTooltipItem(ItemRefTooltip, CLOTH)
    T.eq(#lines("CraftProfit AH:"), 1)
  end,
}
