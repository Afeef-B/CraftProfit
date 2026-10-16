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
    T.eq(msg, "Bid placed for " .. ns.Util.FormatMoney(gold(50)))
    T.eq(msg, "Bid placed for 50g")
    T.eq(#Mock.bought, 1)
    T.eq(Mock.bought[1].kind, "list")
    T.eq(Mock.bought[1].index, 1, "Flipper is the first row on the page")
    T.eq(Mock.bought[1].amount, row.buyout)
    T.eq(Mock.money, gold(950))
    T.eq(ns.Scanner.IsBusy(), true, "a fresh price check started")
    ns.Scanner.Tick(0.1)
    T.eq(#Mock.queries, 1)
    T.eq(Mock.queries[1][1], BAG_NAME)
    T.eq(ns.Flip.State(BAG), "bought")
    T.eq(#changes, 1, "idle -> bought")
    -- The check finishes: the bought listing is gone from the cache.
    T.ok(Mock.pump(ns))
    T.eq(ns.Flip.Info(BAG), nil)
    T.eq(ns.Flip.State(BAG), "idle")
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
    leavePage()
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

  buy_with_the_relisted_row_already_on_the_page = function(T)
    -- The loaded page already shows the 60g relisting: no bid, and the search
    -- for the 50g one answers with the very same page.
    local ns = setup()
    Mock.ah.auctions[1].buyout = gold(60)
    local ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, false)
    T.eq(msg, "Finding it...")
    T.eq(#Mock.bought, 0)
    answer(ns)
    T.eq(ns.Flip.State(BAG), "finding", "an identical page is not an answer")
    ns.Flip.Tick(10)
    T.eq(ns.Flip.State(BAG), "idle", "so it times out instead")
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
      ns.Flip.Reset()
      leavePage()                       -- and again, loading it fresh
      T.eq(ns.Flip.Buy(BAG, BAG_NAME), false, field)
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
    T.eq(msg, "Bid placed for 50g")
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
    leavePage()
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
    T.eq(w.button:GetText(), "Buy it (50g)")
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
    T.eq(w.button:GetText(), "Buy it (50g)")

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
    T.eq(w.button:GetText(), "Bought")
    T.eq(w.button:IsEnabled(), false)
  end,

  widget_gone_state = function(T)
    local ns = setup()
    local w = newWidget(ns)
    w:Update()
    Mock.ah.auctions[1].buyout = gold(60)
    leavePage()
    click(w)
    answer(ns)
    T.eq(ns.Flip.State(BAG), "gone")
    T.eq(w.button:GetText(), "Gone - try again (50g)")
    T.eq(w.button:IsEnabled(), true, "the player can search again")
    T.eq(w.frame:IsShown(), true, "the notice stays so the player sees what happened")
    T.ok(has(w.notice:GetText(), "That listing is gone."), w.notice:GetText())
  end,

  widget_click_buys_and_shows_the_message = function(T)
    local ns = setup()
    local w = newWidget(ns)
    w:Update()
    click(w)
    T.eq(#Mock.bought, 1)
    T.ok(has(w.notice:GetText(), "Bid placed for 50g"), w.notice:GetText())
    T.ok(Mock.pump(ns), "price check finished")
    T.eq(w.frame:IsShown(), false, "the flip is gone from the fresh listings")
  end,

  widget_shows_not_enough_gold = function(T)
    local ns = setup()
    local w = newWidget(ns)
    w:Update()
    Mock.money = 1
    click(w)
    T.eq(#Mock.bought, 0)
    T.ok(has(w.notice:GetText(), "Not enough gold"), w.notice:GetText())
    T.ok(has(w.notice:GetText(), "Possible mistake"), "the notice itself stays")
    T.eq(w.button:GetText(), "Buy it (50g)")
    T.eq(w.button:IsEnabled(), true)
  end,

  widget_shows_busy_message = function(T)
    local ns = setup()
    local w = newWidget(ns)
    w:Update()
    leavePage()
    ns.Scanner.PriceCheck(ITEM)
    click(w)
    T.ok(has(w.notice:GetText(), "busy"), w.notice:GetText())
  end,

  widget_message_does_not_repeat_the_button = function(T)
    local ns = setup()
    local w = newWidget(ns)
    w:Update()
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
    ns.Flip.Tick(100)
    ns.Flip.Reset()
    T.eq(#Mock.bought, 0)
  end,

  second_click_after_purchase_does_not_buy = function(T)
    -- One seller posted two identical mistake stacks.
    local ns = setup({
      auction("Flipper", 1, gold(50)),
      auction("Flipper", 1, gold(50)),
      auction("Bob", 1, gold(420)),
      auction("Carl", 1, gold(430)),
    })
    local w = newWidget(ns)
    w:Update()
    click(w)
    T.eq(#Mock.bought, 1)
    T.eq(ns.Flip.State(BAG), "bought")
    T.eq(w.button:GetText(), "Bought")
    T.eq(w.button:IsEnabled(), false)

    click(w)                                   -- a double click
    T.eq(#Mock.bought, 1, "the second identical stack is not bought by the same click")
    local ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, false)
    T.eq(msg, "Already bought")
    T.eq(#Mock.bought, 1)

    -- The fresh price check replaces the rows: the second stack is a new offer.
    T.ok(Mock.pump(ns), "price check finished")
    T.eq(ns.Flip.State(BAG), "idle")
    T.eq(w.button:GetText(), "Buy it (50g)")
    T.eq(w.button:IsEnabled(), true)
    click(w)
    T.eq(#Mock.bought, 2, "a deliberate click on the next stack buys it")
  end,

  bought_state_follows_the_row_not_the_item = function(T)
    local ns = setup()
    ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ns.Flip.State(BAG), "bought")
    -- Rows replaced without a new flip: nothing left to be "bought".
    ns.Listings.Store(BAG, {})
    T.eq(ns.Flip.State(BAG), "idle")
    T.eq(ns.Flip.Info(BAG), nil)
  end,

  finding_times_out = function(T)
    local ns = setup()
    local changes = recordChanges(ns)
    local statuses = {}
    ns.On("PAGE_STATUS", function(msg) statuses[#statuses + 1] = msg end)
    local w = newWidget(ns)
    w:Update()
    leavePage()
    click(w)
    T.eq(ns.Flip.State(BAG), "finding")
    ns.Flip.Tick(5)
    T.eq(ns.Flip.State(BAG), "finding", "10 s have not passed")
    local before = #changes
    ns.Flip.Tick(5.1)
    T.eq(ns.Flip.State(BAG), "idle")
    T.eq(#changes, before + 1, "the widgets are told")
    T.eq(statuses[#statuses], "Couldn't find it - try again")
    T.eq(w.button:GetText(), "Buy it (50g)")
    T.eq(w.button:IsEnabled(), true, "the player can retry")
    T.ok(has(w.notice:GetText(), "Couldn't find it - try again"), w.notice:GetText())
    T.eq(#Mock.bought, 0, "Tick never buys")
    -- A late answer after the timeout changes nothing.
    answer(ns)
    T.eq(ns.Flip.State(BAG), "idle")
    -- And another click searches again.
    Mock.queries = {}
    leavePage()
    click(w)
    T.eq(ns.Flip.State(BAG), "finding")
    T.eq(#Mock.queries, 1)
  end,

  tick_without_waiting_states_does_nothing = function(T)
    local ns = setup()
    local changes = recordChanges(ns)
    ns.Flip.Tick(100)
    T.eq(#changes, 0)
    ns.Flip.Buy(BAG, BAG_NAME)                  -- bought
    ns.Flip.Tick(100)
    T.eq(ns.Flip.State(BAG), "bought")
    T.eq(#Mock.bought, 1)
  end,

  reset_clears_states = function(T)
    local ns = setup()
    local w = newWidget(ns)
    w:Update()
    leavePage()
    click(w)
    T.eq(ns.Flip.State(BAG), "finding")
    ns.Flip.Reset()                              -- the AH was closed
    T.eq(ns.Flip.State(BAG), "idle")
    T.eq(w.button:GetText(), "Buy it (50g)", "widget redrawn")
    T.eq(w.button:IsEnabled(), true)
    ns.Flip.Tick(100)
    T.eq(ns.Flip.State(BAG), "idle", "no timeout message afterwards")
    answer(ns)
    T.eq(ns.Flip.State(BAG), "idle", "a late answer is ignored")

    -- ready and gone go too; "bought" stays (see reset_keeps_bought).
    local ready = setup()
    leavePage()
    ready.Flip.Buy(BAG, BAG_NAME)
    answer(ready)
    T.eq(ready.Flip.State(BAG), "ready")
    ready.Flip.Reset()
    T.eq(ready.Flip.State(BAG), "idle")

    local gone = setup()
    Mock.ah.auctions[1].buyout = gold(60)
    leavePage()
    gone.Flip.Buy(BAG, BAG_NAME)
    answer(gone)
    T.eq(gone.Flip.State(BAG), "gone")
    gone.Flip.Reset()
    T.eq(gone.Flip.State(BAG), "idle")
  end,

  -- T6: the AH closes after the purchase. Opening it again must not offer the
  -- same stack once more (the bid went through, only the check did not finish).
  reset_keeps_bought = function(T)
    local ns = setup({
      auction("Flipper", 1, gold(50)),
      auction("Flipper", 1, gold(50)),
      auction("Bob", 1, gold(420)),
      auction("Carl", 1, gold(430)),
    })
    local changes = recordChanges(ns)
    local w = newWidget(ns)
    w:Update()
    click(w)
    T.eq(#Mock.bought, 1)
    T.eq(ns.Flip.State(BAG), "bought")
    local before = #changes

    ns.Flip.Reset()                              -- the AH was closed
    T.eq(ns.Flip.State(BAG), "bought", "still bought")
    T.eq(#changes, before, "nothing changed for the widgets")
    w:Update()
    T.eq(w.button:GetText(), "Bought")
    T.eq(w.button:IsEnabled(), false)
    T.ok(has(w.notice:GetText(), "Bid placed for 50g"), w.notice:GetText())

    click(w)
    T.eq(#Mock.bought, 1, "no second stack")
    local ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, false)
    T.eq(msg, "Already bought")
    T.eq(#Mock.bought, 1)

    -- A fresh price check (after the AH opens again) replaces the rows.
    T.ok(Mock.pump(ns))
    T.eq(ns.Flip.State(BAG), "idle")
    T.eq(w.button:GetText(), "Buy it (50g)")
  end,

  stale_identical_page_does_not_say_gone = function(T)
    local ns = setup()
    local function elsewhere()                   -- what the player was looking at
      return {
        { id = 999, name = "Other", count = 1, buyout = gold(1), seller = "Zed" },
        { id = 999, name = "Other", count = 3, buyout = gold(9), seller = "Zed" },
      }
    end
    Mock.list, Mock.total = elsewhere(), 2
    T.eq(ns.Flip.Buy(BAG, BAG_NAME), false)
    T.eq(ns.Flip.State(BAG), "finding")
    local answerList, answerTotal = Mock.list, Mock.total

    -- A late update for the page we left arrives first.
    Mock.list, Mock.total = elsewhere(), 2
    ns.Flip.OnListUpdate()
    T.eq(ns.Flip.State(BAG), "finding", "that is the old page, not the answer")
    ns.Flip.Tick(3)
    T.eq(ns.Flip.State(BAG), "finding", "and forcing a decision does not use it either")

    Mock.list, Mock.total = answerList, answerTotal
    ns.Flip.OnListUpdate()
    T.eq(ns.Flip.State(BAG), "ready")
    T.eq(#Mock.bought, 0)
  end,

  gone_can_retry = function(T)
    local ns = setup()
    local w = newWidget(ns)
    w:Update()
    Mock.ah.auctions[1].buyout = gold(60)
    leavePage()
    click(w)
    answer(ns)
    T.eq(ns.Flip.State(BAG), "gone")
    T.eq(w.button:GetText(), "Gone - try again (50g)")
    T.eq(w.button:IsEnabled(), true)

    Mock.queries = {}
    Mock.ah.auctions[1].buyout = gold(50)        -- relisted at the old price
    leavePage()
    click(w)
    T.eq(#Mock.queries, 1, "a new search")
    T.eq(Mock.queries[1][1], BAG_NAME)
    T.eq(ns.Flip.State(BAG), "finding")
    T.eq(#Mock.bought, 0)
    answer(ns)
    T.eq(ns.Flip.State(BAG), "ready")
    T.eq(#Mock.bought, 0)
    click(w)
    T.eq(#Mock.bought, 1)
  end,

  unreadable_rows_decided_after_wait = function(T)
    local ns = setup()
    Mock.ah.auctions[1].buyout = gold(60)        -- Flipper relisted
    Mock.ah.auctions[2].nilLink = true           -- Bob's row never loads
    Mock.list, Mock.total = {}, 0
    ns.Flip.Buy(BAG, BAG_NAME)
    answer(ns)
    T.eq(ns.Flip.State(BAG), "finding", "an unreadable row might be it: wait")
    ns.Flip.OnListUpdate()
    T.eq(ns.Flip.State(BAG), "finding", "more updates do not restart or end the wait")
    ns.Flip.Tick(1)
    T.eq(ns.Flip.State(BAG), "finding")
    ns.Flip.Tick(1.1)
    T.eq(ns.Flip.State(BAG), "gone", "after 2 s only the readable rows count")
    T.eq(#Mock.bought, 0)
  end,

  unreadable_rows_do_not_hide_the_listing = function(T)
    local ns = setup()
    Mock.ah.auctions[2].nilLink = true           -- Bob's row never loads
    leavePage()
    ns.Flip.Buy(BAG, BAG_NAME)
    answer(ns)
    T.eq(ns.Flip.State(BAG), "ready", "the exact row is readable: no need to wait")
    T.eq(#Mock.bought, 0)
  end,

  click_refuses_when_shown_row_changed = function(T)
    local ns = setup()
    -- A second item with a mistake listing of its own.
    local ROBE = 41600
    local function robe(seller, buyout)
      return { id = ROBE, name = "Frostweave Robe", count = 1, buyout = buyout, seller = seller }
    end
    local auctions = Mock.ah.auctions
    auctions[#auctions + 1] = robe("RobeFlipper", gold(50))
    auctions[#auctions + 1] = robe("Dan", gold(420))
    auctions[#auctions + 1] = robe("Eve", gold(430))
    Mock.items[ROBE] = { name = "Frostweave Robe" }
    assert(ns.Scanner.PriceCheck({ id = ROBE, name = "Frostweave Robe" }))
    assert(Mock.pump(ns))
    T.ok(ns.Flip.Info(ROBE), "robe flip found")
    Mock.queries = {}

    local shown, shownName = BAG, BAG_NAME
    local statuses = {}
    ns.On("PAGE_STATUS", function(msg) statuses[#statuses + 1] = msg end)
    local w = ns.Flip.CreateWidget(UIParent, function() return shown, shownName end)
    w:Update()

    -- The page switched item and did not redraw the widget.
    shown, shownName = ROBE, "Frostweave Robe"
    Mock.list, Mock.total = {}, 0
    click(w)
    T.eq(#Mock.bought, 0, "nothing bought")
    T.eq(#Mock.queries, 0, "nothing searched")
    T.eq(statuses[#statuses], "Listing changed - check again")
    T.eq(w.button:GetText(), "Buy it (50g)", "the widget caught up with the shown item")
    T.ok(has(w.notice:GetText(), "RobeFlipper"), w.notice:GetText())
    T.ok(has(w.notice:GetText(), "Listing changed - check again"))

    -- Same item, but the rows were replaced without anyone telling the widget.
    shown, shownName = BAG, BAG_NAME
    w:Update()
    statuses = {}
    local fresh = ns.Listings.Normalize({
      { count = 1, buyout = gold(50), seller = "Flipper", page = 0, index = 1 },
      { count = 1, buyout = gold(420), seller = "Bob", page = 0, index = 2 },
      { count = 1, buyout = gold(430), seller = "Carl", page = 0, index = 3 },
    }, ns.Listings.MineSet(), ns.Listings.Ratio())
    ns.Listings.cache[BAG] = { t = ns.Now(), rows = fresh }
    Mock.list, Mock.total = Mock.ah.auctions, #Mock.ah.auctions
    click(w)
    T.eq(#Mock.bought, 0, "the row on screen is not the row that would be bought")
    T.eq(statuses[#statuses], "Listing changed - check again")
    -- Now what is shown is current: a click works.
    click(w)
    T.eq(#Mock.bought, 1)
  end,

  click_refuses_without_a_drawn_row = function(T)
    local ns = setup()
    local w = newWidget(ns)                      -- never drawn
    click(w)
    T.eq(#Mock.bought, 0)
    T.eq(#Mock.queries, 0)
  end,

  page_status_carries_every_buy_message = function(T)
    local ns = setup()
    local statuses = {}
    ns.On("PAGE_STATUS", function(msg) statuses[#statuses + 1] = msg end)

    Mock.money = 1
    local _, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(msg, "Not enough gold")
    T.eq(statuses[#statuses], "Not enough gold")

    Mock.money = gold(1000)
    leavePage()
    _, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(statuses[#statuses], "Finding it...")
    answer(ns)

    _, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(msg, "Bid placed for 50g")
    T.eq(statuses[#statuses], "Bid placed for 50g")

    _, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(msg, "Already bought")
    T.eq(statuses[#statuses], "Already bought")
    T.eq(#statuses, 4)
  end,

  page_status_for_gone_and_busy = function(T)
    local ns = setup()
    local statuses = {}
    ns.On("PAGE_STATUS", function(msg) statuses[#statuses + 1] = msg end)
    Mock.ah.auctions[1].buyout = gold(60)
    leavePage()
    ns.Flip.Buy(BAG, BAG_NAME)
    answer(ns)
    T.eq(statuses[#statuses], "That listing is gone.")
    ns.Scanner.PriceCheck(ITEM)                  -- scanner busy
    local ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(statuses[#statuses], msg)
    T.ok(has(msg, "busy"))
  end,

  buy_needs_the_item_name = function(T)
    local ns = setup()
    local ok, msg = ns.Flip.Buy(BAG, nil)        -- cannot search or re-check without it
    T.eq(ok, false)
    T.ok(msg and msg ~= "")
    T.eq(#Mock.bought, 0, "no bid we cannot follow up")
    T.eq(#Mock.queries, 0)
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
  -- I2: the button spends the whole stack, so it says so in every state that
  -- can spend.
  widget_labels_carry_the_stack_total = function(T)
    local ns = setup({
      auction("Flipper", 20, gold(100)),         -- 5g each, 100g for the stack
      auction("Bob", 1, gold(420)),
      auction("Carl", 1, gold(430)),
    })
    local w = newWidget(ns)
    w:Update()
    T.eq(w.button:GetText(), "Buy it (100g)")
    T.eq(w.button:IsEnabled(), true)
    T.ok(has(w.notice:GetText(), "sells 20 at 5g"), w.notice:GetText())

    leavePage()
    click(w)
    T.eq(w.button:GetText(), "Finding it...")
    T.eq(w.button:IsEnabled(), false)
    answer(ns)
    T.eq(w.button:GetText(), "Buy now (100g)")

    -- gone: the player may search again, and knows what the next click costs
    local gone = setup({
      auction("Flipper", 20, gold(100)),
      auction("Bob", 1, gold(420)),
      auction("Carl", 1, gold(430)),
    })
    local g = newWidget(gone)
    g:Update()
    Mock.ah.auctions[1].buyout = gold(110)
    leavePage()
    click(g)
    answer(gone)
    T.eq(gone.Flip.State(BAG), "gone")
    T.eq(g.button:GetText(), "Gone - try again (100g)")
    T.eq(g.button:IsEnabled(), true)
    T.eq(#Mock.bought, 0)

    -- the amount it names is what a click on the loaded page spends
    local buy = setup({
      auction("Flipper", 20, gold(100)),
      auction("Bob", 1, gold(420)),
      auction("Carl", 1, gold(430)),
    })
    local b = newWidget(buy)
    b:Update()
    local money = Mock.money
    click(b)
    T.eq(money - Mock.money, gold(100))
    T.eq(b.button:GetText(), "Bought")
  end,

  -- M2: the client refreshes the list after a buyout. A scan waiting for its
  -- answer would read that refresh as the answer.
  buy_makes_a_waiting_scan_send_its_query_again = function(T)
    local ns = setup()
    local page, total = Mock.list, Mock.total
    T.ok(ns.Scanner.StartTargeted({ { id = OTHER_ITEM, name = "Glacial Bag" } }, { collect = true }))
    ns.Scanner.Tick(0.1)
    T.eq(#Mock.queries, 1, "the scan's query is out")
    T.eq(Mock.queries[1][1], "Glacial Bag")
    -- until the answer comes, the client still shows the bag page
    Mock.list, Mock.total, Mock.pending = page, total, false

    local ok = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, true)
    T.eq(#Mock.bought, 1)

    -- the refresh after the buyout
    ns.Scanner.HandleEvent("AUCTION_ITEM_LIST_UPDATE")
    T.eq(ns.Scanner.IsBusy(), true, "the scan did not take the refresh for its answer")
    T.eq(ns.Listings.Get(OTHER_ITEM), nil)
    ns.Scanner.Tick(0.1)
    T.eq(#Mock.queries, 2, "the query was sent again")
    T.eq(Mock.queries[2][1], "Glacial Bag")
    -- and its real answer finishes the scan
    T.ok(Mock.pump(ns))
    T.ok(ns.Listings.Get(OTHER_ITEM), "the scan finished with its own answer")

    -- an idle scanner stays idle
    local idle = setup()
    idle.Flip.Buy(BAG, BAG_NAME)
    T.eq(#Mock.queries, 0, "nothing sent by the buy itself")
  end,
  -- I5: a "mistake" among random-suffix variants is another variant, not a flip.
  info_nil_for_random_suffix_variants = function(T)
    local function variant(seller, buyout, suffix)
      local a = auction(seller, 1, buyout)
      a.suffix = suffix
      return a
    end
    local ns = setup({
      variant("Bob", gold(50), -9),            -- of the Monkey
      variant("Kim", gold(52), -9),
      variant("Al", gold(300), -40),           -- of the Bear
    })
    local rows = ns.Listings.Get(BAG)
    T.eq(#rows, 3)
    T.eq(rows[1].outlier, true, "the rows do look like a mistake by price alone")
    T.eq(ns.Flip.Info(BAG), nil, "but no flip is offered")
    T.eq(ns.Flip.State(BAG), "idle")
    local w = newWidget(ns)
    w:Update()
    T.eq(w.frame:IsShown(), false)
    local ok, msg = ns.Flip.Buy(BAG, BAG_NAME)
    T.eq(ok, false)
    T.eq(msg, "No mistake listing to buy.")
    T.eq(#Mock.bought, 0)

    -- one variant on its own is not the plain item either
    local one = setup({ variant("Flipper", gold(50), -9), auction("Bob", 1, gold(420)), auction("Carl", 1, gold(430)) })
    T.eq(one.Flip.Info(BAG), nil)

    -- plain rows are unchanged
    T.ok(setup().Flip.Info(BAG), "the standard flip is still found")
  end,
}
