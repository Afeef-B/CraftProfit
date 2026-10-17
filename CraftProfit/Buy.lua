-- CP Buy: search an item, list it cheapest per unit first, buy the cheapest
-- listing one click at a time until the player has as many as they need.
-- Every purchase goes through ns.Buyer and starts from a button OnClick
-- (Buy.BuyCheapest, Buy.BuyRow); events only move the countdown along.
local addonName, ns = ...

local max = math.max

ns.Buy = {}
local Buy = ns.Buy

local PAGE_SIZE = NUM_AUCTION_ITEMS_PER_PAGE or 50
local WAIT_SCAN = "Waiting for the current scan..."
local NAME_WAIT = 2     -- seconds to wait for item names still loading on the page
local RETRY = 0.5       -- seconds between tries of a search the AH refused for now

local current      -- { id, name }: the item shown
local need         -- how many the player wants, or nil
local bought, spent = 0, 0
local counted = {} -- row -> true once its purchase is counted
local message = "" -- the last thing to say when no need is set
local wanted       -- a search that waits for the scanner: { text } or { id, name }
local retryWait = 0
-- A typed name being looked up on the AH's first results page:
-- { text, stale = fingerprint of the page shown before, waiting = seconds
-- spent on a page whose names are still loading }.
local resolving

local function changed()
  ns.Fire("BUY_CHANGED")
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function resetCount()
  bought, spent, counted = 0, 0, {}
end

-- Show item id and price-check it; a busy scanner runs it when it is done.
local function start(id, name)
  resolving = nil -- whatever the player asks for now wins over a lookup in flight
  if not current or current.id ~= id then
    need = nil
    resetCount()
  end
  current = { id = id, name = name }
  local ok, err = ns.Scanner.PriceCheck({ id = id, name = name })
  if ok then
    wanted, message = nil, "Searching..."
  elseif err == "busy" then
    wanted, message = { id = id, name = name }, WAIT_SCAN
  else
    message = "Could not search the Auction House (" .. tostring(err) .. ")."
  end
  changed()
  return ok, err
end

-- Search what the player typed. The item's id comes from the client's item
-- cache; an item the client has not seen yet is looked up by name on the AH
-- (which searches by part of the name: only the exact name counts).
function Buy.Search(text)
  text = trim(text)
  if text == "" then return false, "empty" end
  local name, link = GetItemInfo(text)
  local id = link and ns.Util.ItemIDFromLink(link)
  if id then return start(id, name) end

  local stale = ns.Buyer.PagePrint()
  local ok, err = ns.Scanner.LoadPage(text, 0)
  if not ok then
    if err == "busy" or err == "throttled" then
      wanted, message = { text = text }, WAIT_SCAN
    else
      message = "Could not search the Auction House (" .. tostring(err) .. ")."
    end
    changed()
    return false, err
  end
  resolving, message = { text = text, stale = stale }, "Searching..."
  changed()
  return true
end

-- Search an item whose id is known (a material of a recipe).
function Buy.SearchItem(id, name)
  name = name or GetItemInfo(id)
  if not id or not name then return false, "no-name" end
  return start(id, name)
end

-- Search the item of a link (a shift-clicked reagent, bag item, chat link).
function Buy.SearchLink(link)
  local id = ns.Util.ItemIDFromLink(link)
  if not id then return false, "no-item" end
  local name = ns.Util.ItemNameFromLink(link) or GetItemInfo(id)
  if not name then
    message = "That item isn't loaded yet - try again."
    changed()
    return false, "no-name"
  end
  return start(id, name)
end

-- Decide a lookup from the page the client shows. `force`: names that are
-- still loading are given up on.
local function decide(force)
  local text = resolving.text
  local batch = GetNumAuctionItems("list")
  if batch > PAGE_SIZE then return end -- a whole-AH list, not our page
  local wantedName, unreadable = text:lower(), false
  for i = 1, batch do
    local name = GetAuctionItemInfo("list", i)
    local link = GetAuctionItemLink("list", i)
    if not name or not link then
      unreadable = true
    elseif name:lower() == wantedName then
      local id = ns.Util.ItemIDFromLink(link)
      if id then
        start(id, name)
        return
      end
    end
  end
  if unreadable and not force then
    resolving.waiting = resolving.waiting or 0
    return
  end
  message = "No item called " .. text .. " on the Auction House."
  resolving = nil
  changed()
end

-- AUCTION_ITEM_LIST_UPDATE (routed by Core): the answer to a name lookup. A
-- late update for the page shown before the search is not that answer.
function Buy.OnListUpdate()
  if not resolving then return end
  local print = ns.Buyer.PagePrint()
  if print and print == resolving.stale then return end
  decide(false)
end

-- Driven by Core's OnUpdate. Gives up waiting for names after NAME_WAIT and
-- retries a search the AH refused for now. Never buys.
function Buy.Tick(elapsed)
  if resolving and resolving.waiting then
    resolving.waiting = resolving.waiting + elapsed
    if resolving.waiting >= NAME_WAIT then decide(true) end
  end
  if wanted and not ns.Scanner.IsBusy() then
    retryWait = retryWait + elapsed
    if retryWait >= RETRY then
      retryWait = 0
      local w = wanted
      wanted = nil
      if w.text then Buy.Search(w.text) else start(w.id, w.name) end
    end
  end
end

function Buy.Current()
  if current then return current.id, current.name end
end

function Buy.Rows()
  return current and ns.Listings.Get(current.id) or nil
end

-- nil clears it; 0 means the player already has enough. A new need starts
-- the count over.
function Buy.SetNeed(n)
  n = tonumber(n)
  need = (n and n >= 0) and math.floor(n) or nil
  resetCount()
  changed()
end

-- The need the player set (not counting down), or nil.
function Buy.Target()
  return need
end

-- How many are still needed (0 when done), or nil without a need.
function Buy.Need()
  if not need then return nil end
  return max(0, need - bought)
end

-- The listing "Buy cheapest" buys, or nil: never the player's own (or an
-- alt's), one already bought, one without a buyout or a seller name. Among
-- the stacks that fit the remaining need, the cheapest per unit; when none
-- fits, the smallest total; with no need set, the cheapest per unit.
function Buy.Pick()
  local rows = Buy.Rows()
  if not rows then return nil end
  local remaining = Buy.Need()
  if remaining == 0 then return nil end
  local fit, smallest, cheapest
  for _, row in ipairs(rows) do
    local state = ns.Buyer.State(row)
    if not row.mine and row.seller and (row.buyout or 0) > 0 and state ~= "bought" and state ~= "gone" then
      cheapest = cheapest or row
      if remaining and row.count <= remaining and (not fit or row.unit < fit.unit) then fit = row end
      if not smallest or row.buyout < smallest.buyout then smallest = row end
    end
  end
  if not remaining then return cheapest end
  return fit or smallest
end

-- Call only from a button OnClick.
function Buy.BuyCheapest()
  local row = Buy.Pick()
  if not row then return false, "Nothing to buy." end
  return ns.Buyer.Buy(current.id, row, current.name)
end

-- Buy exactly `row` (the one the player selected). Call only from OnClick.
function Buy.BuyRow(row)
  if not current or not row then return false, "Nothing to buy." end
  if row.mine then return false, "That's your own listing." end
  if ns.Buyer.IsBought(row) then return false, "Already bought" end
  return ns.Buyer.Buy(current.id, row, current.name)
end

function Buy.Status()
  if need then
    if need == 0 then return "You have enough." end
    if bought >= need then return "Done (bought " .. bought .. ")" end
    return "Bought " .. bought .. " of " .. need .. " (spent " .. ns.Style.Money(spent) .. ")"
  end
  return message
end

-- A purchase of the shown item went through: count it once.
ns.On("BUYER_CHANGED", function(id, row)
  if not current or id ~= current.id or counted[row] then return end
  if ns.Buyer.State(row) ~= "bought" then return end
  counted[row] = true
  bought = bought + row.count
  spent = spent + row.buyout
  changed()
end)

ns.On("BUYER_SAID", function(id, _, _, text)
  if current and id == current.id then
    message = text
    changed()
  end
end)

ns.On("LISTINGS_UPDATED", function(id)
  if current and id == current.id then
    if message == "Searching..." then message = "" end
    changed()
  end
end)

-- A listing of the shown item could not be found (sold, or the page never
-- came): search the item again so the list shows what is really there.
ns.On("BUYER_LOST", function(id)
  if current and id == current.id then start(current.id, current.name) end
end)

-- A search that waited for the scanner runs now.
ns.On("SCAN_FINISHED", function()
  local w = wanted
  if not w then return end
  wanted = nil
  if w.text then Buy.Search(w.text) else start(w.id, w.name) end
end)
