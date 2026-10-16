-- CP Buy: search an item, list it cheapest per unit first, buy the cheapest
-- listing one click at a time until the player has as many as they need.
-- Every purchase goes through ns.Buyer and starts from a button OnClick
-- (Buy.BuyCheapest, Buy.BuyRow); events only move the countdown along.
local addonName, ns = ...

local ceil, max = math.ceil, math.max

ns.Buy = {}
local Buy = ns.Buy

local PAGE_SIZE = NUM_AUCTION_ITEMS_PER_PAGE or 50
local WAIT_SCAN = "Waiting for the current scan..."

local current      -- { id, name }: the item shown
local need         -- how many the player wants, or nil
local bought, spent = 0, 0
local counted = {} -- row -> true once its purchase is counted
local message = "" -- the last thing to say when no need is set
local wanted       -- a search that waits for the scanner: { text } or { id, name }
local resolving    -- a typed name being looked up on the AH's first results page

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
  resolving, message = text, "Searching..."
  changed()
  return true
end

-- Search the item of a link (a shift-clicked reagent, bag item, chat link).
function Buy.SearchLink(link)
  local id = ns.Util.ItemIDFromLink(link)
  if not id then return false, "no-item" end
  local name = ns.Util.ItemNameFromLink(link) or GetItemInfo(id)
  return start(id, name)
end

-- AUCTION_ITEM_LIST_UPDATE (routed by Core): the answer to a name lookup.
function Buy.OnListUpdate()
  if not resolving then return end
  local batch = GetNumAuctionItems("list")
  if batch > PAGE_SIZE then return end -- a whole-AH list, not our page
  local wantedName = resolving:lower()
  for i = 1, batch do
    local name = GetAuctionItemInfo("list", i)
    if name and name:lower() == wantedName then
      local id = ns.Util.ItemIDFromLink(GetAuctionItemLink("list", i))
      if id then
        resolving = nil
        start(id, name)
        return
      end
    end
  end
  message = "No item called " .. resolving .. " on the Auction House."
  resolving = nil
  changed()
end

function Buy.Current()
  if current then return current.id, current.name end
end

function Buy.Rows()
  return current and ns.Listings.Get(current.id) or nil
end

-- nil or <= 0 clears it. A new need starts the count over.
function Buy.SetNeed(n)
  n = tonumber(n)
  need = (n and n > 0) and math.floor(n) or nil
  resetCount()
  changed()
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
    if not row.mine and row.seller and (row.buyout or 0) > 0 and not ns.Buyer.IsBought(row) then
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
    if bought >= need then return "Done (bought " .. bought .. ")" end
    return "Bought " .. bought .. " of " .. need .. " (spent " .. ns.Style.Money(spent) .. ")"
  end
  return message
end

-- What `crafts` crafts of recipeId take, as { id, name, need, have }. A
-- from-scratch recipe lists the materials of the materials it can craft.
function Buy.Materials(recipeId, crafts)
  local list, index = {}, {}
  local scratch = ns.Recipes.Depth(recipeId) == "scratch"

  local function add(id, name, qty)
    local entry = index[id]
    if not entry then
      entry = { id = id, name = name, need = 0 }
      index[id] = entry
      list[#list + 1] = entry
    end
    entry.need = entry.need + qty
  end

  -- qty crafts of recipe `id`
  local function expand(id, qty, visiting)
    local recipe = ns.Recipes.Get(id)
    visiting[id] = true
    for _, reagent in ipairs(recipe.reagents) do
      local amount = reagent.count * qty
      local sub = scratch and ns.Recipes.Get(reagent.id)
      if sub and not visiting[reagent.id] then
        expand(reagent.id, amount / (sub.made or 1), visiting)
      else
        add(reagent.id, reagent.name, amount)
      end
    end
    visiting[id] = nil
  end

  if not ns.Recipes.Get(recipeId) then return list end
  expand(recipeId, crafts or 1, {})
  for _, entry in ipairs(list) do
    entry.need = ceil(entry.need - 1e-9)
    entry.have = GetItemCount(entry.id)
  end
  return list
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

-- A search that waited for the scanner runs now.
ns.On("SCAN_FINISHED", function()
  local w = wanted
  if not w then return end
  wanted = nil
  if w.text then Buy.Search(w.text) else start(w.id, w.name) end
end)
