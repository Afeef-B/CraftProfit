local Mock = require("wow_mock")

local CLOTH, THREAD = 33470, 38426

local function load()
  Mock.reset()
  local ns = Mock.load({ "Util.lua", "Profit.lua", "Prices.lua", "Recipes.lua", "Scanner.lua" })
  local db = {}
  ns.Prices.SetDB(db, "Icecrown-Alliance")
  ns.Scanner.SetDB(db)
  hooksecurefunc("QueryAuctionItems", ns.Scanner.OnQuery)
  return ns, ns.Scanner, ns.Prices, db
end

local function auction(id, name, count, buyout)
  return { id = id, name = name, count = count, buyout = buyout }
end

local CLOTH_ITEM = { id = CLOTH, name = "Frostweave Cloth" }
local THREAD_ITEM = { id = THREAD, name = "Eternium Thread" }

return {
  start_rejects_empty_and_busy = function(T)
    local _, S = load()
    local ok, err = S.StartTargeted({})
    T.eq(ok, false); T.eq(err, "empty")
    T.eq(S.StartTargeted({ CLOTH_ITEM }), true)
    ok, err = S.StartTargeted({ CLOTH_ITEM })
    T.eq(ok, false); T.eq(err, "busy")
  end,

  uses_exact_query_args = function(T)
    local _, S = load()
    S.StartTargeted({ CLOTH_ITEM })
    S.Tick(0.1)
    local q = Mock.queries[1]
    T.eq(q.n, 10)
    T.eq(q[1], "Frostweave Cloth"); T.eq(q[2], ""); T.eq(q[3], "")
    T.eq(q[4], nil); T.eq(q[5], nil); T.eq(q[6], nil)
    T.eq(q[7], 0); T.eq(q[8], nil); T.eq(q[9], -1); T.eq(q[10], false)
  end,

  targeted_finds_lowest_unit_price = function(T)
    local ns, S, P = load()
    Mock.ah.auctions = {
      auction(CLOTH, "Frostweave Cloth", 1, 1200),
      auction(CLOTH, "Frostweave Cloth", 1, 1000),
      auction(CLOTH, "Frostweave Cloth", 1, 1500),
    }
    S.StartTargeted({ CLOTH_ITEM })
    T.ok(Mock.pump(ns), "scan finished")
    local price, t, n = P.GetAH(CLOTH)
    T.eq(price, 1000); T.eq(t, Mock.now); T.eq(n, 3)
  end,

  targeted_per_unit_and_skips_bid_only = function(T)
    local ns, S, P = load()
    Mock.ah.auctions = {
      auction(CLOTH, "Frostweave Cloth", 20, 40000),
      auction(CLOTH, "Frostweave Cloth", 1, 0),
      auction(CLOTH, "Frostweave Cloth", 5, 15000),
    }
    S.StartTargeted({ CLOTH_ITEM })
    Mock.pump(ns)
    local price, _, n = P.GetAH(CLOTH)
    T.eq(price, 2000); T.eq(n, 2)
  end,

  targeted_rounds_unit_price = function(T)
    local ns, S, P = load()
    Mock.ah.auctions = { auction(CLOTH, "Frostweave Cloth", 3, 10000) }
    S.StartTargeted({ CLOTH_ITEM })
    Mock.pump(ns)
    T.eq((P.GetAH(CLOTH)), 3333)
  end,

  targeted_filters_other_items = function(T)
    local ns, S, P = load()
    Mock.ah.auctions = {
      auction(4306, "Silk Cloth", 1, 500),
      auction(4305, "Bolt of Silk Cloth", 1, 100),
    }
    S.StartTargeted({ { id = 4306, name = "Silk Cloth" } })
    Mock.pump(ns)
    local price, _, n = P.GetAH(4306)
    T.eq(price, 500); T.eq(n, 1)
    T.eq((P.GetAH(4305)), nil)
  end,

  targeted_pages = function(T)
    local ns, S, P = load()
    for i = 1, 119 do Mock.ah.auctions[i] = auction(CLOTH, "Frostweave Cloth", 1, 2000 + i) end
    Mock.ah.auctions[120] = auction(CLOTH, "Frostweave Cloth", 1, 900)
    S.StartTargeted({ CLOTH_ITEM })
    Mock.pump(ns)
    T.eq(#Mock.queries, 3)
    T.eq(Mock.queries[1][7], 0); T.eq(Mock.queries[2][7], 1); T.eq(Mock.queries[3][7], 2)
    local price, _, n = P.GetAH(CLOTH)
    T.eq(price, 900); T.eq(n, 120)
  end,

  targeted_no_listings_records_none = function(T)
    local ns, S, P = load()
    S.StartTargeted({ CLOTH_ITEM })
    Mock.pump(ns)
    local price, t, n = P.GetAH(CLOTH)
    T.eq(price, nil); T.eq(t, Mock.now); T.eq(n, 0)
  end,

  scans_items_in_order_and_reports_progress = function(T)
    local ns, S, P = load()
    local statuses = {}
    ns.On("SCAN_STATUS", function(text) statuses[#statuses + 1] = text end)
    Mock.ah.auctions = { auction(CLOTH, "Frostweave Cloth", 1, 1000), auction(THREAD, "Eternium Thread", 1, 300) }
    S.StartTargeted({ CLOTH_ITEM, THREAD_ITEM })
    Mock.pump(ns)
    T.eq((P.GetAH(CLOTH)), 1000)
    T.eq((P.GetAH(THREAD)), 300)
    T.eq(statuses[1], "Scanning 1/2: Frostweave Cloth")
    T.eq(statuses[2], "Scanning 2/2: Eternium Thread")
    T.eq(statuses[#statuses], "Scan done: 2 items")
  end,

  waits_for_can_send = function(T)
    local ns, S = load()
    Mock.ah.canQuery = false
    S.StartTargeted({ CLOTH_ITEM })
    for _ = 1, 20 do S.Tick(0.1) end
    T.eq(#Mock.queries, 0)
    Mock.ah.canQuery = true
    S.Tick(0.1)
    T.eq(#Mock.queries, 1)
  end,

  foreign_query_resends = function(T)
    local ns, S, P = load()
    Mock.ah.auctions = {
      auction(CLOTH, "Frostweave Cloth", 1, 1000),
      auction(99, "Runecloth", 1, 5),
    }
    S.StartTargeted({ CLOTH_ITEM })
    S.Tick(0.1)                         -- our query goes out
    QueryAuctionItems("Runecloth", "", "", nil, nil, nil, 0, nil, -1) -- another addon
    Mock.deliver(ns)                    -- its results arrive: must be ignored
    T.eq((P.GetAH(CLOTH)), nil)
    T.ok(S.IsBusy())
    Mock.pump(ns)
    T.eq(#Mock.queries, 3)
    T.eq(Mock.queries[3][1], "Frostweave Cloth")
    T.eq((P.GetAH(CLOTH)), 1000)
  end,

  nil_links_wait_then_read = function(T)
    local ns, S, P = load()
    Mock.ah.auctions = { auction(CLOTH, "Frostweave Cloth", 1, 1000) }
    Mock.ah.nilLinks = true
    S.StartTargeted({ CLOTH_ITEM })
    S.Tick(0.1)
    Mock.deliver(ns)
    T.eq(select(2, P.GetAH(CLOTH)), nil, "not read while links missing")
    Mock.ah.nilLinks = false
    ns.Scanner.HandleEvent("AUCTION_ITEM_LIST_UPDATE") -- item info arrives
    T.eq((P.GetAH(CLOTH)), 1000)
  end,

  nil_links_forced_read_after_wait = function(T)
    local ns, S, P = load()
    Mock.ah.auctions = { auction(CLOTH, "Frostweave Cloth", 1, 1000) }
    Mock.ah.nilLinks = true
    S.StartTargeted({ CLOTH_ITEM })
    S.Tick(0.1)
    Mock.deliver(ns)
    for _ = 1, 21 do S.Tick(0.1) end
    T.eq(S.IsBusy(), false)
  end,

  timeout_retries_once_then_skips = function(T)
    local ns, S, P = load()
    Mock.ah.auctions = { auction(THREAD, "Eternium Thread", 1, 300) }
    S.StartTargeted({ CLOTH_ITEM, THREAD_ITEM })
    S.Tick(0.1)                    -- sent, never answered
    Mock.pending = false
    S.Tick(10.1)                   -- timeout -> retry
    S.Tick(0.1)
    T.eq(#Mock.queries, 2)
    Mock.pending = false
    S.Tick(10.1)                   -- second timeout -> skip
    Mock.pump(ns)
    T.eq(select(2, P.GetAH(CLOTH)), nil)
    T.eq((P.GetAH(THREAD)), 300)
    local warned = false
    for _, msg in ipairs(Mock.chat) do
      if msg:find("Frostweave Cloth", 1, true) and msg:find("skipped", 1, true) then warned = true end
    end
    T.ok(warned, "chat warning about the skipped item")
  end,

  ah_closed_stops_keeps_saved = function(T)
    local ns, S, P = load()
    local last
    ns.On("SCAN_STATUS", function(text) last = text end)
    Mock.ah.auctions = { auction(CLOTH, "Frostweave Cloth", 1, 1000), auction(THREAD, "Eternium Thread", 1, 300) }
    S.StartTargeted({ CLOTH_ITEM, THREAD_ITEM })
    S.Tick(0.1); Mock.deliver(ns)  -- first item done
    S.Tick(0.1)                    -- second sent
    S.HandleEvent("AUCTION_HOUSE_CLOSED")
    T.eq(S.IsBusy(), false)
    T.eq((P.GetAH(CLOTH)), 1000)
    T.eq(select(2, P.GetAH(THREAD)), nil)
    T.eq(last, "Scan stopped (AH closed): 1/2 done")
    T.eq(S.StartTargeted({ THREAD_ITEM }), true, "can start again")
  end,
}
