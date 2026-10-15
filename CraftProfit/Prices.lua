-- Price storage and the rules for picking which price to use.
local addonName, ns = ...

local floor = math.floor
local STALE_AFTER = 86400

ns.Prices = {}
local Prices = ns.Prices

local db, ah

function Prices.SetDB(savedDB, realmKey)
  db = savedDB
  db.prices = db.prices or {}
  db.prices[realmKey] = db.prices[realmKey] or {}
  db.vendor = db.vendor or {}
  db.manual = db.manual or {}
  ah = db.prices[realmKey]
end

-- unit == nil with listings == 0 means "scanned, nothing listed".
function Prices.SetAH(id, unit, listings, t)
  ah[id] = { p = unit, t = t, n = listings }
end

function Prices.GetAH(id)
  local rec = ah[id]
  if not rec then return nil end
  return rec.p, rec.t, rec.n
end

function Prices.AllAH()
  return ah
end

function Prices.SetVendor(id, unit)
  db.vendor[id] = unit
end

function Prices.SetManual(id, unit)
  db.manual[id] = unit
end

local function positive(ok, value)
  if ok and type(value) == "number" and value > 0 then return value end
  return nil
end

-- Last-seen price from Auctionator, if it is installed. Two API shapes exist
-- for 3.3.5 builds; both are optional and guarded.
function Prices.Auctionator(id)
  local api = type(Auctionator) == "table" and Auctionator.API and Auctionator.API.v1
  if api and type(api.GetAuctionPriceByItemID) == "function" then
    local price = positive(pcall(api.GetAuctionPriceByItemID, addonName, id))
    if price then return price end
  end
  if type(Atr_GetAuctionBuyout) == "function" then
    local name, link = GetItemInfo(id)
    for _, key in ipairs({ name, link }) do
      local price = positive(pcall(Atr_GetAuctionBuyout, key))
      if price then return price end
    end
  end
  return nil
end

local function ahQuote(id)
  local rec = ah[id]
  if rec and rec.p then return rec.p, ns.Now() - rec.t end
  return nil
end

-- Material price: manual, else cheapest of AH / vendor / craft, else Auctionator.
function Prices.ResolveBuy(id, craftUnit)
  local manual = db.manual[id]
  if manual then return manual, "manual", nil end

  local best, source, age
  local ahPrice, ahAge = ahQuote(id)
  if ahPrice then best, source, age = ahPrice, "ah", ahAge end
  local vendor = db.vendor[id]
  if vendor and (not best or vendor < best) then best, source, age = vendor, "vendor", nil end
  if craftUnit and (not best or craftUnit < best) then best, source, age = craftUnit, "craft", nil end
  if best then return best, source, age end

  local atr = Prices.Auctionator(id)
  if atr then return atr, "atr", nil end
  return nil
end

-- Sell price: manual, else AH, else Auctionator.
function Prices.ResolveSell(id)
  local manual = db.manual[id]
  if manual then return manual, "manual", nil end
  local ahPrice, ahAge = ahQuote(id)
  if ahPrice then return ahPrice, "ah", ahAge end
  local atr = Prices.Auctionator(id)
  if atr then return atr, "atr", nil end
  return nil
end

function Prices.IsStale(age)
  return age ~= nil and age > STALE_AFTER
end

-- Remember what the open vendor charges per unit (gold-only items).
function Prices.RecordMerchant()
  local count = 0
  for i = 1, GetMerchantNumItems() do
    local _, _, price, quantity, _, _, extendedCost = GetMerchantItemInfo(i)
    local id = ns.Util.ItemIDFromLink(GetMerchantItemLink(i))
    if id and price and price > 0 and not extendedCost and quantity and quantity > 0 then
      local unit = floor(price / quantity + 0.5)
      if db.vendor[id] ~= unit then
        db.vendor[id] = unit
        count = count + 1
      end
    end
  end
  if count > 0 then ns.Fire("PRICES_CHANGED") end
  return count
end

function Prices.MakeContext()
  return {
    recipes = ns.Recipes.All(),
    resolveBuy = Prices.ResolveBuy,
    resolveSell = Prices.ResolveSell,
    cut = db.cut or 0.05,
  }
end
