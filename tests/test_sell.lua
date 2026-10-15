local Mock = require("wow_mock")

local REALM = "Icecrown-Alliance"
local BAG, BAG_NAME = 41599, "Frostweave Bag"
local OTHER, OTHER_NAME = 41600, "Glacial Bag"
local CLOTH, CLOTH_NAME = 33470, "Frostweave Cloth"

local CANT_AUCTION = "This item can't be auctioned."
local NO_ANSWER = "No answer from the Auction House - try again"

local function gold(g, s, c) return g * 10000 + (s or 0) * 100 + (c or 0) end

-- A fresh namespace. The player has 1000000g, no bags, an empty sell slot.
-- Pass opts.db to reuse a saved-variables table (a reload).
local function setup(opts)
  opts = opts or {}
  Mock.reset()
  Mock.installUI()
  local ns = Mock.load({
    "Util.lua", "Profit.lua", "Prices.lua", "Recipes.lua", "Scanner.lua", "Listings.lua",
    "UI.lua", "ListingsUI.lua", "Tabs.lua", "Flip.lua", "Sell.lua",
  })
  local db = opts.db or { cut = 0.05 }
  ns.db = db
  ns.Prices.SetDB(db, REALM)
  ns.Recipes.SetDB({})
  ns.Scanner.SetDB(db)
  ns.Listings.SetDB(db, REALM, "Me")
  ns.Sell.SetDB(db)
  hooksecurefunc("QueryAuctionItems", ns.Scanner.OnQuery)
  Mock.items[BAG] = { name = BAG_NAME, maxStack = 1 }
  Mock.items[OTHER] = { name = OTHER_NAME, maxStack = 1 }
  Mock.items[CLOTH] = { name = CLOTH_NAME, maxStack = 20 }
  return ns, db
end

local function inBag(bag, slot, id, name, count)
  Mock.bags[bag] = Mock.bags[bag] or {}
  Mock.bags[bag][slot] = { id = id, name = name, count = count }
end

local function auction(id, name, seller, count, buyout)
  return { id = id, name = name, count = count or 1, buyout = buyout, seller = seller }
end

local function bagAuction(seller, buyout)
  return auction(BAG, BAG_NAME, seller, 1, buyout)
end

-- The player alt+clicks bag slot (0, 1) with `count` bags there and the
-- price check finishes.
local function putBag(ns, count, pump)
  inBag(0, 1, BAG, BAG_NAME, count or 3)
  assert(ns.Sell.PutItem(0, 1), "item accepted")
  if pump ~= false then assert(Mock.pump(ns), "price check finished") end
end

-- Frostweave Bag is a known recipe: 5 cloth per craft, 2 bags per craft.
local function knowRecipe(ns, clothPrice)
  ns.Recipes.All()[BAG] = {
    name = BAG_NAME, made = 2,
    reagents = { { id = CLOTH, name = CLOTH_NAME, count = 5 } },
  }
  if clothPrice then ns.Prices.SetManual(CLOTH, clothPrice) end
end

-- "Scan tracked" (no collect) stored the lowest listing as the AH price: a 50g
-- mistake listing next to 420g and 430g ones.
local function scanTrackedSawMistake(ns)
  Mock.ah.auctions = {
    bagAuction("Flipper", gold(50)), bagAuction("Bob", gold(420)), bagAuction("Carl", gold(430)),
  }
  assert(ns.Scanner.StartTargeted({ { id = BAG, name = BAG_NAME } }))
  assert(Mock.pump(ns))
  assert(ns.Prices.GetAH(BAG) == gold(50), "stored AH price is the mistake listing")
end

local function events(ns)
  local count = { n = 0 }
  ns.On("SELL_CHANGED", function() count.n = count.n + 1 end)
  return count
end

return {
  defaults_for_gear = function(T)
    local ns = setup()
    inBag(0, 1, BAG, BAG_NAME, 3)
    T.ok(ns.Sell.PutItem(0, 1))
    local s = ns.Sell.State()
    T.eq(s.item.id, BAG)
    T.eq(s.item.name, BAG_NAME)
    T.eq(s.item.maxStack, 1)
    T.eq(s.item.owned, 3)
    T.ok(s.item.texture, "icon")
    T.eq(s.stack, 1, "gear is posted one per auction")
    T.eq(s.stacks, 3)
    T.eq(s.duration, 2)
    T.eq(ns.Sell.lastId, BAG)
    T.eq(Mock.cleared, 0, "nothing came back onto the cursor")
  end,

  defaults_for_stackables = function(T)
    local ns = setup()
    inBag(0, 1, CLOTH, CLOTH_NAME, 30)
    inBag(1, 4, CLOTH, CLOTH_NAME, 15)
    T.ok(ns.Sell.PutItem(0, 1))
    local s = ns.Sell.State()
    T.eq(s.item.maxStack, 20)
    T.eq(s.item.owned, 45)
    T.eq(s.stack, 20)
    T.eq(s.stacks, 2)

    -- fewer than a full stack: one stack of everything
    local ns2 = setup()
    inBag(0, 1, CLOTH, CLOTH_NAME, 7)
    T.ok(ns2.Sell.PutItem(0, 1))
    T.eq(ns2.Sell.State().stack, 7)
    T.eq(ns2.Sell.State().stacks, 1)
  end,

  duration_remembered = function(T)
    local ns, db = setup()
    T.eq(db.sell.duration, 2, "SetDB creates the default")
    T.eq(ns.Sell.State().duration, 2)
    ns.Sell.SetDuration(3)
    T.eq(db.sell.duration, 3, "saved")
    T.eq(ns.Sell.State().duration, 3)
    ns.Sell.SetDuration(7)
    T.eq(ns.Sell.State().duration, 3, "unknown durations are refused")

    -- a new item keeps the choice, and so does a reload
    putBag(ns, 1, false)
    T.eq(ns.Sell.State().duration, 3)
    local ns2 = setup({ db = db })
    T.eq(ns2.Sell.State().duration, 3, "restored after a reload")

    -- garbage in the saved variables falls back to 24 h
    local ns3, db3 = setup({ db = { cut = 0.05, sell = { duration = 9 } } })
    T.eq(db3.sell.duration, 2)
    T.eq(ns3.Sell.State().duration, 2)
  end,

  price_from_listings_undercut = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    putBag(ns, 1, false)
    T.eq(ns.Sell.State().status, "Searching...")
    T.eq(ns.Sell.State().listings, nil)
    T.ok(Mock.pump(ns))
    local s = ns.Sell.State()
    T.eq(s.unit, gold(419, 99))
    T.eq(#s.listings, 1)
    T.eq(s.listings[1].seller, "Bob")
    T.eq(s.status, "", "the search note is gone")
    T.near(s.net, gold(419, 99) * 0.95, 1e-6)
  end,

  mistake_listing_not_undercut_and_flagged = function(T)
    local ns = setup()
    Mock.ah.auctions = {
      bagAuction("Flipper", gold(50)), bagAuction("Bob", gold(420)), bagAuction("Carl", gold(430)),
    }
    putBag(ns, 1)
    local s = ns.Sell.State()
    T.eq(s.unit, gold(419, 99), "priced against Bob, not the 50g mistake")
    T.ok(s.flip, "the mistake listing is reported")
    T.eq(s.flip.row.seller, "Flipper")
    T.eq(s.flip.row.unit, gold(50))
    T.eq(s.flip.next, gold(420))
    T.eq(s.flip.profit, math.floor(gold(420) * 0.95 - gold(50)))
  end,

  price_fallback_when_no_listings = function(T)
    local ns = setup()
    ns.Prices.SetManual(BAG, gold(500))
    putBag(ns, 1, false)
    T.eq(ns.Sell.State().unit, gold(500), "the known price is there while searching")
    T.ok(Mock.pump(ns))
    local s = ns.Sell.State()
    T.eq(s.unit, gold(500), "nobody sells it: the fallback price")
    T.eq(#s.listings, 0)
    T.eq(s.canPost, true)

    -- no fallback at all: empty price, Post disabled
    local ns2 = setup()
    putBag(ns2, 1)
    local s2 = ns2.Sell.State()
    T.eq(s2.unit, nil)
    T.eq(s2.canPost, false)
    T.eq(s2.reason, "no-price")
  end,

  typed_price_survives_price_check = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    putBag(ns, 1, false)
    ns.Sell.SetUnit(gold(300))
    T.ok(Mock.pump(ns))
    local s = ns.Sell.State()
    T.eq(s.unit, gold(300), "the typed price stays")
    T.eq(#s.listings, 1, "the listings still arrive")

    -- a later answer for the same item changes nothing either
    ns.Listings.Store(BAG, s.listings)
    T.eq(ns.Sell.State().unit, gold(300))

    -- a new item starts from the market price again
    inBag(0, 2, OTHER, OTHER_NAME, 1)
    Mock.ah.auctions = { auction(OTHER, OTHER_NAME, "Cara", 1, gold(100)) }
    T.ok(ns.Sell.PutItem(0, 2))
    T.ok(Mock.pump(ns))
    T.eq(ns.Sell.State().unit, gold(99, 99))
  end,

  stale_price_check_ignored = function(T)
    local ns = setup()
    Mock.ah.auctions = {
      bagAuction("Bob", gold(420)),
      auction(OTHER, OTHER_NAME, "Cara", 1, gold(100)),
    }
    inBag(0, 1, BAG, BAG_NAME, 1)
    inBag(0, 2, OTHER, OTHER_NAME, 1)
    T.ok(ns.Sell.PutItem(0, 1))
    ns.Scanner.Tick(0.1)                      -- the bag search is on its way
    T.ok(ns.Scanner.IsBusy())
    T.ok(ns.Sell.PutItem(0, 2))               -- the player swaps the item
    T.eq(ns.Sell.State().item.id, OTHER)
    T.eq(ns.Sell.State().status, "Waiting for the current scan...")

    -- the bag answer arrives: it must not price the other bag
    Mock.deliver(ns)
    T.ok(ns.Listings.Get(BAG), "the old check did store its rows")
    local s = ns.Sell.State()
    T.eq(s.listings, nil)
    T.eq(s.unit, nil)
    T.eq(s.status, "Searching...", "the new item's check took over")

    T.ok(Mock.pump(ns))
    s = ns.Sell.State()
    T.eq(s.unit, gold(99, 99))
    T.eq(s.listings[1].seller, "Cara")
    T.eq(s.status, "")
  end,

  stale_failed_check_does_not_blame_the_new_item = function(T)
    local ns = setup()
    inBag(0, 1, BAG, BAG_NAME, 1)
    inBag(0, 2, OTHER, OTHER_NAME, 1)
    T.ok(ns.Sell.PutItem(0, 1))
    ns.Scanner.Tick(0.1)
    T.ok(ns.Sell.PutItem(0, 2))
    ns.Scanner.Stop("AH closed")              -- the bag check ends without rows
    T.eq(ns.Sell.State().status, "Searching...", "the other item's own check started")
    T.ok(ns.Scanner.IsBusy())
  end,

  failed_price_check_reports_no_answer = function(T)
    local ns = setup()
    ns.Prices.SetManual(BAG, gold(500))
    putBag(ns, 1, false)
    -- the server never answers: the scanner retries once, then gives up
    for _ = 1, 8 do ns.Scanner.Tick(5) end
    T.eq(ns.Scanner.IsBusy(), false)
    local s = ns.Sell.State()
    T.eq(s.status, NO_ANSWER)
    T.eq(s.unit, gold(500), "the price is kept")
    T.eq(s.listings, nil)

    -- the player can ask again by putting the item in again; the answer clears the note
    ns.Listings.Store(BAG, {})
    T.eq(ns.Sell.State().status, "")

    -- a scan that is stopped (AH closed) is a failed check too
    local ns2 = setup()
    putBag(ns2, 1, false)
    ns2.Scanner.Stop("AH closed")
    T.eq(ns2.Sell.State().status, NO_ANSWER)
  end,

  slot_event_after_put_keeps_item_and_does_not_recheck = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    putBag(ns, 2, false)
    ns.Sell.OnSlotChanged(nil)                -- NEW_AUCTION_UPDATE fired by our own drop
    T.eq(ns.Sell.State().item.id, BAG, "the last put id is kept")
    T.eq(ns.Sell.State().status, "Searching...")
    T.ok(Mock.pump(ns))
    T.eq(#Mock.queries, 1, "one search, not two")
    T.eq(ns.Sell.State().unit, gold(419, 99))
  end,

  pick_row_prices = function(T)
    local ns = setup()
    Mock.ah.auctions = {
      bagAuction("Bob", gold(420)), bagAuction("Dave", gold(600)), bagAuction("Me", gold(700)),
    }
    putBag(ns, 1)
    local rows = ns.Sell.State().listings
    T.eq(#rows, 3)
    ns.Sell.PickRow(rows[1])
    T.eq(ns.Sell.State().unit, gold(419, 99))
    ns.Sell.PickRow(rows[2])
    T.eq(ns.Sell.State().unit, gold(599, 99))
    ns.Sell.PickRow(rows[3])
    T.eq(rows[3].mine, true)
    T.eq(ns.Sell.State().unit, gold(700), "our own row: equal, never under")

    -- a picked price is an edited price: the next answer does not replace it
    ns.Listings.Store(BAG, rows)
    T.eq(ns.Sell.State().unit, gold(700))

    -- the same step as the undercut rule
    ns.Sell.PickRow({ unit = gold(5, 0, 57), mine = false })
    T.eq(ns.Sell.State().unit, gold(5))
    ns.Sell.PickRow({ unit = 101, mine = false })
    T.eq(ns.Sell.State().unit, 100)
    ns.Sell.PickRow({ unit = 100, mine = false })
    T.eq(ns.Sell.State().unit, 99)
    ns.Sell.PickRow({ unit = 50, mine = false })
    T.eq(ns.Sell.State().unit, 49)
    ns.Sell.PickRow({ unit = 1, mine = false })
    T.eq(ns.Sell.State().unit, 1)
    ns.Sell.PickRow({ unit = gold(3), mine = true })    -- an alt's row
    T.eq(ns.Sell.State().unit, gold(3))
    ns.Sell.PickRow({ unit = 0, mine = false })         -- a bid-only row has no price to follow
    T.eq(ns.Sell.State().unit, gold(3))
  end,

  post_args_per_stack = function(T)
    local ns = setup()
    putBag(ns, 3)
    ns.Sell.SetUnit(41999)
    ns.Sell.SetStack(1)
    ns.Sell.SetStacks(3)
    T.eq(ns.Sell.State().duration, 2)
    T.eq(ns.Sell.Post(), true)
    T.eq(#Mock.started, 1)
    local a = Mock.started[1]
    T.eq(a.n, 5)
    T.eq(a[1], 41999, "min bid is the buyout")
    T.eq(a[2], 41999)
    T.eq(a[3], 2)
    T.eq(a[4], 1)
    T.eq(a[5], 3)
    T.eq(ns.Sell.State().status, "Posting...")

    -- prices are per stack
    local ns2 = setup()
    inBag(0, 1, CLOTH, CLOTH_NAME, 45)
    T.ok(ns2.Sell.PutItem(0, 1))
    ns2.Sell.SetUnit(250)
    ns2.Sell.SetDuration(3)
    T.eq(ns2.Sell.State().stack, 20)
    T.eq(ns2.Sell.State().stacks, 2)
    T.eq(ns2.Sell.Post(), true)
    local b = Mock.started[1]
    T.eq(b[1], 5000)
    T.eq(b[2], 5000)
    T.eq(b[3], 3)
    T.eq(b[4], 20)
    T.eq(b[5], 2)
  end,

  post_disabled_cases = function(T)
    local ns = setup()
    -- no item
    local s = ns.Sell.State()
    T.eq(s.canPost, false)
    T.eq(s.reason, "no-item")
    T.eq(ns.Sell.Post(), false)

    putBag(ns, 3)
    -- no price
    s = ns.Sell.State()
    T.eq(s.reason, "no-price")
    T.eq(ns.Sell.Post(), false)
    ns.Sell.SetUnit(0)
    T.eq(ns.Sell.State().reason, "no-price", "0c is not a price")

    ns.Sell.SetUnit(gold(10))
    s = ns.Sell.State()
    T.eq(s.canPost, true)
    T.eq(s.reason, nil)
    T.eq(s.deposit, 3 * 100 * 2)

    -- more than the bags hold
    ns.Sell.SetStacks(4)
    s = ns.Sell.State()
    T.eq(s.reason, "too-many")
    T.eq(s.canPost, false)
    T.eq(ns.Sell.Post(), false)
    ns.Sell.SetStack(2)
    ns.Sell.SetStacks(2)
    T.eq(ns.Sell.State().reason, "too-many", "2 x 2 > 3")
    ns.Sell.SetStack(1)
    ns.Sell.SetStacks(3)

    -- cannot pay the deposit
    Mock.money = 599
    s = ns.Sell.State()
    T.eq(s.reason, "no-gold")
    T.eq(ns.Sell.Post(), false)
    T.eq(#Mock.started, 0, "nothing was posted by any refused click")
    Mock.money = 600
    T.eq(ns.Sell.State().canPost, true)

    -- a count can't go below one
    ns.Sell.SetStacks(0)
    T.eq(ns.Sell.State().stacks, 1)
    ns.Sell.SetStack(-5)
    T.eq(ns.Sell.State().stack, 1)
    ns.Sell.SetStack(nil)
    T.eq(ns.Sell.State().stack, 1)

    -- the game's slot was emptied behind our back: nothing to post
    Mock.sellSlot = nil
    s = ns.Sell.State()
    T.eq(s.reason, "no-item")
    T.eq(s.item, nil)
    T.eq(ns.Sell.Post(), false)
    T.eq(#Mock.started, 0)
  end,

  profit_line_uses_cost_per_item = function(T)
    local ns = setup()
    knowRecipe(ns, 2000)                      -- 5 cloth = 10000 per craft, 2 bags per craft
    putBag(ns, 2, false)
    ns.Sell.SetUnit(41999)
    local s = ns.Sell.State()
    T.eq(s.cost, 5000, "recipe cost / bags made")
    T.eq(s.costUnknown, false)
    T.near(s.net, 41999 * 0.95, 1e-6)
    T.near(s.profit, 41999 * 0.95 - 5000, 1e-6)
    T.eq(s.loss, false)
  end,

  loss_flagged_below_cost = function(T)
    local ns = setup()
    knowRecipe(ns, 2000)
    putBag(ns, 2, false)
    ns.Sell.SetUnit(4000)
    local s = ns.Sell.State()
    T.near(s.net, 3800, 1e-6)
    T.near(s.profit, -1200, 1e-6)
    T.eq(s.loss, true)
    T.eq(s.canPost, true, "posting below cost is still allowed")
    ns.Sell.SetUnit(5000 / 0.95 + 1)
    T.eq(ns.Sell.State().loss, false)
  end,

  cost_unknown_when_materials_missing = function(T)
    local ns = setup()
    knowRecipe(ns)                            -- no cloth price anywhere
    putBag(ns, 2, false)
    ns.Sell.SetUnit(41999)
    local s = ns.Sell.State()
    T.eq(s.costUnknown, true)
    T.eq(s.cost, nil)
    T.eq(s.profit, nil)
    T.eq(s.loss, nil)
    T.eq(s.canPost, true)
  end,

  no_cost_line_for_items_that_are_not_recipes = function(T)
    local ns = setup()
    putBag(ns, 2, false)
    ns.Sell.SetUnit(41999)
    local s = ns.Sell.State()
    T.eq(s.cost, nil)
    T.eq(s.profit, nil)
    T.eq(s.loss, nil)
    T.eq(s.costUnknown, false)
    T.near(s.net, 41999 * 0.95, 1e-6)
  end,

  cannot_auction_message = function(T)
    local ns = setup()
    Mock.auctionable[BAG] = false
    inBag(0, 1, BAG, BAG_NAME, 1)
    T.eq(ns.Sell.PutItem(0, 1), false)
    local s = ns.Sell.State()
    T.eq(s.status, CANT_AUCTION)
    T.eq(s.item, nil)
    T.eq(s.reason, "no-item")
    T.eq(Mock.cursor, nil, "the refused item went back to its bag")
    T.ok(Mock.cleared >= 1)
    T.eq(ns.Scanner.IsBusy(), false, "no price check for it")
  end,

  rejected_drop_keeps_the_item_in_the_slot = function(T)
    local ns = setup()
    inBag(0, 1, OTHER, OTHER_NAME, 1)
    inBag(0, 2, BAG, BAG_NAME, 1)
    Mock.ah.auctions = { auction(OTHER, OTHER_NAME, "Cara", 1, gold(100)) }
    T.ok(ns.Sell.PutItem(0, 1))
    T.ok(Mock.pump(ns))
    ns.Sell.SetUnit(gold(80))

    Mock.auctionable[BAG] = false
    T.eq(ns.Sell.PutItem(0, 2), false)
    T.eq(Mock.sellSlot.id, OTHER, "the game still holds the first item")
    local s = ns.Sell.State()
    T.eq(s.item.id, OTHER, "so do we")
    T.eq(s.unit, gold(80), "and its price")
    T.eq(s.status, CANT_AUCTION)
    T.eq(Mock.cursor, nil)
  end,

  emptied_slot_clears_quietly = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    putBag(ns, 2)
    T.eq(ns.Sell.State().unit, gold(419, 99))
    ns.Sell.SetUnit(gold(400))

    -- posting used the last bags: the game empties the slot
    Mock.sellSlot = nil
    ns.Sell.OnSlotChanged(nil)
    local s = ns.Sell.State()
    T.eq(s.item, nil)
    T.eq(s.unit, nil)
    T.eq(s.listings, nil)
    T.eq(s.reason, "no-item")
    T.eq(s.status, "", "no error text for a normal emptying")
    T.eq(ns.Sell.lastId, BAG, "the last item is remembered for the check after posting")

    -- a posting message is not wiped by it
    local ns2 = setup()
    putBag(ns2, 2)
    ns2.Sell.OnMultisell("AUCTION_MULTISELL_START", 2)
    Mock.sellSlot = nil
    ns2.Sell.OnSlotChanged(nil)
    T.eq(ns2.Sell.State().status, "Posting 0/2")

    -- a pending "Searching..." goes with the item
    local ns3 = setup()
    putBag(ns3, 1, false)
    T.eq(ns3.Sell.State().status, "Searching...")
    Mock.sellSlot = nil
    ns3.Sell.OnSlotChanged(nil)
    T.eq(ns3.Sell.State().status, "")
  end,

  drop_swaps_old_item_back = function(T)
    local ns = setup()
    inBag(0, 1, BAG, BAG_NAME, 1)
    inBag(0, 2, OTHER, OTHER_NAME, 1)
    putBag(ns, 1)
    T.eq(Mock.sellSlot.id, BAG)
    T.eq(Mock.cleared, 0)

    PickupContainerItem(0, 2)                 -- the player drags the other bag
    T.eq(Mock.cursor.id, OTHER)
    T.ok(ns.Sell.DropCursorItem())
    T.eq(Mock.sellSlot.id, OTHER, "dropped item is in the slot")
    T.eq(Mock.cursor, nil, "the old item was sent back")
    T.eq(Mock.cleared, 1, "ClearCursor returned it")
    T.eq(Mock.bags[0][1].id, BAG, "it is still in its bag")
    T.eq(ns.Sell.State().item.id, OTHER)
    T.eq(ns.Sell.State().item.name, OTHER_NAME)
    T.eq(ns.Sell.lastId, OTHER)

    -- nothing on the cursor: nothing to do
    T.eq(ns.Sell.DropCursorItem(), false)
    T.eq(Mock.sellSlot.id, OTHER)
  end,

  queued_check_runs_after_scan_finished = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    -- the player's own scan is running
    T.ok(ns.Scanner.StartTargeted({ { id = OTHER, name = OTHER_NAME } }))
    putBag(ns, 1, false)
    T.eq(ns.Sell.State().status, "Waiting for the current scan...")
    T.eq(#Mock.queries, 0)

    T.ok(Mock.pump(ns))
    -- the scan ended, the bag check ran right after it and ended too
    T.eq(Mock.queries[#Mock.queries][1], BAG_NAME, "the bag was searched")
    local s = ns.Sell.State()
    T.eq(s.unit, gold(419, 99))
    T.eq(s.status, "")
    T.eq(#s.listings, 1)
  end,

  put_item_by_id_not_in_bags = function(T)
    local ns = setup()
    local ok, err = ns.Sell.PutItemById(BAG)
    T.eq(ok, false)
    T.eq(err, "not-in-bags")
    T.eq(ns.Sell.State().item, nil)

    -- found in the first bag that has it
    inBag(2, 1, BAG, BAG_NAME, 1)
    inBag(1, 3, BAG, BAG_NAME, 2)
    inBag(0, 5, OTHER, OTHER_NAME, 1)
    ok, err = ns.Sell.PutItemById(BAG)
    T.eq(ok, true)
    T.eq(err, nil)
    T.eq(Mock.sellSlot.id, BAG)
    T.eq(Mock.sellSlot.bag, 1)
    T.eq(Mock.sellSlot.slot, 3)
    T.eq(ns.Sell.State().item.id, BAG)
    T.eq(ns.Sell.State().item.owned, 3)
  end,

  multisell_progress_and_recheck = function(T)
    local ns = setup()
    local changes = events(ns)
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    putBag(ns, 3)
    T.eq(#Mock.queries, 1)
    ns.Sell.SetStacks(3)
    changes.n = 0

    ns.Sell.OnMultisell("AUCTION_MULTISELL_START", 3)
    T.eq(ns.Sell.State().status, "Posting 0/3")
    ns.Sell.OnMultisell("AUCTION_MULTISELL_UPDATE", 1, 3)
    T.eq(ns.Sell.State().status, "Posting 1/3")
    T.eq(ns.Scanner.IsBusy(), false, "no new price check before the end")
    T.eq(changes.n, 2, "each change is announced")

    -- our three new auctions are on the AH by the time the last one is done
    Mock.ah.auctions[#Mock.ah.auctions + 1] = bagAuction("Me", gold(419, 99))
    ns.Sell.OnMultisell("AUCTION_MULTISELL_UPDATE", 3, 3)
    T.eq(ns.Sell.State().status, "Posted 3 auctions")
    T.ok(ns.Scanner.IsBusy(), "a fresh price check started")
    T.ok(Mock.pump(ns))
    T.eq(#Mock.queries, 2)
    local s = ns.Sell.State()
    T.eq(#s.listings, 2, "the listings now include our auctions")
    T.eq(s.status, "Posted 3 auctions", "still shown after the check")

    ns.Sell.OnMultisell("AUCTION_MULTISELL_UPDATE", 1, 1)
    T.eq(ns.Sell.State().status, "Posted 1 auction")
    ns.Sell.OnMultisell("AUCTION_MULTISELL_FAILURE")
    T.eq(ns.Sell.State().status, "Posting failed")
  end,

  refresh_after_posting_part_of_a_stack = function(T)
    local ns = setup()
    inBag(0, 1, CLOTH, CLOTH_NAME, 45)
    T.ok(ns.Sell.PutItem(0, 1))
    T.ok(Mock.pump(ns))
    T.eq(ns.Sell.State().stack, 20)
    T.eq(ns.Sell.State().stacks, 2)

    -- two stacks of 20 were posted: 5 are left and the slot still holds them
    Mock.bags[0][1].count = 5
    Mock.sellSlot.count = 5
    ns.Sell.OnMultisell("AUCTION_MULTISELL_UPDATE", 2, 2)
    ns.Sell.OnSlotChanged(nil)
    local s = ns.Sell.State()
    T.eq(s.item.id, CLOTH)
    T.eq(s.item.owned, 5)
    T.eq(s.stack, 5)
    T.eq(s.stacks, 1)
    T.eq(s.status, "Posted 2 auctions", "the game's update does not wipe the result")
    T.ok(Mock.pump(ns))
    T.eq(ns.Sell.State().status, "Posted 2 auctions")
  end,

  price_check_after_posting_even_if_the_slot_emptied = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    putBag(ns, 2)
    Mock.sellSlot = nil
    ns.Sell.OnSlotChanged(nil)
    T.eq(ns.Sell.State().item, nil)
    Mock.queries = {}
    ns.Sell.OnMultisell("AUCTION_MULTISELL_UPDATE", 2, 2)
    T.ok(ns.Scanner.IsBusy())
    T.ok(Mock.pump(ns))
    T.eq(Mock.queries[1][1], BAG_NAME)
    T.eq(#ns.Listings.Get(BAG), 1)
    T.eq(ns.Sell.State().status, "Posted 2 auctions")
  end,

  post_check_not_swallowed_by_a_check_in_flight = function(T)
    local ns = setup()
    putBag(ns, 2, false)                      -- the first check is still running
    ns.Sell.OnMultisell("AUCTION_MULTISELL_UPDATE", 2, 2)
    T.ok(Mock.pump(ns))
    T.eq(#Mock.queries, 2, "searched again after the post")
  end,

  nothing_but_post_starts_an_auction = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Flipper", gold(50)), bagAuction("Bob", gold(420)), bagAuction("Carl", gold(430)) }
    putBag(ns, 3)
    ns.Fire("SCAN_FINISHED")
    ns.Fire("LISTINGS_UPDATED", BAG)
    ns.Listings.Store(BAG, ns.Sell.State().listings)
    ns.Sell.OnSlotChanged(nil)
    ns.Sell.OnListings(BAG)
    ns.Sell.PickRow(ns.Sell.State().listings[2])
    ns.Sell.SetDuration(1)
    ns.Sell.OnMultisell("AUCTION_MULTISELL_START", 3)
    ns.Sell.OnMultisell("AUCTION_MULTISELL_UPDATE", 3, 3)
    ns.Sell.OnMultisell("AUCTION_MULTISELL_FAILURE")
    Mock.pump(ns)
    ns.Sell.State()
    T.eq(#Mock.started, 0, "a ready, priced item is not posted by itself")
    T.eq(ns.Sell.State().canPost, true)
    T.eq(ns.Sell.Post(), true)
    T.eq(#Mock.started, 1, "only Post posts")
  end,

  post_waits_for_price_check = function(T)
    local ns = setup()
    scanTrackedSawMistake(ns)
    inBag(0, 1, BAG, BAG_NAME, 3)
    T.ok(ns.Sell.PutItem(0, 1))
    local s = ns.Sell.State()
    T.eq(s.status, "Searching...")
    T.eq(s.canPost, false, "the stored 50g is not a price to post at")
    T.eq(s.reason, "checking")
    T.eq(ns.Sell.Post(), false)
    T.eq(#Mock.started, 0)

    T.ok(Mock.pump(ns))
    s = ns.Sell.State()
    T.eq(s.unit, gold(419, 99), "priced from the fresh listings")
    T.eq(s.canPost, true)
    T.eq(s.reason, nil)
  end,

  failed_check_needs_typed_price = function(T)
    local ns = setup()
    scanTrackedSawMistake(ns)
    inBag(0, 1, BAG, BAG_NAME, 3)
    T.ok(ns.Sell.PutItem(0, 1))
    ns.Scanner.Stop("AH closed")              -- the check ends without rows
    local s = ns.Sell.State()
    T.eq(s.status, NO_ANSWER)
    T.eq(s.canPost, false)
    T.eq(s.reason, "no-check")
    T.eq(ns.Sell.Post(), false)
    T.eq(#Mock.started, 0)

    ns.Sell.SetUnit(gold(400))
    s = ns.Sell.State()
    T.eq(s.canPost, true, "a price the player typed is posted as typed")
    T.eq(s.reason, nil)
    T.eq(ns.Sell.Post(), true)
    T.eq(Mock.started[1][1], gold(400))
  end,

  empty_check_ignores_stale_stored_price = function(T)
    local ns = setup()
    -- an earlier Scan tracked saw a lone 50g listing, which has since been bought
    ns.Prices.SetAH(BAG, gold(50), 1, Mock.now - 3600)
    putBag(ns, 3, false)
    T.eq(ns.Sell.State().reason, "checking")
    T.ok(Mock.pump(ns))
    local s = ns.Sell.State()
    T.eq(#s.listings, 0, "nothing is listed now")
    T.eq(s.unit, nil, "the stale stored price is not used")
    T.eq(s.canPost, false)
    T.eq(s.reason, "no-price")
  end,

  empty_check_falls_back_to_manual_then_auctionator = function(T)
    -- Auctionator only
    local ns = setup()
    Atr_GetAuctionBuyout = function() return gold(300) end
    ns.Prices.SetAH(BAG, gold(50), 1, Mock.now - 3600)
    putBag(ns, 3)
    T.eq(ns.Sell.State().unit, gold(300))
    T.eq(ns.Sell.State().canPost, true)

    -- a manual price beats it
    local ns2 = setup()
    Atr_GetAuctionBuyout = function() return gold(300) end
    ns2.Prices.SetManual(BAG, gold(500))
    ns2.Prices.SetAH(BAG, gold(50), 1, Mock.now - 3600)
    putBag(ns2, 3)
    T.eq(ns2.Sell.State().unit, gold(500))

    -- competition beats both
    local ns3 = setup()
    Atr_GetAuctionBuyout = function() return gold(300) end
    ns3.Prices.SetManual(BAG, gold(500))
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    putBag(ns3, 3)
    T.eq(ns3.Sell.State().unit, gold(419, 99))
  end,

  typed_price_can_post_without_check = function(T)
    local ns = setup()
    scanTrackedSawMistake(ns)
    inBag(0, 1, BAG, BAG_NAME, 3)
    T.ok(ns.Sell.PutItem(0, 1))
    T.eq(ns.Sell.State().reason, "checking")
    ns.Sell.SetUnit(gold(300))
    local s = ns.Sell.State()
    T.eq(s.canPost, true)
    T.eq(s.reason, nil)
    T.eq(ns.Sell.Post(), true)
    T.eq(Mock.started[1][1], gold(300))
  end,

  manual_price_can_post_without_check = function(T)
    local ns = setup()
    ns.Prices.SetManual(BAG, gold(500))
    inBag(0, 1, BAG, BAG_NAME, 3)
    T.ok(ns.Sell.PutItem(0, 1))
    local s = ns.Sell.State()
    T.eq(s.status, "Searching...")
    T.eq(s.unit, gold(500))
    T.eq(s.canPost, true, "the player set this price himself")
  end,

  double_post_blocked = function(T)
    local ns = setup()
    putBag(ns, 6)
    ns.Sell.SetUnit(gold(400))
    ns.Sell.SetStacks(3)
    T.eq(ns.Sell.Post(), true)
    local s = ns.Sell.State()
    T.eq(s.canPost, false)
    T.eq(s.reason, "posting")
    T.eq(ns.Sell.Post(), false, "a second click does not post again")
    T.eq(#Mock.started, 1)

    ns.Sell.OnMultisell("AUCTION_MULTISELL_START", 3)
    ns.Sell.OnMultisell("AUCTION_MULTISELL_UPDATE", 1, 3)
    T.eq(ns.Sell.State().reason, "posting", "still posting")
    T.eq(ns.Sell.Post(), false)
    T.eq(#Mock.started, 1)

    ns.Sell.OnMultisell("AUCTION_MULTISELL_UPDATE", 3, 3)
    T.eq(ns.Sell.State().reason, nil, "the last auction is up: free again")
    T.eq(ns.Sell.Post(), true)
    T.eq(#Mock.started, 2)

    -- a different item in the slot ends the lock
    inBag(0, 2, OTHER, OTHER_NAME, 1)
    T.eq(ns.Sell.State().reason, "posting")
    T.ok(ns.Sell.PutItem(0, 2))
    T.eq(ns.Sell.State().item.id, OTHER)
    T.eq(ns.Sell.State().reason, "checking", "not 'posting' any more")
  end,

  single_stack_post_completes_on_slot_empty = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    putBag(ns, 1)
    T.eq(ns.Sell.State().stacks, 1)
    T.eq(ns.Sell.Post(), true)
    T.eq(ns.Sell.State().reason, "posting")
    T.eq(ns.Sell.Post(), false)

    -- no multisell events: the game empties the slot
    Mock.ah.auctions[#Mock.ah.auctions + 1] = bagAuction("Me", gold(419, 99))
    Mock.sellSlot = nil
    Mock.queries = {}
    ns.Sell.OnSlotChanged(nil)
    T.eq(ns.Sell.State().status, "Posted 1 auction")
    T.ok(ns.Scanner.IsBusy(), "a fresh price check of the item started")
    T.ok(Mock.pump(ns))
    T.eq(Mock.queries[1][1], BAG_NAME)
    T.eq(#ns.Listings.Get(BAG), 2)
    T.eq(ns.Sell.State().status, "Posted 1 auction")

    -- the lock is gone: the item back in the slot is not "posting"
    Mock.sellSlot = { id = BAG, name = BAG_NAME, count = 1, bag = 0, slot = 1 }
    ns.Sell.OnSlotChanged(nil)
    T.eq(ns.Sell.State().item.id, BAG)
    T.ok(ns.Sell.State().reason ~= "posting")

    -- several stacks: the empty slot alone does not claim success
    local ns2 = setup()
    putBag(ns2, 3)
    ns2.Sell.SetUnit(gold(10))
    T.eq(ns2.Sell.State().stacks, 3)
    T.eq(ns2.Sell.Post(), true)
    Mock.sellSlot = nil
    ns2.Sell.OnSlotChanged(nil)
    T.eq(ns2.Sell.State().status, "Posting...")
  end,

  single_stack_post_completes_when_the_stack_shrinks = function(T)
    local ns = setup()
    inBag(0, 1, CLOTH, CLOTH_NAME, 30)
    T.ok(ns.Sell.PutItem(0, 1))
    T.ok(Mock.pump(ns))
    ns.Sell.SetUnit(500)
    ns.Sell.SetStack(10)
    ns.Sell.SetStacks(1)
    T.eq(ns.Sell.Post(), true)

    ns.Sell.OnSlotChanged(nil)                -- nothing was used up yet
    T.eq(ns.Sell.State().reason, "posting")

    Mock.bags[0][1].count = 20                -- 10 are gone, the slot keeps the rest
    Mock.sellSlot.count = 20
    ns.Sell.OnSlotChanged(nil)
    T.eq(ns.Sell.State().status, "Posted 1 auction")
    T.ok(ns.Sell.State().reason ~= "posting")
  end,

  failure_clears_posting_lock = function(T)
    local ns = setup()
    putBag(ns, 3)
    ns.Sell.SetUnit(gold(400))
    T.eq(ns.Sell.Post(), true)
    T.eq(ns.Sell.State().reason, "posting")
    ns.Sell.OnMultisell("AUCTION_MULTISELL_FAILURE")
    local s = ns.Sell.State()
    T.eq(s.status, "Posting failed")
    T.eq(s.reason, nil)
    T.eq(s.canPost, true)
    T.eq(ns.Sell.Post(), true, "the player can try again")
    T.eq(#Mock.started, 2)
  end,

  swap_back_drops_stale_queued_check = function(T)
    local ns = setup()
    Mock.ah.auctions = {
      bagAuction("Bob", gold(420)),
      auction(OTHER, OTHER_NAME, "Cara", 1, gold(100)),
    }
    inBag(0, 1, BAG, BAG_NAME, 1)
    inBag(0, 2, OTHER, OTHER_NAME, 1)
    T.ok(ns.Sell.PutItem(0, 1))               -- the bag check runs
    ns.Scanner.Tick(0.1)
    T.ok(ns.Sell.PutItem(0, 2))               -- the other bag waits for it
    T.eq(ns.Sell.State().status, "Waiting for the current scan...")
    T.ok(ns.Sell.PutItem(0, 1))               -- and the player changes his mind
    T.eq(ns.Sell.State().item.id, BAG)
    T.eq(ns.Sell.State().status, "Searching...", "the bag's check is the one in flight")

    T.ok(Mock.pump(ns))
    T.eq(#Mock.queries, 1, "the other bag was never searched")
    T.eq(Mock.queries[1][1], BAG_NAME)
    local s = ns.Sell.State()
    T.eq(s.status, "", "no 'Searching...' left behind")
    T.eq(s.unit, gold(419, 99))
    T.eq(s.listings[1].seller, "Bob")
    T.eq(s.canPost, true)
  end,

  owned_limited_by_sell_slot_total = function(T)
    local ns = setup()
    -- one of the four is equipped: the bags count it, the client will not post it
    Mock.sellTotal[BAG] = 3
    inBag(0, 1, BAG, BAG_NAME, 3)
    inBag(0, 2, BAG, BAG_NAME, 1)
    T.eq(GetItemCount(BAG), 4)
    T.ok(ns.Sell.PutItem(0, 1))
    local s = ns.Sell.State()
    T.eq(s.item.owned, 3)
    T.eq(s.stack, 1)
    T.eq(s.stacks, 3)
    ns.Sell.SetUnit(gold(10))
    T.eq(ns.Sell.State().canPost, true)
    ns.Sell.SetStacks(4)
    T.eq(ns.Sell.State().reason, "too-many")
    T.eq(ns.Sell.Post(), false)
    T.eq(#Mock.started, 0)

    -- stackables too: 45 in the bags, 40 for sale
    local ns2 = setup()
    Mock.sellTotal[CLOTH] = 40
    inBag(0, 1, CLOTH, CLOTH_NAME, 45)
    T.ok(ns2.Sell.PutItem(0, 1))
    T.eq(ns2.Sell.State().item.owned, 40)
    T.eq(ns2.Sell.State().stack, 20)
    T.eq(ns2.Sell.State().stacks, 2)
    ns2.Sell.SetUnit(500)
    ns2.Sell.SetStacks(3)
    T.eq(ns2.Sell.State().reason, "too-many")

    -- the limit follows the game's number as it changes
    Mock.sellTotal[CLOTH] = 10
    ns2.Sell.SetStacks(1)
    T.eq(ns2.Sell.State().reason, "too-many", "20 > 10")
  end,

  slot_holding_other_item_blocks_post = function(T)
    local ns = setup()
    Mock.ah.auctions = { auction(CLOTH, CLOTH_NAME, "Bob", 20, 20 * 300) }
    inBag(0, 1, CLOTH, CLOTH_NAME, 20)
    inBag(0, 2, OTHER, OTHER_NAME, 1)
    T.ok(ns.Sell.PutItem(0, 1))
    T.ok(Mock.pump(ns))
    T.eq(ns.Sell.State().unit, 200, "3s each: the whole silver below")
    T.eq(ns.Sell.State().canPost, true)

    -- the game's slot now holds the other bag and we have not heard about it
    Mock.sellSlot = { id = OTHER, name = OTHER_NAME, count = 1, bag = 0, slot = 2 }
    local s = ns.Sell.State()
    T.eq(s.canPost, false)
    T.eq(s.reason, "slot-changed")
    T.eq(ns.Sell.Post(), false)
    T.eq(#Mock.started, 0, "the cloth price never goes on the bag")

    -- when the event arrives the other bag is priced on its own
    ns.Sell.OnSlotChanged(nil)
    s = ns.Sell.State()
    T.eq(s.item.id, OTHER)
    T.ok(s.unit ~= 200)
    T.ok(s.reason ~= "slot-changed")
  end,

  price_check_uses_item_name_from_id = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    -- the slot names the suffix; the search uses the item's own name
    inBag(0, 1, BAG, "Frostweave Bag of the Eagle", 1)
    T.ok(ns.Sell.PutItem(0, 1))
    T.ok(Mock.pump(ns))
    T.eq(Mock.queries[1][1], BAG_NAME)
    local s = ns.Sell.State()
    T.eq(s.item.name, "Frostweave Bag of the Eagle", "the slot's name is what is shown")
    T.eq(s.unit, gold(419, 99))

    -- GetItemInfo does not know the item: the slot's name is all there is
    local ns2 = setup()
    Mock.items[BAG] = nil
    inBag(0, 1, BAG, "Frostweave Bag of the Eagle", 1)
    T.ok(ns2.Sell.PutItem(0, 1))
    ns2.Scanner.Tick(0.1)
    T.eq(Mock.queries[1][1], "Frostweave Bag of the Eagle")
  end,

  manual_price_set_after_place_updates_price = function(T)
    local ns = setup()
    -- the item goes in showing a stale stored 50g while its check runs
    ns.Prices.SetAH(BAG, gold(50), 1, Mock.now - 3600)
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    putBag(ns, 3, false)
    local s = ns.Sell.State()
    T.eq(s.unit, gold(50))
    T.eq(s.reason, "checking")

    -- /cp price <item> 400g
    ns.Prices.SetManual(BAG, gold(400))
    ns.Fire("PRICES_CHANGED")
    s = ns.Sell.State()
    T.eq(s.unit, gold(400), "the page shows the price the player just set")
    T.eq(s.canPost, true)
    T.eq(s.reason, nil)
    T.eq(ns.Sell.Post(), true)
    T.eq(Mock.started[1][1], gold(400), "and that is what is posted")

    -- the same after a check that got no answer
    local ns2 = setup()
    ns2.Prices.SetAH(BAG, gold(50), 1, Mock.now - 3600)
    putBag(ns2, 3, false)
    ns2.Scanner.Stop("AH closed")
    T.eq(ns2.Sell.State().reason, "no-check")
    ns2.Prices.SetManual(BAG, gold(400))
    ns2.Fire("PRICES_CHANGED")
    s = ns2.Sell.State()
    T.eq(s.unit, gold(400))
    T.eq(s.canPost, true)

    -- removing the price again takes the exemption away with it
    ns2.Prices.SetManual(BAG, nil)
    ns2.Fire("PRICES_CHANGED")
    s = ns2.Sell.State()
    T.eq(s.unit, gold(50), "back to the stored price, which is shown only")
    T.eq(s.canPost, false)
    T.eq(s.reason, "no-check")
  end,

  manual_price_change_keeps_what_the_player_chose_and_the_competition = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    putBag(ns, 3)
    T.eq(ns.Sell.State().unit, gold(419, 99))
    -- the listings decide when someone competes: a manual price is only the fallback
    ns.Prices.SetManual(BAG, gold(400))
    ns.Fire("PRICES_CHANGED")
    T.eq(ns.Sell.State().unit, gold(419, 99))

    -- and a price the player typed is never replaced
    ns.Sell.SetUnit(gold(300))
    ns.Prices.SetManual(BAG, gold(350))
    ns.Fire("PRICES_CHANGED")
    T.eq(ns.Sell.State().unit, gold(300))

    -- nothing shown: nothing to update
    local ns2 = setup()
    ns2.Prices.SetManual(BAG, gold(350))
    ns2.Fire("PRICES_CHANGED")
    T.eq(ns2.Sell.State().item, nil)
    T.eq(ns2.Sell.State().unit, nil)

    -- an unchanged price is not news
    local ns3 = setup()
    ns3.Prices.SetManual(BAG, gold(350))
    putBag(ns3, 3)
    local count = events(ns3)
    ns3.Fire("PRICES_CHANGED")
    T.eq(count.n, 0, "no redraw when the price stayed the same")
  end,

  stale_unit_not_exempt_by_manual_price = function(T)
    local ns = setup()
    ns.Prices.SetAH(BAG, gold(50), 1, Mock.now - 3600)
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    putBag(ns, 3, false)
    -- a manual price now exists, but the price on the page is still the stale one
    ns.Prices.SetManual(BAG, gold(400))
    local s = ns.Sell.State()
    T.eq(s.unit, gold(50))
    T.eq(s.canPost, false, "the exemption is for a price the page shows, not any manual price")
    T.eq(s.reason, "checking")
    T.eq(ns.Sell.Post(), false)
    T.eq(#Mock.started, 0)

    -- same once the check has failed
    ns.Scanner.Stop("AH closed")
    s = ns.Sell.State()
    T.eq(s.canPost, false)
    T.eq(s.reason, "no-check")
    T.eq(ns.Sell.Post(), false)
    T.eq(#Mock.started, 0)

    -- put in with the manual price already set: the page shows it, no check needed
    local ns2 = setup()
    ns2.Prices.SetAH(BAG, gold(50), 1, Mock.now - 3600)
    ns2.Prices.SetManual(BAG, gold(400))
    putBag(ns2, 3, false)
    T.eq(ns2.Sell.State().unit, gold(400))
    T.eq(ns2.Sell.State().canPost, true)
  end,

  swap_back_with_game_updates_drops_stale_check = function(T)
    local ns = setup()
    Mock.ah.auctions = {
      bagAuction("Bob", gold(420)),
      auction(OTHER, OTHER_NAME, "Cara", 1, gold(100)),
    }
    inBag(0, 1, BAG, BAG_NAME, 1)
    inBag(0, 2, OTHER, OTHER_NAME, 1)
    -- the game sends NEW_AUCTION_UPDATE after every drop
    T.ok(ns.Sell.PutItem(0, 1))
    ns.Sell.OnSlotChanged(nil)
    ns.Scanner.Tick(0.1)                      -- the bag's check is on its way
    T.ok(ns.Sell.PutItem(0, 2))
    ns.Sell.OnSlotChanged(nil)
    T.ok(ns.Sell.PutItem(0, 1))
    ns.Sell.OnSlotChanged(nil)
    T.eq(ns.Sell.State().item.id, BAG)

    T.ok(Mock.pump(ns))
    T.eq(#Mock.queries, 1, "the other bag was never searched")
    T.eq(Mock.queries[1][1], BAG_NAME)
    local s = ns.Sell.State()
    T.eq(s.status, "")
    T.eq(s.unit, gold(419, 99))
    T.eq(s.canPost, true)
  end,

  post_check_survives_game_update_for_same_item = function(T)
    local ns = setup()
    putBag(ns, 2, false)                      -- the first check is still running
    ns.Sell.OnMultisell("AUCTION_MULTISELL_UPDATE", 2, 2)   -- queues the check after the post
    ns.Sell.OnSlotChanged(nil)                -- the game's own update for the same item
    T.ok(Mock.pump(ns))
    T.eq(#Mock.queries, 2, "the check after the post still ran")
  end,

  post_waits_for_fresh_check_after_posting = function(T)
    -- several auctions: the last multisell update
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    putBag(ns, 4)
    ns.Sell.SetStacks(2)
    T.eq(ns.Sell.State().unit, gold(419, 99))
    T.eq(ns.Sell.Post(), true)
    Mock.ah.auctions[#Mock.ah.auctions + 1] = bagAuction("Me", gold(419, 99))
    ns.Sell.OnMultisell("AUCTION_MULTISELL_START", 2)
    ns.Sell.OnMultisell("AUCTION_MULTISELL_UPDATE", 2, 2)
    local s = ns.Sell.State()
    T.eq(s.status, "Posted 2 auctions")
    T.eq(s.canPost, false, "the rows on the page are from before the post")
    T.eq(s.reason, "checking")
    T.eq(ns.Sell.Post(), false)
    T.eq(#Mock.started, 1)

    T.ok(Mock.pump(ns))
    s = ns.Sell.State()
    T.eq(s.reason, nil)
    T.eq(s.canPost, true)
    T.eq(s.unit, gold(419, 99), "now matching our own auction, not undercutting it blind")
    T.eq(s.status, "Posted 2 auctions")

    -- a single stack that leaves the rest of a stack in the slot
    local ns2 = setup()
    Mock.ah.auctions = { auction(CLOTH, CLOTH_NAME, "Bob", 20, 20 * 300) }
    inBag(0, 1, CLOTH, CLOTH_NAME, 30)
    T.ok(ns2.Sell.PutItem(0, 1))
    T.ok(Mock.pump(ns2))
    ns2.Sell.SetUnit(250)
    ns2.Sell.SetStack(10)
    ns2.Sell.SetStacks(1)
    T.eq(ns2.Sell.Post(), true)
    Mock.bags[0][1].count = 20                -- 10 are gone, the slot keeps the rest
    Mock.sellSlot.count = 20
    ns2.Sell.OnSlotChanged(nil)
    s = ns2.Sell.State()
    T.eq(s.status, "Posted 1 auction")
    T.eq(s.canPost, false)
    T.eq(s.reason, "checking")
    T.ok(Mock.pump(ns2))
    T.eq(ns2.Sell.State().reason, nil)

    -- the check after the post gets no answer: a typed price is needed
    local ns3 = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    putBag(ns3, 4)
    ns3.Sell.SetStacks(2)
    T.eq(ns3.Sell.Post(), true)
    ns3.Sell.OnMultisell("AUCTION_MULTISELL_UPDATE", 2, 2)
    ns3.Scanner.Stop("AH closed")
    T.eq(ns3.Sell.State().reason, "no-check")
    ns3.Sell.SetUnit(gold(10))
    T.eq(ns3.Sell.State().canPost, true)
  end,

  start_auction_only_in_post = function(T)
    local f = assert(io.open(Mock.root .. "Sell.lua", "r"))
    local src = f:read("*a")
    f:close()
    local first = src:find("StartAuction", 1, true)
    T.ok(first, "Sell.lua posts")
    T.eq(src:find("StartAuction", first + 1, true), nil, "exactly one call")
    local postStart = src:find("\nfunction Sell.Post(", 1, true)
    T.ok(postStart, "Sell.Post exists")
    local postEnd = src:find("\nfunction ", postStart + 1, true) or #src
    T.ok(first > postStart and first < postEnd, "the call is inside Sell.Post")
    -- Only the button may call Post (Task 8 wires it): no caller in this file.
    local calls = 0
    for _ in src:gmatch("Sell%.Post%(") do calls = calls + 1 end
    T.eq(calls, 1, "only the definition")
    T.eq(src:find("CancelAuction", 1, true), nil, "Sell never cancels")
  end,
}
