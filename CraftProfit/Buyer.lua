-- Buying out one exact listing, for every page that buys (the flip notice,
-- CP Buy). A purchase needs a click, so the bid is placed only by Buyer.Buy,
-- which only button OnClicks call. Events and Tick (OnListUpdate, Tick,
-- Reset) merely move a state along; they never buy. Nothing is bought unless
-- a row on the loaded page matches the listing exactly (item, count, buyout,
-- seller).
--
-- States belong to a row table of the listings cache: a fresh price check
-- stores new row tables, which start "idle".
local addonName, ns = ...

ns.Buyer = {}
local Buyer = ns.Buyer

local PAGE_SIZE = NUM_AUCTION_ITEMS_PER_PAGE or 50
local FIND_TIMEOUT = 10 -- seconds to wait for the page we asked for
local LINK_WAIT = 2     -- seconds to wait for item links / seller names on it

-- track[row] = { id, state, waited, linkWait, stale }: state is "finding" |
-- "ready" | "gone" | "bought". waited/linkWait/stale only matter while
-- "finding": seconds since the search, seconds since a page with unreadable
-- rows came in, and the fingerprint of the page we were looking at when we
-- searched.
local track = {}
local finding = 0 -- entries in "finding": Tick does nothing (allocates nothing) at 0

-- After a buyout the client keeps showing the sold auction until the server's
-- refresh arrives. Indexes bid on while the page is still that same page are
-- not bid on again: an identical stack further down is another auction.
local bidPrint, bidIndexes = nil, {}

local function setState(id, row, state, extra)
  local old = track[row]
  if old and old.state == "finding" then finding = finding - 1 end
  local entry = { id = id, state = state, waited = 0 }
  if extra then
    for key, value in pairs(extra) do entry[key] = value end
  end
  track[row] = entry
  if state == "finding" then finding = finding + 1 end
  ns.Fire("BUYER_CHANGED", id, row)
end

local function forget(row)
  local entry = track[row]
  if not entry then return end
  if entry.state == "finding" then finding = finding - 1 end
  track[row] = nil
  ns.Fire("BUYER_CHANGED", entry.id, row)
end

-- Tell the player: BUYER_SAID lets a page remember it next to the listing,
-- PAGE_STATUS puts it on the open page's status line.
local function say(id, row, state, text)
  ns.Fire("BUYER_SAID", id, row, state, text)
  ns.Fire("PAGE_STATUS", text)
end

-- "idle" | "finding" | "ready" | "gone" | "bought"
function Buyer.State(row)
  local entry = row and track[row]
  return entry and entry.state or "idle"
end

function Buyer.IsBought(row)
  return Buyer.State(row) == "bought"
end

-- Fingerprint of the loaded "list" page, or nil for an empty one. The client
-- can fire a late update for the page we just left; an identical page is not
-- the answer to the search we sent. Names are left out: they load later.
local function pagePrint()
  local batch, total = GetNumAuctionItems("list")
  if not batch or batch == 0 then return nil end
  local _, _, firstCount, _, _, _, _, _, firstBuyout = GetAuctionItemInfo("list", 1)
  local _, _, lastCount, _, _, _, _, _, lastBuyout = GetAuctionItemInfo("list", batch)
  return table.concat({
    batch, total or 0,
    GetAuctionItemLink("list", 1) or "?", firstCount or 0, firstBuyout or 0,
    GetAuctionItemLink("list", batch) or "?", lastCount or 0, lastBuyout or 0,
  }, ":")
end

-- Index of the row on the loaded "list" page that is exactly `row` (same item,
-- count, buyout and seller), or nil. The second result is true when part of the
-- page cannot be read yet (item links or seller names still loading), so a
-- missing match proves nothing.
Buyer.PagePrint = pagePrint

local function findOnPage(id, row)
  local unreadable = false
  local batch = GetNumAuctionItems("list")
  -- After Scan All the list is the whole Auction House, not a page. Walking it
  -- row by row would be ~100k API calls in one click: treat it as a page that
  -- cannot be read.
  if batch > PAGE_SIZE then return nil, true end
  local spent = bidPrint ~= nil and bidPrint == pagePrint() and bidIndexes or nil
  for i = 1, batch do
    local link = GetAuctionItemLink("list", i)
    local _, _, count, _, _, _, _, _, buyout, _, _, owner = GetAuctionItemInfo("list", i)
    if not link or not owner then
      unreadable = true
    elseif not (spent and spent[i]) and ns.Util.ItemIDFromLink(link) == id
        and count == row.count and buyout == row.buyout and owner == row.seller then
      return i
    end
  end
  return nil, unreadable
end

local function loadFailure(err)
  if err == "busy" then return "The scanner is busy, try again in a moment." end
  if err == "throttled" then return "The Auction House is busy, try again in a moment." end
  return "Could not search the Auction House (" .. tostring(err) .. ")."
end

local function reply(id, row, state, ok, msg)
  say(id, row, state, msg)
  return ok, msg
end

-- Buy out `row` (a row of item `id`'s listings, as drawn). ok, msg. Call only
-- from a button OnClick. On the loaded page: buy it out and price-check the
-- item again. Otherwise load the page the listing was seen on; the player
-- clicks again once it is there (state "ready").
function Buyer.Buy(id, row, name)
  if not row then return reply(id, nil, nil, false, "Nothing to buy.") end
  local state = Buyer.State(row)
  -- The bought row stays cached until the fresh price check replaces it; a
  -- second click must not buy the next identical stack.
  if state == "bought" then return reply(id, row, state, false, "Already bought") end
  if GetMoney() < row.buyout then return reply(id, row, state, false, "Not enough gold") end
  -- Without the name there is no search to load the page or re-check with.
  if not name or name == "" then return reply(id, row, state, false, "Item name unknown.") end

  local index = findOnPage(id, row)
  if index then
    local print = pagePrint()
    if print ~= bidPrint then bidPrint, bidIndexes = print, {} end
    bidIndexes[index] = true
    PlaceAuctionBid("list", index, row.buyout)
    -- The client refreshes the list after a buyout. A scan that is waiting for
    -- its own answer would take that refresh for it: have it ask again.
    if ns.Scanner.IsBusy() then ns.Scanner.Resend() end
    setState(id, row, "bought")
    ns.Scanner.PriceCheck({ id = id, name = name })
    return reply(id, row, "bought", true, "Bid placed for " .. ns.Util.FormatMoney(row.buyout))
  end

  local stale = pagePrint() -- before the search replaces what the client shows
  local ok, err = ns.Scanner.LoadPage(name, row.page)
  if not ok then return reply(id, row, state, false, loadFailure(err)) end
  setState(id, row, "finding", { stale = stale })
  return reply(id, row, "finding", false, "Finding it...")
end

-- Decide about a "finding" entry from the page the client shows now. A page
-- identical to the one we left is no answer. `force`: stop waiting for
-- unreadable rows and decide from the readable ones.
local function evaluate(row, entry, force)
  local print = pagePrint()
  if print and print == entry.stale then return end
  local index, unreadable = findOnPage(entry.id, row)
  if index then
    setState(entry.id, row, "ready")
  elseif force or not unreadable then
    say(entry.id, row, "gone", "That listing is gone.")
    setState(entry.id, row, "gone")
    ns.Fire("BUYER_LOST", entry.id, row)
  else
    -- Names still loading; the client sends another update when they are.
    entry.linkWait = entry.linkWait or 0
  end
end

-- AUCTION_ITEM_LIST_UPDATE (routed by Core): a page arrived. Only moves
-- "finding" on to "ready" or "gone"; never buys.
function Buyer.OnListUpdate()
  if finding == 0 then return end
  for row, entry in pairs(track) do
    if entry.state == "finding" then evaluate(row, entry, false) end
  end
end

-- Driven by Core's OnUpdate. A search that gets no answer in FIND_TIMEOUT
-- seconds ends (the player can click again); a page that stays unreadable
-- for LINK_WAIT seconds is judged by its readable rows. Never buys.
function Buyer.Tick(elapsed)
  if finding == 0 then return end
  for row, entry in pairs(track) do
    if entry.state == "finding" then
      entry.waited = entry.waited + elapsed
      if entry.linkWait then
        entry.linkWait = entry.linkWait + elapsed
        if entry.linkWait >= LINK_WAIT then evaluate(row, entry, true) end
      end
      if track[row] == entry and entry.waited >= FIND_TIMEOUT then
        local id = entry.id
        say(id, row, "idle", "Couldn't find it - try again")
        forget(row)
        ns.Fire("BUYER_LOST", id, row)
      end
    end
  end
end

-- Forget the states that wait for an answer, e.g. when the Auction House
-- closes: no answer will come. A bought listing stays bought: the bid went
-- through, and the same stack must not be offered again when the AH reopens.
-- A fresh price check replaces its rows, which ends it.
function Buyer.Reset()
  for row, entry in pairs(track) do
    if entry.state ~= "bought" then forget(row) end
  end
  ns.Fire("BUYER_RESET")
end

-- A fresh price check stored new row tables for `id`: entries of the old ones
-- are done with.
ns.On("LISTINGS_UPDATED", function(id)
  local current = {}
  for _, row in ipairs(ns.Listings.Get(id) or {}) do current[row] = true end
  for row, entry in pairs(track) do
    if entry.id == id and not current[row] then forget(row) end
  end
end)
