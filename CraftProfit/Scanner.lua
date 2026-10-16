-- Auction House scanning: one name search per item ("Scan tracked"), or the
-- whole AH in one getAll request ("Scan All"). Driven by Scanner.Tick (OnUpdate) and Scanner.HandleEvent (AH events).
local addonName, ns = ...

local floor = math.floor
local PAGE_SIZE = NUM_AUCTION_ITEMS_PER_PAGE or 50
local QUERY_TIMEOUT = 10   -- seconds without an answer before retrying
local LINK_WAIT = 2        -- seconds to wait for uncached item links
local SCAN_ALL_COOLDOWN = 900
local SCAN_ALL_TIMEOUT = 120
local SCAN_ALL_CHUNK = 500 -- auctions read per frame so the game stays responsive

ns.Scanner = {}
local Scanner = ns.Scanner

-- True only while we are calling QueryAuctionItems ourselves, so the
-- QueryAuctionItems hook can tell our searches from other addons'.
Scanner.sending = false
Scanner.statusText = ""

local db
local state = "idle"   -- idle | send | wait | allSend | allWait | allRead
local job
-- Fingerprint of the last results page we read. The client can fire a late
-- AUCTION_ITEM_LIST_UPDATE for that page after our next search went out;
-- an identical page is then not the answer to the new search. lastKey names
-- the search ("name:page") that page answered: the same search sent again
-- legitimately gets an identical page back.
local lastPrint, lastKey

function Scanner.SetDB(savedDB)
  db = savedDB
end

function Scanner.IsBusy()
  return state ~= "idle"
end

local function setStatus(text)
  Scanner.statusText = text
  ns.Fire("SCAN_STATUS", text)
end

local function announceItem()
  local item = job.items[job.index]
  setStatus("Scanning " .. job.index .. "/" .. #job.items .. ": " .. item.name)
end

-- opts.collect: also keep every listing of the item (count, buyout, seller,
-- page, index) and hand the rows to ns.Listings.
function Scanner.StartTargeted(items, opts)
  if state ~= "idle" then return false, "busy" end
  if not items or #items == 0 then return false, "empty" end
  job = { items = items, index = 1, page = 0, n = 0, retries = 0 }
  if opts and opts.collect then
    job.collect = true
    job.raw = {}
  end
  state = "send"
  announceItem()
  return true
end

-- Search one item by itself and keep all its listings.
function Scanner.PriceCheck(item)
  return Scanner.StartTargeted({ item }, { collect = true })
end

-- Ask the AH for one results page of a name search so the player can act on
-- it. Not a scan: the scanner stays idle and never reads the answer.
function Scanner.LoadPage(name, page)
  if state ~= "idle" then return false, "busy" end
  if not CanSendAuctionQuery() then return false, "throttled" end
  Scanner.sending = true
  local ok, err = pcall(QueryAuctionItems, name, "", "", nil, nil, nil, page, nil, -1, false)
  Scanner.sending = false
  if not ok then return false, "error: " .. tostring(err) end
  return true
end

function Scanner.Stop(reason)
  if state == "idle" then return end
  if job.all then
    state, job = "idle", nil
    setStatus("Scan All stopped (" .. reason .. ")")
    ns.Fire("SCAN_FINISHED")
    return
  end
  local done = job and (job.index - 1) or 0
  local total = job and #job.items or 0
  state, job = "idle", nil
  setStatus("Scan stopped (" .. reason .. "): " .. done .. "/" .. total .. " done")
  ns.Fire("SCAN_FINISHED")
end

local function sendQuery()
  local item = job.items[job.index]
  Scanner.sending = true
  local ok, err = pcall(QueryAuctionItems, item.name, "", "", nil, nil, nil, job.page, nil, -1, false)
  Scanner.sending = false
  if not ok then
    Scanner.Stop("error: " .. tostring(err))
    return
  end
  state = "wait"
  job.waited, job.linkWait = 0, nil
  job.queryKey = item.name .. ":" .. job.page
end

local function nextItem()
  job.index = job.index + 1
  job.page, job.best, job.n, job.retries = 0, nil, 0, 0
  if job.collect then job.raw = {} end
  if job.index > #job.items then
    local count = #job.items
    state, job = "idle", nil
    setStatus("Scan done: " .. count .. " items")
    ns.Fire("PRICES_CHANGED")
    ns.Fire("SCAN_FINISHED")
  else
    state = "send"
    announceItem()
  end
end

local function finishItem()
  local item = job.items[job.index]
  local unit = job.best and floor(job.best + 0.5) or nil
  if job.collect then
    local rows = ns.Listings.Normalize(job.raw, ns.Listings.MineSet(), ns.Listings.Ratio())
    -- Rows first: whoever hears about the new price can already read them.
    ns.Listings.Store(item.id, rows)
    -- A mistake listing must not become the stored price; any other seller
    -- counts, mine included. Rows without a buyout have unit 0.
    unit = nil
    for i = 1, #rows do
      local row = rows[i]
      if row.unit > 0 and not row.outlier and (not unit or row.unit < unit) then unit = row.unit end
    end
  end
  ns.Prices.SetAH(item.id, unit, job.n, ns.Now())
  ns.Fire("PRICES_CHANGED")
  nextItem()
end

local function allLinksReady(batch)
  for i = 1, batch do
    if not GetAuctionItemLink("list", i) then return false end
  end
  return true
end

-- Seller names load like item links do: nil until the client has them.
local function allOwnersReady(batch)
  for i = 1, batch do
    if not select(12, GetAuctionItemInfo("list", i)) then return false end
  end
  return true
end

local function pagePrint(batch, total)
  if batch == 0 then return nil end -- no late updates for empty pages
  local _, _, firstCount, _, _, _, _, _, firstBuyout = GetAuctionItemInfo("list", 1)
  local _, _, lastCount, _, _, _, _, _, lastBuyout = GetAuctionItemInfo("list", batch)
  return table.concat({
    batch, total or 0,
    GetAuctionItemLink("list", 1) or "?", firstCount or 0, firstBuyout or 0,
    GetAuctionItemLink("list", batch) or "?", lastCount or 0, lastBuyout or 0,
  }, ":")
end

-- Read the current results page for the item being scanned. Unless forced,
-- waits for the next update when some item links aren't cached yet.
local function readPage(force)
  local batch, total = GetNumAuctionItems("list")
  local fingerprint = pagePrint(batch, total)
  if not force and fingerprint and fingerprint == lastPrint and job.queryKey ~= lastKey then return end
  if not force and (not allLinksReady(batch) or (job.collect and not allOwnersReady(batch))) then
    job.linkWait = job.linkWait or 0
    return
  end

  lastPrint, lastKey = fingerprint, job.queryKey
  local target = job.items[job.index].id
  for i = 1, batch do
    if ns.Util.ItemIDFromLink(GetAuctionItemLink("list", i)) == target then
      local _, _, count, _, _, _, _, _, buyout, _, _, owner = GetAuctionItemInfo("list", i)
      if job.collect then
        job.raw[#job.raw + 1] = {
          count = count, buyout = buyout, seller = owner, page = job.page, index = i,
        }
      end
      if buyout and buyout > 0 and count and count > 0 then
        local unit = buyout / count
        if not job.best or unit < job.best then job.best = unit end
        job.n = job.n + 1
      end
    end
  end

  if (job.page + 1) * PAGE_SIZE < (total or 0) then
    job.page = job.page + 1
    job.retries = 0
    state = "send"
  else
    finishItem()
  end
end

-- 0 when Scan All is allowed now, seconds left when we know the cooldown,
-- -1 when the server says no and we don't know why (e.g. another addon used it).
function Scanner.ScanAllCooldown()
  local _, canQueryAll = CanSendAuctionQuery()
  if canQueryAll then return 0 end
  local last = db and db.lastScanAll
  if last then
    local left = last + SCAN_ALL_COOLDOWN - ns.Now()
    if left > 0 then return left end
  end
  return -1
end

function Scanner.StartScanAll()
  if state ~= "idle" then return false, "busy" end
  if Scanner.ScanAllCooldown() ~= 0 then return false, "cooldown" end
  job = { all = true, waited = 0 }
  state = "allSend"
  setStatus("Scan All: asking the server...")
  return true
end

local function sendScanAll()
  Scanner.sending = true
  local ok, err = pcall(QueryAuctionItems, "", "", "", nil, nil, nil, 0, nil, -1, true)
  Scanner.sending = false
  if not ok then
    Scanner.Stop("error: " .. tostring(err))
    return
  end
  db.lastScanAll = ns.Now()
  state = "allWait"
  job.waited = 0
  setStatus("Scan All: downloading the auction list...")
end

local function finishScanAll()
  local now = ns.Now()
  local items = 0
  for id, rec in pairs(job.seen) do
    ns.Prices.SetAH(id, rec.best and floor(rec.best + 0.5) or nil, rec.n, now)
    items = items + 1
  end
  -- Only a complete read proves the other items have no listings.
  if job.unreadable == 0 then
    for id in pairs(ns.Prices.AllAH()) do
      if not job.seen[id] then ns.Prices.SetAH(id, nil, 0, now) end
    end
  end
  local text = "Scan All done: " .. items .. " items from " .. job.total .. " auctions"
  if job.unreadable > 0 then text = text .. " (" .. job.unreadable .. " unreadable)" end
  state, job = "idle", nil
  setStatus(text)
  ns.Fire("PRICES_CHANGED")
  ns.Fire("SCAN_FINISHED")
end

local function readScanAllChunk()
  local last = math.min(job.total, job.next + SCAN_ALL_CHUNK - 1)
  for i = job.next, last do
    local id = ns.Util.ItemIDFromLink(GetAuctionItemLink("list", i))
    if id then
      local rec = job.seen[id]
      if not rec then
        rec = { n = 0 }
        job.seen[id] = rec
      end
      local _, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("list", i)
      if buyout and buyout > 0 and count and count > 0 then
        local unit = buyout / count
        if not rec.best or unit < rec.best then rec.best = unit end
        rec.n = rec.n + 1
      end
    else
      job.unreadable = job.unreadable + 1
    end
  end
  job.next = last + 1
  if job.next > job.total then
    finishScanAll()
  else
    setStatus("Scan All: reading " .. last .. "/" .. job.total)
  end
end

function Scanner.Tick(elapsed)
  if state == "allSend" then
    local _, canQueryAll = CanSendAuctionQuery()
    if canQueryAll then sendScanAll() end
    return
  elseif state == "allWait" then
    job.waited = job.waited + elapsed
    if job.waited >= SCAN_ALL_TIMEOUT then Scanner.Stop("no answer from the server") end
    return
  elseif state == "allRead" then
    readScanAllChunk()
    return
  end

  if state == "send" then
    if CanSendAuctionQuery() then sendQuery() end
  elseif state == "wait" then
    job.waited = job.waited + elapsed
    if job.linkWait then
      job.linkWait = job.linkWait + elapsed
      if job.linkWait >= LINK_WAIT then readPage(true) end
    elseif job.waited >= QUERY_TIMEOUT then
      if job.retries < 1 then
        job.retries = job.retries + 1
        -- The retry's answer may legitimately repeat the last page.
        lastPrint = nil
        state = "send"
      else
        ns.Util.Print("No answer from the AH for " .. job.items[job.index].name .. ", skipped.")
        nextItem()
      end
    end
  end
end

function Scanner.HandleEvent(event)
  if event == "AUCTION_HOUSE_CLOSED" then
    Scanner.Stop("AH closed")
  elseif event == "AUCTION_ITEM_LIST_UPDATE" then
    if state == "wait" then
      readPage(false)
    elseif state == "allWait" then
      -- An empty update can arrive before the data; keep waiting for it.
      local total = GetNumAuctionItems("list")
      if total and total > 0 then
        job.total = total
        job.next, job.seen, job.unreadable = 1, {}, 0
        state = "allRead"
      end
    end
  end
end

-- The page the client shows is not the answer to the query that is waiting
-- (someone else searched, or the client refreshed the list after a buyout):
-- send the query again. A scan that is not waiting for a page is left alone.
function Scanner.Resend()
  if state == "wait" then state = "send" end
end

-- Hooked onto QueryAuctionItems. Someone else searched while we waited, so
-- the results that arrive will be theirs: search again.
function Scanner.OnQuery()
  if Scanner.sending then return end
  if state == "wait" then
    Scanner.Resend()
  elseif state == "allWait" or state == "allRead" then
    -- The server replaces the full list with their results; can't recover.
    Scanner.Stop("interrupted by another search")
  end
end
