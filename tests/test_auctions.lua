local Mock = require("wow_mock")

local REALM = "Icecrown-Alliance"
local BAG, BAG_NAME = 41599, "Frostweave Bag"
local CLOTH, CLOTH_NAME = 33470, "Frostweave Cloth"
local DUST, DUST_NAME = 22445, "Arcane Dust"
local ORE, ORE_NAME = 36912, "Saronite Ore"

local MAILBOX = "Collect it from your mailbox first."

local function gold(g, s, c) return g * 10000 + (s or 0) * 100 + (c or 0) end

-- A fresh namespace; the player is "Me" and has been warned about cancelling
-- (pass { unwarned = true } for the very first cancel).
local function setup(opts)
  opts = opts or {}
  Mock.reset()
  Mock.installUI()
  local ns = Mock.load({
    "Util.lua", "Profit.lua", "Prices.lua", "Recipes.lua", "Scanner.lua", "Listings.lua", "Buyer.lua",
    "UI.lua", "ListingsUI.lua", "Tabs.lua", "Flip.lua", "Sell.lua", "Auctions.lua",
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
  return ns, db
end

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
-- Returns how many answers it took.
local function readAll(ns)
  ns.Auctions.Refresh()
  local answers = 0
  while Mock.deliverOwned(ns) do
    answers = answers + 1
    assert(answers < 20, "owner list never settled")
  end
  return answers
end

local function changes(ns)
  local count = { n = 0 }
  ns.On("AUCTIONS_CHANGED", function() count.n = count.n + 1 end)
  return count
end

local function group(ns, id)
  for _, g in ipairs(ns.Auctions.Groups()) do
    if g.id == id then return g end
  end
  return nil
end

local function names(groups)
  local list = {}
  for i, g in ipairs(groups) do list[i] = g.name end
  return table.concat(list, "|")
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

return {
  groups_from_owner_list = function(T)
    local ns = setup()
    local changed = changes(ns)
    Mock.owned = {
      bagAuction(gold(420), { timeLeft = 3, texture = "bagtex" }),
      owned(CLOTH, CLOTH_NAME, gold(30), { count = 20, timeLeft = 4 }),
      bagAuction(gold(400), { timeLeft = 2 }),
      bagAuction(gold(420), { timeLeft = 1, sold = true }),
      bagAuction(gold(430), { timeLeft = 3 }),
    }
    T.eq(#ns.Auctions.Groups(), 0, "nothing read yet")

    ns.Auctions.Refresh()
    T.eq(#Mock.ownerRequests, 1)
    T.eq(Mock.ownerRequests[1], 0, "the first page")
    T.eq(changed.n, 0, "nothing to show before the server answers")
    T.ok(Mock.deliverOwned(ns))
    T.eq(changed.n, 1)

    local groups = ns.Auctions.Groups()
    T.eq(#groups, 2)
    local bag, cloth = groups[1], groups[2]
    T.eq(bag.id, BAG)
    T.eq(bag.name, BAG_NAME)
    T.eq(bag.texture, "bagtex")
    T.eq(bag.active, 3, "the sold auction is not active")
    T.eq(bag.sold, 1)
    T.eq(bag.lowestUnit, gold(400))
    T.eq(bag.timeLeft, 2, "shortest of the active ones; a sold auction's delivery time does not count")
    T.eq(bag.status, "unchecked")
    T.eq(bag.diff, nil)
    T.eq(bag.seller, nil)
    T.eq(bag.flip, nil)

    T.eq(cloth.id, CLOTH)
    T.eq(cloth.active, 1)
    T.eq(cloth.sold, 0)
    T.eq(cloth.lowestUnit, gold(1, 50), "price each of a stack of 20")
    T.eq(cloth.timeLeft, 4)
  end,

  paging_over_50 = function(T)
    local ns = setup()
    local changed = changes(ns)
    Mock.ownerPaged = true
    Mock.owned = {}
    for i = 1, 50 do Mock.owned[#Mock.owned + 1] = bagAuction(gold(400) + i) end
    for i = 1, 50 do Mock.owned[#Mock.owned + 1] = owned(CLOTH, CLOTH_NAME, gold(5) + i) end
    for i = 1, 20 do Mock.owned[#Mock.owned + 1] = bagAuction(gold(500) + i) end

    ns.Auctions.Refresh()
    T.ok(Mock.deliverOwned(ns))
    T.eq(Mock.ownerRequests[2], 1, "a batch of 50 out of 120: ask for the next page")
    T.eq(changed.n, 0, "nothing is shown until everything is read")
    T.eq(#ns.Auctions.Groups(), 0)

    local answers = 1
    while Mock.deliverOwned(ns) do answers = answers + 1 end
    T.eq(answers, 3)
    T.eq(table.concat(Mock.ownerRequests, ","), "0,1,2", "no page 3: 150 > 120")
    T.eq(changed.n, 1)
    local groups = ns.Auctions.Groups()
    T.eq(#groups, 2)
    T.eq(groups[1].id, BAG)
    T.eq(groups[1].active, 70, "pages 1 and 3")
    T.eq(groups[1].lowestUnit, gold(400) + 1)
    T.eq(groups[2].id, CLOTH)
    T.eq(groups[2].active, 50, "page 2")
  end,

  no_extra_page_when_batch_is_total = function(T)
    -- The client's own Auctions tab reads one batch: when it holds everything,
    -- even more than 50 auctions, there is no next page to ask for.
    local ns = setup()
    Mock.owned = {}
    for i = 1, 75 do Mock.owned[#Mock.owned + 1] = bagAuction(gold(400) + i) end
    T.eq(readAll(ns), 1)
    T.eq(table.concat(Mock.ownerRequests, ","), "0")
    T.eq(ns.Auctions.Groups()[1].active, 75)

    -- 50 of 50 on a paged list: the batch is the total as well
    local ns2 = setup()
    Mock.ownerPaged = true
    Mock.owned = {}
    for i = 1, 50 do Mock.owned[#Mock.owned + 1] = bagAuction(gold(400) + i) end
    T.eq(readAll(ns2), 1)
    T.eq(table.concat(Mock.ownerRequests, ","), "0")
    T.eq(ns2.Auctions.Groups()[1].active, 50)

    -- 51 of them: now the batch is smaller than the total
    local ns3 = setup()
    Mock.ownerPaged = true
    Mock.owned = {}
    for i = 1, 51 do Mock.owned[#Mock.owned + 1] = bagAuction(gold(400) + i) end
    T.eq(readAll(ns3), 2)
    T.eq(table.concat(Mock.ownerRequests, ","), "0,1")
    T.eq(ns3.Auctions.Groups()[1].active, 51)
  end,

  sold_only_group = function(T)
    local ns = setup()
    Mock.owned = {
      bagAuction(gold(420), { sold = true }),
      owned(CLOTH, CLOTH_NAME, gold(30), { sold = true, count = 20 }),
    }
    -- a cached check that would otherwise say "undercut"
    cache(ns, BAG, { row("Me", gold(420)), row("Bob", gold(410)) })
    readAll(ns)
    local bag, cloth = ns.Auctions.Groups()[1], ns.Auctions.Groups()[2]
    T.eq(bag.id, BAG)
    T.eq(bag.status, "sold", "nothing of the item is for sale any more")
    T.eq(bag.active, 0)
    T.eq(bag.sold, 1)
    T.eq(bag.lowestUnit, nil)
    T.eq(bag.timeLeft, nil)
    T.eq(bag.diff, nil)
    T.eq(bag.seller, nil)
    T.eq(cloth.status, "sold", "also without a price check")
    T.eq(ns.Auctions.CountUndercut(BAG), 0)
  end,

  status_from_cache = function(T)
    local ns = setup()
    Mock.owned = {
      owned(ORE, ORE_NAME, gold(50)),
      owned(CLOTH, CLOTH_NAME, gold(410)),
      owned(DUST, DUST_NAME, gold(400)),
      bagAuction(gold(420)),
    }
    cache(ns, DUST, { row("Me", gold(400)), row("Bob", gold(410)) })
    cache(ns, BAG, { row("Me", gold(420)), row("Bob", gold(410)) })
    cache(ns, CLOTH, { row("Me", gold(410)), row("Bob", gold(410)) })
    readAll(ns)

    local groups = ns.Auctions.Groups()
    T.eq(names(groups), "Frostweave Bag|Arcane Dust|Frostweave Cloth|Saronite Ore",
      "undercut first, then by name")
    local bag, dust, cloth, ore = groups[1], groups[2], groups[3], groups[4]
    T.eq(bag.status, "undercut")
    T.eq(bag.diff, gold(10))
    T.eq(bag.seller, "Bob")
    T.eq(dust.status, "cheapest")
    T.eq(dust.diff, gold(10))
    T.eq(cloth.status, "tied")
    T.eq(cloth.diff, 0)
    T.eq(ore.status, "unchecked", "never price-checked")
  end,

  listings_update_refreshes_status = function(T)
    local ns = setup()
    Mock.owned = { bagAuction(gold(420)) }
    readAll(ns)
    local changed = changes(ns)
    T.eq(ns.Auctions.Groups()[1].status, "unchecked")

    cache(ns, BAG, { row("Me", gold(420)), row("Bob", gold(410)) })
    T.eq(changed.n, 1, "a price check of an item we hold")
    T.eq(ns.Auctions.Groups()[1].status, "undercut")

    cache(ns, ORE, { row("Bob", gold(5)) })
    T.eq(changed.n, 1, "an item we do not hold changes nothing")
  end,

  alts_are_not_competitors = function(T)
    local ns, db = setup()
    db.chars[REALM].Alt = true
    Mock.owned = { bagAuction(gold(420)) }
    cache(ns, BAG, { row("Me", gold(420)), row("Alt", gold(410)) })
    readAll(ns)
    T.eq(ns.Auctions.Groups()[1].status, "cheapest")
    T.eq(ns.Auctions.CountUndercut(BAG), 0, "an alt's listing is yours")
  end,

  check_undercuts_scans_active_items = function(T)
    local ns = setup()
    Mock.ah.auctions = {
      { id = BAG, name = BAG_NAME, count = 1, buyout = gold(420), seller = "Me" },
      { id = BAG, name = BAG_NAME, count = 1, buyout = gold(410), seller = "Bob" },
      { id = CLOTH, name = CLOTH_NAME, count = 1, buyout = gold(100), seller = "Me" },
      { id = CLOTH, name = CLOTH_NAME, count = 1, buyout = gold(110), seller = "Bob" },
    }
    Mock.owned = {
      owned(CLOTH, CLOTH_NAME, gold(100)),
      owned(DUST, DUST_NAME, gold(10), { sold = true }),
      bagAuction(gold(420)),
    }
    readAll(ns)

    local ok, err = ns.Auctions.CheckUndercuts()
    T.eq(ok, true)
    T.eq(err, nil)
    T.ok(ns.Scanner.IsBusy())
    T.ok(Mock.pump(ns))
    local searched = {}
    for i, q in ipairs(Mock.queries) do searched[i] = q[1] end
    T.eq(table.concat(searched, "|"), BAG_NAME .. "|" .. CLOTH_NAME,
      "the items with an active auction, in list order; not the sold-only one")
    T.ok(ns.Listings.Get(BAG), "listings were collected")
    T.eq(ns.Listings.Get(DUST), nil)
    T.eq(ns.Auctions.Groups()[1].id, BAG, "undercut first")
    T.eq(group(ns, BAG).status, "undercut")
    T.eq(group(ns, CLOTH).status, "cheapest")
    T.eq(group(ns, DUST).status, "sold")
    T.eq(ns.Auctions.CountAllUndercut(), 1)

    -- a scan is running: the scanner's answer comes back as it is
    T.ok(ns.Scanner.StartTargeted({ { id = ORE, name = ORE_NAME } }))
    local ok2, err2 = ns.Auctions.CheckUndercuts()
    T.eq(ok2, false)
    T.eq(err2, "busy")
  end,

  check_undercuts_with_nothing_to_check = function(T)
    local ns = setup()
    T.eq(select(2, ns.Auctions.CheckUndercuts()), "empty", "nothing read")
    Mock.owned = { bagAuction(gold(420), { sold = true }) }
    readAll(ns)
    local ok, err = ns.Auctions.CheckUndercuts()
    T.eq(ok, false)
    T.eq(err, "empty", "only sold auctions")
    T.eq(ns.Scanner.IsBusy(), false)
  end,

  select_uses_fresh_cache_or_checks = function(T)
    local ns = setup()
    Mock.ah.auctions = {
      { id = BAG, name = BAG_NAME, count = 1, buyout = gold(420), seller = "Me" },
      { id = CLOTH, name = CLOTH_NAME, count = 1, buyout = gold(100), seller = "Me" },
    }
    Mock.owned = { bagAuction(gold(420)), owned(CLOTH, CLOTH_NAME, gold(100)) }
    readAll(ns)
    cache(ns, BAG, { row("Me", gold(420)), row("Bob", gold(410)) })
    local changed = changes(ns)
    T.eq(ns.Auctions.Selected(), nil)

    -- 59 s old: used as it is
    Mock.now = Mock.now + 59
    T.eq(ns.Auctions.Select(BAG), true)
    T.eq(ns.Auctions.Selected(), BAG)
    T.eq(ns.Scanner.IsBusy(), false, "no price check")
    T.eq(#Mock.queries, 0)
    T.eq(changed.n, 1, "the selection changed")

    -- the same item again changes nothing
    T.eq(ns.Auctions.Select(BAG), true)
    T.eq(changed.n, 1)

    -- 60 s old: checked again
    Mock.now = Mock.now + 1
    T.eq(ns.Auctions.Select(BAG), true)
    T.ok(ns.Scanner.IsBusy())
    T.ok(Mock.pump(ns))
    T.eq(#Mock.queries, 1)
    T.eq(Mock.queries[1][1], BAG_NAME)
    T.eq(select(2, ns.Listings.Get(BAG)), 0, "fresh rows")
    T.ok(changed.n >= 2, "the new rows redraw the page")

    -- never checked: a price check
    T.eq(ns.Auctions.Select(CLOTH), true)
    T.eq(ns.Auctions.Selected(), CLOTH)
    T.ok(ns.Scanner.IsBusy())

    -- the scanner is busy and the cache is old: the item stays selected
    Mock.now = Mock.now + 100
    local ok, err = ns.Auctions.Select(BAG)
    T.eq(ok, false)
    T.eq(err, "busy")
    T.eq(ns.Auctions.Selected(), BAG)
    T.ok(Mock.pump(ns))
  end,

  first_cancel_asks_confirmation = function(T)
    local ns, db = setup({ unwarned = true })
    local first, _, second = bagsUndercutByBob(ns)

    local ok, err = ns.Auctions.CancelUndercut(BAG)
    T.eq(ok, false)
    T.eq(err, "confirm")
    T.eq(Mock.popup, "CRAFTPROFIT_CANCEL")
    T.eq(#Mock.cancelled, 0, "nothing is cancelled before the player accepts")
    T.eq(db.cancelWarned, nil)

    local dialog = StaticPopupDialogs.CRAFTPROFIT_CANCEL
    T.eq(dialog.text, "Cancelled auctions go back to you by mail and the deposit is lost.")
    T.eq(dialog.button1, ACCEPT)
    T.eq(dialog.button2, CANCEL)
    T.eq(dialog.timeout, 0)
    T.eq(dialog.whileDead, 1)
    T.eq(dialog.hideOnEscape, 1)
    T.eq(dialog.OnAccept(nil, Mock.popupData), nil, "a truthy result would keep the popup open")
    T.eq(db.cancelWarned, true)
    T.eq(#Mock.cancelled, 1, "accepting repeats the click")
    T.eq(Mock.cancelled[1].auction, first)

    -- warned once: no popup the next time
    Mock.popup = nil
    Mock.deliverOwned(ns)
    T.eq(ns.Auctions.CancelUndercut(BAG), true)
    T.eq(Mock.popup, nil)
    T.eq(Mock.cancelled[2].auction, second)
  end,

  first_cancel_retries_the_same_call = function(T)
    -- the retry is for the item that was clicked, not for the first undercut one
    local ns = setup({ unwarned = true })
    Mock.owned = { bagAuction(gold(420)), owned(CLOTH, CLOTH_NAME, gold(120)) }
    cache(ns, BAG, { row("Me", gold(420)), row("Bob", gold(410)) })
    cache(ns, CLOTH, { row("Me", gold(120)), row("Bob", gold(110)) })
    readAll(ns)
    local clothAuction = Mock.owned[2]

    T.eq(select(2, ns.Auctions.CancelUndercut(CLOTH)), "confirm")
    StaticPopupDialogs.CRAFTPROFIT_CANCEL.OnAccept(nil, Mock.popupData)
    T.eq(#Mock.cancelled, 1)
    T.eq(Mock.cancelled[1].auction, clothAuction)

    -- and the "next undercut" button retries as that button
    local ns2, db2 = setup({ unwarned = true })
    Mock.owned = { owned(CLOTH, CLOTH_NAME, gold(120)), bagAuction(gold(420)) }
    cache(ns2, BAG, { row("Me", gold(420)), row("Bob", gold(410)) })
    cache(ns2, CLOTH, { row("Me", gold(120)), row("Bob", gold(110)) })
    readAll(ns2)
    local bagAuctionEntry = Mock.owned[2]

    local ok2, err2 = ns2.Auctions.CancelNextUndercut()
    T.eq(ok2, false)
    T.eq(err2, "confirm")
    T.eq(Mock.popup, "CRAFTPROFIT_CANCEL")
    T.eq(#Mock.cancelled, 0)
    StaticPopupDialogs.CRAFTPROFIT_CANCEL.OnAccept(nil, Mock.popupData)
    T.eq(db2.cancelWarned, true)
    T.eq(#Mock.cancelled, 1)
    T.eq(Mock.cancelled[1].auction, bagAuctionEntry, "the bag group comes first")
  end,

  cancel_uses_fresh_index = function(T)
    local ns = setup()
    local sold = bagAuction(gold(420), { sold = true })
    local first = bagAuction(gold(420))
    local cheap = bagAuction(gold(400))
    local tied = bagAuction(gold(410))
    local second = bagAuction(gold(420))
    Mock.owned = { sold, first, cheap, tied, second }
    cache(ns, BAG, {
      row("Me", gold(420)), row("Me", gold(420)), row("Me", gold(400)), row("Me", gold(410)),
      row("Bob", gold(410)),
    })
    readAll(ns)
    T.eq(ns.Auctions.CountUndercut(BAG), 2)

    T.eq(ns.Auctions.CancelUndercut(BAG), true)
    T.eq(#Mock.cancelled, 1)
    T.eq(Mock.cancelled[1].index, 2)
    T.eq(Mock.cancelled[1].auction, first)
    T.ok(Mock.ownerPending, "the owner list is asked for again")

    -- The list moved on: the player posted two more items that sit in front now.
    -- The second 420g auction is neither where the first read had it (index 5,
    -- now the tied 410g one) nor where it moved to after the first cancel (index
    -- 4, now the 400g one).
    table.insert(Mock.owned, 1, owned(CLOTH, CLOTH_NAME, gold(5)))
    table.insert(Mock.owned, 1, owned(DUST, DUST_NAME, gold(6)))
    T.eq(Mock.owned[5], tied)
    T.eq(Mock.owned[4], cheap)
    T.ok(Mock.deliverOwned(ns))
    T.eq(ns.Auctions.CountUndercut(BAG), 1)
    T.eq(ns.Auctions.CancelUndercut(BAG), true)
    T.eq(#Mock.cancelled, 2)
    T.eq(Mock.cancelled[2].index, 6)
    T.eq(Mock.cancelled[2].auction, second)

    Mock.deliverOwned(ns)
    T.eq(ns.Auctions.CountUndercut(BAG), 0)
    local ok, err = ns.Auctions.CancelUndercut(BAG)
    T.eq(ok, false)
    T.eq(err, "none")
    T.eq(#Mock.cancelled, 2, "the 400g and the tied 410g auctions stay, and so does the sold one")
    local left = {}
    for _, a in ipairs(Mock.owned) do left[a] = true end
    T.ok(left[sold] and left[cheap] and left[tied])
  end,

  second_cancel_waits_for_owner_update = function(T)
    local ns = setup()
    local first, _, second = bagsUndercutByBob(ns)

    T.eq(ns.Auctions.CancelUndercut(BAG), true)
    T.eq(Mock.cancelled[1].auction, first)

    -- The client's list is stale until the server answers.
    local ok, err = ns.Auctions.CancelUndercut(BAG)
    T.eq(ok, false)
    T.eq(err, "busy")
    local ok2, err2 = ns.Auctions.CancelNextUndercut()
    T.eq(ok2, false)
    T.eq(err2, "busy")
    T.eq(#Mock.cancelled, 1)

    T.ok(Mock.deliverOwned(ns))
    T.eq(ns.Auctions.CancelUndercut(BAG), true)
    T.eq(#Mock.cancelled, 2)
    T.eq(Mock.cancelled[2].auction, second)
  end,

  cancel_wait_ends_after_5_seconds = function(T)
    local ns = setup()
    bagsUndercutByBob(ns)
    T.eq(ns.Auctions.CancelUndercut(BAG), true)

    Mock.now = Mock.now + 4
    T.eq(select(2, ns.Auctions.CancelUndercut(BAG)), "busy")
    Mock.now = Mock.now + 1
    T.eq(ns.Auctions.CancelUndercut(BAG), true, "no answer for 5 s: do not wait forever")
    T.eq(#Mock.cancelled, 2)
    T.eq(select(2, ns.Auctions.CancelNextUndercut()), "busy", "and the wait starts again")
  end,

  cancel_next_undercut_order_and_count = function(T)
    local ns = setup()
    local cloth = owned(CLOTH, CLOTH_NAME, gold(120))
    local dust = owned(DUST, DUST_NAME, gold(100))
    local bag430 = bagAuction(gold(430))
    local ore = owned(ORE, ORE_NAME, gold(999))
    local bag420 = bagAuction(gold(420))
    Mock.owned = { cloth, dust, bag430, ore, bag420 }
    cache(ns, DUST, { row("Me", gold(100)), row("Bob", gold(150)) })
    cache(ns, BAG, { row("Me", gold(420)), row("Me", gold(430)), row("Bob", gold(410)) })
    cache(ns, CLOTH, { row("Me", gold(120)), row("Bob", gold(110)) })
    -- the price checks are old: the cache counts at any age
    Mock.now = Mock.now + 7200
    readAll(ns)

    T.eq(names(ns.Auctions.Groups()), "Frostweave Bag|Frostweave Cloth|Arcane Dust|Saronite Ore")
    T.eq(ns.Auctions.CountUndercut(BAG), 2)
    T.eq(ns.Auctions.CountUndercut(CLOTH), 1)
    T.eq(ns.Auctions.CountUndercut(DUST), 0, "the cheapest")
    T.eq(ns.Auctions.CountUndercut(ORE), 0, "never price-checked")
    T.eq(ns.Auctions.CountAllUndercut(), 3)

    local expected = { bag430, bag420, cloth }
    for i, entry in ipairs(expected) do
      T.eq(ns.Auctions.CancelNextUndercut(), true)
      T.eq(Mock.cancelled[i].auction, entry, "cancel " .. i)
      T.ok(Mock.deliverOwned(ns))
      T.eq(ns.Auctions.CountAllUndercut(), 3 - i)
    end
    local ok, err = ns.Auctions.CancelNextUndercut()
    T.eq(ok, false)
    T.eq(err, "none")
    T.eq(#Mock.cancelled, 3, "the cheapest and the unchecked auctions are kept")
  end,

  undercut_counts_match_single_counts = function(T)
    local ns = setup()
    Mock.owned = {
      owned(CLOTH, CLOTH_NAME, gold(120)),
      owned(DUST, DUST_NAME, gold(100)),
      bagAuction(gold(430)),
      owned(ORE, ORE_NAME, gold(999)),
      bagAuction(gold(420)),
      bagAuction(gold(450), { sold = true }),   -- sold: never counted
      bagAuction(gold(440), { bid = 5 }),       -- a bid on it: never counted
      bagAuction(gold(460), { suffix = 7 }),    -- a random-suffix variant: never counted
      bagAuction(gold(400)),                    -- the cheapest: kept
    }
    cache(ns, DUST, { row("Me", gold(100)), row("Bob", gold(150)) })
    cache(ns, BAG, { row("Me", gold(400)), row("Me", gold(420)), row("Bob", gold(410)) })
    cache(ns, CLOTH, { row("Me", gold(120)), row("Bob", gold(110)) })
    readAll(ns)

    local counts, total = ns.Auctions.UndercutCounts()
    T.eq(total, 3)
    T.eq(counts[BAG], 2)
    T.eq(counts[CLOTH], 1)
    T.eq(counts[DUST], nil, "the cheapest: no entry")
    T.eq(counts[ORE], nil, "never price-checked: no entry")

    -- the same answers as the single counts, for every item there is
    for _, id in ipairs({ BAG, CLOTH, DUST, ORE, 123456 }) do
      T.eq(counts[id] or 0, ns.Auctions.CountUndercut(id), "item " .. id)
    end
    T.eq(total, ns.Auctions.CountAllUndercut())

    -- a pass over the owner list, once
    local reads = 0
    local info = GetAuctionItemInfo
    GetAuctionItemInfo = function(kind, i)
      if kind == "owner" then reads = reads + 1 end
      return info(kind, i)
    end
    ns.Auctions.UndercutCounts()
    T.eq(reads, #Mock.owned, "one read per auction")

    -- the counts follow the list after a cancel (the cloth is undercut, so it goes first)
    T.eq(ns.Auctions.CancelNextUndercut(), true)
    T.ok(Mock.deliverOwned(ns))
    local after, afterTotal = ns.Auctions.UndercutCounts()
    T.eq(afterTotal, 2)
    T.eq(after[BAG], 2)
    T.eq(after[CLOTH], nil)
    T.eq(afterTotal, ns.Auctions.CountAllUndercut())
  end,

  outlier_only_is_not_undercut = function(T)
    local ns = setup()
    Mock.owned = { bagAuction(gold(420)) }
    -- the only cheaper listing is a mistake listing: a flip, not competition
    cache(ns, BAG, { row("Me", gold(420)), row("Flipper", gold(50)) })
    readAll(ns)

    local group = ns.Auctions.Groups()[1]
    T.eq(group.status, "cheapest")
    T.ok(group.flip, "flagged as a flip")
    T.eq(group.flip.unit, gold(50))
    T.eq(group.flip.seller, "Flipper")
    T.eq(ns.Auctions.CountUndercut(BAG), 0)
    T.eq(ns.Auctions.CountAllUndercut(), 0)
    T.eq(select(2, ns.Auctions.CancelUndercut(BAG)), "none")
    T.eq(select(2, ns.Auctions.CancelNextUndercut()), "none")
    T.eq(#Mock.cancelled, 0)
  end,

  auction_with_bid_is_never_cancelled = function(T)
    local ns = setup()
    local bid = bagAuction(gold(420), { bid = gold(300) })
    local plain = bagAuction(gold(420))
    Mock.owned = { bid, plain }
    cache(ns, BAG, { row("Me", gold(420)), row("Me", gold(420)), row("Bob", gold(410)) })
    readAll(ns)

    T.eq(ns.Auctions.Groups()[1].active, 2, "it is still one of the active auctions")
    T.eq(ns.Auctions.CountUndercut(BAG), 1, "but not an undercut one")
    T.eq(ns.Auctions.CountAllUndercut(), 1)
    T.eq(ns.Auctions.CancelNextUndercut(), true)
    T.eq(Mock.cancelled[1].auction, plain)

    Mock.deliverOwned(ns)
    T.eq(ns.Auctions.CountUndercut(BAG), 0)
    T.eq(select(2, ns.Auctions.CancelUndercut(BAG)), "none")
    T.eq(select(2, ns.Auctions.CancelNextUndercut()), "none")
    T.eq(#Mock.cancelled, 1, "a bid on it costs a fee and may sell it")
  end,

  unfit_auctions_are_not_undercut = function(T)
    local ns = setup()
    local noBuyout = bagAuction(0)
    local locked = bagAuction(gold(420))
    local fine = bagAuction(gold(420))
    local sold = bagAuction(gold(420), { sold = true })
    Mock.owned = { noBuyout, locked, fine, sold }
    cache(ns, BAG, { row("Me", gold(420)), row("Me", gold(420)), row("Bob", gold(410)) })
    readAll(ns)
    -- the client allows everything but the second one, a sold auction included
    CanCancelAuction = function(i) return i ~= 2 end

    T.eq(ns.Auctions.Groups()[1].active, 3)
    T.eq(ns.Auctions.Groups()[1].sold, 1)
    T.eq(ns.Auctions.CountUndercut(BAG), 1, "no buyout, not cancellable and sold do not count")
    T.eq(ns.Auctions.CancelUndercut(BAG), true)
    T.eq(#Mock.cancelled, 1)
    T.eq(Mock.cancelled[1].auction, fine)
  end,

  unreadable_auction_is_skipped = function(T)
    local ns = setup()
    Mock.owned = { bagAuction(gold(420), { nilLink = true }), bagAuction(gold(400)) }
    readAll(ns)
    local groups = ns.Auctions.Groups()
    T.eq(#groups, 1)
    T.eq(groups[1].active, 1, "an auction whose item the client has not loaded yet is left out")
  end,

  nothing_cancels_without_a_click = function(T)
    local ns = setup()
    Mock.ah.auctions = {
      { id = BAG, name = BAG_NAME, count = 1, buyout = gold(420), seller = "Me" },
      { id = BAG, name = BAG_NAME, count = 1, buyout = gold(410), seller = "Bob" },
    }
    Mock.owned = { bagAuction(gold(420)) }
    readAll(ns)
    T.eq(ns.Auctions.CheckUndercuts(), true)
    T.ok(Mock.pump(ns))
    ns.Auctions.Select(BAG)
    ns.Auctions.Refresh()
    Mock.deliverOwned(ns)
    ns.Fire("LISTINGS_UPDATED", BAG)
    ns.Fire("SCAN_FINISHED")
    ns.Fire("PAGE_SHOWN", "auctions")
    T.eq(ns.Auctions.CountAllUndercut(), 1, "there is something to cancel")
    T.eq(#Mock.cancelled, 0, "only a click cancels")
  end,

  undercut_goes_to_sell_or_mailbox_message = function(T)
    local ns = setup()
    T.eq(ns.Tabs.Ensure(), true)
    local changed = changes(ns)
    T.eq(ns.Auctions.status, "")

    -- The tab switches only once the item is in the slot: watch the tab at the
    -- moment of the put.
    local tabAtPut = "never put"
    local realPut = ns.Sell.PutItemById
    ns.Sell.PutItemById = function(id)
      tabAtPut = Mock.lastTab
      return realPut(id)
    end

    -- in the bags: CP Sell opens with the item in its slot
    Mock.bags[0] = { [1] = { id = BAG, name = BAG_NAME, count = 2 } }
    T.eq(ns.Auctions.Undercut(BAG), true)
    T.eq(tabAtPut, nil, "the item goes in first")
    T.eq(Mock.lastTab, 4, "then CP Sell opens")
    T.eq(Mock.sellSlot.id, BAG)
    T.eq(ns.Sell.State().item.id, BAG)
    T.eq(ns.Auctions.status, "")
    T.eq(changed.n, 0)

    -- not in the bag slots (it is in the mailbox, or an equipped copy): stay
    -- where we are and say where it is
    Mock.bags, Mock.sellSlot, Mock.lastTab = {}, nil, nil
    local ok, err = ns.Auctions.Undercut(CLOTH)
    T.eq(ok, false)
    T.eq(err, "not-in-bags")
    T.eq(Mock.lastTab, nil, "no tab switch")
    T.eq(ns.Auctions.status, MAILBOX)
    T.eq(changed.n, 1)

    -- any other failure: its own message, and the tab stays as well
    ns.Sell.PutItemById = function() return false, "put-failed" end
    changed.n = 0
    local ok3, err3 = ns.Auctions.Undercut(BAG)
    T.eq(ok3, false)
    T.eq(err3, "put-failed")
    T.eq(Mock.lastTab, nil, "no tab switch")
    T.eq(ns.Auctions.status, "Couldn't put it in the sell slot.")
    T.eq(changed.n, 1)

    -- a good put afterwards wipes the message
    ns.Sell.PutItemById = realPut
    Mock.bags[0] = { [1] = { id = BAG, name = BAG_NAME, count = 2 } }
    T.eq(ns.Auctions.Undercut(BAG), true)
    T.eq(Mock.lastTab, 4)
    T.eq(ns.Auctions.status, "")
    T.eq(changed.n, 2)

    -- picking another item wipes the message too
    ns.Auctions.status = MAILBOX
    Mock.owned = { bagAuction(gold(420)) }
    readAll(ns)
    ns.Auctions.Select(BAG)
    T.eq(ns.Auctions.status, "")
  end,

  suffix_variant_is_never_cancelled = function(T)
    -- Random-suffix items share one item id; the cached rows are one variant's.
    local ns = setup()
    local plain = bagAuction(gold(420))
    local eagle = bagAuction(gold(400), { suffix = -14, name = "Belt of the Eagle" })
    local bear = bagAuction(gold(430), { suffix = 1221, name = "Belt of the Bear" })
    Mock.owned = { eagle, bear, plain }
    cache(ns, BAG, { row("Me", gold(420)), row("Bob", gold(300)) })
    readAll(ns)

    local g = group(ns, BAG)
    T.eq(g.active, 3, "still grouped and shown")
    T.eq(g.lowestUnit, gold(400))
    T.eq(ns.Auctions.CountUndercut(BAG), 1, "only the one without a suffix can be compared")
    T.eq(ns.Auctions.CountAllUndercut(), 1)

    T.eq(ns.Auctions.CancelNextUndercut(), true)
    T.eq(Mock.cancelled[1].auction, plain)
    T.ok(Mock.deliverOwned(ns))
    T.eq(ns.Auctions.CountUndercut(BAG), 0)
    T.eq(select(2, ns.Auctions.CancelUndercut(BAG)), "none")
    T.eq(select(2, ns.Auctions.CancelNextUndercut()), "none")
    T.eq(#Mock.cancelled, 1, "the Eagle and the Bear keep their deposits")
  end,

  unnamed_cheaper_row_never_triggers_cancel = function(T)
    -- A row without a seller name may be an alt's: it is not proof of a competitor.
    local ns = setup()
    local mine = bagAuction(gold(420))
    Mock.owned = { mine }
    cache(ns, BAG, { row("Me", gold(420)), row(nil, gold(300)) })
    readAll(ns)

    -- the page still shows what the cache says
    T.eq(group(ns, BAG).status, "undercut")
    T.eq(group(ns, BAG).seller, nil)
    T.eq(ns.Auctions.CountUndercut(BAG), 0)
    T.eq(ns.Auctions.CountAllUndercut(), 0)
    T.eq(select(2, ns.Auctions.CancelUndercut(BAG)), "none")
    T.eq(select(2, ns.Auctions.CancelNextUndercut()), "none")
    T.eq(#Mock.cancelled, 0)

    -- a named seller at that price is a competitor
    cache(ns, BAG, { row("Me", gold(420)), row(nil, gold(300)), row("Bob", gold(300)) })
    T.eq(ns.Auctions.CountUndercut(BAG), 1)
    T.eq(ns.Auctions.CancelUndercut(BAG), true)
    T.eq(Mock.cancelled[1].auction, mine)

    -- and a named seller above the unnamed one sets the price to beat
    local ns2 = setup()
    Mock.owned = { bagAuction(gold(420)) }
    cache(ns2, BAG, { row("Me", gold(420)), row(nil, gold(300)), row("Bob", gold(430)) })
    readAll(ns2)
    T.eq(ns2.Auctions.CountUndercut(BAG), 0, "Bob is dearer than we are")
  end,
  -- R1: "of the Monkey" at 50g and 52g are competition for my 60g Monkey belt,
  -- not mistakes to leave out of the comparison (the 300g Bear made them look
  -- like one). No flip marker either.
  random_suffix_rows_are_competition_not_mistakes = function(T)
    local ns = setup()
    Mock.owned = { bagAuction(gold(60), { suffix = -9 }) }
    cache(ns, BAG, {
      { count = 1, buyout = gold(50), seller = "Bob", suffix = -9 },
      { count = 1, buyout = gold(52), seller = "Kim", suffix = -9 },
      { count = 1, buyout = gold(60), seller = "Me", suffix = -9 },
      { count = 1, buyout = gold(300), seller = "Al", suffix = -40 },
    })
    readAll(ns)
    local g = group(ns, BAG)
    T.eq(g.status, "undercut", "Bob's 50g is below my 60g")
    T.eq(g.diff, gold(10))
    T.eq(g.seller, "Bob")
    T.eq(g.flip, nil, "no flip marker on the item")
    for _, r in ipairs(ns.Listings.Get(BAG)) do
      T.eq(r.outlier, false, "no mistake mark on " .. tostring(r.seller))
    end
  end,
}
