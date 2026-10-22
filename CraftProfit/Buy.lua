-- CP Buy, the way Auctionator searches: a search shows every item it finds
-- (the results view), an item shows its listings with identical ones grouped
-- (the item view), and a shopping list shows its items with the last price
-- seen (the list view). The cheapest listing is bought one click at a time
-- until the player has as many as they need. Every purchase goes through
-- ns.Buyer and starts from a button OnClick (Buy.BuyCheapest, Buy.BuyGroup);
-- events only move the countdown along.
local addonName, ns = ...

local floor, max = math.floor, math.max

ns.Buy = {}
local Buy = ns.Buy

local WAIT_SCAN = "Waiting for the current scan..."
local RETRY = 0.5       -- seconds between tries of a search the AH refused for now

local view         -- "results" | "item" | "list" | nil
local back         -- the view the item view was opened from: "results" | "list" | nil
local current      -- { id, name }: the item of the item view
local need         -- how many the player wants, or nil
local bought, spent = 0, 0
local counted = {} -- row -> true once its purchase is counted
local message = "" -- the last thing to say when no need is set
local wanted       -- a search that waits for the scanner: { text } or { id, name, force }
local retryWait = 0
local searching    -- the text of our name search, until its SEARCH_DONE
local scanning = false -- our Search all runs: its progress is the message
local results, capped = nil, false
local listKey      -- the shopping list of the list view
local crafts = 1   -- crafts an automatic list is for

local function changed()
  ns.Fire("BUY_CHANGED")
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function resetCount()
  bought, spent, counted = 0, 0, {}
end

local function failed(err)
  return "Could not search the Auction House (" .. tostring(err) .. ")."
end

-- Listings of item id for the item view: those of a price check younger than
-- the fresh window are shown as they are, else the item is price-checked (a
-- busy scanner runs it when it is done). `force`: always check.
local function check(id, name, force)
  local rows, age = ns.Listings.Get(id)
  if not force and rows and age < ns.Prices.FreshSeconds() then
    wanted, message = nil, ""
    changed()
    return true
  end
  local ok, err = ns.Scanner.PriceCheck({ id = id, name = name })
  if ok then
    wanted, message = nil, "Searching..."
  elseif err == "busy" then
    wanted, message = { id = id, name = name, force = force }, WAIT_SCAN
  else
    message = failed(err)
  end
  changed()
  return ok, err
end

-- The player asked for something else: a name search of ours that runs or
-- waits for the scanner is dropped, so the new request starts at once.
local function dropPending()
  wanted = nil
  local running = searching
  searching = nil
  if running and ns.Scanner.SearchText() == running then ns.Scanner.Stop("replaced") end
end

-- The name search behind the results view.
local function search(text)
  if searching == text and ns.Scanner.SearchText() == text then
    view, back, listKey = "results", nil, nil -- already running
    changed()
    return true
  end
  dropPending()
  view, back, listKey = "results", nil, nil
  results, capped = nil, false
  local ok, err = ns.Scanner.Search(text, { stopOnExact = true })
  if ok then
    searching, wanted, message = text, nil, "Searching..."
  elseif err == "busy" then
    searching, wanted, message = nil, { text = text }, WAIT_SCAN
  else
    searching, message = nil, failed(err)
  end
  changed()
  return ok, err
end

-- "results" | "item" | "list" | nil (nothing searched yet).
function Buy.View()
  return view
end

-- Search what the player typed. A name the client knows, or a tracked
-- recipe's or material's name, opens that item at once. Anything else is a
-- name search; it stops at the first page with an item of exactly that name,
-- which then opens.
function Buy.Search(text)
  text = trim(text)
  if text == "" then return false, "empty" end
  local name, link = GetItemInfo(text)
  local id = link and ns.Util.ItemIDFromLink(link)
  if id then return Buy.OpenItem(id, name) end
  id, name = ns.Recipes.IdByName(text)
  if id then return Buy.OpenItem(id, name) end
  return search(text)
end

-- results ({ id, name, texture, unit, auctions, quantity, t } by name),
-- whether the search stopped at its page cap, and whether it has answered.
function Buy.Results()
  return results or {}, capped, results ~= nil
end

-- Show item id's listings. `needN` sets the need. Opened from the results or
-- a list, Back returns there.
function Buy.OpenItem(id, name, needN)
  name = name or (id and GetItemInfo(id))
  if not id or not name then return false, "no-name" end
  dropPending() -- whatever the player asks for now wins over a search in flight
  if view == "results" or view == "list" then
    back = view
  elseif view ~= "item" then
    back = nil
  end
  view = "item"
  if not current or current.id ~= id then
    need = nil
    resetCount()
  end
  current = { id = id, name = name }
  if needN ~= nil then
    need = needN
    resetCount()
  end
  return check(id, name, false)
end

-- Search an item whose id is known (a material of a recipe).
function Buy.SearchItem(id, name)
  return Buy.OpenItem(id, name)
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
  return Buy.OpenItem(id, name)
end

function Buy.CanGoBack()
  return view == "item" and back ~= nil
end

function Buy.Back()
  if not Buy.CanGoBack() then return end
  view, back = back, nil
  changed()
end

-- Driven by Core's OnUpdate: retries a search the scanner was too busy for.
-- Never buys.
function Buy.Tick(elapsed)
  if wanted and not ns.Scanner.IsBusy() then
    retryWait = retryWait + elapsed
    if retryWait >= RETRY then
      retryWait = 0
      local w = wanted
      wanted = nil
      if w.text then search(w.text) else check(w.id, w.name, w.force) end
    end
  end
end

function Buy.Current()
  if current then return current.id, current.name end
end

function Buy.Rows()
  return current and ns.Listings.Get(current.id) or nil
end

-- The item's listings, identical ones as one group; a stack bought a moment
-- ago has left its group.
function Buy.Groups()
  local rows = Buy.Rows()
  if not rows then return {} end
  return ns.Listings.Group(ns.Listings.MarkUnderYou(rows), ns.Buyer.IsBought)
end

-- nil clears it; 0 means the player already has enough. A new need starts
-- the count over.
function Buy.SetNeed(n)
  n = tonumber(n)
  need = (n and n >= 0) and floor(n) or nil
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

local function buyable(row)
  local state = ns.Buyer.State(row)
  return not row.mine and row.seller and (row.buyout or 0) > 0 and state ~= "bought" and state ~= "gone"
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
    if buyable(row) then
      cheapest = cheapest or row
      if remaining and row.count <= remaining and (not fit or row.unit < fit.unit) then fit = row end
      if not smallest or row.buyout < smallest.buyout then smallest = row end
    end
  end
  if not remaining then return cheapest end
  return fit or smallest
end

-- The stack of `group` that "Buy one" buys: its first one that can be bought.
function Buy.GroupPick(group)
  if not group then return nil end
  for _, row in ipairs(group.rows) do
    if buyable(row) then return row end
  end
  return nil
end

-- The one way every Buy click reaches ns.Buyer.
local function buyRow(row)
  if not current or not row then return false, "Nothing to buy." end
  if row.mine then return false, "That's your own listing." end
  if ns.Buyer.IsBought(row) then return false, "Already bought" end
  return ns.Buyer.Buy(current.id, row, current.name)
end

-- Call only from a button OnClick.
function Buy.BuyCheapest()
  local row = Buy.Pick()
  if not row then return false, "Nothing to buy." end
  return buyRow(row)
end

-- Buy one stack of `group`. Call only from a button OnClick.
function Buy.BuyGroup(group)
  local row = Buy.GroupPick(group)
  if not row then return false, "Nothing to buy." end
  return buyRow(row)
end

function Buy.Status()
  if need then
    if need == 0 then return "You have enough." end
    if bought >= need then return "Done (bought " .. bought .. ")" end
    return "Bought " .. bought .. " of " .. need .. " (spent " .. ns.Style.Money(spent) .. ")"
  end
  return message
end

-- Shopping lists

-- Show the list `key` (from ns.Lists.All).
function Buy.OpenList(key)
  dropPending()
  view, back, listKey = "list", nil, key
  changed()
end

function Buy.ListKey()
  return listKey
end

function Buy.SetCrafts(n)
  n = tonumber(n)
  crafts = (n and n >= 1) and floor(n) or 1
  changed()
end

function Buy.Crafts()
  return crafts
end

function Buy.ListLines()
  if not listKey then return {} end
  return ns.Lists.Lines(listKey, crafts)
end

-- Open a list line's item. An automatic list's line sets the need to what is
-- still missing (0: "You have enough."); one of the player's lists has none.
function Buy.OpenLine(line)
  if not line then return false end
  local ok, err = Buy.OpenItem(line.id, line.name)
  Buy.SetNeed(line.need and max(0, line.need - line.have) or nil)
  return ok, err
end

-- Price-check every item of the list shown, leaving out those scanned within
-- the fresh window, so its cheapest column fills in.
function Buy.SearchAll()
  local items = {}
  for _, line in ipairs(Buy.ListLines()) do items[#items + 1] = { id = line.id, name = line.name } end
  if #items == 0 then
    message = "Nothing on this list."
    changed()
    return false, "empty"
  end
  local ok, err = ns.Scanner.StartTargeted(items, { skipFresh = true })
  if ok then
    scanning, message = true, ns.Scanner.statusText
  elseif err == "fresh" then
    message = ns.Scanner.statusText
  elseif err == "busy" then
    message = "A scan is already running."
  else
    message = failed(err)
  end
  changed()
  return ok, err
end

-- The list shown is gone (deleted, or its recipe no longer tracked).
local function checkList()
  if view ~= "list" or not listKey then return end
  for _, list in ipairs(ns.Lists.All()) do
    if list.key == listKey then return end
  end
  view, listKey = nil, nil
  changed()
end

ns.On("LISTS_CHANGED", checkList)
ns.On("TRACKING_CHANGED", checkList)

-- Our name search is done: its results, or the item it found by name.
ns.On("SEARCH_DONE", function(text, list, wasCapped, exactId)
  if searching ~= text then return end
  searching = nil
  if exactId then
    local name
    for _, r in ipairs(list) do
      if r.id == exactId then name = r.name end
    end
    view = nil -- straight to the item: there were no results to go back to
    Buy.OpenItem(exactId, name)
    return
  end
  results, capped, message = list, wasCapped, ns.Scanner.statusText
  changed()
end)

ns.On("SCAN_STATUS", function(text)
  if searching or scanning then
    message = text
    changed()
  end
end)

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
  if current and id == current.id then check(current.id, current.name, true) end
end)

-- A search that waited for the scanner runs now. A search of ours that ended
-- without SEARCH_DONE (stopped) leaves its reason on the line.
ns.On("SCAN_FINISHED", function()
  scanning = false
  if searching then
    searching, message = nil, ns.Scanner.statusText
    changed()
  end
  local w = wanted
  if not w then return end
  wanted = nil
  if w.text then search(w.text) else check(w.id, w.name, w.force) end
end)
