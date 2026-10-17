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
local SEARCH_MAX_PAGES = 20 -- a name search reads at most this many pages (1000 listings)
local SEARCH_CAPPED = "Showing the first 1000 listings - type more of the name."

ns.Scanner = {}
local Scanner = ns.Scanner

-- True only while we are calling QueryAuctionItems ourselves, so the
-- QueryAuctionItems hook can tell our searches from other addons'.
Scanner.sending = false
Scanner.statusText = ""

local db
local state = "idle"   -- idle | send | wait | allSend | allWait | allRead
local job
-- Core says when the Auction House opens and closes (SetAHOpen). While it is
-- closed nothing may start a search: a search queued by a SCAN_FINISHED listener
-- during the close would otherwise go out at the next open. Until told, the AH
-- counts as open, so a scanner used on its own (tests, a reload with the AH
-- already up) works.
local ahOpen = true
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

function Scanner.SetAHOpen(open)
  ahOpen = open and true or false
end

function Scanner.IsAHOpen()
  return ahOpen
end

local function setStatus(text)
  if text == Scanner.statusText then return end -- said already
  Scanner.statusText = text
  ns.Fire("SCAN_STATUS", text)
end

local function announceItem()
  local item = job.items[job.index]
  setStatus("Scanning " .. job.index .. "/" .. #job.items .. ": " .. item.name)
end

-- opts.collect: also keep every listing of the item (count, buyout, seller,
-- page, index) and hand the rows to ns.Listings.
-- opts.skipFresh: leave out items scanned within the fresh window
-- (Prices.IsFresh); "fresh" when that leaves nothing.
function Scanner.StartTargeted(items, opts)
  if not ahOpen then return false, "closed" end
  if state ~= "idle" then return false, "busy" end
  if not items or #items == 0 then return false, "empty" end
  local skipped = 0
  if opts and opts.skipFresh then
    local keep = {}
    for _, item in ipairs(items) do
      if ns.Prices.IsFresh(item.id) then skipped = skipped + 1 else keep[#keep + 1] = item end
    end
    if #keep == 0 then
      setStatus("Nothing to scan: all " .. skipped .. " items were scanned in the last "
        .. floor(ns.Prices.FreshSeconds() / 60) .. " min")
      return false, "fresh"
    end
    items = keep
  end
  job = { items = items, index = 1, page = 0, n = 0, retries = 0, skipped = skipped }
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

-- Everything a name search finds, item by item (CP Buy's results). Fires
-- SEARCH_DONE(text, results, capped, exactId). Only a search that read every
-- page stores prices; no search stores listings, because their page numbers
-- belong to this name search, not to the item's own (category) price check.
-- opts.stopOnExact: end at the first page with an item named exactly `text`.
function Scanner.Search(text, opts)
  if not ahOpen then return false, "closed" end
  if state ~= "idle" then return false, "busy" end
  text = (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
  if text == "" then return false, "empty" end
  job = {
    search = true, text = text, page = 0, retries = 0, found = {}, order = {},
    stopOnExact = opts and opts.stopOnExact,
  }
  state = "send"
  setStatus('Searching "' .. text .. '"...')
  return true
end

-- The AH searches names by part: "King's Amber" also finds every cut King's
-- Amber, page after page. Searching in the item's own Browse category (Gem >
-- Simple) leaves the other items out. class, subclass indexes into
-- GetAuctionItemClasses / GetAuctionItemSubClasses, or nil (name only) when
-- the client hasn't cached the item or the AH doesn't list its type.
local function category(id)
  if not id then return nil end
  local _, _, _, _, _, itemType, itemSubType = GetItemInfo(id)
  if not itemType then return nil end
  local classes = { GetAuctionItemClasses() }
  for class, className in ipairs(classes) do
    if className == itemType then
      local subs = { GetAuctionItemSubClasses(class) }
      for subclass, subName in ipairs(subs) do
        if subName == itemSubType then return class, subclass end
      end
      return class, nil
    end
  end
  return nil
end
Scanner.Category = category

-- "Gem > Simple", or nil for a search by name only.
local function categoryText(class, subclass)
  if not class then return nil end
  local name = select(class, GetAuctionItemClasses())
  if subclass then name = name .. " > " .. select(subclass, GetAuctionItemSubClasses(class)) end
  return name
end

-- Ask the AH for one results page of a name search so the player can act on
-- it. Not a scan: the scanner stays idle and never reads the answer. With the
-- item's id the search is the price check's (same category), so its page
-- numbers are the same.
function Scanner.LoadPage(name, page, id)
  if not ahOpen then return false, "closed" end
  if state ~= "idle" then return false, "busy" end
  if not CanSendAuctionQuery() then return false, "throttled" end
  local class, subclass = category(id)
  Scanner.sending = true
  local ok, err = pcall(QueryAuctionItems, name, "", "", nil, class, subclass, page, nil, -1, false)
  Scanner.sending = false
  if not ok then return false, "error: " .. tostring(err) end
  return true
end

function Scanner.Stop(reason)
  if state == "idle" then return end
  if job.search then
    state, job = "idle", nil
    setStatus("Search stopped (" .. reason .. ")")
    ns.Fire("SCAN_FINISHED")
    return
  end
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

-- One results page of the name search (no category: every item counts).
local function sendSearchQuery()
  setStatus('Searching "' .. job.text .. '": page ' .. (job.page + 1))
  Scanner.sending = true
  local ok, err = pcall(QueryAuctionItems, job.text, "", "", nil, nil, nil, job.page, nil, -1, false)
  Scanner.sending = false
  if not ok then
    Scanner.Stop("error: " .. tostring(err))
    return
  end
  state = "wait"
  job.waited, job.linkWait = 0, nil
  job.queryKey = "search:" .. job.text .. ":" .. job.page
end

local function sendQuery()
  if job.search then return sendSearchQuery() end
  local item = job.items[job.index]
  -- The category is chosen once per item: every page of one search must use
  -- the same one, or the page numbers mean different things.
  if not job.filterSet then
    job.class, job.subclass = category(item.id)
    job.filterSet = true
  end
  local where = categoryText(job.class, job.subclass)
  setStatus("Scanning " .. job.index .. "/" .. #job.items .. ": " .. item.name
    .. (where and (" (" .. where .. ")") or "") .. (job.page > 0 and (", page " .. (job.page + 1)) or ""))
  Scanner.sending = true
  local ok, err = pcall(QueryAuctionItems, item.name, "", "", nil, job.class, job.subclass, job.page, nil, -1, false)
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
  job.filterSet, job.class, job.subclass, job.restarted = nil, nil, nil, nil
  if job.collect then job.raw = {} end
  if job.index > #job.items then
    local count, skipped = #job.items, job.skipped or 0
    state, job = "idle", nil
    setStatus("Scan done: " .. count .. " items"
      .. (skipped > 0 and (" (" .. skipped .. " still fresh, skipped)") or ""))
    ns.Fire("PRICES_CHANGED")
    ns.Fire("SCAN_FINISHED")
  else
    state = "send"
    announceItem()
  end
end

-- The price to store from normalized rows: the cheapest unit that is not a
-- mistake listing; any seller counts, mine included. Rows without a buyout
-- have unit 0.
local function bestUnit(rows)
  local unit
  for i = 1, #rows do
    local row = rows[i]
    if row.unit > 0 and not row.outlier and (not unit or row.unit < unit) then unit = row.unit end
  end
  return unit
end

local function finishItem()
  local item = job.items[job.index]
  local unit = job.best and floor(job.best + 0.5) or nil
  if job.collect then
    local rows = ns.Listings.Normalize(job.raw, ns.Listings.MineSet(), ns.Listings.Ratio())
    -- Rows first: whoever hears about the new price can already read them.
    ns.Listings.Store(item.id, rows)
    unit = bestUnit(rows)
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

-- A name search is done. capped: stopped at SEARCH_MAX_PAGES with more to
-- come; exactId: stopped at the item named exactly like the search.
local function finishSearch(capped, exactId)
  local text, now = job.text, ns.Now()
  local complete = not capped and not exactId
  local results, exactName = {}, nil
  for _, entry in ipairs(job.order) do
    local rows = ns.Listings.Normalize(entry.raw, ns.Listings.MineSet(), ns.Listings.Ratio())
    local unit, priced, quantity = bestUnit(rows), 0, 0
    for i = 1, #rows do
      quantity = quantity + (rows[i].count or 0)
      if rows[i].unit > 0 then priced = priced + 1 end
    end
    if complete then ns.Prices.SetAH(entry.id, unit, priced, now) end
    if entry.id == exactId then exactName = entry.name end
    results[#results + 1] = {
      id = entry.id, name = entry.name, texture = entry.texture,
      unit = unit, auctions = #rows, quantity = quantity, t = now,
    }
  end
  table.sort(results, function(a, b)
    local an, bn = a.name:lower(), b.name:lower()
    if an ~= bn then return an < bn end
    return a.id < b.id
  end)
  state, job = "idle", nil
  if exactId then
    setStatus("Found " .. exactName)
  elseif capped then
    setStatus(SEARCH_CAPPED)
  elseif #results == 0 then
    setStatus('No items called "' .. text .. '" on the Auction House.')
  else
    setStatus("Search done: " .. #results .. " items")
  end
  ns.Fire("SEARCH_DONE", text, results, capped, exactId)
  ns.Fire("PRICES_CHANGED")
  ns.Fire("SCAN_FINISHED")
end

-- Every row of a search's results page, kept per item in first-seen order.
local function readSearchPage(batch, total)
  local wanted, exactId = job.text:lower(), nil
  for i = 1, batch do
    local link = GetAuctionItemLink("list", i)
    local id = ns.Util.ItemIDFromLink(link)
    if id then
      local _, texture, count, _, _, _, _, _, buyout, _, _, owner = GetAuctionItemInfo("list", i)
      local entry = job.found[id]
      if not entry then
        entry = { id = id, name = ns.Util.ItemNameFromLink(link) or ("item " .. id), texture = texture, raw = {} }
        job.found[id] = entry
        job.order[#job.order + 1] = entry
      end
      entry.raw[#entry.raw + 1] = {
        count = count, buyout = buyout, seller = owner, page = job.page, index = i,
        suffix = ns.Util.SuffixFromLink(link),
      }
      if job.stopOnExact and not exactId and entry.name:lower() == wanted then exactId = id end
    end
  end
  if exactId then return finishSearch(false, exactId) end
  local more = (job.page + 1) * PAGE_SIZE < (total or 0)
  if more and job.page + 1 >= SEARCH_MAX_PAGES then return finishSearch(true) end
  if more then
    job.page = job.page + 1
    job.retries = 0
    state = "send"
  else
    finishSearch(false)
  end
end

-- Read the current results page for the item being scanned. Unless forced,
-- waits for the next update when some item links aren't cached yet.
local function readPage(force)
  local batch, total = GetNumAuctionItems("list")
  -- A list bigger than a page is the whole Auction House (the answer to a
  -- Scan All), never the answer to a name search; reading it would take ~100k
  -- API calls in one frame. Wait for the real answer. (The wait for item links
  -- is off too, so the query timeout still resends.)
  if batch > PAGE_SIZE then
    job.linkWait = nil
    return
  end
  local fingerprint = pagePrint(batch, total)
  if not force and fingerprint and fingerprint == lastPrint and job.queryKey ~= lastKey then return end
  if not force and (not allLinksReady(batch) or (job.collect and not allOwnersReady(batch))) then
    job.linkWait = job.linkWait or 0
    return
  end

  lastPrint, lastKey = fingerprint, job.queryKey
  if job.search then return readSearchPage(batch, total) end
  local target = job.items[job.index].id
  for i = 1, batch do
    local link = GetAuctionItemLink("list", i)
    if ns.Util.ItemIDFromLink(link) == target then
      local _, _, count, _, _, _, _, _, buyout, _, _, owner = GetAuctionItemInfo("list", i)
      if job.collect then
        -- The suffix tells the variants of a random-enchant item apart: they
        -- share the id and not the price.
        job.raw[#job.raw + 1] = {
          count = count, buyout = buyout, seller = owner, page = job.page, index = i,
          suffix = ns.Util.SuffixFromLink(link),
        }
      end
      if buyout and buyout > 0 and count and count > 0 then
        local unit = buyout / count
        if not job.best or unit < job.best then job.best = unit end
        job.n = job.n + 1
      end
    end
  end

  local more = (job.page + 1) * PAGE_SIZE < (total or 0)
  -- A first page that went out by name only (the item wasn't cached yet) and
  -- has more pages after it: the client knows the item now, so search again in
  -- its category rather than read every page of every item with that name.
  if more and job.page == 0 and not job.class and not job.restarted then
    local class, subclass = category(job.items[job.index].id)
    if class then
      job.class, job.subclass, job.restarted = class, subclass, true
      job.best, job.n, job.retries = nil, 0, 0
      if job.collect then job.raw = {} end
      state = "send"
      return
    end
  end
  if more then
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
  if not ahOpen then return false, "closed" end
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
      elseif job.search then
        Scanner.Stop("no answer from the AH")
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
-- send the query again. A Scan All that has not downloaded yet has no query to
-- repeat (its one request is limited to every 15 minutes), and the refresh
-- would be read as the whole Auction House: it stops, as it does for a foreign
-- search. A download that has arrived (allRead) is left alone, like a scan that
-- is not waiting for a page; nothing is bought from a list that big.
function Scanner.Resend()
  if state == "wait" then
    state = "send"
  elseif state == "allSend" or state == "allWait" then
    Scanner.Stop("interrupted by a purchase")
  end
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
