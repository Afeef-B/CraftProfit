-- Logic of the "CP Auctions" Auction House tab: the player's own auctions
-- grouped by item, how each item compares with the other sellers (from the
-- listings cache), and the cancel / undercut actions. No widgets: the page
-- redraws from Groups() when AUCTIONS_CHANGED fires.
-- An auction is cancelled only by CancelUndercut / CancelNextUndercut, which
-- only a button's OnClick (or the confirmation popup's OnAccept) calls. Events
-- (OnOwnedListUpdate, LISTINGS_UPDATED) just read and redraw; they never cancel.
local addonName, ns = ...

local floor, max = math.floor, math.max

ns.Auctions = {}
local Auctions = ns.Auctions

local PAGE_SIZE = NUM_AUCTION_ITEMS_PER_PAGE or 50
local CACHE_FRESH = 60   -- seconds a price check is good for
local CANCEL_WAIT = 5    -- seconds to wait for the owner list after a cancel
local MAILBOX = "Collect it from your mailbox first."

-- One line for the page to show (see Undercut).
Auctions.status = ""

local db
local pages = {}          -- pages[p] = the auctions of owner page p, as read
local page = 0            -- the owner page the client has loaded: the last one asked for
local groups, groupById = {}, {}
local selected            -- item id shown in the right panel
local cancelAt            -- ns.Now() of a cancel the owner list has not answered yet

local function changed()
  ns.Fire("AUCTIONS_CHANGED")
end

-- Price each, rounded like Listings.Normalize so it compares with the cached
-- rows; nil without a buyout.
local function unitOf(a)
  if a.buyout <= 0 then return nil end
  return max(1, floor(a.buyout / max(a.count, 1) + 0.5))
end

-- True for a random-suffix variant ("of the Bear"): the item string
-- item:id:enchant:gem1:gem2:gem3:gem4:suffix:... has a suffix other than 0.
-- Such variants share one item id but not a price, so the cached rows of that
-- id say nothing about them.
local function isVariant(link)
  local suffix = link and link:match("item:%d+:%-?%d+:%-?%d+:%-?%d+:%-?%d+:%-?%d+:(%-?%d+)")
  return suffix ~= nil and tonumber(suffix) ~= 0
end

-- The auction at `index` of the loaded owner batch, or nil while the client
-- has not loaded its item yet.
local function readAuction(index)
  local link = GetAuctionItemLink("owner", index)
  local id = ns.Util.ItemIDFromLink(link)
  if not id then return nil end
  local name, texture, count, _, _, _, _, _, buyout, bid, _, _, saleStatus =
    GetAuctionItemInfo("owner", index)
  return {
    id = id, name = name or ns.Util.ItemNameFromLink(link) or "", texture = texture,
    count = count or 1, buyout = buyout or 0, bid = bid or 0,
    sold = saleStatus == 1, variant = isVariant(link),
    timeLeft = GetAuctionItemTimeLeft("owner", index),
  }
end

local function readBatch(batch)
  local list = {}
  for index = 1, batch do list[#list + 1] = readAuction(index) end
  return list
end

-- Rebuild the item list from what was read and the listings cache.
local function buildGroups()
  local list, byId = {}, {}
  for p = 0, page do
    for _, a in ipairs(pages[p] or {}) do
      local g = byId[a.id]
      if not g then
        g = { id = a.id, name = a.name, texture = a.texture, active = 0, sold = 0 }
        byId[a.id] = g
        list[#list + 1] = g
      end
      if a.sold then
        g.sold = g.sold + 1
      else
        g.active = g.active + 1
        local unit = unitOf(a)
        if unit and (not g.lowestUnit or unit < g.lowestUnit) then g.lowestUnit = unit end
        if a.timeLeft and (not g.timeLeft or a.timeLeft < g.timeLeft) then g.timeLeft = a.timeLeft end
      end
    end
  end

  for _, g in ipairs(list) do
    local rows = ns.Listings.Get(g.id)
    if g.active == 0 then
      g.status = "sold"
    elseif rows then
      g.status, g.diff, g.seller = ns.Listings.Status(rows)
    else
      g.status = "unchecked"
    end
    if rows then g.flip = ns.Listings.Summarize(rows).flip end
  end

  table.sort(list, function(a, b)
    local au, bu = a.status == "undercut", b.status == "undercut"
    if au ~= bu then return au end
    local an, bn = a.name:lower(), b.name:lower()
    if an ~= bn then return an < bn end
    return a.id < b.id
  end)
  groups, groupById = list, byId
end

function Auctions.SetDB(savedDB)
  db = savedDB
end

-- Ask for the owner list; the answer is OnOwnedListUpdate.
function Auctions.Refresh()
  page = 0
  GetOwnerAuctionItems(0)
end

-- AUCTION_OWNED_LIST_UPDATE. The client holds one batch; when it is smaller
-- than the total, the next page is asked for until everything is read.
function Auctions.OnOwnedListUpdate()
  cancelAt = nil   -- the list is current again
  local batch, total = GetNumAuctionItems("owner")
  batch, total = batch or 0, total or 0
  -- A batch that is the whole list is page 0, whatever page we asked for.
  if batch >= total or page == 0 then
    page, pages = 0, {}
  end
  pages[page] = readBatch(batch)
  if batch < total and (page + 1) * PAGE_SIZE < total then
    page = page + 1
    GetOwnerAuctionItems(page)
    return
  end
  buildGroups()
  changed()
end

-- { id, name, texture, active, sold, lowestUnit, timeLeft, status, diff, seller, flip },
-- undercut items first, then by name. Status: "undercut" / "tied" / "cheapest"
-- from the listings cache, "sold" (only sold auctions), "unchecked".
function Auctions.Groups()
  return groups
end

-- Price-check every item that has an active auction. ok, or false and why.
function Auctions.CheckUndercuts()
  local items = {}
  for _, g in ipairs(groups) do
    if g.active > 0 then items[#items + 1] = { id = g.id, name = g.name } end
  end
  if #items == 0 then return false, "empty" end
  return ns.Scanner.StartTargeted(items, { collect = true })
end

function Auctions.Selected()
  return selected
end

-- Show an item's listings: the cache when it is younger than a minute, else a
-- price check. ok, or false and why ("busy": the item stays selected).
function Auctions.Select(id)
  local isNew = id ~= selected
  selected = id
  if isNew then Auctions.status = "" end

  local ok, err = true
  if id then
    local rows, age = ns.Listings.Get(id)
    if not (rows and age < CACHE_FRESH) then
      local g = groupById[id]
      local name = g and g.name or (GetItemInfo(id))
      if name then
        ok, err = ns.Scanner.PriceCheck({ id = id, name = name })
      else
        ok, err = false, "unknown-item"
      end
    end
  end
  if isNew then changed() end
  return ok, err
end

-- Price to beat for a cancel: the cheapest priced row of another seller that is
-- not a mistake listing, or false. Only rows that name their seller count: the
-- scanner reads a page whose owner names have not loaded after a while, and an
-- unnamed row may be an alt's listing, which is ours.
local function priceToBeat(rows)
  local best = false
  for _, r in ipairs(rows) do
    if not r.mine and not r.outlier and (r.unit or 0) > 0 and r.seller and r.seller ~= ""
        and (not best or r.unit < best) then
      best = r.unit
    end
  end
  return best
end

-- Indexes in the loaded owner batch of the undercut auctions: { [id] = { i, ... } }
-- in batch order, and how many there are. Undercut = active, with a buyout, no
-- bid on it, cancellable, no random-suffix variant, and priced above the price to
-- beat from the cached price check (of any age). Read fresh from the client
-- every time.
local function undercutIndexes()
  local byId, total, lowest = {}, 0, {}
  local batch = GetNumAuctionItems("owner") or 0
  for index = 1, batch do
    local a = readAuction(index)
    if a and not a.sold and not a.variant and a.buyout > 0 and a.bid == 0 then
      local other = lowest[a.id]
      if other == nil then
        local rows = ns.Listings.Get(a.id)
        other = rows and priceToBeat(rows) or false
        lowest[a.id] = other
      end
      if other and unitOf(a) > other and CanCancelAuction(index) then
        byId[a.id] = byId[a.id] or {}
        table.insert(byId[a.id], index)
        total = total + 1
      end
    end
  end
  return byId, total
end

-- { [id] = n } for the items that have undercut auctions (items without any have
-- no entry), and how many there are in all. One pass over the owner list: a page
-- that needs several counts asks for all of them at once.
function Auctions.UndercutCounts()
  local byId, total = undercutIndexes()
  local counts = {}
  for id, list in pairs(byId) do counts[id] = #list end
  return counts, total
end

function Auctions.CountUndercut(id)
  return (Auctions.UndercutCounts())[id] or 0
end

function Auctions.CountAllUndercut()
  return select(2, Auctions.UndercutCounts())
end

-- Cancel the auction `pick(byId)` names. ok, or false and why: "confirm" (the
-- popup asks first and repeats `retry` once accepted), "busy" (the client's list
-- is stale until the server answers the last cancel), "none".
local function cancelOne(retry, pick)
  if not (db and db.cancelWarned) then
    StaticPopup_Show("CRAFTPROFIT_CANCEL", nil, nil, retry)
    return false, "confirm"
  end
  if cancelAt and ns.Now() - cancelAt < CANCEL_WAIT then return false, "busy" end
  local index = pick((undercutIndexes()))
  if not index then return false, "none" end
  CancelAuction(index)
  cancelAt = ns.Now()
  Auctions.Refresh()
  return true
end

-- Call only from a button's OnClick (or the popup's OnAccept).
function Auctions.CancelUndercut(id)
  if not id then return false, "none" end
  return cancelOne(function() Auctions.CancelUndercut(id) end, function(byId)
    return byId[id] and byId[id][1]
  end)
end

-- The next undercut auction across all items: undercut items come first, then by name.
function Auctions.CancelNextUndercut()
  return cancelOne(Auctions.CancelNextUndercut, function(byId)
    for _, g in ipairs(groups) do
      if byId[g.id] then return byId[g.id][1] end
    end
  end)
end

StaticPopupDialogs["CRAFTPROFIT_CANCEL"] = {
  text = "Cancelled auctions go back to you by mail and the deposit is lost.",
  button1 = ACCEPT,
  button2 = CANCEL,
  -- `retry` is the click that asked. Returning nothing lets the popup close.
  OnAccept = function(_, retry)
    if db then db.cancelWarned = true end
    if retry then retry() end
  end,
  timeout = 0,
  whileDead = 1,
  hideOnEscape = 1,
}

-- Put the item in CP Sell to list it again under the others. The tab opens only
-- once the item is in the slot, so a message always lands on the page the
-- player is looking at. ok, or false and why ("not-in-bags": status says to
-- collect it from the mailbox).
function Auctions.Undercut(id)
  local ok, err = ns.Sell.PutItemById(id)
  if ok then
    ns.Tabs.Select("sell")
    if Auctions.status ~= "" then
      Auctions.status = ""
      changed()
    end
    return true
  end
  Auctions.status = err == "not-in-bags" and MAILBOX or "Couldn't put it in the sell slot."
  changed()
  return false, err
end

-- Statuses follow the listings cache.
ns.On("LISTINGS_UPDATED", function(id)
  if not groupById[id] then return end
  buildGroups()
  changed()
end)
