local Mock = require("wow_mock")

local CLOTH, THREAD, BAG = 33470, 38426, 41599

local function load(db)
  Mock.reset()
  local ns = Mock.load({ "Util.lua", "Style.lua", "Profit.lua", "Prices.lua" })
  ns.Prices.SetDB(db or {}, "Icecrown-Alliance")
  return ns, ns.Prices
end

return {
  is_fresh_inside_window = function(T)
    local _, P = load()
    P.SetAH(1, 100, 1, Mock.now - 179)
    P.SetAH(2, 100, 1, Mock.now - 180)
    P.SetAH(3, nil, 0, Mock.now)
    T.eq(P.IsFresh(1), true, "179 s old")
    T.eq(P.IsFresh(2), false, "180 s old")
    T.eq(P.IsFresh(4), false, "never scanned")
    T.eq(P.IsFresh(3), true, "scanned, nothing listed")
  end,

  fresh_seconds_setting = function(T)
    local db = {}
    local _, P = load(db)
    T.eq(P.FreshSeconds(), 180)
    P.SetFreshSeconds(300)
    T.eq(db.freshSeconds, 300)
    T.eq(P.FreshSeconds(), 300)
    P.SetFreshSeconds(0)
    P.SetAH(1, 100, 1, Mock.now)
    T.eq(P.IsFresh(1), false, "0 always rescans")
  end,

  set_db_creates_tables_and_separates_realms = function(T)
    local db = {}
    local _, P = load(db)
    T.ok(db.prices["Icecrown-Alliance"] and db.vendor and db.manual)
    P.SetAH(CLOTH, 100, 3, Mock.now)
    T.eq((P.GetAH(CLOTH)), 100)
    P.SetDB(db, "Icecrown-Horde")
    T.eq((P.GetAH(CLOTH)), nil)
    P.SetDB(db, "Icecrown-Alliance")
    T.eq((P.GetAH(CLOTH)), 100)
  end,

  manual_wins = function(T)
    local _, P = load()
    P.SetAH(CLOTH, 1000, 5, Mock.now)
    P.SetManual(CLOTH, 5000)
    local price, source = P.ResolveBuy(CLOTH, 100)
    T.eq(price, 5000)
    T.eq(source, "manual")
    P.SetManual(CLOTH, nil)
    T.eq((P.ResolveBuy(CLOTH)), 1000)
  end,

  cheapest_of_ah_vendor_craft = function(T)
    local _, P = load()
    P.SetAH(THREAD, 1000, 5, Mock.now - 120)
    local price, source, age = P.ResolveBuy(THREAD)
    T.eq(price, 1000); T.eq(source, "ah"); T.eq(age, 120)
    P.SetVendor(THREAD, 800)
    price, source, age = P.ResolveBuy(THREAD, 900)
    T.eq(price, 800); T.eq(source, "vendor"); T.eq(age, nil)
    price, source = P.ResolveBuy(THREAD, 700)
    T.eq(price, 700); T.eq(source, "craft")
  end,

  ties_prefer_ah = function(T)
    local _, P = load()
    P.SetAH(THREAD, 1000, 5, Mock.now)
    P.SetVendor(THREAD, 1000)
    local _, source = P.ResolveBuy(THREAD, 1000)
    T.eq(source, "ah")
  end,

  atr_fallback_only_when_nothing_else = function(T)
    local _, P = load()
    Mock.items[THREAD] = { name = "Eternium Thread" }
    Atr_GetAuctionBuyout = function() return 777 end
    local price, source = P.ResolveBuy(THREAD)
    T.eq(price, 777); T.eq(source, "atr")
    P.SetAH(THREAD, 1000, 1, Mock.now)
    price, source = P.ResolveBuy(THREAD)
    T.eq(price, 1000); T.eq(source, "ah")
  end,

  sell_ignores_vendor_and_craft = function(T)
    local _, P = load()
    P.SetVendor(BAG, 100)
    T.eq((P.ResolveSell(BAG)), nil)
    P.SetAH(BAG, 2000, 1, Mock.now - 30)
    local price, source, age = P.ResolveSell(BAG)
    T.eq(price, 2000); T.eq(source, "ah"); T.eq(age, 30)
    P.SetManual(BAG, 3000)
    price, source = P.ResolveSell(BAG)
    T.eq(price, 3000); T.eq(source, "manual")
  end,

  none_listing_is_no_price = function(T)
    local _, P = load()
    P.SetAH(CLOTH, nil, 0, Mock.now)
    T.eq((P.ResolveBuy(CLOTH)), nil)
    local price, t, n = P.GetAH(CLOTH)
    T.eq(price, nil); T.eq(t, Mock.now); T.eq(n, 0)
  end,

  stale_flag = function(T)
    local _, P = load()
    T.eq(P.IsStale(86401), true)
    T.eq(P.IsStale(100), false)
    T.eq(P.IsStale(nil), false)
  end,

  merchant_records_unit_price_skips_tokens = function(T)
    local _, P = load()
    Mock.merchant = {
      { id = THREAD, name = "Eternium Thread", price = 1000, quantity = 5 },
      { id = 1, name = "Badge item", price = 5000, quantity = 1, extendedCost = 1 },
      { id = 2, name = "Free thing", price = 0, quantity = 1 },
    }
    T.eq(P.RecordMerchant(), 1)
    local price, source = P.ResolveBuy(THREAD)
    T.eq(price, 200); T.eq(source, "vendor")
    T.eq((P.ResolveBuy(1)), nil)
  end,

  auctionator_api_shapes = function(T)
    local _, P = load()
    Mock.items[THREAD] = { name = "Eternium Thread" }

    Auctionator = { API = { v1 = { GetAuctionPriceByItemID = function(caller, id)
      if caller == "CraftProfit" and id == THREAD then return 1234 end
    end } } }
    T.eq(P.Auctionator(THREAD), 1234)

    Auctionator = nil
    Atr_GetAuctionBuyout = function(item)
      if item == "Eternium Thread" then return 555 end
    end
    T.eq(P.Auctionator(THREAD), 555)

    Atr_GetAuctionBuyout = function() error("boom") end
    T.eq(P.Auctionator(THREAD), nil)

    Atr_GetAuctionBuyout = function() return 0 end
    T.eq(P.Auctionator(THREAD), nil)
  end,

  make_context = function(T)
    local db = { cut = 0.15 }
    local ns, P = load(db)
    ns.Recipes = { All = function() return { marker = true } end, Depth = function() return "ready" end }
    local ctx = P.MakeContext()
    T.eq(ctx.depth, ns.Recipes.Depth)
    T.eq(ctx.cut, 0.15)
    T.eq(ctx.recipes.marker, true)
    T.eq(ctx.resolveBuy, P.ResolveBuy)
    T.eq(ctx.resolveSell, P.ResolveSell)
    db.cut = nil
    T.eq(P.MakeContext().cut, 0.05)
  end,
}
