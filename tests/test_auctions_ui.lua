local Mock = require("wow_mock")

local REALM = "Icecrown-Alliance"
local BAG, BAG_NAME = 41599, "Frostweave Bag"
local CLOTH, CLOTH_NAME = 33470, "Frostweave Cloth"
local DUST, DUST_NAME = 22445, "Arcane Dust"
local ORE, ORE_NAME = 36912, "Saronite Ore"
local EBON, EBON_NAME = 41595, "Ebonweave"

local MAILBOX = "Collect it from your mailbox first."
local WAIT_LIST = "Waiting for the auction list to update..."
local WAIT_SCAN = "Waiting for the current scan..."
local NO_ACTIVE = "You have no active auctions."
local BAD = "|cffff4040"

local function gold(g, s, c) return g * 10000 + (s or 0) * 100 + (c or 0) end

-- A fresh namespace with the tabs built (CP Sell is tab 4, CP Auctions tab 5).
-- The player is "Me" and has been warned about cancelling (pass
-- { unwarned = true } for the very first cancel).
local function setup(opts)
  opts = opts or {}
  Mock.reset()
  Mock.installUI()
  local ns = Mock.load({
    "Util.lua", "Profit.lua", "Prices.lua", "Recipes.lua", "Scanner.lua", "Listings.lua",
    "UI.lua", "ListingsUI.lua", "Tabs.lua", "Flip.lua", "Sell.lua", "Auctions.lua", "AuctionsUI.lua",
  })
  local db = { cut = 0.05 }
  if not opts.unwarned then db.cancelWarned = true end
  ns.db = db
  ns.Prices.SetDB(db, REALM)
  ns.Recipes.SetDB({})
  ns.Scanner.SetDB(db)
  ns.Listings.SetDB(db, REALM, "Me")
  ns.Sell.SetDB(db)
  ns.Auctions.SetDB(db)
  hooksecurefunc("QueryAuctionItems", ns.Scanner.OnQuery)
  Mock.items[BAG] = { name = BAG_NAME }
  Mock.items[CLOTH] = { name = CLOTH_NAME, maxStack = 20 }
  Mock.items[DUST] = { name = DUST_NAME }
  Mock.items[ORE] = { name = ORE_NAME }
  Mock.items[EBON] = { name = EBON_NAME }
  assert(ns.Tabs.Ensure())
  return ns, db
end

local function click(frame)
  frame:GetScript("OnClick")(frame)
end

-- The player clicks one of the tabs.
local function openAuctions() click(AuctionFrameTab5) end
local function openSell() click(AuctionFrameTab4) end
local function openBrowse() click(AuctionFrameTab1) end

-- One of the player's auctions as the owner list holds it.
local function owned(id, name, buyout, extra)
  local a = { id = id, name = name, count = 1, buyout = buyout }
  for key, value in pairs(extra or {}) do a[key] = value end
  return a
end

local function bagAuction(buyout, extra) return owned(BAG, BAG_NAME, buyout, extra) end

-- A raw price-check row.
local function row(seller, buyout, count)
  return { count = count or 1, buyout = buyout, seller = seller }
end

-- Store the price check of `id` the way the scanner does.
local function cache(ns, id, raw)
  local rows = ns.Listings.Normalize(raw, ns.Listings.MineSet(), ns.Listings.Ratio())
  ns.Listings.Store(id, rows)
end

-- Ask for the owner list and answer every request until nothing is pending.
local function readAll(ns)
  ns.Auctions.Refresh()
  local answers = 0
  while Mock.deliverOwned(ns) do
    answers = answers + 1
    assert(answers < 20, "owner list never settled")
  end
end

-- Five items, one of each kind. The list reads (undercut items first, then by name):
--   Frostweave Bag   1 active + 1 sold  undercut by Bob (10g)
--   Arcane Dust      tied with Bob
--   Ebonweave        never checked
--   Frostweave Cloth cheapest, with a mistake listing by Flipper
--   Saronite Ore     only a sold auction
local function fiveItems(ns)
  Mock.owned = {
    bagAuction(gold(420), { texture = "bagtex" }),
    bagAuction(gold(430), { sold = true }),
    owned(CLOTH, CLOTH_NAME, gold(30)),
    owned(DUST, DUST_NAME, gold(5)),
    owned(ORE, ORE_NAME, gold(50), { sold = true }),
    owned(EBON, EBON_NAME, gold(70)),
  }
  cache(ns, BAG, { row("Me", gold(420)), row("Bob", gold(410)) })
  cache(ns, CLOTH, { row("Me", gold(30)), row("Flipper", gold(1)), row("Bob", gold(40)) })
  cache(ns, DUST, { row("Me", gold(5)), row("Bob", gold(5)) })
  readAll(ns)
end

-- Three bags: two at 420g and one at 400g, another seller at 410g.
local function bagsUndercutByBob(ns, extra)
  local first, cheap, second = bagAuction(gold(420)), bagAuction(gold(400)), bagAuction(gold(420))
  Mock.owned = { first, cheap, second }
  for _, a in ipairs(extra or {}) do Mock.owned[#Mock.owned + 1] = a end
  cache(ns, BAG, { row("Me", gold(420)), row("Me", gold(420)), row("Me", gold(400)), row("Bob", gold(410)) })
  readAll(ns)
  return first, cheap, second
end

-- The visible list row that shows item `name`.
local function rowOf(ns, name)
  for _, r in ipairs(ns.AuctionsUI.rows) do
    if r:IsShown() and r.name:GetText() == name then return r end
  end
  error("no row for " .. name)
end

local function names(ns)
  local list = {}
  for _, r in ipairs(ns.AuctionsUI.rows) do
    if r:IsShown() then list[#list + 1] = r.name:GetText() end
  end
  return table.concat(list, "|")
end

-- Count the calls the page makes into Auctions (the page must call through the
-- ns.Auctions table so this sees them).
local function countCalls(ns)
  local calls = { CancelUndercut = 0, CancelNextUndercut = 0, Undercut = 0, CheckUndercuts = 0 }
  local args = {}
  for name in pairs(calls) do
    local original = ns.Auctions[name]
    ns.Auctions[name] = function(...)
      calls[name] = calls[name] + 1
      args[name] = (...)
      return original(...)
    end
  end
  return calls, args
end

return {
  build_and_refresh_on_show = function(T)
    local ns = setup()
    local created = 0
    local create = CreateFrame
    CreateFrame = function(kind, name, ...)
      if name == "CraftProfitCheckUndercuts" then created = created + 1 end
      return create(kind, name, ...)
    end

    T.eq(CraftProfitCheckUndercuts, nil, "nothing is built before the page is shown")
    ns.AuctionsUI.Update()   -- harmless before the build
    ns.Fire("PAGE_SHOWN", "sell")
    T.eq(CraftProfitCheckUndercuts, nil, "the other page does not build ours")
    T.eq(#Mock.ownerRequests, 0, "nor does it ask for the owner list")

    Mock.owned = { bagAuction(gold(420)) }
    openAuctions()
    local page = ns.Tabs.Page("auctions")
    T.eq(created, 1)
    T.eq(CraftProfitCheckUndercuts._parent, page)
    T.eq(CraftProfitCheckUndercuts._template, "UIPanelButtonTemplate")
    T.eq(CraftProfitCancelNext._parent, page)
    T.eq(CraftProfitCancelUndercut._parent, page)
    T.eq(CraftProfitUndercutButton._parent, page)
    T.eq(ns.AuctionsUI.listings.frame._parent, page)
    T.eq(ns.AuctionsUI.flip.frame._parent, page)
    T.eq(#ns.AuctionsUI.rows, 12, "twelve list rows")
    T.eq(#Mock.ownerRequests, 1, "the owner list is asked for when the page opens")
    T.eq(Mock.ownerRequests[1], 0)

    -- the answer fills the list
    T.ok(Mock.deliverOwned(ns))
    T.eq(names(ns), BAG_NAME)

    -- shown again: built once, asked again
    local button = CraftProfitCheckUndercuts
    openBrowse()
    openAuctions()
    ns.Fire("PAGE_SHOWN", "auctions")
    ns.AuctionsUI.Build()
    T.eq(created, 1, "built once")
    T.eq(CraftProfitCheckUndercuts, button)
    T.eq(#Mock.ownerRequests, 3, "every show asks again")
  end,

  events_before_the_build_are_harmless = function(T)
    local ns = setup()
    ns.Fire("AUCTIONS_CHANGED")
    ns.Fire("LISTINGS_UPDATED", BAG)
    ns.Fire("SCAN_FINISHED")
    ns.Fire("SCAN_STATUS", "Scanning")
    ns.Fire("PAGE_STATUS", "early")
    ns.Fire("PAGE_ERROR", "early")
    ns.AuctionsUI.Update()
    T.eq(CraftProfitCheckUndercuts, nil)
    T.eq(ns.AuctionsUI.status, nil)
  end,

  status_texts = function(T)
    local ns = setup()
    openAuctions()
    fiveItems(ns)
    local Util = ns.Util
    local FLIP = Util.ICON_GOLD .. " flip"

    T.eq(names(ns), BAG_NAME .. "|" .. DUST_NAME .. "|" .. EBON_NAME .. "|" .. CLOTH_NAME .. "|" .. ORE_NAME)
    T.eq(rowOf(ns, BAG_NAME).status:GetText(), Util.ICON_WARN .. " undercut 10g (Bob)")
    T.eq(rowOf(ns, DUST_NAME).status:GetText(), Util.ICON_WARN .. " tied")
    T.eq(rowOf(ns, EBON_NAME).status:GetText(), "-")
    T.eq(rowOf(ns, CLOTH_NAME).status:GetText(), Util.ICON_OK .. " cheapest")
    T.eq(rowOf(ns, ORE_NAME).status:GetText(), "sold")

    -- the flip marker has a cell of its own, empty on rows without a flip
    T.eq(rowOf(ns, CLOTH_NAME).flip:GetText(), FLIP)
    T.eq(rowOf(ns, BAG_NAME).flip:GetText(), "")
    T.eq(rowOf(ns, DUST_NAME).flip:GetText(), "")
    T.eq(rowOf(ns, EBON_NAME).flip:GetText(), "")
    T.eq(rowOf(ns, ORE_NAME).flip:GetText(), "")

    -- yours: the active count, and the sold ones next to it
    T.eq(rowOf(ns, BAG_NAME).yours:GetText(), "1 (+1 sold)")
    T.eq(rowOf(ns, DUST_NAME).yours:GetText(), "1")
    T.eq(rowOf(ns, ORE_NAME).yours:GetText(), "0 (+1 sold)")
    T.eq(rowOf(ns, BAG_NAME).icon._texture, "bagtex")

    -- an undercutter whose name has not loaded
    cache(ns, DUST, { row("Me", gold(5)), { count = 1, buyout = gold(4) } })
    T.eq(rowOf(ns, DUST_NAME).status:GetText(), Util.ICON_WARN .. " undercut 1g (?)")

    -- an undercut item that is also a flip: the status text is the same, the cell fills
    cache(ns, BAG, { row("Me", gold(420)), row("Flipper", gold(1)), row("Bob", gold(410)) })
    T.eq(rowOf(ns, BAG_NAME).status:GetText(), Util.ICON_WARN .. " undercut 10g (Bob)")
    T.eq(rowOf(ns, BAG_NAME).flip:GetText(), FLIP)

    -- a row that scrolls to another item takes its own flip state with it
    cache(ns, BAG, { row("Me", gold(420)), row("Bob", gold(410)) })
    T.eq(rowOf(ns, BAG_NAME).flip:GetText(), "")
  end,

  flip_marker_has_its_own_cell = function(T)
    local ns = setup()
    -- remember the widths the page gives its frames and texts
    local create = CreateFrame
    local function remember(o) o.SetWidth = function(self, w) self._width = w end end
    CreateFrame = function(...)
      local f = create(...)
      remember(f)
      local createText = f.CreateFontString
      f.CreateFontString = function(self, ...)
        local fs = createText(self, ...)
        remember(fs)
        return fs
      end
      return f
    end
    openAuctions()
    local Util = ns.Util
    Mock.owned = { bagAuction(gold(420)) }
    readAll(ns)
    -- the longest row there is: undercut, a 12-letter seller, a flip
    cache(ns, BAG, { row("Me", gold(420)), row("Flipper", gold(1)), row("Characternam", gold(410)) })
    local r = rowOf(ns, BAG_NAME)
    T.eq(r.status:GetText(), Util.ICON_WARN .. " undercut 10g (Characternam)")
    T.eq(r.flip:GetText(), Util.ICON_GOLD .. " flip")
    T.eq(r.flip:IsShown(), true)
    T.ok(not r.status:GetText():find("flip", 1, true), "the status text never carries the marker")

    -- the cell sits at the right end of the row, apart from the status text
    T.eq(r.flip._points[1].point, "RIGHT")
    T.eq(r.flip._points[1].rel, r)
    T.eq(r.flip._points[1].relPoint, "RIGHT")
    T.eq(r.status._points[1].point, "LEFT")

    -- and the status text ends before the cell starts: it clips, the marker never does
    T.ok(r._width and r.flip._width and r.status._width, "widths were set")
    T.ok(r.flip._width >= 36, "room for the icon and the word")
    T.ok(r.status._points[1].x + r.status._width <= r._width - r.flip._width,
      "the status text stops where the flip cell begins")
  end,

  row_status_never_carries_an_age = function(T)
    local ns = setup()
    openAuctions()
    fiveItems(ns)
    local Util = ns.Util
    local page = ns.Tabs.Page("auctions")
    local function plain()
      T.eq(rowOf(ns, BAG_NAME).status:GetText(), Util.ICON_WARN .. " undercut 10g (Bob)")
      T.eq(rowOf(ns, DUST_NAME).status:GetText(), Util.ICON_WARN .. " tied")
      T.eq(rowOf(ns, CLOTH_NAME).status:GetText(), Util.ICON_OK .. " cheapest")
      T.eq(rowOf(ns, EBON_NAME).status:GetText(), "-")
      T.eq(rowOf(ns, ORE_NAME).status:GetText(), "sold")
    end
    plain()
    Mock.now = Mock.now + 5 * 60
    ns.AuctionsUI.Update()
    plain()
    Mock.now = Mock.now + 2 * 3600
    page:GetScript("OnUpdate")(page, 16)
    plain()
  end,

  title_shows_the_check_age = function(T)
    local ns = setup()
    openAuctions()
    fiveItems(ns)
    local ui = ns.AuctionsUI
    local page = ns.Tabs.Page("auctions")
    local title = ui.listings.title

    -- nothing picked: no title
    T.eq(title:GetText(), "")

    -- a check just made
    click(rowOf(ns, BAG_NAME))
    T.eq(title:GetText(), BAG_NAME .. ": all listings (checked now)")

    -- the title ages with the page open, 15 s at a time, with no other event
    Mock.now = Mock.now + 5 * 60
    ns.Fire("PAGE_STATUS", "unrelated")
    T.eq(title:GetText(), BAG_NAME .. ": all listings (checked now)", "no event redraws it")
    page:GetScript("OnUpdate")(page, 15)
    T.eq(title:GetText(), BAG_NAME .. ": all listings (checked 5m ago)")
    Mock.now = Mock.now + 2 * 3600
    page:GetScript("OnUpdate")(page, 15)
    T.eq(title:GetText(), BAG_NAME .. ": all listings (checked 2h ago)")

    -- an item nobody checked has just its name, until the search answers
    Mock.ah.auctions = {
      { id = EBON, name = EBON_NAME, count = 1, buyout = gold(60), seller = "Bob" },
    }
    click(rowOf(ns, EBON_NAME))
    T.eq(title:GetText(), EBON_NAME .. ": all listings")
    T.ok(Mock.pump(ns))
    T.eq(title:GetText(), EBON_NAME .. ": all listings (checked now)")

    -- an old check the click searches again starts from "now"
    click(rowOf(ns, BAG_NAME))
    T.ok(Mock.pump(ns))
    T.eq(title:GetText(), BAG_NAME .. ": all listings (checked now)")

    -- picking nothing clears it
    ns.Auctions.Select(nil)
    T.eq(title:GetText(), "")
  end,

  oldest_check_line = function(T)
    local ns = setup()
    openAuctions()
    local ui = ns.AuctionsUI
    local page = ns.Tabs.Page("auctions")
    local line = ui.oldest
    T.eq(line:GetText(), "", "nothing to cancel, nothing to say")

    Mock.owned = { bagAuction(gold(420)), owned(CLOTH, CLOTH_NAME, gold(50)), owned(DUST, DUST_NAME, gold(5)) }
    readAll(ns)
    T.eq(line:GetText(), "", "never checked")

    -- the dust is checked first and is not undercut: its age does not count
    cache(ns, DUST, { row("Me", gold(5)), row("Bob", gold(6)) })
    T.eq(line:GetText(), "")
    Mock.now = Mock.now + 10 * 60
    cache(ns, CLOTH, { row("Me", gold(50)), row("Bob", gold(40)) })
    T.eq(line:GetText(), "Oldest check: now", "one undercut item, just checked")
    Mock.now = Mock.now + 10 * 60
    cache(ns, BAG, { row("Me", gold(420)), row("Bob", gold(410)) })
    T.eq(ns.Auctions.CountAllUndercut(), 2)
    T.eq(line:GetText(), "Oldest check: 10m ago", "the cloth, not the 20 minutes of the dust")

    -- it ages with the page open
    Mock.now = Mock.now + 5 * 60
    T.eq(line:GetText(), "Oldest check: 10m ago", "no event redraws it")
    page:GetScript("OnUpdate")(page, 15)
    T.eq(line:GetText(), "Oldest check: 15m ago")

    -- checking the cloth again makes the bag the oldest
    cache(ns, CLOTH, { row("Me", gold(50)), row("Bob", gold(40)) })
    T.eq(line:GetText(), "Oldest check: 5m ago")

    -- no undercut left to cancel: nothing to say
    Mock.owned = { owned(DUST, DUST_NAME, gold(5)) }
    readAll(ns)
    T.eq(ns.Auctions.CountAllUndercut(), 0)
    T.eq(line:GetText(), "")
  end,

  ages_tick_without_events = function(T)
    local ns = setup()
    openAuctions()
    fiveItems(ns)
    local Util = ns.Util
    local page = ns.Tabs.Page("auctions")
    local onUpdate = page:GetScript("OnUpdate")
    T.ok(onUpdate, "the page redraws itself now and then")
    local ui = ns.AuctionsUI
    click(rowOf(ns, BAG_NAME))
    local title, line = ui.listings.title, ui.oldest
    local changedEvents = 0
    ns.On("AUCTIONS_CHANGED", function() changedEvents = changedEvents + 1 end)
    local BAG_NOW = BAG_NAME .. ": all listings (checked now)"

    -- the player reads the page for five minutes; no event comes
    T.eq(title:GetText(), BAG_NOW)
    T.eq(line:GetText(), "Oldest check: now")
    Mock.now = Mock.now + 5 * 60
    onUpdate(page, 14)
    T.eq(title:GetText(), BAG_NOW, "not before 15 s")
    T.eq(line:GetText(), "Oldest check: now")
    onUpdate(page, 2)
    T.eq(title:GetText(), BAG_NAME .. ": all listings (checked 5m ago)")
    T.eq(line:GetText(), "Oldest check: 5m ago")
    T.eq(changedEvents, 0, "a plain redraw")

    -- and again, 15 s at a time (small frames add up)
    Mock.now = Mock.now + 60
    for _ = 1, 10 do onUpdate(page, 1) end
    T.eq(title:GetText(), BAG_NAME .. ": all listings (checked 5m ago)", "10 s so far")
    for _ = 1, 5 do onUpdate(page, 1) end
    T.eq(title:GetText(), BAG_NAME .. ": all listings (checked 6m ago)")
    T.eq(line:GetText(), "Oldest check: 6m ago")

    -- the rows were redrawn too, and they stay plain
    T.eq(rowOf(ns, BAG_NAME).status:GetText(), Util.ICON_WARN .. " undercut 10g (Bob)")
  end,

  hidden_page_ignores_the_tick = function(T)
    local ns = setup()
    openAuctions()
    fiveItems(ns)
    local page = ns.Tabs.Page("auctions")
    local onUpdate = page:GetScript("OnUpdate")
    local ui = ns.AuctionsUI
    click(rowOf(ns, BAG_NAME))
    local title, line = ui.listings.title, ui.oldest
    local BAG_NOW = BAG_NAME .. ": all listings (checked now)"
    T.eq(title:GetText(), BAG_NOW)

    Mock.now = Mock.now + 10 * 60
    openBrowse()
    onUpdate(page, 60)
    T.eq(title:GetText(), BAG_NOW, "another tab is shown")
    T.eq(line:GetText(), "Oldest check: now")
    openAuctions()
    T.eq(title:GetText(), BAG_NAME .. ": all listings (checked 10m ago)", "showing it redraws")
    T.eq(line:GetText(), "Oldest check: 10m ago")

    -- the Auction House closed on this tab
    Mock.now = Mock.now + 10 * 60
    AuctionFrame:Hide()
    onUpdate(page, 60)
    T.eq(title:GetText(), BAG_NAME .. ": all listings (checked 10m ago)", "the AH is closed")
    T.eq(line:GetText(), "Oldest check: 10m ago")
    AuctionFrame:Show()
    onUpdate(page, 60)
    T.eq(title:GetText(), BAG_NAME .. ": all listings (checked 20m ago)")
    T.eq(line:GetText(), "Oldest check: 20m ago")
  end,

  empty_message = function(T)
    local ns = setup()
    openAuctions()
    local ui = ns.AuctionsUI
    T.eq(ui.empty:IsShown(), true)
    T.eq(ui.empty:GetText(), "You have no auctions.")
    T.eq(names(ns), "")

    Mock.owned = { bagAuction(gold(420)) }
    readAll(ns)
    T.eq(ui.empty:IsShown(), false)
    T.eq(names(ns), BAG_NAME)

    Mock.owned = {}
    readAll(ns)
    T.eq(ui.empty:IsShown(), true)
    T.eq(names(ns), "")
  end,

  row_click_selects_and_shows_listings = function(T)
    local ns = setup()
    openAuctions()
    fiveItems(ns)
    local ui = ns.AuctionsUI
    local Util = ns.Util
    T.eq(ns.Auctions.Selected(), nil)
    T.eq(ui.listings.title:GetText(), "")
    T.eq(#ui.listings.rows, 0)
    for _, r in ipairs(ui.rows) do T.eq(r.selected:IsShown(), false) end

    -- a check younger than a minute is shown without a new search
    click(rowOf(ns, BAG_NAME))
    T.eq(ns.Auctions.Selected(), BAG)
    T.eq(#Mock.queries, 0)
    T.eq(ui.listings.title:GetText(), BAG_NAME .. ": all listings (checked now)")
    T.eq(#ui.listings.rows, 2)
    local lines = ui.listings.lines
    T.eq(lines[1].seller:GetText(), "Bob")
    T.eq(lines[1].note:GetText(), BAD .. Util.ICON_WARN .. " under you|r")
    T.eq(lines[2].seller:GetText(), "YOU")
    T.eq(lines[2].note:GetText(), "")
    T.eq(rowOf(ns, BAG_NAME).selected:IsShown(), true, "the picked row is marked")
    T.eq(rowOf(ns, DUST_NAME).selected:IsShown(), false)

    -- an item nobody looked at is searched; the table follows the answer
    Mock.ah.auctions = {
      { id = EBON, name = EBON_NAME, count = 1, buyout = gold(80), seller = "Me" },
      { id = EBON, name = EBON_NAME, count = 1, buyout = gold(60), seller = "Bob" },
    }
    click(rowOf(ns, EBON_NAME))
    T.eq(ns.Auctions.Selected(), EBON)
    T.eq(ui.listings.title:GetText(), EBON_NAME .. ": all listings")
    T.eq(#ui.listings.rows, 0, "nothing to show before the search answers")
    T.eq(ui.status:GetText(), "Scanning 1/1: " .. EBON_NAME)
    T.ok(Mock.pump(ns))
    T.eq(#Mock.queries, 1)
    T.eq(#ui.listings.rows, 2)
    T.eq(lines[1].seller:GetText(), "Bob")
    T.eq(lines[2].seller:GetText(), "YOU")

    -- the list reordered itself (it is undercut now); the mark followed the item
    T.eq(rowOf(ns, EBON_NAME).status:GetText(), Util.ICON_WARN .. " undercut 20g (Bob)")
    T.eq(rowOf(ns, EBON_NAME).selected:IsShown(), true)
    T.eq(rowOf(ns, BAG_NAME).selected:IsShown(), false)
    T.eq(names(ns):sub(1, #EBON_NAME), EBON_NAME)
  end,

  cancel_buttons_counts_and_disable = function(T)
    local ns = setup()
    openAuctions()

    -- nothing to act on
    T.eq(CraftProfitCheckUndercuts:GetText(), "Check undercuts")
    T.eq(CraftProfitCheckUndercuts:IsEnabled(), false)
    T.eq(CraftProfitCancelNext:GetText(), "Cancel next undercut (0)")
    T.eq(CraftProfitCancelNext:IsEnabled(), false)
    T.eq(CraftProfitCancelUndercut:GetText(), "Cancel undercut (0)")
    T.eq(CraftProfitCancelUndercut:IsEnabled(), false)
    T.eq(CraftProfitUndercutButton:GetText(), "Undercut")
    T.eq(CraftProfitUndercutButton:IsEnabled(), false)

    -- two bags are undercut, a cloth is not
    local first, _, second = bagsUndercutByBob(ns, { owned(CLOTH, CLOTH_NAME, gold(30)) })
    cache(ns, CLOTH, { row("Me", gold(30)), row("Bob", gold(40)) })
    T.eq(CraftProfitCheckUndercuts:IsEnabled(), true)
    T.eq(CraftProfitCancelNext:GetText(), "Cancel next undercut (2)")
    T.eq(CraftProfitCancelNext:IsEnabled(), true)
    T.eq(CraftProfitCancelUndercut:GetText(), "Cancel undercut (0)")
    T.eq(CraftProfitCancelUndercut:IsEnabled(), false, "no item picked")
    T.eq(CraftProfitUndercutButton:IsEnabled(), false, "no item picked")

    click(rowOf(ns, CLOTH_NAME))
    T.eq(CraftProfitCancelUndercut:GetText(), "Cancel undercut (0)")
    T.eq(CraftProfitCancelUndercut:IsEnabled(), false, "the cloth is the cheapest")
    T.eq(CraftProfitUndercutButton:IsEnabled(), true)
    T.eq(CraftProfitCancelNext:IsEnabled(), true, "the bags still count")

    click(rowOf(ns, BAG_NAME))
    T.eq(CraftProfitCancelUndercut:GetText(), "Cancel undercut (2)")
    T.eq(CraftProfitCancelUndercut:IsEnabled(), true)

    -- one cancel per click, the counts follow the owner list
    click(CraftProfitCancelUndercut)
    T.eq(#Mock.cancelled, 1)
    T.eq(Mock.cancelled[1].auction, first)
    T.ok(Mock.deliverOwned(ns))
    T.eq(CraftProfitCancelUndercut:GetText(), "Cancel undercut (1)")
    T.eq(CraftProfitCancelNext:GetText(), "Cancel next undercut (1)")

    click(CraftProfitCancelNext)
    T.eq(#Mock.cancelled, 2)
    T.eq(Mock.cancelled[2].auction, second)
    T.ok(Mock.deliverOwned(ns))
    T.eq(CraftProfitCancelUndercut:GetText(), "Cancel undercut (0)")
    T.eq(CraftProfitCancelUndercut:IsEnabled(), false)
    T.eq(CraftProfitCancelNext:GetText(), "Cancel next undercut (0)")
    T.eq(CraftProfitCancelNext:IsEnabled(), false)
    T.eq(CraftProfitUndercutButton:IsEnabled(), true, "the bag is still picked")
  end,

  actions_run_only_from_their_buttons = function(T)
    local ns = setup()
    bagsUndercutByBob(ns, { owned(DUST, DUST_NAME, gold(5)) })
    -- what the check will find: the same bags and the dust
    Mock.ah.auctions = {
      { id = BAG, name = BAG_NAME, count = 1, buyout = gold(420), seller = "Me" },
      { id = BAG, name = BAG_NAME, count = 1, buyout = gold(400), seller = "Me" },
      { id = BAG, name = BAG_NAME, count = 1, buyout = gold(420), seller = "Me" },
      { id = BAG, name = BAG_NAME, count = 1, buyout = gold(410), seller = "Bob" },
      { id = DUST, name = DUST_NAME, count = 1, buyout = gold(5), seller = "Me" },
    }
    local calls, args = countCalls(ns)
    openAuctions()

    -- everything that is not a click: events, redraws, selecting, scans
    ns.Fire("PAGE_SHOWN", "auctions")
    ns.Fire("AUCTIONS_CHANGED")
    ns.Fire("LISTINGS_UPDATED", BAG)
    ns.Fire("SCAN_STATUS", "Scanning")
    ns.Fire("SCAN_FINISHED")
    ns.Fire("PAGE_STATUS", "hello")
    ns.Fire("PAGE_ERROR", "oops")
    ns.AuctionsUI.Update()
    local page = ns.Tabs.Page("auctions")
    for _ = 1, 5 do
      Mock.now = Mock.now + 20
      page:GetScript("OnUpdate")(page, 20)     -- the page's own redraw tick
    end
    readAll(ns)
    ns.Auctions.Select(BAG)
    click(rowOf(ns, DUST_NAME))
    T.ok(Mock.pump(ns))
    openBrowse()
    ns.Fire("SCAN_FINISHED")
    page:GetScript("OnUpdate")(page, 100)
    openAuctions()
    page:GetScript("OnUpdate")(page, 100)
    T.eq(calls.CancelUndercut + calls.CancelNextUndercut + calls.Undercut + calls.CheckUndercuts, 0)
    T.eq(#Mock.cancelled, 0, "nothing was cancelled")

    -- each button does its one thing
    click(rowOf(ns, BAG_NAME))
    click(CraftProfitCheckUndercuts)
    T.eq(calls.CheckUndercuts, 1)
    T.ok(Mock.pump(ns))
    click(CraftProfitCancelUndercut)
    T.eq(calls.CancelUndercut, 1)
    T.eq(args.CancelUndercut, BAG, "the picked item")
    T.eq(#Mock.cancelled, 1)
    Mock.now = Mock.now + 10
    click(CraftProfitCancelNext)
    T.eq(calls.CancelNextUndercut, 1)
    T.eq(#Mock.cancelled, 2)
    click(CraftProfitUndercutButton)
    T.eq(calls.Undercut, 1)
    T.eq(args.Undercut, BAG)
    T.eq(calls.CancelUndercut + calls.CancelNextUndercut, 2)
  end,

  popup_confirm_leaves_the_status_line_alone = function(T)
    local ns = setup({ unwarned = true })
    bagsUndercutByBob(ns)
    openAuctions()
    click(rowOf(ns, BAG_NAME))
    click(CraftProfitCancelNext)
    T.eq(Mock.popup, "CRAFTPROFIT_CANCEL")
    T.eq(#Mock.cancelled, 0, "the popup asks first")
    T.eq(ns.AuctionsUI.status:GetText(), "", "the popup speaks")

    click(CraftProfitCancelUndercut)
    T.eq(#Mock.cancelled, 0)
    T.eq(ns.AuctionsUI.status:GetText(), "")

    -- accepting runs the click again
    StaticPopupDialogs["CRAFTPROFIT_CANCEL"].OnAccept(nil, Mock.popupData)
    T.eq(#Mock.cancelled, 1)
  end,

  error_replies_go_on_the_status_line = function(T)
    local ns = setup()
    openAuctions()
    local status = ns.AuctionsUI.status
    T.eq(status:GetText(), "")

    -- nothing to check
    click(CraftProfitCheckUndercuts)
    T.eq(status:GetText(), NO_ACTIVE)

    -- a cancel that goes through takes the old reply away; a second one waits
    -- for the owner list, and the answer clears that note
    bagsUndercutByBob(ns)
    click(rowOf(ns, BAG_NAME))
    click(CraftProfitCancelUndercut)
    T.eq(#Mock.cancelled, 1)
    T.eq(status:GetText(), "")
    click(CraftProfitCancelUndercut)
    T.eq(#Mock.cancelled, 1, "the list is stale: nothing is cancelled")
    T.eq(status:GetText(), WAIT_LIST)
    click(CraftProfitCancelNext)
    T.eq(#Mock.cancelled, 1)
    T.eq(status:GetText(), WAIT_LIST)
    T.ok(Mock.deliverOwned(ns))
    T.eq(status:GetText(), "", "the list is current again")

    -- a check waits for the scan in progress
    T.ok(ns.Scanner.PriceCheck({ id = DUST, name = DUST_NAME }))
    click(CraftProfitCheckUndercuts)
    T.eq(status:GetText(), WAIT_SCAN)
    T.ok(Mock.pump(ns))
    T.eq(status:GetText(), "Scan done: 1 items")

    -- a check that starts shows the scanner's progress
    click(CraftProfitCheckUndercuts)
    T.eq(status:GetText(), "Scanning 1/1: " .. BAG_NAME)
    T.ok(Mock.pump(ns))

    -- Undercut for an item that is not in the bags: Auctions says where it is
    click(CraftProfitUndercutButton)
    T.eq(status:GetText(), MAILBOX)
    T.eq(Mock.lastTab, 5, "no tab switch")
    ns.Fire("PAGE_STATUS", "Bought for 50g")
    T.eq(status:GetText(), "Bought for 50g")
    click(CraftProfitUndercutButton)
    T.eq(status:GetText(), MAILBOX, "the same message again is shown again")

    -- the item goes in the sell slot: CP Sell opens
    Mock.bags[0] = { [1] = { id = BAG, name = BAG_NAME, count = 2 } }
    click(CraftProfitUndercutButton)
    T.eq(ns.Sell.State().item.id, BAG)
    T.eq(Mock.lastTab, 4)

    -- back on this page the last visit's reply is gone
    openAuctions()
    T.eq(status:GetText(), "")
  end,

  busy_select_retries_after_scan = function(T)
    local ns = setup()
    Mock.owned = { bagAuction(gold(420)), owned(DUST, DUST_NAME, gold(5)), owned(CLOTH, CLOTH_NAME, gold(30)) }
    Mock.ah.auctions = {
      { id = BAG, name = BAG_NAME, count = 1, buyout = gold(410), seller = "Bob" },
      { id = DUST, name = DUST_NAME, count = 1, buyout = gold(4), seller = "Bob" },
    }
    openAuctions()
    readAll(ns)
    local ui = ns.AuctionsUI

    -- another page's scan is running when the player picks the bag
    T.ok(ns.Scanner.PriceCheck({ id = DUST, name = DUST_NAME }))
    click(rowOf(ns, BAG_NAME))
    T.eq(ns.Auctions.Selected(), BAG)
    T.eq(ui.status:GetText(), WAIT_SCAN)
    T.eq(#ui.listings.rows, 0)
    T.eq(#Mock.queries, 0)

    -- when the scan ends, the pick is searched
    T.ok(Mock.pump(ns))
    T.eq(#Mock.queries, 2, "the dust, then the bag")
    T.eq(Mock.queries[2][1], BAG_NAME)
    T.eq(#ui.listings.rows, 1)
    T.eq(ui.listings.lines[1].seller:GetText(), "Bob")
    T.eq(ui.status:GetText(), "Scan done: 1 items")

    -- once: the next scan does not search it again
    cache(ns, CLOTH, { row("Me", gold(30)), row("Bob", gold(40)) })
    T.ok(ns.Scanner.PriceCheck({ id = DUST, name = DUST_NAME }))
    T.ok(Mock.pump(ns))
    T.eq(#Mock.queries, 3, "only the dust")

    -- the player picked something else meanwhile: no search for the old pick
    Mock.now = Mock.now + 120
    cache(ns, CLOTH, { row("Me", gold(30)), row("Bob", gold(40)) })
    T.ok(ns.Scanner.PriceCheck({ id = DUST, name = DUST_NAME }))
    click(rowOf(ns, BAG_NAME))                     -- the cache is old: busy
    T.eq(ui.status:GetText(), WAIT_SCAN)
    click(rowOf(ns, CLOTH_NAME))                   -- a fresh cache: nothing to wait for
    T.eq(ns.Auctions.Selected(), CLOTH)
    T.eq(ui.status:GetText(), "", "the wait note went with the pick")
    T.ok(Mock.pump(ns))
    T.eq(#Mock.queries, 4, "only the dust")

    -- the pick moved by another route than a click on this page: same
    Mock.now = Mock.now + 120
    cache(ns, CLOTH, { row("Me", gold(30)), row("Bob", gold(40)) })
    T.ok(ns.Scanner.PriceCheck({ id = DUST, name = DUST_NAME }))
    click(rowOf(ns, BAG_NAME))
    T.eq(ui.status:GetText(), WAIT_SCAN)
    T.ok(ns.Auctions.Select(CLOTH))
    T.ok(Mock.pump(ns))
    T.eq(#Mock.queries, 5, "only the dust")

    -- the page is hidden when the scan ends: no search
    Mock.now = Mock.now + 120
    T.ok(ns.Scanner.PriceCheck({ id = DUST, name = DUST_NAME }))
    click(rowOf(ns, BAG_NAME))
    openBrowse()
    T.ok(Mock.pump(ns))
    T.eq(#Mock.queries, 6, "only the dust")
    T.eq(ns.Auctions.Selected(), BAG)

    -- a later visit and a later scan do not search it either: only a click does
    openAuctions()
    T.ok(ns.Scanner.PriceCheck({ id = DUST, name = DUST_NAME }))
    T.ok(Mock.pump(ns))
    T.eq(#Mock.queries, 7, "only the dust")
  end,

  status_line_messages_only_while_the_page_is_shown = function(T)
    local ns = setup()
    openAuctions()
    local status = ns.AuctionsUI.status
    ns.Fire("PAGE_STATUS", "first")
    T.eq(status:GetText(), "first")
    ns.Fire("PAGE_ERROR", "Not enough money")
    T.eq(status:GetText(), BAD .. "Not enough money|r")
    ns.Fire("SCAN_STATUS", "Scanning 2/9: Frostweave Bag")
    T.eq(status:GetText(), "Scanning 2/9: Frostweave Bag")
    ns.AuctionsUI.Update()
    T.eq(status:GetText(), "Scanning 2/9: Frostweave Bag", "a redraw keeps it")
    ns.Fire("PAGE_STATUS", nil)
    T.eq(status:GetText(), "")
    ns.Fire("PAGE_STATUS", "first")

    -- another tab: not meant for us
    openBrowse()
    ns.Fire("PAGE_STATUS", "meant for another page")
    ns.Fire("PAGE_ERROR", "also for another page")
    ns.Fire("SCAN_STATUS", "Scan done: 3 items")
    T.eq(status:GetText(), "first")
    openSell()
    ns.Fire("PAGE_STATUS", "meant for CP Sell")
    T.eq(status:GetText(), "first")

    -- the Auction House closed on this tab: not the page the player sees
    openAuctions()
    ns.Fire("PAGE_STATUS", "second")
    T.eq(status:GetText(), "second")
    AuctionFrame:Hide()
    ns.Fire("PAGE_STATUS", "while closed")
    ns.Fire("PAGE_ERROR", "while closed")
    ns.Fire("SCAN_STATUS", "while closed")
    T.eq(status:GetText(), "second")
  end,

  item_change_resets_scroll_and_flip_widget = function(T)
    local ns = setup()
    openAuctions()
    fiveItems(ns)
    local ui = ns.AuctionsUI
    local tbl, flip = ui.listings, ui.flip
    local bar = _G[tbl.scroll:GetName() .. "ScrollBar"]
    local barValue
    bar.SetValue = function(_, v) barValue = v end

    T.eq(flip.frame:IsShown(), false, "no item, no notice")
    click(rowOf(ns, CLOTH_NAME))
    T.eq(tbl.title:GetText(), CLOTH_NAME .. ": all listings (checked now)")
    T.eq(flip.frame:IsShown(), true, "the mistake listing is offered")
    T.eq(tbl.scroll.offset, 0)
    T.eq(barValue, 0)

    -- the same item redrawn keeps the scroll position
    tbl.scroll.offset = 3
    barValue = nil
    cache(ns, CLOTH, { row("Me", gold(30)), row("Flipper", gold(1)), row("Bob", gold(40)) })
    ns.AuctionsUI.Update()
    T.eq(tbl.scroll.offset, 3)
    T.eq(barValue, nil)
    T.eq(flip.frame:IsShown(), true)

    -- another item: back to the top, and the old item's notice goes at once
    click(rowOf(ns, DUST_NAME))
    T.eq(tbl.scroll.offset, 0)
    T.eq(barValue, 0)
    T.eq(tbl.title:GetText(), DUST_NAME .. ": all listings (checked now)")
    T.eq(flip.frame:IsShown(), false)

    -- and back again: the cached listings show the notice again
    tbl.scroll.offset = 2
    click(rowOf(ns, CLOTH_NAME))
    T.eq(tbl.scroll.offset, 0)
    T.eq(flip.frame:IsShown(), true)

    -- nothing picked: no title
    tbl.scroll.offset = 2
    ns.Auctions.Select(nil)
    T.eq(tbl.title:GetText(), "")
    T.eq(#tbl.rows, 0)
    T.eq(tbl.scroll.offset, 0)
    T.eq(flip.frame:IsShown(), false)
  end,

  flip_widget_follows_the_picked_item = function(T)
    local ns = setup()
    openAuctions()
    fiveItems(ns)
    click(rowOf(ns, CLOTH_NAME))
    local flip = ns.AuctionsUI.flip
    T.eq(flip.button:GetText(), "Buy it")
    T.eq(flip.button:IsEnabled(), true)
    T.ok(flip.notice:GetText():find("Flipper", 1, true), "the notice is about the picked item")
    T.eq(#Mock.bought, 0, "nothing is bought by looking")
  end,

  left_list_scrolls_without_jumping = function(T)
    local ns = setup()
    openAuctions()
    local ui = ns.AuctionsUI
    Mock.owned = {}
    for i = 1, 25 do Mock.owned[i] = owned(1000 + i, string.format("Item %02d", i), gold(1)) end
    readAll(ns)
    T.eq(ui.rows[1].name:GetText(), "Item 01")
    T.eq(ui.rows[12].name:GetText(), "Item 12")
    T.eq(ui.rows[12]:IsShown(), true)

    -- scrolled down: later updates leave it there
    ui.scroll.offset = 5
    ns.AuctionsUI.Update()
    T.eq(ui.scroll.offset, 5)
    T.eq(ui.rows[1].name:GetText(), "Item 06")
    T.eq(ui.rows[12].name:GetText(), "Item 17")
    readAll(ns)
    T.eq(ui.scroll.offset, 5)
    T.eq(ui.rows[1].name:GetText(), "Item 06")

    -- a click picks the item in the row, not the first of the list
    Mock.ah.auctions = {}
    click(ui.rows[2])
    T.eq(ns.Auctions.Selected(), 1007)
    T.eq(ui.rows[2].selected:IsShown(), true)
    T.eq(ui.rows[1].selected:IsShown(), false)

    -- fewer auctions than the scroll position: back to the top
    local bar = _G[ui.scroll:GetName() .. "ScrollBar"]
    local barValue
    bar.SetValue = function(_, v) barValue = v end
    Mock.owned = { Mock.owned[1], Mock.owned[2], Mock.owned[3] }
    readAll(ns)
    T.eq(ui.scroll.offset, 0)
    T.eq(barValue, 0)
    T.eq(names(ns), "Item 01|Item 02|Item 03")
    T.eq(ui.rows[4]:IsShown(), false)
  end,

  left_list_keeps_its_place_when_it_shrinks = function(T)
    local ns = setup()
    openAuctions()
    local ui = ns.AuctionsUI
    local function items(n)
      Mock.owned = {}
      for i = 1, n do Mock.owned[i] = owned(1000 + i, string.format("Item %02d", i), gold(1)) end
      readAll(ns)
    end
    local bar = _G[ui.scroll:GetName() .. "ScrollBar"]
    local barValue
    bar.SetValue = function(_, v) barValue = v end

    -- scrolled to the very bottom of 25, then one auction is gone
    items(25)
    ui.scroll.offset = 13
    ns.AuctionsUI.Update()
    T.eq(ui.rows[12].name:GetText(), "Item 25")
    items(24)
    T.eq(ui.scroll.offset, 12, "the bottom of the shorter list, not the top")
    T.eq(barValue, 12 * 16, "the scroll bar follows")
    T.eq(ui.rows[1].name:GetText(), "Item 13")
    T.eq(ui.rows[12].name:GetText(), "Item 24")

    -- a list that still reaches the position does not move
    barValue = nil
    ui.scroll.offset = 5
    items(24)
    T.eq(ui.scroll.offset, 5)
    T.eq(barValue, nil)

    -- one that fits the window goes back to the top
    items(10)
    T.eq(ui.scroll.offset, 0)
    T.eq(barValue, 0)
    T.eq(ui.rows[1].name:GetText(), "Item 01")
  end,

  page_follows_events_after_the_build = function(T)
    local ns = setup()
    openAuctions()
    local ui = ns.AuctionsUI
    T.eq(names(ns), "")

    -- the owner list answers
    Mock.owned = { bagAuction(gold(420)) }
    readAll(ns)
    T.eq(names(ns), BAG_NAME)
    T.eq(rowOf(ns, BAG_NAME).status:GetText(), "-")

    -- a price check lands (LISTINGS_UPDATED)
    cache(ns, BAG, { row("Me", gold(420)), row("Bob", gold(410)) })
    T.eq(rowOf(ns, BAG_NAME).status:GetText(), ns.Util.ICON_WARN .. " undercut 10g (Bob)")
    T.eq(CraftProfitCancelNext:GetText(), "Cancel next undercut (1)")

    -- the shown item's listings change without a group of ours (all sold and gone)
    ns.Auctions.Select(BAG)
    Mock.owned = {}
    readAll(ns)
    T.eq(names(ns), "")
    cache(ns, BAG, { row("Bob", gold(400)) })
    T.eq(#ui.listings.rows, 1)
    T.eq(ui.listings.title:GetText(), BAG_NAME .. ": all listings (checked now)",
      "the name of an item no longer listed")
  end,
}
