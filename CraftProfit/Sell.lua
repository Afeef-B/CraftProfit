-- Logic of the "CP Sell" Auction House tab: the item in the game's sell slot,
-- default price / stack / duration, the profit line, and the price check that
-- keeps the listings current. No widgets: the page redraws from Sell.State()
-- when SELL_CHANGED fires and calls the functions below from its handlers.
-- An auction is created only by Sell.Post, which only the Post button's
-- OnClick calls. Events and ticks (OnSlotChanged, OnListings, OnMultisell, the
-- scanner's SCAN_FINISHED) just move the state along.
local addonName, ns = ...

local floor, max, min = math.floor, math.max, math.min

ns.Sell = {}
local Sell = ns.Sell

local DEFAULT_CUT = 0.05
local DEFAULT_DURATION = 2        -- 1/2/3 = 12/24/48 h
local MAX_BAG = 4

-- Status lines. Plain ASCII: the 3.3.5 fonts lack many symbols.
local CANT_AUCTION = "This item can't be auctioned."
local SEARCHING = "Searching..."
local WAITING = "Waiting for the current scan..."
local NO_ANSWER = "No answer from the Auction House - try again"
local POST_BUSY = "Wait until the post finishes."
local MISTAKE_ROW = "That's a mistake listing - use Buy it to flip it."
-- Notes that only describe a price check in progress, or a click that did
-- nothing; they go away with the next answer.
local TRANSIENT = {
  [SEARCHING] = true, [WAITING] = true, [NO_ANSWER] = true, [MISTAKE_ROW] = true,
}

local db
local item                  -- { id, name, texture, maxStack, owned, suffix } or nil
local unit                  -- price each in copper; nil = none yet
local stack, stacks = 1, 1  -- items per auction, number of auctions
local duration = DEFAULT_DURATION
local priceEdited = false   -- the player chose the price: price checks leave it alone
local listings              -- rows of the last price check of the current item
local checked = false       -- a price check of the current item has returned its listings
local checkFailed = false   -- the current item's check ended without an answer
local status = ""
local lastName              -- the sell slot's name for Sell.lastId

-- A post is under way from the Post click until the last auction is up (or it
-- failed, or the slot moved on): one post at a time.
local posting = false
local postStacks            -- how many auctions that post makes
local postOwned             -- how many items we could post when it started
local multisellSeen = false -- a multisell event arrived for this post: it ends through its own events

-- Our price check, as the scanner sees it. Only one runs at a time, and the
-- scanner has no cancel, so a check for an item the player has since replaced
-- runs on and its answer is ignored.
local running  -- { id, got, quiet }: started, not yet idle; got = rows arrived
local wanted   -- { id, name, quiet }: waits for the scanner to go idle

-- The last item we put in the slot. It stays after the slot empties so the
-- price check after posting still knows which item to look up.
Sell.lastId = nil

local function changed()
  ns.Fire("SELL_CHANGED")
end

-- What an item is worth when nobody sells it: the player's own price, else
-- Auctionator's. Not the stored AH price: a scan that saw a mistake listing
-- may have stored that, and it outlives the listings we just read.
local function standbyPrice(id)
  local price, source = ns.Prices.ResolveSell(id)
  if source == "manual" then return price end
  return ns.Prices.Auctionator(id)
end

-- A random-enchant item ("of the Monkey"): one item id, many prices. The item in
-- the slot says so through its link, the price check's rows through their
-- suffixes (Listings.MixedSuffix).
local function isVariant(rows)
  if item and (item.suffix or 0) ~= 0 then return true end
  return rows ~= nil and ns.Listings.MixedSuffix(rows)
end

-- Price each when nobody else sets it. From a price check's rows: under the
-- cheapest other seller, equal to our own, else the standby price (nil when
-- there is none). Before the check has answered: the last known price, which
-- the page may show but Post does not accept (see State). A random-enchant item
-- has no default: what the other variants cost says nothing about this one.
local function defaultPrice(id, rows)
  if isVariant(rows) then return nil end
  if not rows then return (ns.Prices.ResolveSell(id)) end
  local price = ns.Listings.UndercutPrice(rows, standbyPrice(id))
  return price
end

-- What to search the AH for: the item's own name, else what the slot calls it.
local function searchName(id, slotName)
  return (GetItemInfo(id)) or slotName
end

-- Items of `id` the client will let us post: the bags' count, but never more
-- than the sell slot's own total (it leaves out equipped and bound copies).
local function ownedCount(id, slotTotal)
  local inBags = GetItemCount(id)
  if slotTotal and slotTotal < inBags then return slotTotal end
  return inBags
end

local function postedText(n)
  return "Posted " .. n .. (n == 1 and " auction" or " auctions")
end

local function startCheck(id, name, quiet)
  local ok, err = ns.Scanner.PriceCheck({ id = id, name = name })
  if ok then
    running = { id = id, got = false, quiet = quiet }
    if not quiet then status = SEARCHING end
  elseif err == "busy" then
    wanted = { id = id, name = name, quiet = quiet }
    if not quiet then status = WAITING end
  else
    -- Nothing will answer this.
    if not checked then checkFailed = true end
    if not quiet then
      status = "Could not search the Auction House (" .. tostring(err) .. ")."
    end
  end
end

-- Ask for a price check of `id`. A busy scanner makes it wait for SCAN_FINISHED.
-- A check of the same item that is already running is enough, unless `force`
-- (the auctions we just posted are not in its answer). `quiet` leaves the
-- status line alone.
local function requestCheck(id, name, quiet, force)
  if running and running.id == id and not force then
    running.quiet = running.quiet and quiet
    -- The player is back on the item that is being checked: a check queued for
    -- the item he had in between is not wanted any more, quiet or not (the
    -- game's own update after that drop queued it quietly). One for this item
    -- stays: it is the check after a post.
    if wanted and wanted.id ~= id then wanted = nil end
    if not quiet then status = SEARCHING end
    return
  end
  if running or ns.Scanner.IsBusy() then
    wanted = { id = id, name = name, quiet = quiet }
    if not quiet then status = WAITING end
    return
  end
  startCheck(id, name, quiet)
end

-- The scanner went idle. SCAN_FINISHED carries no success flag: when our check
-- ended without rows for its item, the AH did not answer.
local function onScanFinished()
  local beforeStatus, beforeFailed = status, checkFailed
  local finished = running
  running = nil
  if finished and not finished.got and item and item.id == finished.id then
    -- Never answered: without a typed price the item can't be posted. A quiet
    -- check (the game's own slot update) fails the same way, but the status
    -- line stays as it was.
    if not checked then checkFailed = true end
    if not finished.quiet then status = NO_ANSWER end
  end
  if wanted then
    local following = wanted
    wanted = nil
    -- Only the item still in the slot is worth a search the player waits for.
    if following.quiet or (item and item.id == following.id) then
      startCheck(following.id, following.name, following.quiet)
    end
  end
  -- Nothing is searching, so nothing may say it is.
  if not running and not wanted and (status == SEARCHING or status == WAITING) then
    status = ""
  end
  -- Every scan of the player's ends here; most have nothing to do with us.
  if status ~= beforeStatus or checkFailed ~= beforeFailed then changed() end
end

-- Look the last item up again so the listings show what was just posted. The
-- slot may be empty by now, hence the remembered id.
local function checkAfterPosting()
  local id = Sell.lastId
  local name = id and searchName(id, lastName)
  if not name then return end
  -- The rows held for the item still in the slot are from before the post:
  -- Post waits for the new ones (it would undercut the auction just posted).
  if item and item.id == id then checked, checkFailed = false, false end
  requestCheck(id, name, true, true)
end

-- Back to "no item". A posting message stays; a pending search goes.
local function resetItem()
  item, unit, listings, priceEdited = nil, nil, nil, false
  checked, checkFailed = false, false
  stack, stacks = 1, 1
  if wanted and not wanted.quiet then wanted = nil end
  if TRANSIENT[status] then status = "" end
end

-- Stack size and number of auctions to start an item at: what the player
-- last posted it with, else the default they set. Out of the box that is one
-- auction of 2 (of 1 for what doesn't stack): undercutting posts a little at
-- a time, so the rest stays in the bags to undercut back with. Always cut to
-- the item's stack size and to what the player has.
local DEFAULT_STACK, DEFAULT_STACKS = 2, 1
local MAX_STACK_SIZE, MAX_AUCTIONS = 1000, 100
local function defaultCounts(id, maxStack, owned)
  if owned < 1 then return 1, 1 end
  local saved = db and db.sell.sizes[id]
  local wantStack = saved and saved.stack or (db and db.sell.defaultStack) or DEFAULT_STACK
  local wantStacks = saved and saved.stacks or (db and db.sell.defaultStacks) or DEFAULT_STACKS
  local size = max(1, min(wantStack, maxStack, owned))
  return size, max(1, min(wantStacks, floor(owned / size)))
end

local function wholeCount(n)
  n = tonumber(n)
  if not n then return 1 end
  return max(1, floor(n))
end

-- Item id for a name in the sell slot when we did not put it there ourselves.
local function idForSlotName(slotName)
  if item and item.name == slotName then return item.id end
  if Sell.lastId and lastName == slotName then return Sell.lastId end
  local _, link = GetItemInfo(slotName)
  return ns.Util.ItemIDFromLink(link)
end

function Sell.SetDB(savedDB)
  db = savedDB
  db.sell = db.sell or {}
  db.sell.sizes = db.sell.sizes or {}
  local saved = db.sell.duration
  if saved ~= 1 and saved ~= 2 and saved ~= 3 then db.sell.duration = DEFAULT_DURATION end
  duration = db.sell.duration
end

-- The game's sell slot changed. `id` is the item we just put there ourselves,
-- `suffix` its random-suffix id from the link we had; both nil when
-- NEW_AUCTION_UPDATE says so (the slot was emptied after posting, or its count
-- changed), then the item is the one already shown.
function Sell.OnSlotChanged(id, suffix)
  local slotName, slotTexture, _, _, _, _, _, _, slotTotal = GetAuctionSellItemInfo()
  local fromEvent = id == nil

  if not slotName then
    -- With no multisell progress to go by, a single auction is done when the
    -- slot empties.
    local singleStackDone = fromEvent and posting and postStacks == 1
    posting = false
    resetItem()
    if id then
      status = CANT_AUCTION
    elseif singleStackDone then
      status = postedText(1)
      checkAfterPosting()
    end
    changed()
    return
  end

  id = id or idForSlotName(slotName)
  if not id then
    -- Something we know nothing about sits in the slot.
    posting = false
    resetItem()
    changed()
    return
  end

  local sameItem = item ~= nil and item.id == id
  local owned = ownedCount(id, slotTotal)

  -- Another item, or the player's own drop, ends a post we were waiting for.
  -- The same item with fewer of it than when a single auction was posted means
  -- that auction is made (the slot keeps the rest).
  local singleStackDone = false
  if posting then
    if not (sameItem and fromEvent) then
      posting = false
    elseif postStacks == 1 and owned < postOwned then
      posting, singleStackDone = false, true
    end
  end

  local maxStack = select(8, GetItemInfo(id))
  if not sameItem then listings, checked, checkFailed = nil, false, false end
  -- No link to read (the game's own update): the item shown keeps its suffix.
  suffix = suffix or (sameItem and item.suffix) or 0
  item = {
    id = id, name = slotName, texture = slotTexture or select(10, GetItemInfo(id)),
    maxStack = maxStack or 1, owned = owned, suffix = suffix,
  }
  stack, stacks = defaultCounts(id, item.maxStack, owned)
  priceEdited = false
  unit = defaultPrice(id, listings)
  Sell.lastId, lastName = id, slotName
  -- The player's own drop starts a fresh status; an update from the game
  -- must not wipe what the page last said (e.g. a posting result).
  if not fromEvent then status = "" end
  if singleStackDone then
    status = postedText(1)
    checkAfterPosting()
  else
    requestCheck(id, searchName(id, slotName), fromEvent)
  end
  changed()
end

-- A post is under way: the game's own sell frame blocks the slot, the inputs
-- and the Create button until the last auction is up, so does this page. The
-- item the player is carrying goes back to the bags.
local function refuseWhilePosting()
  ClearCursor()
  status = POST_BUSY
  changed()
  return false, "posting"
end

-- The cursor holds an item we just clicked into the sell slot (or tried to);
-- `link` is its item link.
local function place(id, link)
  local oldName = GetAuctionSellItemInfo()
  local knownId = item and item.id
  ClickAuctionSellItemButton()

  -- A refused item stays on the cursor. The same item there after a swap is
  -- the old slot item, which is the same kind as the new one.
  local cursorKind, cursorId = GetCursorInfo()
  local swappedSame = oldName ~= nil and (knownId == id or oldName == (GetItemInfo(id)))
  local refused = cursorKind == "item" and cursorId == id and not swappedSame
  -- The swapped-out old item (or the refused one) goes back to the bags.
  if cursorKind then ClearCursor() end

  if refused and oldName then
    -- The slot still holds the old item and so does our state.
    status = CANT_AUCTION
    changed()
    return false
  end
  Sell.OnSlotChanged(id, ns.Util.SuffixFromLink(link))
  return item ~= nil and item.id == id
end

-- Drag-and-drop onto our slot: whatever the cursor carries goes in.
-- ok, or false and "posting".
function Sell.DropCursorItem()
  local kind, id, link = GetCursorInfo()
  if kind ~= "item" or not id then return false end
  if posting then return refuseWhilePosting() end
  return place(id, link)
end

-- Alt+click on a bag item. ok, or false and "posting".
function Sell.PutItem(bag, slot)
  if posting then return refuseWhilePosting() end
  PickupContainerItem(bag, slot)
  local kind, id, link = GetCursorInfo()
  if kind ~= "item" or not id then
    if kind then ClearCursor() end
    return false
  end
  return place(id, link)
end

-- ok, or false and "not-in-bags" / "put-failed" / "posting".
function Sell.PutItemById(id)
  if posting then return refuseWhilePosting() end
  for bag = 0, MAX_BAG do
    for slot = 1, GetContainerNumSlots(bag) do
      if ns.Util.ItemIDFromLink(GetContainerItemLink(bag, slot)) == id then
        if Sell.PutItem(bag, slot) then return true end
        return false, "put-failed"
      end
    end
  end
  return false, "not-in-bags"
end

-- A price check stored rows for `id` (also fired for checks other pages ran).
function Sell.OnListings(id)
  if not item then
    -- The slot is empty, but the table still shows the last item's rows (see
    -- State): the check after a post lands here.
    if id == Sell.lastId then changed() end
    return
  end
  if item.id ~= id then return end
  local rows = ns.Listings.Get(id)
  if not rows then return end
  listings, checked, checkFailed = rows, true, false
  if not priceEdited then unit = defaultPrice(id, listings) end
  if TRANSIENT[status] then status = "" end
  changed()
end

function Sell.SetUnit(copper)
  copper = tonumber(copper)
  unit = copper and floor(copper) or nil
  priceEdited = true
  changed()
end

function Sell.SetStack(n)
  stack = wholeCount(n)
  changed()
end

function Sell.SetStacks(n)
  stacks = wholeCount(n)
  changed()
end

-- The stack size and number of auctions an item not posted before starts at.
function Sell.Default()
  return db and db.sell.defaultStack or DEFAULT_STACK, db and db.sell.defaultStacks or DEFAULT_STACKS
end

-- ok; false (nothing changes) unless both are whole numbers, 1-1000 items
-- and 1-100 auctions.
function Sell.SetDefault(size, count)
  size, count = tonumber(size), tonumber(count)
  local function whole(n, top) return n and n == floor(n) and n >= 1 and n <= top end
  if not (whole(size, MAX_STACK_SIZE) and whole(count, MAX_AUCTIONS)) then return false end
  db.sell.defaultStack, db.sell.defaultStacks = size, count
  status = "Default post: " .. size .. " x " .. count
  changed()
  return true
end

function Sell.SetDuration(d)
  d = tonumber(d)
  if d ~= 1 and d ~= 2 and d ~= 3 then return end
  duration = d
  if db then db.sell.duration = d end
  changed()
end

-- Click on a listings row: one step under it, or equal to it when it is ours
-- (or an alt's). Rows without a buyout have no price to follow, and a mistake
-- listing is something to buy, not a price: ok, or false and "outlier".
function Sell.PickRow(row)
  if not row or (row.unit or 0) <= 0 then return end
  -- Rows can stay on show after the slot empties; there is nothing to price.
  if not item then return false, "no-item" end
  -- (Among random-enchant variants a cheap row is just another variant.)
  if row.outlier and not isVariant(listings) then
    status = MISTAKE_ROW
    changed()
    return false, "outlier"
  end
  if row.mine then
    unit = row.unit
  else
    unit = ns.Listings.StepUnder(row.unit)
  end
  priceEdited = true
  if status == MISTAKE_ROW then status = "" end
  changed()
  return true
end

-- Everything the page shows. `shownId` / `shownName` name the item whose
-- `listings` the table shows: the item in the slot, or once the slot has
-- emptied (after a post) the last item, with its cached rows, until another
-- item goes in. `reason` says why canPost is false:
--   "no-item"      nothing in the slot
--   "slot-changed" the slot holds something other than our item (we have not
--                  heard of the change yet)
--   "posting"      a post is under way
--   "checking"     the price check has not answered yet
--   "no-check"     it ended without an answer; type a price to post anyway
--   "no-price"     no price
--   "variant"      a random-enchant item has no default price; type or pick one
--   "too-big"      a stack above the item's maximum stack
--   "too-many"     more than the client lets us post
--   "no-gold"      cannot pay the deposit
-- A typed or picked price, or one the player set in Craft Profit, needs no
-- price check.
function Sell.State()
  -- The game's slot is the truth: if it was emptied without us hearing, there
  -- is nothing to post.
  local slotName, _, _, _, _, _, _, _, slotTotal = GetAuctionSellItemInfo()
  local current = item
  if current and not slotName then current = nil end

  local s = {
    item = current, unit = unit, stack = stack, stacks = stacks, duration = duration,
    deposit = 0, costUnknown = false, listings = listings, status = status,
  }
  if not current then
    s.canPost, s.reason = false, "no-item"
    s.shownId, s.shownName = Sell.lastId, lastName
    s.listings = Sell.lastId and (ns.Listings.Get(Sell.lastId)) or nil
    return s
  end
  s.shownId, s.shownName = current.id, current.name

  current.owned = ownedCount(current.id, slotTotal)
  s.variant = isVariant(listings)
  s.flip = ns.Flip.Info(current.id)
  s.deposit = CalculateAuctionDeposit(duration, stack * stacks)

  local cut = db and db.cut or DEFAULT_CUT
  if unit then s.net = unit * (1 - cut) end

  -- Cost each, for a craft we know: what one craft costs / items per craft.
  if ns.Recipes.Get(current.id) then
    local result = ns.Profit.Evaluate(current.id, ns.Prices.MakeContext())
    if result and result.cost then
      s.cost = result.cost / result.made
      if s.net then
        s.profit = s.net - s.cost
        s.loss = s.profit < 0
      end
    else
      s.costUnknown = true
    end
  end

  -- The player's own price needs no check, but only when that is the price
  -- on the page: one set after the item went in is not (yet) the unit shown.
  local manual, source = ns.Prices.ResolveSell(current.id)
  local awaitingCheck = not (priceEdited or checked or (source == "manual" and unit == manual))
  if slotName ~= current.name then
    s.reason = "slot-changed"
  elseif posting then
    s.reason = "posting"
  elseif awaitingCheck then
    s.reason = checkFailed and "no-check" or "checking"
  elseif not unit or unit < 1 then
    s.reason = (s.variant and not priceEdited) and "variant" or "no-price"
  elseif stack > current.maxStack then
    s.reason = "too-big"
  elseif stack * stacks > current.owned then
    s.reason = "too-many"
  elseif GetMoney() < s.deposit then
    s.reason = "no-gold"
  end
  s.canPost = s.reason == nil
  return s
end

-- Post the auctions as shown (starting bid = buyout, prices are per stack).
-- Call only from the Post button's OnClick.
function Sell.Post()
  local s = Sell.State()
  if not s.canPost then return false end
  local price = s.unit * s.stack
  -- The item starts at this size the next time it goes in the slot.
  db.sell.sizes[s.item.id] = { stack = s.stack, stacks = s.stacks }
  posting, postStacks, postOwned = true, s.stacks, s.item.owned
  multisellSeen = false
  status = "Posting..."
  StartAuction(price, price, s.duration, s.stack, s.stacks)
  changed()
  return true
end

-- AUCTION_MULTISELL_START (numRepetitions), AUCTION_MULTISELL_UPDATE
-- (created, total), AUCTION_MULTISELL_FAILURE.
function Sell.OnMultisell(event, a, b)
  if event == "AUCTION_MULTISELL_START" then
    multisellSeen = true
    status = "Posting 0/" .. tostring(a or 0)
  elseif event == "AUCTION_MULTISELL_UPDATE" then
    multisellSeen = true
    if a and b and b > 0 and a >= b then
      posting = false
      status = postedText(b)
      checkAfterPosting()
    else
      status = "Posting " .. tostring(a) .. "/" .. tostring(b)
    end
  elseif event == "AUCTION_MULTISELL_FAILURE" then
    posting = false
    status = "Posting failed"
  else
    return
  end
  changed()
end

-- UI_ERROR_MESSAGE (Core routes it here with the message). A single-stack post
-- the server refuses sends no multisell event, so without this "Posting..."
-- would stick. Only that case is ours: once a multisell has started it ends
-- through its own UPDATE / FAILURE, and an unrelated error ("Can't do that while
-- moving") must not free Post in the middle of it.
function Sell.OnPostError(msg)
  if not posting or multisellSeen then return end
  posting = false
  status = (msg and msg ~= "") and msg or "Posting failed"
  changed()
end

-- The Auction House closed. The game empties its sell slot then, and no
-- multisell or slot event will say how the post ended: drop the lock and
-- whatever the status line said about it, and the searches in flight.
function Sell.OnAuctionHouseClosed()
  posting = false
  -- Nothing is going to answer a search that was running or waiting, and none
  -- may start at the next open on its own.
  running, wanted = nil, nil
  status = ""
  changed()
end

-- A price changed (/cp price, a scan): an item shown with the price we chose
-- for it gets the new default, e.g. the manual price just set. The default
-- still comes from the listings when someone competes.
local function onPricesChanged()
  if not item or priceEdited then return end
  local price = defaultPrice(item.id, listings)
  if price ~= unit then
    unit = price
    changed()
  end
end

ns.On("PRICES_CHANGED", onPricesChanged)
ns.On("LISTINGS_UPDATED", function(id)
  if running and running.id == id then running.got = true end
  Sell.OnListings(id)
end)
ns.On("SCAN_FINISHED", onScanFinished)
