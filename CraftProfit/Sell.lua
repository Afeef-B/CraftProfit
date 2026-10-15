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
-- Notes that only describe a price check in progress; they go away with it.
local TRANSIENT = { [SEARCHING] = true, [WAITING] = true, [NO_ANSWER] = true }

local db
local item                  -- { id, name, texture, maxStack, owned } or nil
local unit                  -- price each in copper; nil = none yet
local stack, stacks = 1, 1  -- items per auction, number of auctions
local duration = DEFAULT_DURATION
local priceEdited = false   -- the player chose the price: price checks leave it alone
local listings              -- rows of the last price check of the current item
local status = ""
local lastName              -- the sell slot's name for Sell.lastId

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

-- Price each when nobody else sets it: under the cheapest other seller, equal
-- to our own, else the last known price (nil when there is none).
local function defaultPrice(id, rows)
  local price = ns.Listings.UndercutPrice(rows or {}, (ns.Prices.ResolveSell(id)))
  return price
end

local function startCheck(id, name, quiet)
  local ok, err = ns.Scanner.PriceCheck({ id = id, name = name })
  if ok then
    running = { id = id, got = false, quiet = quiet }
    if not quiet then status = SEARCHING end
  elseif err == "busy" then
    wanted = { id = id, name = name, quiet = quiet }
    if not quiet then status = WAITING end
  elseif not quiet then
    status = "Could not search the Auction House (" .. tostring(err) .. ")."
  end
end

-- Ask for a price check of `id`. A busy scanner makes it wait for SCAN_FINISHED.
-- A check of the same item that is already running is enough, unless `force`
-- (the auctions we just posted are not in its answer). `quiet` leaves the
-- status line alone.
local function requestCheck(id, name, quiet, force)
  if running and running.id == id and not force then
    running.quiet = running.quiet and quiet
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
  local before = status
  local finished = running
  running = nil
  if finished and not finished.got and not finished.quiet and item and item.id == finished.id then
    status = NO_ANSWER
  end
  if wanted then
    local following = wanted
    wanted = nil
    startCheck(following.id, following.name, following.quiet)
  end
  -- Every scan of the player's ends here; most have nothing to do with us.
  if status ~= before then changed() end
end

-- Back to "no item". A posting message stays; a pending search goes.
local function resetItem()
  item, unit, listings, priceEdited = nil, nil, nil, false
  stack, stacks = 1, 1
  if wanted and not wanted.quiet then wanted = nil end
  if TRANSIENT[status] then status = "" end
end

-- Stack size and number of auctions that sell everything we own.
local function defaultCounts(maxStack, owned)
  if owned < 1 then return 1, 1 end
  if maxStack <= 1 then return 1, owned end
  local size = min(maxStack, owned)
  return size, floor(owned / size)
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
  local saved = db.sell.duration
  if saved ~= 1 and saved ~= 2 and saved ~= 3 then db.sell.duration = DEFAULT_DURATION end
  duration = db.sell.duration
end

-- The game's sell slot changed. `id` is the item we just put there ourselves;
-- nil when NEW_AUCTION_UPDATE says so (the slot was emptied after posting, or
-- its count changed), then the item is the one already shown.
function Sell.OnSlotChanged(id)
  local slotName, slotTexture = GetAuctionSellItemInfo()
  if not slotName then
    resetItem()
    if id then status = CANT_AUCTION end
    changed()
    return
  end

  local fromEvent = id == nil
  id = id or idForSlotName(slotName)
  if not id then
    -- Something we know nothing about sits in the slot.
    resetItem()
    changed()
    return
  end

  local maxStack, _, infoTexture = select(8, GetItemInfo(id))
  local owned = GetItemCount(id)
  if not (item and item.id == id) then listings = nil end
  item = {
    id = id, name = slotName, texture = slotTexture or infoTexture,
    maxStack = maxStack or 1, owned = owned,
  }
  stack, stacks = defaultCounts(item.maxStack, owned)
  priceEdited = false
  unit = defaultPrice(id, listings)
  Sell.lastId, lastName = id, slotName
  -- The player's own drop starts a fresh status; an update from the game
  -- must not wipe what the page last said (e.g. a posting result).
  if not fromEvent then status = "" end
  requestCheck(id, slotName, fromEvent)
  changed()
end

-- The cursor holds an item we just clicked into the sell slot (or tried to).
local function place(id)
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
  Sell.OnSlotChanged(id)
  return item ~= nil and item.id == id
end

-- Drag-and-drop onto our slot: whatever the cursor carries goes in.
function Sell.DropCursorItem()
  local kind, id = GetCursorInfo()
  if kind ~= "item" or not id then return false end
  return place(id)
end

-- Alt+click on a bag item.
function Sell.PutItem(bag, slot)
  PickupContainerItem(bag, slot)
  local kind, id = GetCursorInfo()
  if kind ~= "item" or not id then
    if kind then ClearCursor() end
    return false
  end
  return place(id)
end

-- ok, or false and "not-in-bags" / "put-failed".
function Sell.PutItemById(id)
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
  if not item or item.id ~= id then return end
  local rows = ns.Listings.Get(id)
  if rows then listings = rows end
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

function Sell.SetDuration(d)
  d = tonumber(d)
  if d ~= 1 and d ~= 2 and d ~= 3 then return end
  duration = d
  if db then db.sell.duration = d end
  changed()
end

-- Click on a listings row: one step under it, or equal to it when it is ours
-- (or an alt's). Rows without a buyout have no price to follow.
function Sell.PickRow(row)
  if not row or (row.unit or 0) <= 0 then return end
  if row.mine then
    unit = row.unit
  else
    unit = ns.Listings.StepUnder(row.unit)
  end
  priceEdited = true
  changed()
end

-- Everything the page shows. `reason` says why canPost is false: "no-item",
-- "no-price", "too-many" (more than the bags hold) or "no-gold" (deposit).
function Sell.State()
  -- The game's slot is the truth: if it was emptied without us hearing, there
  -- is nothing to post.
  local current = item
  if current and GetAuctionSellItemInfo() == nil then current = nil end

  local s = {
    item = current, unit = unit, stack = stack, stacks = stacks, duration = duration,
    deposit = 0, costUnknown = false, listings = listings, status = status,
  }
  if not current then
    s.canPost, s.reason = false, "no-item"
    return s
  end

  current.owned = GetItemCount(current.id)
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

  if not unit or unit < 1 then
    s.reason = "no-price"
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
  status = "Posting..."
  StartAuction(price, price, s.duration, s.stack, s.stacks)
  changed()
  return true
end

-- AUCTION_MULTISELL_START (numRepetitions), AUCTION_MULTISELL_UPDATE
-- (created, total), AUCTION_MULTISELL_FAILURE.
function Sell.OnMultisell(event, a, b)
  if event == "AUCTION_MULTISELL_START" then
    status = "Posting 0/" .. tostring(a or 0)
  elseif event == "AUCTION_MULTISELL_UPDATE" then
    if a and b and b > 0 and a >= b then
      status = "Posted " .. b .. (b == 1 and " auction" or " auctions")
      -- Look the item up again so the listings show what we just posted; the
      -- slot may be empty by now, hence the remembered id.
      local id = Sell.lastId
      local name = item and item.name or lastName
      if id and name then requestCheck(id, name, true, true) end
    else
      status = "Posting " .. tostring(a) .. "/" .. tostring(b)
    end
  elseif event == "AUCTION_MULTISELL_FAILURE" then
    status = "Posting failed"
  else
    return
  end
  changed()
end

ns.On("LISTINGS_UPDATED", function(id)
  if running and running.id == id then running.got = true end
  Sell.OnListings(id)
end)
ns.On("SCAN_FINISHED", onScanFinished)
