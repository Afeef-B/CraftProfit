-- Rows of one item's price check (count, buyout, seller) and the undercut
-- maths built on them. Pure: no WoW API calls, only ns.Now() and ns.Fire().
local addonName, ns = ...

local floor = math.floor

ns.Listings = {}
local Listings = ns.Listings

-- Results of the last price check per item id: cache[id] = { t = epoch, rows = {...} }.
Listings.cache = {}

local DEFAULT_RATIO = 0.5
local MAX_OUTLIER_ROWS = 3

local db, realm

-- Remember this character as ours; its alts (same realm and faction) are
-- the other names in db.chars[realmKey].
function Listings.SetDB(savedDB, realmKey, playerName)
  db = savedDB
  realm = realmKey
  db.chars = db.chars or {}
  db.chars[realmKey] = db.chars[realmKey] or {}
  if playerName then db.chars[realmKey][playerName] = true end
end

-- { [name] = true } for this character and its alts.
function Listings.MineSet()
  return db and realm and db.chars[realm] or {}
end

-- A row is a "mistake listing" when it is this many times cheaper than the next one.
function Listings.Ratio()
  return db and db.outlierRatio or DEFAULT_RATIO
end

-- Normalize gives unit > 0 exactly when the row has a buyout.
local function hasBuyout(row)
  return (row.unit or 0) > 0
end

-- Cheapest priced listing of ours that costs more than `unit`, or nil.
local function cheapestMineAbove(rows, unit)
  local best
  for i = 1, #rows do
    local row = rows[i]
    if row.mine and hasBuyout(row) and row.unit > unit and (not best or row.unit < best) then
      best = row.unit
    end
  end
  return best
end

-- raw rows { count, buyout, seller, page, index, suffix } -> sorted rows with
-- unit, mine and outlier added (suffix is kept as it came). The raw rows are
-- left alone.
function Listings.Normalize(raw, mineSet, ratio)
  mineSet = mineSet or {}
  ratio = ratio or DEFAULT_RATIO

  local rows, seq = {}, {}
  for i = 1, #raw do
    local r = raw[i]
    local count, buyout = r.count or 1, r.buyout or 0
    local unit = 0
    if buyout > 0 then
      unit = math.max(1, floor(buyout / math.max(count, 1) + 0.5))
    end
    local row = {
      count = count, buyout = buyout, seller = r.seller,
      page = r.page, index = r.index, suffix = r.suffix,
      unit = unit,
      mine = r.seller ~= nil and mineSet[r.seller] ~= nil,
      outlier = false,
    }
    rows[i] = row
    seq[row] = i
  end

  -- Cheapest first, rows without a buyout last; bigger stacks first on a tie.
  table.sort(rows, function(a, b)
    local ab, bb = hasBuyout(a), hasBuyout(b)
    if ab ~= bb then return ab end
    if a.unit ~= b.unit then return a.unit < b.unit end
    if a.count ~= b.count then return a.count > b.count end
    return seq[a] < seq[b]
  end)

  -- Mistake listings: among other sellers' priced rows o1..on, the largest
  -- i <= 3 (and < n) whose unit is under ratio * o(i+1) marks rows 1..i.
  -- With exactly one other seller there is no o(i+1); then our cheapest
  -- priced listing above it is the reference (none: not a mistake).
  local others = {}
  for i = 1, #rows do
    local row = rows[i]
    if not row.mine and hasBuyout(row) then others[#others + 1] = row end
  end
  if #others == 1 then
    local reference = cheapestMineAbove(rows, others[1].unit)
    if reference and others[1].unit < ratio * reference then others[1].outlier = true end
  else
    for i = math.min(MAX_OUTLIER_ROWS, #others - 1), 1, -1 do
      if others[i].unit < ratio * others[i + 1].unit then
        for j = 1, i do others[j].outlier = true end
        break
      end
    end
  end

  return rows
end

-- True when the rows are not one plain item: some carry a random-suffix id
-- ("of the Monkey"), alone or next to others (more than one distinct suffix
-- always includes a nonzero one). Variants share an item id and not a price, so
-- rows like these say nothing about what one of them is worth. A row whose
-- suffix is unknown counts as plain.
function Listings.MixedSuffix(rows)
  for i = 1, #rows do
    if (rows[i].suffix or 0) ~= 0 then return true end
  end
  return false
end

-- Cheapest priced rows by who owns them. Outliers are flips, not competition.
-- flipRef is the unit price that marked `flip` as a mistake: the cheapest
-- non-outlier other seller, or (a lone other seller) our listing above it.
function Listings.Summarize(rows)
  local s = { mineCount = 0 }
  local lowestOtherRow, flip
  for i = 1, #rows do
    local row = rows[i]
    if row.mine then
      s.mineCount = s.mineCount + 1
      if hasBuyout(row) and (not s.lowestMine or row.unit < s.lowestMine) then
        s.lowestMine = row.unit
      end
    elseif hasBuyout(row) then
      if row.outlier then
        if not flip or row.unit < flip.unit then flip = row end
      elseif not lowestOtherRow or row.unit < lowestOtherRow.unit then
        lowestOtherRow = row
      end
    end
  end
  if lowestOtherRow then
    s.lowestOther = lowestOtherRow.unit
    s.lowestOtherSeller = lowestOtherRow.seller
  end
  if flip then
    s.flip = flip
    s.flipRef = s.lowestOther or cheapestMineAbove(rows, flip.unit)
  end
  return s
end

-- One step under `price`: the whole silver below it above 1s, else 1c under
-- (never under 1c).
function Listings.StepUnder(price)
  if price > 100 then return floor((price - 1) / 100) * 100 end
  return math.max(1, price - 1)
end

-- Price each to list at: under the cheapest other seller, equal to our own
-- when that is already the cheapest (or nobody else competes), `fallback`
-- when there is neither a competitor nor a listing of ours.
function Listings.UndercutPrice(rows, fallback)
  local s = Listings.Summarize(rows)
  if not s.lowestOther then
    if s.lowestMine then return s.lowestMine, "match-own" end
    return fallback, "no-competition"
  end
  if s.lowestMine and s.lowestMine <= s.lowestOther then
    return s.lowestMine, "match-own"
  end
  return Listings.StepUnder(s.lowestOther), "undercut"
end

-- How our cheapest listing compares with the cheapest other seller:
-- "undercut" (diff = how much cheaper they are), "tied" (0), "cheapest"
-- (diff = our lead). seller is that other seller. With no other seller, or
-- no listing of ours, there is nothing to compare: "cheapest", nil, nil.
function Listings.Status(rows)
  local s = Listings.Summarize(rows)
  if not s.lowestOther or not s.lowestMine then return "cheapest" end
  if s.lowestOther < s.lowestMine then
    return "undercut", s.lowestMine - s.lowestOther, s.lowestOtherSeller
  elseif s.lowestOther == s.lowestMine then
    return "tied", 0, s.lowestOtherSeller
  end
  return "cheapest", s.lowestOther - s.lowestMine, s.lowestOtherSeller
end

-- Flag other sellers' priced rows that are cheaper than our cheapest listing.
-- Marks from an earlier call are cleared first.
function Listings.MarkUnderYou(rows)
  local lowestMine = Listings.Summarize(rows).lowestMine
  for i = 1, #rows do
    local row = rows[i]
    if lowestMine and not row.mine and not row.outlier
        and hasBuyout(row) and row.unit < lowestMine then
      row.underYou = true
    else
      row.underYou = nil
    end
  end
  return rows
end

function Listings.Store(id, rows)
  Listings.cache[id] = { t = ns.Now(), rows = rows }
  ns.Fire("LISTINGS_UPDATED", id)
end

-- rows, age in seconds; nil when this item was not price-checked yet.
function Listings.Get(id)
  local entry = Listings.cache[id]
  if not entry then return nil, nil end
  return entry.rows, ns.Now() - entry.t
end
