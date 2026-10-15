local Mock = require("wow_mock")

local REALM = "Icecrown-Alliance"
local BAG, BAG_NAME = 41599, "Frostweave Bag"
local OTHER_ITEM = 41600
local RED = "|cffff4040"
local ITEM = { id = BAG, name = BAG_NAME }

local function gold(g) return g * 10000 end

local function auction(seller, count, buyout)
  return { id = BAG, name = BAG_NAME, count = count, buyout = buyout, seller = seller }
end

-- Flipper's 50g bag is a mistake listing next to Bob's 420g and Carl's 430g.
local function standardAuctions()
  return {
    auction("Flipper", 1, gold(50)),
    auction("Bob", 1, gold(420)),
    auction("Carl", 1, gold(430)),
  }
end

-- A fresh namespace after a real price check of the bag against `auctions`:
-- the cached rows carry page and index, the "list" page still shows the
-- results, the player has 1000g.
local function setup(auctions)
  Mock.reset()
  Mock.installUI()
  local ns = Mock.load({
    "Util.lua", "Profit.lua", "Prices.lua", "Recipes.lua", "Scanner.lua", "Listings.lua",
    "UI.lua", "ListingsUI.lua", "Tabs.lua", "Flip.lua",
  })
  local db = { cut = 0.05 }
  ns.db = db
  ns.Prices.SetDB(db, REALM)
  ns.Scanner.SetDB(db)
  ns.Listings.SetDB(db, REALM, "Me")
  hooksecurefunc("QueryAuctionItems", ns.Scanner.OnQuery)
  Mock.items[BAG] = { name = BAG_NAME }
  Mock.ah.auctions = auctions or standardAuctions()
  Mock.money = gold(1000)
  assert(ns.Scanner.PriceCheck(ITEM))
  assert(Mock.pump(ns), "price check finished")
  Mock.queries = {}
  return ns
end

-- The player moved on: the "list" page no longer shows the bag.
local function leavePage()
  Mock.list, Mock.total = {}, 0
end

-- The server answered our LoadPage query; Core routes the event to Flip.
local function answer(ns)
  Mock.deliver(ns)
  ns.Flip.OnListUpdate()
end

local function recordChanges(ns)
  local changes = {}
  ns.On("FLIP_CHANGED", function(id) changes[#changes + 1] = id end)
  return changes
end

local function newWidget(ns)
  return ns.Flip.CreateWidget(UIParent, function() return BAG, BAG_NAME end)
end

local function click(w)
  w.button:GetScript("OnClick")(w.button)
end

local function has(text, part)
  return text ~= nil and text:find(part, 1, true) ~= nil
end

return {
  info_reports_flip_and_profit = function(T)
    local ns = setup()
    local info = ns.Flip.Info(BAG)
    T.ok(info, "flip found")
    T.eq(info.row.seller, "Flipper")
    T.eq(info.row.unit, gold(50))
    T.eq(info.next, gold(420))
    T.eq(info.profit, gold(349), "420g * 0.95 - 50g")
  end,

  info_profit_scales_with_stack_and_cut = function(T)
    local ns = setup({
      auction("Flipper", 5, gold(250)),      -- 50g each
      auction("Bob", 1, gold(420)),
      auction("Carl", 1, gold(430)),
    })
    T.eq(ns.Flip.Info(BAG).profit, gold(349) * 5)
    ns.db.cut = 0.15
    T.eq(ns.Flip.Info(BAG).profit, (gold(420) * 0.85 - gold(50)) * 5)
    ns.db = nil
    T.eq(ns.Flip.Info(BAG).profit, gold(349) * 5, "no db yet: default cut 5%")
  end,

  info_lone_flip_uses_the_reference_price = function(T)
    -- No other non-mistake seller: our own listing is what made it a mistake.
    local ns = setup({
      auction("Flipper", 1, gold(50)),
      auction("Me", 1, gold(420)),
    })
    local info = ns.Flip.Info(BAG)
    T.ok(info, "lone flip found")
    T.eq(info.row.seller, "Flipper")
    T.eq(info.next, 4200000)
    T.eq(info.profit, gold(349))
  end,

  info_nil_without_a_flip = function(T)
    local ns = setup({ auction("Bob", 1, gold(420)), auction("Carl", 1, gold(430)) })
    T.eq(ns.Flip.Info(BAG), nil, "no cheap outlier")
    T.eq(ns.Flip.Info(OTHER_ITEM), nil, "never price-checked")
    -- Nothing to compare a lone cheap seller with.
    local alone = setup({ auction("Flipper", 1, gold(50)) })
    T.eq(alone.Flip.Info(BAG), nil)
  end,

  buy_on_loaded_page_places_bid = function(T)
    local ns = setup()
    local changes = recordChanges(ns)
    local row = ns.Flip.Info(BAG).row
    local ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, true)
    T.eq(msg, "Bought for " .. ns.Util.FormatMoney(gold(50)))
    T.eq(msg, "Bought for 50g")
    T.eq(#Mock.bought, 1)
    T.eq(Mock.bought[1].kind, "list")
    T.eq(Mock.bought[1].index, 1, "Flipper is the first row on the page")
    T.eq(Mock.bought[1].amount, row.buyout)
    T.eq(Mock.money, gold(950))
    T.eq(ns.Scanner.IsBusy(), true, "a fresh price check started")
    ns.Scanner.Tick(0.1)
    T.eq(#Mock.queries, 1)
    T.eq(Mock.queries[1][1], BAG_NAME)
    T.eq(ns.Flip.State(BAG), "idle")
    T.eq(#changes, 0, "the state did not change")
    -- The check finishes: the bought listing is gone from the cache.
    T.ok(Mock.pump(ns))
    T.eq(ns.Flip.Info(BAG), nil)
  end,

  buy_picks_the_right_index_on_the_page = function(T)
    -- Dave has the same stack and price as Flipper: only the seller tells them apart.
    local ns = setup({
      auction("Bob", 1, gold(420)),
      auction("Carl", 1, gold(430)),
      auction("Dave", 1, gold(50)),
      auction("Flipper", 1, gold(50)),
    })
    local row = ns.Flip.Info(BAG).row
    T.eq(row.seller, "Dave", "ties keep scan order")
    T.eq(row.index, 3)
    -- Dave's auction is bought by someone else; Flipper moves up one place.
    table.remove(Mock.list, 3)
    local ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, false, "no exact match: " .. tostring(msg))
    T.eq(#Mock.bought, 0, "Flipper's identical-looking listing is not Dave's")
  end,

  buy_uses_the_current_index_not_the_scanned_one = function(T)
    local ns = setup()
    table.insert(Mock.list, 1, auction("Zed", 1, gold(500)))   -- a new row shifted everything
    local ok = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, true)
    T.eq(Mock.bought[1].index, 2, "Flipper is second now")
    T.eq(Mock.bought[1].auction.seller, "Flipper")
  end,

  buy_requires_exact_match = function(T)
    -- Same seller relists at another price before the click.
    local ns = setup()
    local changes = recordChanges(ns)
    Mock.ah.auctions[1].buyout = gold(60)
    local ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, false)
    T.eq(msg, "Finding it...")
    T.eq(#Mock.bought, 0, "the 60g listing is not the 50g one")
    T.eq(ns.Flip.State(BAG), "finding")
    T.eq(#Mock.queries, 1, "looked for it with a fresh page")
    answer(ns)
    T.eq(ns.Flip.State(BAG), "gone")
    T.eq(#Mock.bought, 0)
    T.eq(#changes, 2, "finding, then gone")
    -- Even a stale click cannot buy: there is nothing exact on the page.
    ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, false)
    T.eq(#Mock.bought, 0)
  end,

  buy_requires_every_field = function(T)
    local mutations = {
      seller = function(a) a.seller = "Someone" end,
      count = function(a) a.count = 2 end,
      buyout = function(a) a.buyout = gold(51) end,
      item = function(a) a.id = OTHER_ITEM end,
    }
    for field, mutate in pairs(mutations) do
      local ns = setup()
      mutate(Mock.ah.auctions[1])       -- the page shows the changed auction
      local ok = ns.Flip.Buy(BAG, BAG_NAME)
      T.eq(ok, false, field)
      T.eq(#Mock.bought, 0, "different " .. field .. ": no bid")
      answer(ns)
      T.eq(ns.Flip.State(BAG), "gone", field)
      T.eq(#Mock.bought, 0, field)
    end
  end,

  buy_never_matches_an_unloaded_seller_name = function(T)
    local ns = setup()
    Mock.ah.nilOwners = true            -- names still loading on the page
    local ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, false)
    T.eq(msg, "Finding it...")
    T.eq(#Mock.bought, 0)
  end,

  buy_loads_page_then_second_click_buys = function(T)
    local ns = setup()
    local changes = recordChanges(ns)
    local row = ns.Flip.Info(BAG).row
    leavePage()
    local ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, false)
    T.eq(msg, "Finding it...")
    T.eq(ns.Flip.State(BAG), "finding")
    T.eq(#Mock.queries, 1)
    T.eq(Mock.queries[1][1], BAG_NAME)
    T.eq(Mock.queries[1][7], row.page)
    T.eq(#Mock.bought, 0, "the first click never buys")

    answer(ns)
    T.eq(ns.Flip.State(BAG), "ready")
    T.eq(#Mock.bought, 0, "the list update never buys")
    T.eq(#changes, 2)
    T.eq(changes[1], BAG)
    T.eq(changes[2], BAG)

    ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, true)
    T.eq(msg, "Bought for 50g")
    T.eq(#Mock.bought, 1)
    T.eq(Mock.bought[1].index, 1)
    T.eq(Mock.bought[1].amount, row.buyout)
  end,

  load_page_uses_the_page_the_row_was_seen_on = function(T)
    local auctions = {}
    for i = 1, 50 do auctions[i] = auction("Seller" .. i, 1, gold(420) + i) end
    auctions[51] = auction("Flipper", 1, gold(50))
    local ns = setup(auctions)
    local row = ns.Flip.Info(BAG).row
    T.eq(row.seller, "Flipper")
    T.eq(row.page, 1)
    T.eq(row.index, 1)
    leavePage()
    ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(Mock.queries[1][7], 1, "page 1")
    answer(ns)
    T.eq(ns.Flip.State(BAG), "ready")
    T.eq(ns.Flip.Buy(BAG, BAG_NAME), true)
    T.eq(Mock.bought[1].index, 1, "index on the loaded page, not a stale one")
  end,

  finding_waits_while_names_load = function(T)
    local ns = setup()
    leavePage()
    ns.Flip.Buy(BAG, BAG_NAME)
    Mock.ah.nilOwners = true
    answer(ns)
    T.eq(ns.Flip.State(BAG), "finding", "cannot tell yet: wait for the next update")
    Mock.ah.nilOwners = false
    ns.Flip.OnListUpdate()
    T.eq(ns.Flip.State(BAG), "ready")
    T.eq(#Mock.bought, 0)
  end,

  list_update_ignored_unless_finding = function(T)
    local ns = setup()
    local changes = recordChanges(ns)
    ns.Flip.OnListUpdate()
    leavePage()
    ns.Flip.OnListUpdate()
    T.eq(ns.Flip.State(BAG), "idle")
    T.eq(#changes, 0)
    T.eq(#Mock.bought, 0)
  end,

  state_resets_after_a_fresh_price_check = function(T)
    local ns = setup()
    Mock.ah.auctions[1].buyout = gold(60)
    ns.Flip.Buy(BAG, BAG_NAME)
    answer(ns)
    T.eq(ns.Flip.State(BAG), "gone")
    -- Listings checked again: the 60g listing is the one to judge now.
    T.eq(ns.Scanner.PriceCheck(ITEM), true)
    T.ok(Mock.pump(ns))
    T.eq(ns.Flip.State(BAG), "idle")
    T.eq(ns.Flip.State(OTHER_ITEM), "idle")
  end,

  not_enough_gold = function(T)
    local ns = setup()
    Mock.money = gold(50) - 1
    local ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, false)
    T.eq(msg, "Not enough gold")
    T.eq(#Mock.bought, 0)
    T.eq(#Mock.queries, 0, "no search either")
    T.eq(ns.Flip.State(BAG), "idle")
    -- Also when the page would need loading first.
    leavePage()
    ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(msg, "Not enough gold")
    T.eq(#Mock.queries, 0)
    -- Exactly the buyout is enough.
    Mock.money = gold(50)
    T.eq(ns.Flip.Buy(BAG, BAG_NAME), false, "page must load first")
    answer(ns)
    T.eq(ns.Flip.Buy(BAG, BAG_NAME), true)
    T.eq(Mock.money, 0)
  end,

  busy_scanner_message = function(T)
    local ns = setup()
    leavePage()
    T.eq(ns.Scanner.PriceCheck(ITEM), true)       -- the scanner is working
    Mock.queries = {}
    local ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, false)
    T.ok(has(msg, "busy"), "message says busy: " .. tostring(msg))
    T.eq(#Mock.queries, 0)
    T.eq(#Mock.bought, 0)
    T.eq(ns.Flip.State(BAG), "idle", "nothing is being found")
  end,

  throttled_message = function(T)
    local ns = setup()
    leavePage()
    Mock.ah.canQuery = false
    local ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, false)
    T.ok(has(msg, "try again"), "message says to retry: " .. tostring(msg))
    T.eq(#Mock.queries, 0)
    T.eq(ns.Flip.State(BAG), "idle")
  end,

  buy_without_a_flip = function(T)
    local ns = setup({ auction("Bob", 1, gold(420)), auction("Carl", 1, gold(430)) })
    local ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, false)
    T.ok(msg and msg ~= "")
    T.eq(#Mock.bought, 0)
    T.eq(#Mock.queries, 0)
  end,

  widget_hidden_without_a_flip = function(T)
    local ns = setup({ auction("Bob", 1, gold(420)), auction("Carl", 1, gold(430)) })
    local w = newWidget(ns)
    w:Update()
    T.eq(w.frame:IsShown(), false)
    -- Also while the page shows no item.
    local none = ns.Flip.CreateWidget(UIParent, function() return nil end)
    none:Update()
    T.eq(none.frame:IsShown(), false)
  end,

  widget_shows_notice_and_buy_button = function(T)
    local ns = setup()
    local U = ns.Util
    local w = newWidget(ns)
    T.eq(w.button._template, "UIPanelButtonTemplate")
    T.eq(w.button._parent, w.frame)
    T.eq(w.frame._parent, UIParent)
    w:Update()
    T.eq(w.frame:IsShown(), true)
    T.eq(w.notice:GetText(), RED .. U.ICON_GOLD .. " Possible mistake: Flipper sells 1 at "
      .. U.FormatMoney(gold(50)) .. " (next " .. U.FormatMoney(gold(420))
      .. "). Flip profit ~" .. U.FormatMoney(gold(349)) .. "|r")
    T.eq(w.button:GetText(), "Buy it")
    T.eq(w.button:IsEnabled(), true)
    for _, bad in ipairs({ "\226\156\147", "\226\154\160" }) do
      T.eq(w.notice:GetText():find(bad, 1, true), nil, "no ✓/⚠ characters")
    end
  end,

  widget_hides_when_the_flip_goes_away = function(T)
    local ns = setup()
    local w = newWidget(ns)
    w:Update()
    T.eq(w.frame:IsShown(), true)
    ns.Listings.Store(BAG, {})             -- fires LISTINGS_UPDATED
    T.eq(w.frame:IsShown(), false, "redrawn by itself")
  end,

  widget_button_follows_the_state = function(T)
    local ns = setup()
    local w = newWidget(ns)
    w:Update()
    T.eq(w.button:GetText(), "Buy it")

    leavePage()
    click(w)
    T.eq(ns.Flip.State(BAG), "finding")
    T.eq(w.button:GetText(), "Finding it...")
    T.eq(w.button:IsEnabled(), false)

    answer(ns)                             -- FLIP_CHANGED redraws the widget
    T.eq(ns.Flip.State(BAG), "ready")
    T.eq(w.button:GetText(), "Buy now (" .. ns.Util.FormatMoney(gold(50)) .. ")")
    T.eq(w.button:GetText(), "Buy now (50g)")
    T.eq(w.button:IsEnabled(), true)
    T.eq(#Mock.bought, 0)

    click(w)
    T.eq(#Mock.bought, 1)
  end,

  widget_gone_state = function(T)
    local ns = setup()
    local w = newWidget(ns)
    Mock.ah.auctions[1].buyout = gold(60)
    click(w)
    answer(ns)
    T.eq(ns.Flip.State(BAG), "gone")
    T.eq(w.button:GetText(), "That listing is gone.")
    T.eq(w.button:IsEnabled(), false)
    T.eq(w.frame:IsShown(), true, "the notice stays so the player sees what happened")
  end,

  widget_click_buys_and_shows_the_message = function(T)
    local ns = setup()
    local w = newWidget(ns)
    w:Update()
    click(w)
    T.eq(#Mock.bought, 1)
    T.ok(has(w.notice:GetText(), "Bought for 50g"), w.notice:GetText())
    T.ok(Mock.pump(ns), "price check finished")
    T.eq(w.frame:IsShown(), false, "the flip is gone from the fresh listings")
  end,

  widget_shows_not_enough_gold = function(T)
    local ns = setup()
    local w = newWidget(ns)
    Mock.money = 1
    click(w)
    T.eq(#Mock.bought, 0)
    T.ok(has(w.notice:GetText(), "Not enough gold"), w.notice:GetText())
    T.ok(has(w.notice:GetText(), "Possible mistake"), "the notice itself stays")
    T.eq(w.button:GetText(), "Buy it")
    T.eq(w.button:IsEnabled(), true)
  end,

  widget_shows_busy_message = function(T)
    local ns = setup()
    local w = newWidget(ns)
    leavePage()
    ns.Scanner.PriceCheck(ITEM)
    click(w)
    T.ok(has(w.notice:GetText(), "busy"), w.notice:GetText())
  end,

  widget_message_does_not_repeat_the_button = function(T)
    local ns = setup()
    local w = newWidget(ns)
    leavePage()
    click(w)
    T.eq(w.button:GetText(), "Finding it...")
    T.eq(has(w.notice:GetText(), "Finding it"), false)
  end,

  widget_ignores_click_without_an_item = function(T)
    local ns = setup()
    local w = ns.Flip.CreateWidget(UIParent, function() return nil end)
    click(w)
    T.eq(#Mock.bought, 0)
    T.eq(#Mock.queries, 0)
  end,

  nothing_buys_without_a_click = function(T)
    local ns = setup()
    local w = newWidget(ns)
    w:Update()
    ns.Flip.OnListUpdate()
    ns.Flip.Info(BAG)
    ns.Fire("LISTINGS_UPDATED", BAG)
    ns.Fire("FLIP_CHANGED", BAG)
    T.eq(#Mock.bought, 0)
  end,

  place_auction_bid_only_in_buy = function(T)
    local f = assert(io.open(Mock.root .. "Flip.lua", "r"))
    local src = f:read("*a")
    f:close()
    local first = src:find("PlaceAuctionBid", 1, true)
    T.ok(first, "Flip.lua places the bid")
    T.eq(src:find("PlaceAuctionBid", first + 1, true), nil, "exactly one call")
    local buyStart = src:find("\nfunction Flip.Buy(", 1, true)
    T.ok(buyStart, "Flip.Buy exists")
    local buyEnd = src:find("\nfunction ", buyStart + 1, true) or #src
    T.ok(first > buyStart and first < buyEnd, "the bid is inside Flip.Buy")
    -- Exactly one caller of Buy: the button's OnClick.
    local calls = 0
    for _ in src:gmatch("Flip%.Buy%(") do calls = calls + 1 end
    T.eq(calls, 2, "the definition and the OnClick call")
    for _, api in ipairs({ "StartAuction", "CancelAuction" }) do
      T.eq(src:find(api, 1, true), nil, api .. " must not appear")
    end
  end,
}
