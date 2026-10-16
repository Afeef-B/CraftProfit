local Mock = require("wow_mock")

local REALM = "Icecrown-Alliance"
local CLOTH, CLOTH_NAME = 33470, "Frostweave Cloth"
local BOLT, BOLT_NAME = 41510, "Bolt of Frostweave"
local BAG, BAG_NAME = 41599, "Frostweave Bag"
local THREAD, THREAD_NAME = 38426, "Eternium Thread"

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

  materials_ready_and_scratch = function(T)
    local ns = setup()
    local recipes = ns.Recipes.All()
    recipes[BAG] = { name = BAG_NAME, made = 1, reagents = {
      { id = BOLT, name = BOLT_NAME, count = 2 }, { id = THREAD, name = THREAD_NAME, count = 1 } } }
    recipes[BOLT] = { name = BOLT_NAME, made = 1, reagents = { { id = CLOTH, name = CLOTH_NAME, count = 5 } } }
    Mock.bags[0] = { [1] = { id = BOLT, name = BOLT_NAME, count = 2 } }

    ns.Recipes.SetDepth(BAG, "ready")
    local list = ns.Buy.Materials(BAG, 3)
    T.eq(#list, 2)
    T.eq(list[1].id, BOLT)
    T.eq(list[1].need, 6)
    T.eq(list[1].have, 2)
    T.eq(list[2].id, THREAD)
    T.eq(list[2].need, 3)

    ns.Recipes.SetDepth(BAG, "scratch")
    list = ns.Buy.Materials(BAG, 3)
    T.eq(#list, 2)
    T.eq(list[1].id, CLOTH)
    T.eq(list[1].need, 30)
    T.eq(list[2].id, THREAD)
    T.eq(list[2].need, 3)
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
}
