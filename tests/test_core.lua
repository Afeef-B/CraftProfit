local Mock = require("wow_mock")

local BAG, BOLT, CLOTH, THREAD, DUST = 41599, 41510, 33470, 38426, 34054

local ALL = { "Util.lua", "Profit.lua", "Prices.lua", "Recipes.lua", "Scanner.lua", "UI.lua", "Core.lua" }

local function load(savedDB)
  Mock.reset()
  Mock.installUI()
  CraftProfitDB = savedDB
  local ns = Mock.load(ALL)
  ns.Core.OnEvent("PLAYER_LOGIN")
  Mock.trade.rows = {
    { name = "Frostweave Bag", id = BAG, reagents = {
      { id = BOLT, name = "Bolt of Frostweave", count = 2 },
      { id = THREAD, name = "Eternium Thread", count = 1 } } },
  }
  return ns, ns.Core
end

local function chatHas(text)
  for _, msg in ipairs(Mock.chat) do
    if msg:find(text, 1, true) then return true end
  end
  return false
end

return {
  login_initialises_defaults = function(T)
    local ns = load(nil)
    T.eq(CraftProfitDB.version, 1)
    T.eq(CraftProfitDB.cut, 0.05)
    T.ok(CraftProfitDB.prices["Icecrown-Alliance"])
    T.ok(CraftProfitCharDB.recipes and CraftProfitCharDB.tracked)
    T.eq(SLASH_CRAFTPROFIT1, "/cp")
    T.eq(SlashCmdList.CRAFTPROFIT, ns.Core.Slash)
    T.eq(Mock.hooks.QueryAuctionItems, ns.Scanner.OnQuery)
  end,

  login_keeps_saved_values = function(T)
    load({ cut = 0.15, scanAllWarned = true })
    T.eq(CraftProfitDB.cut, 0.15)
    T.eq(CraftProfitDB.scanAllWarned, true)
  end,

  trade_skill_event_learns_and_adds_checkbox = function(T)
    local ns, Core = load()
    Core.OnEvent("TRADE_SKILL_SHOW")
    T.ok(ns.Recipes.Get(BAG))
    T.ok(CraftProfitTrackCheck)
  end,

  merchant_event_records_vendor_prices = function(T)
    local ns, Core = load()
    Mock.merchant = { { id = THREAD, name = "Eternium Thread", price = 1000, quantity = 5 } }
    Core.OnEvent("MERCHANT_SHOW")
    T.eq(CraftProfitDB.vendor[THREAD], 200)
  end,

  auction_house_show_shows_panel = function(T)
    local _, Core = load()
    Core.OnEvent("AUCTION_HOUSE_SHOW")
    T.eq(CraftProfitPanel:IsShown(), true)
    CraftProfitPanel:Hide()
    Core.OnEvent("AUCTION_HOUSE_SHOW")
    T.eq(CraftProfitPanel:IsShown(), true)
  end,

  auction_events_reach_scanner = function(T)
    local ns, Core = load()
    ns.Scanner.StartTargeted({ { id = CLOTH, name = "Frostweave Cloth" } })
    Core.OnEvent("AUCTION_HOUSE_CLOSED")
    T.eq(ns.Scanner.IsBusy(), false)
  end,

  parse_price_command = function(T)
    local ns, Core = load()
    Core.OnEvent("TRADE_SKILL_SHOW")
    Core.Slash("price " .. Mock.Link(BOLT, "Bolt of Frostweave") .. " 1g50s")
    T.eq(CraftProfitDB.manual[BOLT], 15000)
    Core.Slash("price eternium thread 1.5")
    T.eq(CraftProfitDB.manual[THREAD], 15000)
    Core.Slash("price Eternium Thread clear")
    T.eq(CraftProfitDB.manual[THREAD], nil)
    Mock.items[DUST] = { name = "Infinite Dust" }
    Core.Slash("price Infinite Dust 2")
    T.eq(CraftProfitDB.manual[DUST], 20000)
    local id = Core.ParseItemArg("Unknown Thing 5")
    T.eq(id, nil)
    Core.Slash("price Eternium Thread lots")
    T.ok(chatHas("Usage: /cp price"))
  end,

  slash_cut_sets_fraction = function(T)
    local _, Core = load()
    Core.Slash("cut 15")
    T.eq(CraftProfitDB.cut, 0.15)
    Core.Slash("cut abc")
    T.eq(CraftProfitDB.cut, 0.15)
    Core.Slash("cut 150")
    T.eq(CraftProfitDB.cut, 0.15)
  end,

  slash_track_toggles_selected = function(T)
    local ns, Core = load()
    Core.Slash("track")
    T.ok(chatHas("select a recipe"))
    Mock.trade.selected = 1
    Core.Slash("track")
    T.eq(ns.Recipes.IsTracked(BAG), true)
    T.ok(chatHas("Now tracking Frostweave Bag"))
    Core.Slash("track")
    T.eq(ns.Recipes.IsTracked(BAG), false)
  end,

  slash_list_prints_results = function(T)
    local ns, Core = load()
    Core.OnEvent("TRADE_SKILL_SHOW")
    ns.Recipes.SetTracked(BAG, true)
    ns.Prices.SetAH(BOLT, 3000, 1, Mock.now)
    ns.Prices.SetAH(THREAD, 500, 1, Mock.now)
    ns.Prices.SetAH(BAG, 10000, 1, Mock.now)
    Core.Slash("list")
    T.ok(chatHas("Frostweave Bag: profit 30s (46%), cost 65s, sell 1g"))
  end,

  slash_scan_needs_auction_house = function(T)
    local ns, Core = load()
    AuctionFrame:Hide()
    Core.Slash("scan")
    T.ok(chatHas("Open the Auction House first."))
    T.eq(ns.Scanner.IsBusy(), false)
  end,

  slash_reset_prices = function(T)
    local ns, Core = load()
    ns.Prices.SetAH(CLOTH, 100, 1, Mock.now)
    Core.Slash("reset prices")
    T.eq((ns.Prices.GetAH(CLOTH)), nil)
  end,

  on_update_ticks_scanner = function(T)
    local ns, Core = load()
    ns.Scanner.StartTargeted({ { id = CLOTH, name = "Frostweave Cloth" } })
    Core.OnUpdate(nil, 0.1)
    T.eq(#Mock.queries, 1)
  end,
}
