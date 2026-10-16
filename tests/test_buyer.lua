local Mock = require("wow_mock")

local REALM = "Icecrown-Alliance"
local CLOTH, CLOTH_NAME = 33470, "Frostweave Cloth"
local ITEM = { id = CLOTH, name = CLOTH_NAME }

local function gold(g) return g * 10000 end

local function auction(seller, count, buyout)
  return { id = CLOTH, name = CLOTH_NAME, count = count, buyout = buyout, seller = seller }
end

-- A fresh namespace after a price check of the cloth: the cached rows carry
-- page and index, the "list" page still shows them, the player has 1000g.
local function setup(auctions)
  Mock.reset()
  Mock.installUI()
  local ns = Mock.load({
    "Util.lua", "Profit.lua", "Prices.lua", "Recipes.lua", "Scanner.lua", "Listings.lua",
    "Buyer.lua",
  })
  local db = { cut = 0.05 }
  ns.db = db
  ns.Prices.SetDB(db, REALM)
  ns.Scanner.SetDB(db)
  ns.Listings.SetDB(db, REALM, "Me")
  hooksecurefunc("QueryAuctionItems", ns.Scanner.OnQuery)
  Mock.items[CLOTH] = { name = CLOTH_NAME }
  Mock.ah.auctions = auctions or {
    auction("Bob", 20, gold(4)),
    auction("Kim", 5, gold(1)),
  }
  Mock.money = gold(1000)
  assert(ns.Scanner.PriceCheck(ITEM))
  assert(Mock.pump(ns), "price check finished")
  Mock.queries = {}
  return ns
end

local function rowBy(ns, seller)
  for _, row in ipairs(ns.Listings.Get(CLOTH)) do
    if row.seller == seller then return row end
  end
end

return {
  buys_exact_row_on_page = function(T)
    local ns = setup()
    local row = rowBy(ns, "Kim")
    local ok, msg = ns.Buyer.Buy(CLOTH, row, CLOTH_NAME)
    T.ok(ok, "bought")
    T.eq(#Mock.bought, 1)
    T.eq(Mock.bought[1].amount, gold(1))
    T.eq(Mock.bought[1].auction.seller, "Kim")
    T.eq(ns.Buyer.State(row), "bought")
    T.ok(ns.Buyer.IsBought(row))
    T.ok(msg:find("Bid placed for", 1, true), msg)
  end,

  state_is_per_row = function(T)
    local ns = setup()
    local kim, bob = rowBy(ns, "Kim"), rowBy(ns, "Bob")
    ns.Buyer.Buy(CLOTH, kim, CLOTH_NAME)
    T.eq(ns.Buyer.State(kim), "bought")
    T.eq(ns.Buyer.State(bob), "idle")
    T.ok(not ns.Buyer.IsBought(bob))
  end,

  replaced_rows_are_idle = function(T)
    local ns = setup()
    local kim = rowBy(ns, "Kim")
    ns.Buyer.Buy(CLOTH, kim, CLOTH_NAME)
    -- the post-buy check stores fresh row tables
    Mock.pump(ns)
    local fresh = rowBy(ns, "Bob")
    T.ok(fresh, "Bob still listed")
    T.eq(ns.Buyer.State(fresh), "idle")
    T.ok(not rowBy(ns, "Kim"), "Kim's stack is gone after the buy")
  end,

  second_buy_of_a_bought_row_refused = function(T)
    local ns = setup()
    local kim = rowBy(ns, "Kim")
    ns.Buyer.Buy(CLOTH, kim, CLOTH_NAME)
    local ok, msg = ns.Buyer.Buy(CLOTH, kim, CLOTH_NAME)
    T.ok(not ok)
    T.eq(msg, "Already bought")
    T.eq(#Mock.bought, 1)
  end,

  reset_keeps_bought = function(T)
    local ns = setup()
    local kim, bob = rowBy(ns, "Kim"), rowBy(ns, "Bob")
    -- Bob's row is searched for while the player looks at another page...
    local page, total = Mock.list, Mock.total
    Mock.list, Mock.total = {}, 0
    ns.Buyer.Buy(CLOTH, bob, CLOTH_NAME)
    T.eq(ns.Buyer.State(bob), "finding")
    -- ...then Kim's stack, on the page again, is bought.
    Mock.list, Mock.total = page, total
    ns.Buyer.Buy(CLOTH, kim, CLOTH_NAME)
    T.eq(ns.Buyer.State(kim), "bought")
    ns.Buyer.Reset()
    T.eq(ns.Buyer.State(kim), "bought")
    T.eq(ns.Buyer.State(bob), "idle")
  end,

  changes_fire_buyer_changed = function(T)
    local ns = setup()
    local seen = {}
    ns.On("BUYER_CHANGED", function(id, row) seen[#seen + 1] = { id = id, row = row } end)
    local kim = rowBy(ns, "Kim")
    ns.Buyer.Buy(CLOTH, kim, CLOTH_NAME)
    T.eq(#seen, 1)
    T.eq(seen[1].id, CLOTH)
    T.ok(seen[1].row == kim)
  end,

  tick_allocates_nothing_when_idle = function(T)
    local ns = setup()
    local function allocated(fn)
      collectgarbage("collect")
      collectgarbage("stop")
      local before = collectgarbage("count")
      fn()
      local after = collectgarbage("count")
      collectgarbage("restart")
      return after - before
    end
    local function ticks() for _ = 1, 200 do ns.Buyer.Tick(0.016) end end
    T.eq(allocated(ticks), 0, "nothing tracked")
    ns.Buyer.Buy(CLOTH, rowBy(ns, "Kim"), CLOTH_NAME)
    T.eq(allocated(ticks), 0, "only a bought row")
  end,
}
