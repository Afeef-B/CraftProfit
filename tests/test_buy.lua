local Mock = require("wow_mock")

local REALM = "Icecrown-Alliance"
local CLOTH, CLOTH_NAME = 33470, "Frostweave Cloth"
local BOLT, BOLT_NAME = 41510, "Bolt of Frostweave"
local BAG, BAG_NAME = 41599, "Frostweave Bag"
local THREAD, THREAD_NAME = 38426, "Eternium Thread"
local DUST, DUST_NAME = 34054, "Infinite Dust"

local function silver(s) return s * 100 end

local function auction(id, name, seller, count, unit)
  return { id = id, name = name, count = count, buyout = count * unit, seller = seller }
end

local function cloth(seller, count, unit) return auction(CLOTH, CLOTH_NAME, seller, count, unit) end

local function setup(auctions, cached)
  Mock.reset()
  Mock.installUI()
  local ns = Mock.load({
    "Util.lua", "Style.lua", "Profit.lua", "Prices.lua", "Recipes.lua", "Scanner.lua",
    "Listings.lua", "Buyer.lua", "Buy.lua",
  })
  local db = { cut = 0.05, chars = { [REALM] = { Twink = true } } }
  ns.db = db
  ns.Prices.SetDB(db, REALM)
  ns.Scanner.SetDB(db)
  ns.Listings.SetDB(db, REALM, "Me")
  ns.Recipes.SetDB({})
  hooksecurefunc("QueryAuctionItems", ns.Scanner.OnQuery)
  if cached ~= false then Mock.items[CLOTH] = { name = CLOTH_NAME, maxStack = 20 } end
  Mock.ah.auctions = auctions or {}
  Mock.money = 1000 * 10000
  return ns
end

-- Search the cloth and let the price check finish.
local function searchCloth(ns)
  assert(ns.Buy.Search(CLOTH_NAME))
  assert(Mock.pump(ns), "price check finished")
end

local function rowOf(ns, seller)
  for _, row in ipairs(ns.Buy.Rows()) do
    if row.seller == seller then return row end
  end
end

return {
  pick_cheapest_that_fits = function(T)
    local ns = setup({
      cloth("A", 20, silver(9)), cloth("B", 5, silver(10)),
      cloth("C", 3, silver(11)), cloth("D", 1, silver(12)),
    })
    searchCloth(ns)
    ns.Buy.SetNeed(4)
    T.eq(ns.Buy.Pick().count, 3, "20 and 5 are bigger than needed; 3 @ 11s is the cheapest that fits")
  end,

  nothing_fits_takes_lowest_total = function(T)
    local ns = setup({ cloth("A", 20, silver(9)), cloth("B", 5, silver(10)) })
    searchCloth(ns)
    ns.Buy.SetNeed(4)
    T.eq(ns.Buy.Pick().count, 5, "50s in total beats 1g 80s")
  end,

  no_need_takes_cheapest_unit = function(T)
    local ns = setup({ cloth("A", 20, silver(9)), cloth("B", 5, silver(10)) })
    searchCloth(ns)
    T.eq(ns.Buy.Need(), nil)
    T.eq(ns.Buy.Pick().count, 20)
  end,

  own_rows_never_picked = function(T)
    local ns = setup({
      cloth("Me", 5, silver(5)), cloth("Twink", 5, silver(6)), cloth("Bob", 5, silver(9)),
    })
    searchCloth(ns)
    T.eq(ns.Buy.Pick().seller, "Bob", "mine and my alt's are skipped")
    local ok, msg = ns.Buy.BuyRow(rowOf(ns, "Me"))
    T.ok(not ok)
    T.eq(msg, "That's your own listing.")
    T.eq(#Mock.bought, 0)
  end,

  bought_row_skipped_until_refresh = function(T)
    local ns = setup({ cloth("A", 5, silver(9)), cloth("B", 5, silver(10)) })
    searchCloth(ns)
    local first = ns.Buy.Pick()
    T.eq(first.seller, "A")
    T.ok(ns.Buy.BuyCheapest())
    T.eq(#Mock.bought, 1)
    -- the post-buy check has not answered: A's row is still cached
    T.ok(rowOf(ns, "A") == first)
    T.eq(ns.Buy.Pick().seller, "B", "the bought row is not picked again")
  end,

  countdown_and_done = function(T)
    local ns = setup({ cloth("A", 20, silver(9)), cloth("B", 20, silver(10)), cloth("C", 20, silver(11)) })
    searchCloth(ns)
    ns.Buy.SetNeed(40)
    T.ok(ns.Buy.BuyCheapest())
    T.eq(ns.Buy.Status(), "Bought 20 of 40 (spent " .. ns.Style.Money(20 * silver(9)) .. ")")
    T.eq(ns.Buy.Need(), 20)
    Mock.pump(ns) -- the post-buy check
    T.ok(ns.Buy.BuyCheapest())
    T.eq(ns.Buy.Status(), "Done (bought 40)")
    T.eq(ns.Buy.Need(), 0)
    T.eq(ns.Buy.Pick(), nil, "nothing more to buy")
    ns.Buy.SetNeed(10)
    T.eq(ns.Buy.Need(), 10, "a new need starts over")
    T.ok(ns.Buy.Pick(), "C is left")
  end,

  substring_results_keep_only_the_named_item = function(T)
    local ns = setup({
      auction(BOLT, BOLT_NAME, "Bob", 5, silver(80)),
      cloth("Kim", 20, silver(9)),
      auction(BAG, BAG_NAME, "Ann", 1, 4000000),
    }, false) -- the cloth is not in the client's item cache
    T.ok(ns.Buy.Search("Frostweave Cloth"))
    Mock.deliver(ns)
    ns.Buy.OnListUpdate()           -- the name search answered: find the exact name
    T.ok(Mock.pump(ns), "price check of the cloth")
    local id, name = ns.Buy.Current()
    T.eq(id, CLOTH)
    T.eq(name, CLOTH_NAME)
    for _, row in ipairs(ns.Buy.Rows()) do T.eq(row.seller, "Kim", "only cloth rows") end
    T.eq(#ns.Buy.Rows(), 1)

    local ns2 = setup({ auction(BOLT, BOLT_NAME, "Bob", 5, silver(80)), cloth("Kim", 20, silver(9)) }, false)
    T.ok(ns2.Buy.Search("frostweave cloth"))
    Mock.deliver(ns2)
    ns2.Buy.OnListUpdate()
    T.ok(Mock.pump(ns2))
    T.eq((ns2.Buy.Current()), CLOTH, "the name is matched without regard to case")
  end,

  unknown_name_says_so = function(T)
    local ns = setup({ auction(BOLT, BOLT_NAME, "Bob", 5, silver(80)) }, false)
    T.ok(ns.Buy.Search("Frostweave Cloth"))
    Mock.deliver(ns)
    ns.Buy.OnListUpdate()
    T.eq(ns.Buy.Current(), nil)
    T.eq(ns.Buy.Status(), "No item called Frostweave Cloth on the Auction House.")
    T.eq(#Mock.bought, 0)
  end,

  search_waits_for_busy_scanner = function(T)
    local ns = setup({ cloth("Kim", 20, silver(9)), auction(BOLT, BOLT_NAME, "Bob", 5, silver(80)) })
    Mock.items[BOLT] = { name = BOLT_NAME }
    assert(ns.Scanner.PriceCheck({ id = BOLT, name = BOLT_NAME }))
    local ok, err = ns.Buy.Search(CLOTH_NAME)
    T.ok(not ok)
    T.eq(err, "busy")
    T.eq(ns.Buy.Status(), "Waiting for the current scan...")
    T.ok(Mock.pump(ns), "the bolt check ends, then ours runs")
    T.ok(Mock.pump(ns))
    T.eq((ns.Buy.Current()), CLOTH)
    T.eq(#ns.Buy.Rows(), 1)
  end,

  buy_never_without_click = function(T)
    local ns = setup({ cloth("A", 5, silver(9)) })
    searchCloth(ns)
    ns.Buy.SetNeed(5)
    for _, event in ipairs({ "LISTINGS_UPDATED", "SCAN_FINISHED", "PRICES_CHANGED", "BUYER_CHANGED" }) do
      ns.Fire(event, CLOTH)
    end
    ns.Buy.OnListUpdate()
    T.eq(#Mock.bought, 0, "events never buy")
  end,

  identical_stacks_bid_distinct_auctions = function(T)
    local ns = setup({ cloth("Bob", 20, silver(9)), cloth("Bob", 20, silver(9)), cloth("Bob", 20, silver(9)) })
    searchCloth(ns)
    Mock.staleList = true            -- the page keeps showing sold auctions until it refreshes
    ns.Buy.SetNeed(60)
    for _ = 1, 3 do T.ok(ns.Buy.BuyCheapest()) end
    T.eq(#Mock.bought, 3)
    local seen = {}
    for _, b in ipairs(Mock.bought) do
      T.ok(not b.refused, "every bid hits an auction still for sale")
      T.ok(not seen[b.index], "index " .. b.index .. " bid once")
      seen[b.index] = true
    end
    T.eq(ns.Buy.Status(), "Done (bought 60)")
  end,

  vanished_cheapest_is_skipped_and_searched_again = function(T)
    local ns = setup({ cloth("A", 5, silver(9)), cloth("B", 5, silver(10)) })
    searchCloth(ns)
    local a = rowOf(ns, "A")
    -- someone else bought A while the player looked at another page
    table.remove(Mock.ah.auctions, 1)
    Mock.list, Mock.total = { auction(BOLT, BOLT_NAME, "Zed", 1, silver(80)) }, 1
    local ok, msg = ns.Buy.BuyCheapest()
    T.ok(not ok)
    T.eq(msg, "Finding it...")
    Mock.deliver(ns)
    ns.Buyer.OnListUpdate()
    T.eq(ns.Buyer.State(a), "gone")
    T.ok(ns.Scanner.IsBusy(), "the item is searched again")
    T.ok(Mock.pump(ns))
    T.eq(ns.Buy.Pick().seller, "B", "the next click tries B")
    T.ok(ns.Buy.BuyCheapest())
    T.eq(Mock.bought[#Mock.bought].auction.seller, "B")
  end,

  gone_row_not_picked_before_the_refresh = function(T)
    local ns = setup({ cloth("A", 5, silver(9)), cloth("B", 5, silver(10)) })
    searchCloth(ns)
    local a = rowOf(ns, "A")
    table.remove(Mock.ah.auctions, 1)
    Mock.list, Mock.total = { auction(BOLT, BOLT_NAME, "Zed", 1, silver(80)) }, 1
    ns.Buy.BuyCheapest()
    Mock.deliver(ns)
    ns.Buyer.OnListUpdate()
    T.eq(ns.Buyer.State(a), "gone")
    T.ok(rowOf(ns, "A") == a, "still cached until the new search answers")
    T.eq(ns.Buy.Pick().seller, "B")
  end,

  search_that_never_answers_searches_again = function(T)
    local ns = setup({ cloth("A", 5, silver(9)), cloth("B", 5, silver(10)) })
    searchCloth(ns)
    Mock.list, Mock.total = { auction(BOLT, BOLT_NAME, "Zed", 1, silver(80)) }, 1
    Mock.ah.canQuery = true
    T.eq(select(2, ns.Buy.BuyCheapest()), "Finding it...")
    Mock.pending = false            -- the answer never comes
    for _ = 1, 11 do ns.Buyer.Tick(1) end
    T.ok(ns.Scanner.IsBusy(), "the item is searched again after the timeout")
  end,

  lookup_waits_for_names_to_load = function(T)
    local ns = setup({ cloth("Kim", 20, silver(9)) }, false)
    Mock.ah.nilNames = true
    T.ok(ns.Buy.Search(CLOTH_NAME))
    Mock.deliver(ns)
    ns.Buy.OnListUpdate()
    T.eq(ns.Buy.Current(), nil, "not decided yet")
    T.ok(ns.Buy.Status() ~= "No item called Frostweave Cloth on the Auction House.")
    Mock.ah.nilNames = false
    ns.Buy.OnListUpdate()                     -- the names arrived
    T.eq((ns.Buy.Current()), CLOTH)

    -- names that never load: after a moment, decide from what can be read
    local ns2 = setup({ cloth("Kim", 20, silver(9)) }, false)
    Mock.ah.nilNames = true
    T.ok(ns2.Buy.Search(CLOTH_NAME))
    Mock.deliver(ns2)
    ns2.Buy.OnListUpdate()
    ns2.Buy.Tick(2.5)
    T.eq(ns2.Buy.Status(), "No item called Frostweave Cloth on the Auction House.")
  end,

  late_lookup_does_not_switch_items = function(T)
    local ns = setup({ cloth("Kim", 20, silver(9)), auction(DUST, DUST_NAME, "Dee", 5, silver(30)) })
    T.ok(ns.Buy.Search(DUST_NAME))            -- not cached: looked up on the AH
    -- before the answer, the player shift-clicks cloth and sets a need
    ns.Buy.SearchLink(Mock.Link(CLOTH, CLOTH_NAME))
    ns.Buy.SetNeed(40)
    Mock.deliver(ns)
    ns.Buy.OnListUpdate()                     -- the dust answer arrives late
    T.eq((ns.Buy.Current()), CLOTH, "still the cloth")
    T.eq(ns.Buy.Need(), 40)
  end,

  stale_page_is_not_the_answer = function(T)
    local ns = setup({ cloth("Kim", 20, silver(9)), auction(DUST, DUST_NAME, "Dee", 5, silver(30)) }, false)
    -- the client shows a page of bolts; its late update must not count
    Mock.list, Mock.total = { auction(BOLT, BOLT_NAME, "Bob", 5, silver(80)) }, 1
    local saved = Mock.list
    T.ok(ns.Buy.Search(CLOTH_NAME))
    Mock.list, Mock.total = saved, 1          -- a late update for that same page
    ns.Buy.OnListUpdate()
    T.eq(ns.Buy.Current(), nil)
    T.ok(ns.Buy.Status() ~= "No item called Frostweave Cloth on the Auction House.", "no false answer")
  end,

  throttled_lookup_retries = function(T)
    local ns = setup({ cloth("Kim", 20, silver(9)) }, false)
    Mock.ah.canQuery = false
    local ok = ns.Buy.Search(CLOTH_NAME)
    T.ok(not ok)
    local sent = #Mock.queries
    Mock.ah.canQuery = true
    ns.Buy.Tick(1)
    T.eq(#Mock.queries, sent + 1, "the lookup is sent once the AH allows it")
  end,

  search_item_by_id_needs_no_lookup = function(T)
    local ns = setup({ auction(BOLT, BOLT_NAME, "Bob", 5, silver(80)) }, false)
    ns.Buy.SearchItem(BOLT, BOLT_NAME)
    T.eq((ns.Buy.Current()), BOLT, "shown at once, by id")
    ns.Buy.SetNeed(4)
    T.ok(Mock.pump(ns))
    T.eq(ns.Buy.Need(), 4, "the need belongs to the bolts")
  end,

  link_without_a_name_is_refused = function(T)
    local ns = setup({}, false)
    local ok, err = ns.Buy.SearchLink("item:" .. DUST .. ":0:0:0:0:0:0:0:80")
    T.ok(not ok)
    T.eq(err, "no-name")
    T.eq(ns.Buy.Current(), nil)
  end,

  have_enough_means_no_target = function(T)
    local ns = setup({ cloth("A", 5, silver(9)) })
    searchCloth(ns)
    ns.Buy.SetNeed(0)
    T.eq(ns.Buy.Need(), 0)
    T.eq(ns.Buy.Pick(), nil, "nothing to buy when you have enough")
    T.eq(ns.Buy.Status(), "You have enough.")
  end,
}
