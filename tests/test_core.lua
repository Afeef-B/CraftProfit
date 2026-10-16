local Mock = require("wow_mock")

local BAG, BOLT, CLOTH, THREAD, DUST = 41599, 41510, 33470, 38426, 34054

-- Every addon file, in the order of the toc.
local ALL = {
  "Util.lua", "Profit.lua", "Prices.lua", "Recipes.lua", "Scanner.lua", "Listings.lua",
  "UI.lua", "ListingsUI.lua", "Tabs.lua", "Flip.lua", "Sell.lua", "SellUI.lua",
  "Auctions.lua", "AuctionsUI.lua", "Core.lua",
}

-- `player` names the character that logs in (default "Me").
local function load(savedDB, player)
  Mock.reset()
  Mock.installUI()
  if player then Mock.playerName = player end
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
  Core.OnUpdate(nil, 1.6)
  for _ = 1, #Mock.trade.rows + 2 do Core.OnUpdate(nil, 0.016) end
end

local function chatHas(text)
  for _, msg in ipairs(Mock.chat) do
    local plain = msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    if plain:find(text, 1, true) then return true end
  end
  return false
end

-- The game delivers an event to the addon's frame: this is the real entry point,
-- so every argument has to get through it.
local function fire(event, ...)
  local frame = CraftProfitEventFrame
  frame:GetScript("OnEvent")(frame, event, ...)
end

-- Replace tbl[name] with a recorder; calls[i] = { n = arg count, arg1, arg2, ... }.
local function spy(tbl, name, log)
  local calls = {}
  tbl[name] = function(...)
    calls[#calls + 1] = { n = select("#", ...), ... }
    if log then log[#log + 1] = name end
  end
  return calls
end

local function click(frame)
  frame:GetScript("OnClick")(frame)
end

local function gold(g) return g * 10000 end

-- A Frostweave Bag stack of `count` in the first bag slot, put into the sell
-- slot (as an Alt+click does) with the price check finished.
local function putBag(ns, count)
  Mock.items[BAG] = { name = "Frostweave Bag", maxStack = 1 }
  Mock.bags[0] = { [1] = { id = BAG, name = "Frostweave Bag", count = count } }
  assert(ns.Sell.PutItem(0, 1), "item accepted")
  assert(Mock.pump(ns), "price check finished")
  ns.Sell.SetUnit(gold(400))
end

-- A foreign addon's tab, as Auctionator adds one.
local function addForeignTab(n)
  local tab = CreateFrame("Button", "AuctionFrameTab" .. n, AuctionFrame, "AuctionTabTemplate")
  tab:SetID(n)
  tab:SetPoint("TOPLEFT", _G["AuctionFrameTab" .. (n - 1)], "TOPRIGHT", -8, 0)
  return tab
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

  nothing_touches_the_window_while_it_opens = function(T)
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
      Core.OnUpdate(nil, 0.3)
    end
    T.eq(CraftProfitTrackCheck, nil, "no checkbox while opening")
    T.eq(Mock.reagentLinkCalls, 0, "no recipe reads while opening")

    Core.OnUpdate(nil, 1.3)                 -- quiet for 1.6 s: settled
    T.ok(CraftProfitTrackCheck, "checkbox added once settled")
    T.ok(ns.Recipes.Get(50001), "selected recipe read once settled")
    T.ok(Mock.reagentLinkCalls <= 4, "settling reads the selected recipe, not all of them: " .. Mock.reagentLinkCalls)
  end,

  selection_hook_is_inert_while_the_window_reopens = function(T)
    local ns, Core = load()
    Mock.trade.selected = 1
    openProfession(Core)                    -- hook installed, recipes known
    Core.OnEvent("TRADE_SKILL_CLOSE")
    Mock.reagentLinkCalls = 0
    Core.OnEvent("TRADE_SKILL_SHOW")
    Core.OnEvent("TRADE_SKILL_UPDATE")
    TradeSkillFrame_SetSelection(1)
    T.eq(Mock.reagentLinkCalls, 0, "hook does nothing while the window opens")
    Core.OnUpdate(nil, 1.6)
    TradeSkillFrame_SetSelection(1)
    T.ok(Mock.reagentLinkCalls > 0, "hook works again once settled")
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
    Core.OnUpdate(nil, 1.2)
    T.eq(ns.Recipes.Get(50001), nil, "nothing read while the window settles")
    Core.OnUpdate(nil, 0.4)                  -- 1.6 s since the last update
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
    Core.OnUpdate(nil, 1.6)
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
      Core.OnUpdate(nil, 1.6)
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

  diag_mode_runs_one_step_per_command = function(T)
    local ns, Core = load()
    Mock.trade.selected = 1
    Core.Slash("diag")
    T.ok(chatHas("Diagnostic mode is ON"))
    Core.OnEvent("TRADE_SKILL_SHOW")
    T.ok(chatHas("diag 0/8 Tailoring opened"), "start line printed")
    T.ok(chatHas("Next: 1/8 create Track checkbox - type /cp step"))
    Core.OnEvent("TRADE_SKILL_UPDATE")
    for _ = 1, 50 do Core.OnUpdate(nil, 0.1) end
    T.eq(CraftProfitTrackCheck, nil, "nothing runs on its own")

    Core.Slash("step")
    T.ok(CraftProfitTrackCheck, "step 1 ran")
    T.ok(chatHas("diag 1/8 create Track checkbox: done"))
    T.ok(chatHas("Next: 2/8 position Track label - type /cp step"))

    for _ = 2, 8 do Core.Slash("step") end
    T.ok(chatHas("diag 8/8 start background scan: done"))
    T.ok(chatHas("all 8 steps ran without freezing"))
    T.ok(ns.Recipes.Get(BAG), "selected recipe read")
    TradeSkillFrame_SetSelection(1)
    T.ok(chatHas("diag selection hook #1"))
    Core.Slash("step")
    T.ok(chatHas("No diagnostic step waiting"))
  end,

  diag_step_before_opening_explains = function(T)
    local _, Core = load()
    Core.Slash("diag")
    Core.Slash("step")
    T.ok(chatHas("No diagnostic step waiting"))
  end,

  diag_off_by_default = function(T)
    local _, Core = load()
    Core.OnEvent("TRADE_SKILL_SHOW")
    Core.OnUpdate(nil, 1.6)
    T.ok(CraftProfitTrackCheck, "normal mode builds the checkbox once settled")
    T.ok(not chatHas("diag "))
  end,

  status_reports_window_and_checkbox_state = function(T)
    local ns, Core = load()
    Mock.trade.selected = 1
    Core.Slash("status")
    T.ok(chatHas("Profession window: closed"))
    Core.OnEvent("TRADE_SKILL_SHOW")
    Core.OnEvent("TRADE_SKILL_UPDATE")
    Core.OnEvent("TRADE_SKILL_UPDATE")
    Core.OnUpdate(nil, 0.4)
    Mock.chat = {}
    Core.Slash("status")
    T.ok(chatHas("Profession window: opening (quiet 0.4 s, 2 updates since it opened)"))
    T.ok(chatHas("Track checkbox: not created yet"))
    Core.OnUpdate(nil, 1.6)
    Mock.chat = {}
    Core.Slash("status")
    T.ok(chatHas("Profession window: ready (2 updates since it opened)"))
    T.ok(chatHas("Track checkbox: created, shown yes, visible yes"))
    T.ok(chatHas("Selected recipe: row 1, item 41599 (Frostweave Bag)"))
    T.ok(chatHas("Recipes known: 1, tracked: 0"))
  end,

  -- Saving the character at login is what makes its alts count as "you".
  login_records_character_for_alts = function(T)
    local ns = load(nil)
    T.eq(CraftProfitDB.chars["Icecrown-Alliance"].Me, true)
    T.eq(ns.Listings.MineSet().Me, true)

    local saved = CraftProfitDB
    local ns2 = load(saved, "Altie")             -- the alt logs in later
    T.eq(CraftProfitDB, saved, "the saved table is kept")
    T.eq(ns2.Listings.MineSet().Me, true, "the first character is still ours")
    T.eq(ns2.Listings.MineSet().Altie, true)

    -- and another character's auction is not
    local rows = ns2.Listings.Normalize({
      { count = 1, buyout = 1000, seller = "Altie" },
      { count = 1, buyout = 2000, seller = "Bob" },
    }, ns2.Listings.MineSet(), ns2.Listings.Ratio())
    T.eq(rows[1].mine, true)
    T.eq(rows[2].mine, false)
  end,

  login_wires_saved_settings_into_sell_and_auctions = function(T)
    local ns = load(nil)
    T.eq(CraftProfitDB.sell.duration, 2, "Sell.SetDB ran")
    local ok, why = ns.Auctions.CancelNextUndercut()
    T.eq(ok, false)
    T.eq(why, "confirm", "Auctions.SetDB ran: the cancel warning is still to be shown")
    T.eq(Mock.popup, "CRAFTPROFIT_CANCEL")

    local ns2 = load({ cancelWarned = true, sell = { duration = 3 } })
    T.eq(ns2.Sell.State().duration, 3, "the saved duration is used")
    local _, why2 = ns2.Auctions.CancelNextUndercut()
    T.eq(why2, "none", "the saved warning flag is used: no popup, just nothing to cancel")
  end,

  slash_outlier_sets_ratio = function(T)
    local ns, Core = load()
    Core.Slash("outlier 30")
    T.eq(CraftProfitDB.outlierRatio, 0.3)
    T.eq(ns.Listings.Ratio(), 0.3, "the listings maths reads it")
    T.ok(chatHas("30%"), "the new value is printed")

    Core.Slash("outlier 1")
    T.eq(CraftProfitDB.outlierRatio, 0.01)
    Core.Slash("outlier 99")
    T.eq(CraftProfitDB.outlierRatio, 0.99)
    Core.Slash("outlier 30")
    Mock.chat = {}

    for _, bad in ipairs({ "outlier", "outlier 0", "outlier 100", "outlier -5", "outlier abc", "outlier 12.5" }) do
      Mock.chat = {}
      Core.Slash(bad)
      T.eq(CraftProfitDB.outlierRatio, 0.3, bad .. " leaves the ratio alone")
      T.ok(chatHas("Usage: /cp outlier <1-99>"), bad .. " prints the usage")
      T.ok(chatHas("now 30)"), bad .. " says what it is now")
    end
  end,

  slash_outlier_usage_shows_the_default = function(T)
    local _, Core = load()
    Core.Slash("outlier")
    T.eq(CraftProfitDB.outlierRatio, nil)
    T.ok(chatHas("now 50)"))
  end,

  help_lists_outlier = function(T)
    local _, Core = load()
    Core.Slash("nonsense")
    T.ok(chatHas("/cp outlier <percent>"))
  end,

  -- Other tab addons (Auctionator) build theirs when the AH UI loads; ours wait
  -- for the first AUCTION_HOUSE_SHOW so the first free tab id is really free.
  tabs_created_on_first_ah_show = function(T)
    local ns, Core = load()
    T.eq(AuctionFrameTab4, nil, "no tabs at login, even though the AH frame exists")
    Core.OnEvent("ADDON_LOADED", "Blizzard_AuctionUI")
    T.eq(AuctionFrameTab4, nil, "none when the AH UI loads either")

    Core.OnEvent("AUCTION_HOUSE_SHOW")
    T.ok(AuctionFrameTab4 and AuctionFrameTab5, "tabs after the first show")
    T.eq(AuctionFrameTab4:GetText(), "CP Sell")
    T.eq(AuctionFrameTab5:GetText(), "CP Auctions")
    T.eq(AuctionFrameTab6, nil)
    T.eq(Mock.numTabs, 5)
    local sell, auctions = AuctionFrameTab4, AuctionFrameTab5

    Core.OnEvent("AUCTION_HOUSE_SHOW")
    T.eq(AuctionFrameTab4, sell, "same tab objects on the second show")
    T.eq(AuctionFrameTab5, auctions)
    T.eq(AuctionFrameTab6, nil, "no duplicates")
    T.eq(Mock.numTabs, 5)
  end,

  tabs_come_after_tabs_other_addons_added_first = function(T)
    local _, Core = load()
    addForeignTab(4)                          -- Auctionator's tab, built when the AH UI loaded
    addForeignTab(5)
    Core.OnEvent("AUCTION_HOUSE_SHOW")
    T.eq(AuctionFrameTab6:GetText(), "CP Sell")
    T.eq(AuctionFrameTab7:GetText(), "CP Auctions")
    T.eq(AuctionFrameTab4:GetText(), nil, "their tabs are left alone")
    T.eq(Mock.numTabs, 7)
  end,

  ah_show_without_the_ah_ui_makes_no_tabs = function(T)
    Mock.reset()
    Mock.installUI()
    local auctionFrame = AuctionFrame
    AuctionFrame = nil
    local ns = Mock.load(ALL)
    ns.Core.OnEvent("PLAYER_LOGIN")
    ns.Core.OnEvent("AUCTION_HOUSE_SHOW")     -- nothing to build on yet: no error
    T.eq(AuctionFrameTab4, nil)
    AuctionFrame = auctionFrame
    ns.Core.OnEvent("AUCTION_HOUSE_SHOW")
    T.ok(AuctionFrameTab4 and AuctionFrameTab5, "built on the show after the AH UI exists")
  end,

  -- The events we listen to are exactly these: a new one added without a test
  -- (and a route) shows up here.
  registered_events = function(T)
    load()
    local expected = {
      "PLAYER_LOGIN", "ADDON_LOADED",
      "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_CLOSE",
      "MERCHANT_SHOW", "MERCHANT_UPDATE",
      "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "AUCTION_ITEM_LIST_UPDATE",
      "NEW_AUCTION_UPDATE", "AUCTION_OWNED_LIST_UPDATE",
      "AUCTION_MULTISELL_START", "AUCTION_MULTISELL_UPDATE", "AUCTION_MULTISELL_FAILURE",
      "PLAYER_MONEY", "UI_ERROR_MESSAGE",
    }
    local want = {}
    for _, e in ipairs(expected) do
      want[e] = true
      T.ok(CraftProfitEventFrame:IsEventRegistered(e), e .. " is registered")
    end
    for e in pairs(CraftProfitEventFrame._events) do
      T.ok(want[e], e .. " is registered but not expected")
    end
  end,

  events_route_to_sell_and_auctions = function(T)
    local ns = load()
    local slot = spy(ns.Sell, "OnSlotChanged")
    local owned = spy(ns.Auctions, "OnOwnedListUpdate")
    local multi = spy(ns.Sell, "OnMultisell")

    fire("NEW_AUCTION_UPDATE", "no arguments in the game")
    T.eq(#slot, 1)
    T.eq(slot[1].n, 1)
    T.eq(slot[1][1], nil, "the item already shown stays: no new id")

    fire("AUCTION_OWNED_LIST_UPDATE")
    T.eq(#owned, 1)

    fire("AUCTION_MULTISELL_START", 3)
    fire("AUCTION_MULTISELL_FAILURE")
    T.eq(#multi, 2)
    T.eq(multi[1][1], "AUCTION_MULTISELL_START")
    T.eq(multi[1][2], 3)
    T.eq(multi[2][1], "AUCTION_MULTISELL_FAILURE")
    T.eq(#slot, 1, "nothing else reached the slot handler")
    T.eq(#owned, 1)
  end,

  multisell_update_reaches_sell_with_both_args = function(T)
    local ns = load()
    local multi = spy(ns.Sell, "OnMultisell")
    fire("AUCTION_MULTISELL_UPDATE", 2, 3)
    T.eq(#multi, 1)
    T.eq(multi[1][1], "AUCTION_MULTISELL_UPDATE")
    T.eq(multi[1][2], 2)
    T.eq(multi[1][3], 3)
  end,

  -- The same events, through the real modules.
  posting_progress_arrives_through_core = function(T)
    local ns = load()
    putBag(ns, 3)
    ns.Sell.SetStacks(3)
    T.eq(ns.Sell.Post(), true)
    fire("AUCTION_MULTISELL_START", 3)
    T.eq(ns.Sell.State().status, "Posting 0/3")
    fire("AUCTION_MULTISELL_UPDATE", 2, 3)
    T.eq(ns.Sell.State().status, "Posting 2/3")
    fire("AUCTION_MULTISELL_UPDATE", 3, 3)
    T.eq(ns.Sell.State().status, "Posted 3 auctions")
    T.eq(ns.Sell.State().reason, nil)
  end,

  new_auction_update_keeps_the_item_through_core = function(T)
    local ns = load()
    putBag(ns, 2)
    Mock.sellSlot.count = 1                    -- the game changed the slot's count
    fire("NEW_AUCTION_UPDATE")
    T.eq(ns.Sell.State().item.id, BAG, "still the same item")
    Mock.sellSlot = nil                        -- the game emptied the slot
    fire("NEW_AUCTION_UPDATE")
    T.eq(ns.Sell.State().item, nil)
  end,

  owned_list_update_reaches_auctions = function(T)
    local ns = load()
    Mock.owned = { { id = BAG, name = "Frostweave Bag", count = 1, buyout = gold(400) } }
    fire("AUCTION_OWNED_LIST_UPDATE")
    local groups = ns.Auctions.Groups()
    T.eq(#groups, 1)
    T.eq(groups[1].id, BAG)
  end,

  flip_follows_list_updates_and_scanner_still_does = function(T)
    local ns = load()
    local order = {}
    local flip = spy(ns.Flip, "OnListUpdate", order)
    local scanner = spy(ns.Scanner, "HandleEvent", order)
    fire("AUCTION_ITEM_LIST_UPDATE")
    T.eq(#flip, 1)
    T.eq(#scanner, 1)
    T.eq(scanner[1][1], "AUCTION_ITEM_LIST_UPDATE")
    T.eq(order[1], "HandleEvent", "the scanner reads the page first")
    T.eq(order[2], "OnListUpdate")
  end,

  ah_close_resets_flip_and_sell_and_stops_the_scanner = function(T)
    local ns = load()
    local order = {}
    local scanner = spy(ns.Scanner, "HandleEvent", order)
    local flip = spy(ns.Flip, "Reset", order)
    local sell = spy(ns.Sell, "OnAuctionHouseClosed", order)
    fire("AUCTION_HOUSE_CLOSED")
    T.eq(#scanner, 1)
    T.eq(scanner[1][1], "AUCTION_HOUSE_CLOSED")
    T.eq(#flip, 1)
    T.eq(#sell, 1)
    T.eq(order[1], "HandleEvent", "the scan stops before the pages are cleared")
  end,

  ah_close_frees_a_stuck_post = function(T)
    local ns = load()
    putBag(ns, 3)
    ns.Sell.SetStacks(3)
    T.eq(ns.Sell.Post(), true)
    fire("AUCTION_MULTISELL_START", 3)
    T.eq(ns.Sell.State().reason, "posting")
    fire("AUCTION_HOUSE_CLOSED")
    T.ok(ns.Sell.State().reason ~= "posting", "the lock is gone")
    T.eq(ns.Sell.State().status, "")
  end,

  on_update_ticks_flip = function(T)
    local ns, Core = load()
    local flip = spy(ns.Flip, "Tick")
    local scanner = spy(ns.Scanner, "Tick")
    Core.OnUpdate(nil, 0.25)
    T.eq(#flip, 1)
    T.eq(flip[1][1], 0.25, "gets the elapsed time")
    T.eq(#scanner, 1, "the scanner still ticks")
  end,

  player_money_tells_the_pages = function(T)
    local ns = load()
    local count = 0
    ns.On("MONEY_CHANGED", function() count = count + 1 end)
    fire("PLAYER_MONEY")
    T.eq(count, 1)
  end,

  -- With CP Sell open, a change in gold decides whether Post is on.
  player_money_redraws_the_sell_page = function(T)
    local ns, Core = load()
    Core.OnEvent("AUCTION_HOUSE_SHOW")
    click(AuctionFrameTab4)
    putBag(ns, 1)
    T.eq(ns.SellUI.post:IsEnabled(), true)
    Mock.money = 100                           -- below the 200c deposit
    fire("PLAYER_MONEY")
    T.eq(ns.SellUI.post:IsEnabled(), false)
    Mock.money = gold(10)
    fire("PLAYER_MONEY")
    T.eq(ns.SellUI.post:IsEnabled(), true)
  end,

  ui_error_goes_to_the_pages_and_to_sell = function(T)
    local ns = load()
    local pages, errors = {}, spy(ns.Sell, "OnPostError")
    ns.On("PAGE_ERROR", function(msg) pages[#pages + 1] = msg end)
    fire("UI_ERROR_MESSAGE", "Not enough money.")
    T.eq(#pages, 1)
    T.eq(pages[1], "Not enough money.")
    T.eq(#errors, 1)
    T.eq(errors[1][1], "Not enough money.")
  end,

  -- Only the page the player looks at shows it.
  ui_error_reaches_visible_page = function(T)
    local ns, Core = load()
    Core.OnEvent("AUCTION_HOUSE_SHOW")
    click(AuctionFrameTab4)                    -- CP Sell
    fire("UI_ERROR_MESSAGE", "Item not found.")
    T.eq(ns.SellUI.status:GetText(), "|cffff4040Item not found.|r")

    click(AuctionFrameTab5)                    -- CP Auctions
    fire("UI_ERROR_MESSAGE", "You can't cancel that.")
    T.eq(ns.AuctionsUI.status:GetText(), "|cffff4040You can't cancel that.|r")
    T.eq(ns.SellUI.status:GetText(), "|cffff4040Item not found.|r", "the page that is hidden is left alone")

    click(AuctionFrameTab1)                    -- back to Blizzard's Browse tab
    fire("UI_ERROR_MESSAGE", "Nobody is looking.")
    T.eq(ns.AuctionsUI.status:GetText(), "|cffff4040You can't cancel that.|r")
  end,

  -- A refused single-stack post sends no multisell event: the error is all there is.
  ui_error_after_a_refused_post_frees_the_sell_page = function(T)
    local ns, Core = load()
    Core.OnEvent("AUCTION_HOUSE_SHOW")
    click(AuctionFrameTab4)
    putBag(ns, 1)
    T.eq(ns.Sell.Post(), true)
    T.eq(ns.Sell.State().reason, "posting")

    fire("UI_ERROR_MESSAGE", "You do not have enough money.")
    T.eq(ns.Sell.State().reason, nil)
    T.eq(ns.SellUI.post:IsEnabled(), true, "Post is back")
    T.eq(ns.SellUI.status:GetText(), "|cffff4040You do not have enough money.|r", "shown in red")
  end,

  ui_error_in_the_middle_of_a_multisell_keeps_the_lock = function(T)
    local ns = load()
    putBag(ns, 3)
    ns.Sell.SetStacks(3)
    T.eq(ns.Sell.Post(), true)
    fire("AUCTION_MULTISELL_START", 3)
    fire("AUCTION_MULTISELL_UPDATE", 1, 3)
    fire("UI_ERROR_MESSAGE", "Can't do that while moving.")
    T.eq(ns.Sell.State().reason, "posting")
    T.eq(ns.Sell.State().status, "Posting 1/3")
    fire("AUCTION_MULTISELL_UPDATE", 3, 3)
    T.eq(ns.Sell.State().reason, nil)
  end,
}
