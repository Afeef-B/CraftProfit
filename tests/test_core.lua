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

-- Open the profession window and let the background scan finish.
local function openProfession(Core)
  Core.OnEvent("TRADE_SKILL_SHOW")
  Core.OnUpdate(nil, 1.1)
  for _ = 1, #Mock.trade.rows + 2 do Core.OnUpdate(nil, 0.016) end
end

local function chatHas(text)
  for _, msg in ipairs(Mock.chat) do
    local plain = msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    if plain:find(text, 1, true) then return true end
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
    openProfession(Core)
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
    openProfession(Core)
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
    openProfession(Core)
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

  panel_built_when_auction_ui_loads = function(T)
    Mock.reset()
    Mock.installUI()
    local auctionFrame = AuctionFrame
    AuctionFrame = nil                      -- Blizzard_AuctionUI not loaded yet
    local ns = Mock.load(ALL)
    ns.Core.OnEvent("PLAYER_LOGIN")
    ns.Core.OnEvent("AUCTION_HOUSE_SHOW")   -- reaches us before the AH frame exists
    T.eq(CraftProfitPanel, nil)
    AuctionFrame = auctionFrame
    ns.Core.OnEvent("ADDON_LOADED", "Blizzard_AuctionUI")
    T.ok(CraftProfitPanel, "panel built once the AH UI loads")
  end,

  panel_built_at_login_if_auction_ui_already_loaded = function(T)
    load()
    T.ok(CraftProfitPanel, "AH UI was loaded before us (e.g. by Auctionator)")
  end,

  opening_tailoring_reads_only_the_selected_recipe = function(T)
    local ns, Core = load()
    local rows = {}
    for i = 1, 450 do
      rows[i] = { name = "Recipe " .. i, id = 50000 + i, reagents = {
        { id = 60000 + i, name = "Mat A" .. i, count = 1 },
        { id = 70000 + i, name = "Mat B" .. i, count = 2 } } }
    end
    Mock.trade.rows = rows
    Mock.trade.selected = 1
    Mock.reagentLinkCalls = 0
    Core.OnEvent("TRADE_SKILL_SHOW")
    for _ = 1, 5 do
      Core.OnEvent("TRADE_SKILL_UPDATE")
      TradeSkillFrame_SetSelection(1)       -- Blizzard re-selects on each update
    end
    T.ok(Mock.reagentLinkCalls <= 20, "event handlers read " .. Mock.reagentLinkCalls .. " reagent links")
    T.ok(ns.Recipes.Get(50001), "selected recipe learned right away")
  end,

  background_scan_learns_everything_one_row_per_frame = function(T)
    local ns, Core = load()
    local fired = 0
    ns.On("RECIPES_CHANGED", function() fired = fired + 1 end)
    local rows = {}
    for i = 1, 30 do rows[i] = { name = "Recipe " .. i, id = 50000 + i, reagents = { { id = 60000 + i, name = "Mat" .. i, count = 1 } } } end
    Mock.trade.rows = rows
    Core.OnEvent("TRADE_SKILL_SHOW")
    Core.OnUpdate(nil, 0.5)
    Core.OnEvent("TRADE_SKILL_UPDATE")       -- window still settling
    Core.OnUpdate(nil, 0.8)
    T.eq(ns.Recipes.Get(50001), nil, "nothing read while the window settles")
    Core.OnUpdate(nil, 0.3)                  -- 1.1 s since the last update
    Mock.reagentLinkCalls = 0
    Core.OnUpdate(nil, 0.016)
    T.ok(Mock.reagentLinkCalls <= 1, "one recipe per frame")
    for _ = 1, 40 do Core.OnUpdate(nil, 0.016) end
    T.ok(ns.Recipes.Get(50001) and ns.Recipes.Get(50030), "all recipes learned")
    T.eq(fired, 1, "one refresh at the end, not one per recipe")
  end,

  background_scan_stops_when_window_closes = function(T)
    local ns, Core = load()
    local rows = {}
    for i = 1, 30 do rows[i] = { name = "Recipe " .. i, id = 50000 + i, reagents = { { id = 60000 + i, name = "Mat" .. i, count = 1 } } } end
    Mock.trade.rows = rows
    Core.OnEvent("TRADE_SKILL_SHOW")
    Core.OnUpdate(nil, 1.1)
    Core.OnUpdate(nil, 0.016)
    Core.OnEvent("TRADE_SKILL_CLOSE")
    Mock.reagentLinkCalls = 0
    for _ = 1, 40 do Core.OnUpdate(nil, 0.016) end
    T.eq(Mock.reagentLinkCalls, 0)
  end,

  background_scan_runs_once_per_session_until_recipes_change = function(T)
    local ns, Core = load()
    local rows = {}
    for i = 1, 10 do rows[i] = { name = "Recipe " .. i, id = 50000 + i, reagents = { { id = 60000 + i, name = "Mat" .. i, count = 1 } } } end
    Mock.trade.rows = rows
    local function openAndSettle()
      Core.OnEvent("TRADE_SKILL_SHOW")
      Core.OnUpdate(nil, 1.1)
      for _ = 1, 20 do Core.OnUpdate(nil, 0.016) end
      Core.OnEvent("TRADE_SKILL_CLOSE")
    end
    openAndSettle()
    Mock.reagentLinkCalls = 0
    openAndSettle()
    T.eq(Mock.reagentLinkCalls, 0, "second open: no rescan")
    rows[11] = { name = "New Recipe", id = 59999, reagents = { { id = 69999, name = "New Mat", count = 1 } } }
    openAndSettle()
    T.ok(ns.Recipes.Get(59999), "new recipe learned after the count changed")
  end,

  diag_mode_runs_tailoring_steps_one_frame_apart = function(T)
    local ns, Core = load()
    Mock.trade.selected = 1
    Core.Slash("diag")
    T.ok(chatHas("Diagnostic mode is ON"))
    Core.OnEvent("TRADE_SKILL_SHOW")
    T.ok(chatHas("diag 0/8 Tailoring opened"), "start line printed")
    T.eq(CraftProfitTrackCheck, nil, "nothing done in the event itself")
    Core.OnEvent("TRADE_SKILL_UPDATE")
    T.eq(CraftProfitTrackCheck, nil, "updates don't build the checkbox in diag mode")

    Core.OnUpdate(nil, 0.016)                 -- frame 1: announce step 1 only
    T.ok(chatHas("diag 1/8 create Track checkbox"))
    T.eq(CraftProfitTrackCheck, nil, "announced before it runs")
    Core.OnUpdate(nil, 0.016)                 -- frame 2: run step 1
    T.ok(CraftProfitTrackCheck, "step 1 ran on the next frame")

    for _ = 1, 20 do Core.OnUpdate(nil, 0.016) end
    T.ok(chatHas("diag 8/8 start background scan"))
    T.ok(chatHas("diag done"))
    T.ok(ns.Recipes.Get(BAG), "selected recipe read")
    TradeSkillFrame_SetSelection(1)
    T.ok(chatHas("diag selection hook #1"))
  end,

  diag_off_by_default = function(T)
    local _, Core = load()
    Core.OnEvent("TRADE_SKILL_SHOW")
    T.ok(CraftProfitTrackCheck, "normal mode builds the checkbox immediately")
    T.ok(not chatHas("diag "))
  end,
}
