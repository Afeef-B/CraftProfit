local Mock = require("wow_mock")

local REALM = "Icecrown-Alliance"

local function load(db)
  Mock.reset()
  local ns = Mock.load({ "Util.lua", "Listings.lua" })
  db = db or {}
  ns.Listings.SetDB(db, REALM, "Me")
  return ns, ns.Listings, db
end

local function g(gold, silver, copper)
  return gold * 10000 + (silver or 0) * 100 + (copper or 0)
end

-- Raw scanner row: one stack of `count` at `buyout`.
local function raw(count, buyout, seller, page, index)
  return { count = count, buyout = buyout, seller = seller, page = page, index = index }
end

-- Single-item listings from sellers: { {unit, seller}, ... } -> normalized rows.
local function rowsOf(L, list, mineSet, ratio)
  local r = {}
  for i, e in ipairs(list) do r[i] = raw(1, e[1], e[2]) end
  return L.Normalize(r, mineSet or L.MineSet(), ratio or L.Ratio())
end

return {
  normalize_units_mine_alts_and_sort = function(T)
    local _, L = load()
    local mineSet = { Me = true, Twink = true }
    local rows = L.Normalize({
      raw(20, 40000, "Bob", 0, 1),     -- 2000 each
      raw(1, 3000, "Twink", 0, 2),     -- alt, 3000 each
      raw(5, 10000, "Me", 1, 7),       -- 2000 each, fewer than the 20-stack
      raw(3, 0, "Bob", 1, 8),          -- bid only
      raw(3, 10, nil, 2, 3),           -- 3.33 -> 3 each, seller unknown
      raw(2, 7001, "Cara", 1, 1),      -- 3500.5 -> 3501 each
    }, mineSet, 0.5)

    T.eq(#rows, 6)
    -- unit ascending, count descending on ties, bid-only last.
    T.eq(rows[1].unit, 3); T.eq(rows[1].seller, nil); T.eq(rows[1].mine, false)
    T.eq(rows[2].unit, 2000); T.eq(rows[2].count, 20); T.eq(rows[2].seller, "Bob")
    T.eq(rows[3].unit, 2000); T.eq(rows[3].count, 5)
    T.eq(rows[3].mine, true, "own character")
    T.eq(rows[4].unit, 3000); T.eq(rows[4].mine, true, "alt in mineSet")
    T.eq(rows[5].unit, 3501); T.eq(rows[5].mine, false)
    T.eq(rows[6].buyout, 0); T.eq(rows[6].unit, 0)
    T.eq(rows[6].mine, false)

    -- page and index survive for the flip buy.
    T.eq(rows[2].page, 0); T.eq(rows[2].index, 1)
    T.eq(rows[3].page, 1); T.eq(rows[3].index, 7)
    T.eq(rows[5].page, 1); T.eq(rows[5].index, 1)
    T.eq(rows[6].page, 1); T.eq(rows[6].index, 8)
    T.eq(rows[1].page, 2); T.eq(rows[1].index, 3)
    T.eq(rows[2].buyout, 40000)
  end,

  normalize_keeps_raw_rows_and_handles_empty = function(T)
    local _, L = load()
    local input = { raw(2, 100, "Bob", 0, 1) }
    local rows = L.Normalize(input, {}, 0.5)
    T.eq(input[1].unit, nil, "raw rows are not modified")
    T.eq(rows[1].unit, 50)
    T.eq(#L.Normalize({}, {}, 0.5), 0)
    -- a missing mineSet means nobody is ours.
    T.eq(L.Normalize({ raw(1, 5, "Me") }, nil, 0.5)[1].mine, false)
  end,

  normalize_orders_ties_deterministically = function(T)
    local _, L = load()
    local rows = L.Normalize({
      raw(1, 100, "A", 0, 1), raw(1, 100, "B", 0, 2), raw(1, 100, "C", 0, 3),
      raw(1, 0, "D", 0, 4), raw(1, 0, "E", 0, 5),
    }, {}, 0.5)
    local names = {}
    for i, r in ipairs(rows) do names[i] = r.seller end
    T.eq(table.concat(names), "ABCDE")
  end,

  set_db_records_character = function(T)
    local db = { chars = { [REALM] = { Twink = true }, ["Other-Horde"] = { Orc = true } } }
    local ns, L = load(db)
    T.eq(db.chars[REALM].Me, true)
    T.eq(db.chars[REALM].Twink, true, "existing alts kept")
    T.eq(db.chars["Other-Horde"].Orc, true)
    local set = L.MineSet()
    T.eq(set.Me, true); T.eq(set.Twink, true); T.eq(set.Orc, nil, "other realm not mixed in")

    -- fresh saved variables get the tables created.
    local fresh = {}
    ns.Listings.SetDB(fresh, REALM, "Me")
    T.eq(fresh.chars[REALM].Me, true)
  end,

  ratio_defaults_and_setting = function(T)
    local ns, L, db = load()
    T.eq(L.Ratio(), 0.5)
    db.outlierRatio = 0.7
    T.eq(L.Ratio(), 0.7)
    -- before SetDB the defaults still work.
    local ns2 = Mock.load({ "Util.lua", "Listings.lua" })
    T.eq(ns2.Listings.Ratio(), 0.5)
    local empty = ns2.Listings.MineSet()
    T.eq(next(empty), nil)
  end,

  undercut_price_cases = function(T)
    local _, L = load()
    local function price(unit, seller, mine)
      local rows = rowsOf(L, { { unit, seller or "Bob" } }, mine or {})
      return L.UndercutPrice(rows, 123)
    end
    local p, why = price(g(420))
    T.eq(p, g(419, 99)); T.eq(why, "undercut")
    T.eq(price(g(419, 99, 57)), g(419, 99))
    T.eq(price(g(1, 0, 1)), g(1))               -- 101c -> 100c
    T.eq(price(100), 99)
    T.eq(price(50), 49)
    T.eq(price(2), 1)
    T.eq(price(1), 1, "never below 1c")

    -- own or alt cheapest: match it, never undercut it.
    local rows = rowsOf(L, { { g(400), "Me" }, { g(420), "Bob" } }, { Me = true })
    p, why = L.UndercutPrice(rows, 123)
    T.eq(p, g(400)); T.eq(why, "match-own")
    rows = rowsOf(L, { { g(400), "Twink" }, { g(420), "Bob" } }, { Me = true, Twink = true })
    p, why = L.UndercutPrice(rows, 123)
    T.eq(p, g(400)); T.eq(why, "match-own")
    -- equal price to a stranger: match ours.
    rows = rowsOf(L, { { g(400), "Me" }, { g(400), "Bob" } }, { Me = true })
    p, why = L.UndercutPrice(rows, 123)
    T.eq(p, g(400)); T.eq(why, "match-own")
    -- someone is cheaper than us: undercut them.
    rows = rowsOf(L, { { g(300), "Bob" }, { g(400), "Me" } }, { Me = true })
    p, why = L.UndercutPrice(rows, 123)
    T.eq(p, g(299, 99)); T.eq(why, "undercut")

    -- nobody else: the fallback, which may be nil.
    p, why = L.UndercutPrice({}, 777)
    T.eq(p, 777); T.eq(why, "no-competition")
    p, why = L.UndercutPrice({}, nil)
    T.eq(p, nil); T.eq(why, "no-competition")
    -- only a bid-only listing of ours: nothing priced to match.
    rows = L.Normalize({ raw(1, 0, "Me") }, { Me = true }, 0.5)
    p, why = L.UndercutPrice(rows, 777)
    T.eq(p, 777); T.eq(why, "no-competition")

    -- bid-only rows never set the price.
    rows = L.Normalize({ raw(1, 0, "Bob"), raw(1, g(420), "Cara") }, {}, 0.5)
    p, why = L.UndercutPrice(rows, 123)
    T.eq(p, g(419, 99)); T.eq(why, "undercut")
    rows = L.Normalize({ raw(1, 0, "Bob") }, {}, 0.5)
    p, why = L.UndercutPrice(rows, 123)
    T.eq(p, 123); T.eq(why, "no-competition")
  end,

  outliers_marked = function(T)
    local _, L = load()
    local function flags(list, ratio)
      local rows = rowsOf(L, list, {}, ratio)
      local out = {}
      for i, r in ipairs(rows) do out[i] = r.outlier and "x" or "-" end
      return table.concat(out)
    end
    T.eq(flags({ { g(50), "A" }, { g(60), "B" }, { g(420), "C" }, { g(425), "D" } }), "xx--")
    T.eq(flags({ { g(300), "A" }, { g(420), "B" } }), "--")
    T.eq(flags({ { g(50), "A" }, { g(420), "B" } }), "x-")
    T.eq(flags({ { g(50), "A" }, { g(60), "B" }, { g(70), "C" }, { g(420), "D" } }), "xxx-")
    -- only the first three rows can be a mistake.
    T.eq(flags({ { g(10), "A" }, { g(11), "B" }, { g(12), "C" }, { g(13), "D" }, { g(420), "E" } }), "-----")
    T.eq(flags({ { g(420), "A" } }), "-", "a single listing is not a mistake")
    T.eq(flags({}), "")

    -- ratio 0.7 (from the setting) is stricter than 0.5.
    T.eq(flags({ { g(290), "A" }, { g(420), "B" } }, 0.5), "--")
    T.eq(flags({ { g(290), "A" }, { g(420), "B" } }, 0.7), "x-")
    local _, L2, db = load()
    db.outlierRatio = 0.7
    local rows = rowsOf(L2, { { g(290), "A" }, { g(420), "B" } })
    T.eq(rows[1].outlier, true, "Normalize with Ratio() from the setting")

    -- our own listings are never mistakes and are skipped in the sequence;
    -- bid-only rows are ignored too.
    local mine = { Me = true }
    local rows2 = L.Normalize({
      raw(1, g(40), "Me"), raw(1, g(50), "A"), raw(1, 0, "Z"), raw(1, g(420), "B"),
    }, mine, 0.5)
    T.eq(rows2[1].seller, "Me"); T.eq(rows2[1].outlier, false)
    T.eq(rows2[2].seller, "A"); T.eq(rows2[2].outlier, true)
    T.eq(rows2[3].outlier, false)
    T.eq(rows2[4].seller, "Z"); T.eq(rows2[4].outlier, false)
  end,

  undercut_ignores_outliers = function(T)
    local _, L = load()
    local rows = rowsOf(L, { { g(50), "A" }, { g(420), "B" } })
    local p, why = L.UndercutPrice(rows, 1)
    T.eq(p, g(419, 99)); T.eq(why, "undercut")
    -- a mistake alone is no competition.
    rows = rowsOf(L, { { g(50), "A" } })
    T.eq(rows[1].outlier, false, "one row cannot be compared")
    rows = rowsOf(L, { { g(50), "A" }, { g(60), "B" }, { g(420), "C" } })
    p, why = L.UndercutPrice(rows, 1)
    T.eq(p, g(419, 99))
  end,

  summarize_fields = function(T)
    local _, L = load()
    local mineSet = { Me = true, Twink = true }
    local rows = L.Normalize({
      raw(1, g(50), "Flipper", 0, 1),
      raw(1, g(420), "Bob", 0, 2),
      raw(1, g(430), "Me", 0, 3),
      raw(1, g(425), "Twink", 0, 4),
      raw(1, g(500), "Cara", 0, 5),
      raw(2, 0, "Me", 0, 6),
    }, mineSet, 0.5)
    local s = L.Summarize(rows)
    T.eq(s.lowestOther, g(420)); T.eq(s.lowestOtherSeller, "Bob")
    T.eq(s.lowestMine, g(425))
    T.eq(s.mineCount, 3, "all our listings, bid-only too")
    T.ok(s.flip, "cheapest outlier")
    T.eq(s.flip.seller, "Flipper"); T.eq(s.flip.unit, g(50))
    T.eq(s.flip.page, 0); T.eq(s.flip.index, 1)

    s = L.Summarize({})
    T.eq(s.lowestOther, nil); T.eq(s.lowestOtherSeller, nil)
    T.eq(s.lowestMine, nil); T.eq(s.mineCount, 0); T.eq(s.flip, nil)

    -- only bid-only rows from others.
    s = L.Summarize(L.Normalize({ raw(1, 0, "Bob") }, {}, 0.5))
    T.eq(s.lowestOther, nil); T.eq(s.flip, nil)
  end,

  status_cases = function(T)
    local _, L = load()
    local mine = { Me = true }

    -- someone is cheaper than us.
    local rows = rowsOf(L, { { g(300), "Bob" }, { g(301), "Me" } }, mine)
    local st, diff, who = L.Status(rows)
    T.eq(st, "undercut"); T.eq(diff, g(1)); T.eq(who, "Bob")
    rows = rowsOf(L, { { 5000, "Bob" }, { 6000, "Me" } }, mine)
    st, diff, who = L.Status(rows)
    T.eq(st, "undercut"); T.eq(diff, 1000); T.eq(who, "Bob")

    -- tied.
    rows = rowsOf(L, { { 5000, "Bob" }, { 5000, "Me" } }, mine)
    st, diff, who = L.Status(rows)
    T.eq(st, "tied"); T.eq(diff, 0); T.eq(who, "Bob")

    -- we are the cheapest, by the gap to the next seller.
    rows = rowsOf(L, { { 5000, "Me" }, { 6000, "Bob" } }, mine)
    st, diff, who = L.Status(rows)
    T.eq(st, "cheapest"); T.eq(diff, 1000); T.eq(who, "Bob")

    -- nobody else at all.
    rows = rowsOf(L, { { 5000, "Me" } }, mine)
    st, diff, who = L.Status(rows)
    T.eq(st, "cheapest"); T.eq(diff, nil); T.eq(who, nil)
    st, diff = L.Status({})
    T.eq(st, "cheapest"); T.eq(diff, nil)

    -- an alt counts as us.
    rows = rowsOf(L, { { 5000, "Twink" }, { 6000, "Me" }, { 7000, "Bob" } }, { Me = true, Twink = true })
    st = L.Status(rows)
    T.eq(st, "cheapest")

    -- a mistake below us is a flip, not an undercut.
    rows = L.Normalize({ raw(1, g(50), "Flipper"), raw(1, g(430), "Bob"), raw(1, g(420), "Me") }, mine, 0.5)
    T.eq(rows[1].seller, "Flipper"); T.eq(rows[1].outlier, true)
    st, diff, who = L.Status(rows)
    T.eq(st, "cheapest"); T.eq(diff, g(10)); T.eq(who, "Bob")
    T.eq(L.Summarize(rows).flip.seller, "Flipper")
    -- a lone cheap seller is judged against our listing (see lone_outlier_against_own_listing).
    rows = L.Normalize({ raw(1, g(50), "Flipper"), raw(1, g(420), "Me") }, mine, 0.5)
    T.eq(rows[1].outlier, true)
    T.eq((L.Status(rows)), "cheapest")

    -- bid-only rows of others do not count.
    rows = L.Normalize({ raw(1, 0, "Bob"), raw(1, 5000, "Me") }, mine, 0.5)
    T.eq((L.Status(rows)), "cheapest")
  end,

  mark_under_you_skips_outliers = function(T)
    local _, L = load()
    local mine = { Me = true }
    local rows = L.Normalize({
      raw(1, g(50), "Flipper"),   -- mistake: not "under you"
      raw(1, g(390), "Bob"),      -- cheaper than ours
      raw(1, g(400), "Cara"),     -- equal: not under
      raw(1, g(400), "Me"),
      raw(1, g(410), "Dan"),      -- dearer
      raw(1, 0, "Eve"),           -- bid only
    }, mine, 0.5)
    L.MarkUnderYou(rows)
    local by = {}
    for _, r in ipairs(rows) do by[r.seller] = r end
    T.ok(by.Flipper.outlier)
    T.ok(not by.Flipper.underYou, "outlier row skipped")
    T.eq(by.Bob.underYou, true)
    T.ok(not by.Cara.underYou)
    T.ok(not by.Me.underYou, "never marks our own")
    T.ok(not by.Dan.underYou)
    T.ok(not by.Eve.underYou, "bid-only row skipped")

    -- no listing of ours: nothing to be under.
    rows = L.Normalize({ raw(1, g(390), "Bob") }, mine, 0.5)
    L.MarkUnderYou(rows)
    T.ok(not rows[1].underYou)

    -- re-marking after our price changed clears stale marks.
    rows = L.Normalize({ raw(1, g(390), "Bob"), raw(1, g(400), "Me") }, mine, 0.5)
    L.MarkUnderYou(rows)
    T.eq(rows[1].underYou, true)
    rows[2].unit = g(380)
    L.MarkUnderYou(rows)
    T.ok(not rows[1].underYou)
  end,

  lone_outlier_against_own_listing = function(T)
    local _, L = load()
    local mine = { Me = true }
    local rows = L.Normalize({ raw(1, g(50), "Flipper", 1, 4), raw(1, g(420), "Me") }, mine, 0.5)
    T.eq(rows[1].seller, "Flipper"); T.eq(rows[1].outlier, true)
    T.eq(rows[2].seller, "Me"); T.eq(rows[2].outlier, false)
    local s = L.Summarize(rows)
    T.eq(s.flip, rows[1])
    T.eq(s.flip.page, 1); T.eq(s.flip.index, 4)
    T.eq(s.lowestOther, nil)
    local st, diff, who = L.Status(rows)
    T.eq(st, "cheapest"); T.eq(diff, nil); T.eq(who, nil)
    local p, why = L.UndercutPrice(rows, 123)
    T.eq(p, 4200000); T.eq(why, "match-own")

    -- the reference is the cheapest of our rows dearer than the candidate;
    -- one of ours below it is ignored.
    rows = L.Normalize({
      raw(1, g(10), "Me"), raw(1, g(50), "Flipper"), raw(1, g(420), "Twink"), raw(1, g(900), "Me"),
    }, { Me = true, Twink = true }, 0.5)
    T.eq(rows[2].seller, "Flipper"); T.eq(rows[2].outlier, true)
    -- a bid-only listing of ours is no reference.
    rows = L.Normalize({ raw(1, g(50), "Flipper"), raw(1, 0, "Me") }, mine, 0.5)
    T.eq(rows[1].outlier, false)
    -- our listing cheaper than the candidate is no reference either.
    rows = L.Normalize({ raw(1, g(10), "Me"), raw(1, g(50), "Flipper") }, mine, 0.5)
    T.eq(rows[2].seller, "Flipper"); T.eq(rows[2].outlier, false)
    -- the setting applies: ratio 0.1 makes 50g vs 420g competition again.
    rows = L.Normalize({ raw(1, g(50), "Flipper"), raw(1, g(420), "Me") }, mine, 0.1)
    T.eq(rows[1].outlier, false)
  end,

  lone_cheap_seller_not_outlier = function(T)
    local _, L = load()
    local rows = L.Normalize({ raw(1, g(300), "Bob"), raw(1, g(420), "Me") }, { Me = true }, 0.5)
    T.eq(rows[1].outlier, false)
    T.eq(L.Summarize(rows).flip, nil)
    local p, why = L.UndercutPrice(rows, 123)
    T.eq(p, 2999900); T.eq(why, "undercut")
    T.eq((L.Status(rows)), "undercut")
  end,

  two_outliers_before_own_listing = function(T)
    local _, L = load()
    local rows = L.Normalize({
      raw(1, g(50), "Bob"), raw(1, g(60), "Kim"), raw(1, g(420), "Me"),
    }, { Me = true }, 0.5)
    T.eq(rows[1].seller, "Bob"); T.eq(rows[1].outlier, true)
    T.eq(rows[2].seller, "Kim"); T.eq(rows[2].outlier, true)
    T.eq(rows[3].seller, "Me"); T.eq(rows[3].outlier, false)
    T.eq(L.Summarize(rows).flip.seller, "Bob")
    local p, why = L.UndercutPrice(rows, 123)
    T.eq(p, 4200000); T.eq(why, "match-own")
  end,

  no_others_only_mine_matches_own = function(T)
    local _, L = load()
    local rows = L.Normalize({ raw(1, g(420), "Me") }, { Me = true }, 0.5)
    T.eq(rows[1].outlier, false)
    local p, why = L.UndercutPrice(rows, 123)
    T.eq(p, 4200000); T.eq(why, "match-own")
    -- an alt's listing counts as ours too.
    rows = L.Normalize({ raw(1, g(420), "Twink") }, { Me = true, Twink = true }, 0.5)
    p, why = L.UndercutPrice(rows, 123)
    T.eq(p, 4200000); T.eq(why, "match-own")
    -- nobody at all: the fallback.
    p, why = L.UndercutPrice({}, 123)
    T.eq(p, 123); T.eq(why, "no-competition")
  end,

  store_get_age_and_event = function(T)
    local ns, L = load()
    local fired = {}
    ns.On("LISTINGS_UPDATED", function(id) fired[#fired + 1] = id end)

    T.eq(L.Get(33470), nil)
    local rows = L.Normalize({ raw(1, 100, "Bob") }, {}, 0.5)
    L.Store(33470, rows)
    T.eq(#fired, 1); T.eq(fired[1], 33470)
    T.eq(L.cache[33470].t, Mock.now)
    T.eq(L.cache[33470].rows, rows)

    local got, age = L.Get(33470)
    T.eq(got, rows); T.eq(age, 0)
    Mock.now = Mock.now + 45
    got, age = L.Get(33470)
    T.eq(got, rows); T.eq(age, 45)

    -- a newer price check replaces the old one.
    local rows2 = L.Normalize({ raw(1, 200, "Cara") }, {}, 0.5)
    L.Store(33470, rows2)
    got, age = L.Get(33470)
    T.eq(got, rows2); T.eq(age, 0)
    T.eq(#fired, 2)
    T.eq(L.Get(1), nil)
  end,
}
