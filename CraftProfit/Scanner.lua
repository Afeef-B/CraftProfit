-- Auction House scanning: one name search per item ("Scan tracked").
-- Driven by Scanner.Tick (OnUpdate) and Scanner.HandleEvent (AH events).
local addonName, ns = ...

local floor = math.floor
local PAGE_SIZE = NUM_AUCTION_ITEMS_PER_PAGE or 50
local QUERY_TIMEOUT = 10   -- seconds without an answer before retrying
local LINK_WAIT = 2        -- seconds to wait for uncached item links

ns.Scanner = {}
local Scanner = ns.Scanner

-- True only while we are calling QueryAuctionItems ourselves, so the
-- QueryAuctionItems hook can tell our searches from other addons'.
Scanner.sending = false
Scanner.statusText = ""

local db
local state = "idle"   -- idle | send | wait
local job

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

function Scanner.StartTargeted(items)
  if state ~= "idle" then return false, "busy" end
  if not items or #items == 0 then return false, "empty" end
  job = { items = items, index = 1, page = 0, n = 0, retries = 0 }
  state = "send"
  announceItem()
  return true
end

function Scanner.Stop(reason)
  if state == "idle" then return end
  local done = job and (job.index - 1) or 0
  local total = job and #job.items or 0
  state, job = "idle", nil
  setStatus("Scan stopped (" .. reason .. "): " .. done .. "/" .. total .. " done")
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
end

local function nextItem()
  job.index = job.index + 1
  job.page, job.best, job.n, job.retries = 0, nil, 0, 0
  if job.index > #job.items then
    local count = #job.items
    state, job = "idle", nil
    setStatus("Scan done: " .. count .. " items")
    ns.Fire("PRICES_CHANGED")
  else
    state = "send"
    announceItem()
  end
end

local function finishItem()
  local item = job.items[job.index]
  local unit = job.best and floor(job.best + 0.5) or nil
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

-- Read the current results page for the item being scanned. Unless forced,
-- waits for the next update when some item links aren't cached yet.
local function readPage(force)
  local batch, total = GetNumAuctionItems("list")
  if not force and not allLinksReady(batch) then
    job.linkWait = job.linkWait or 0
    return
  end

  local target = job.items[job.index].id
  for i = 1, batch do
    if ns.Util.ItemIDFromLink(GetAuctionItemLink("list", i)) == target then
      local _, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("list", i)
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

function Scanner.Tick(elapsed)
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
    if state == "wait" then readPage(false) end
  end
end

-- Hooked onto QueryAuctionItems. Someone else searched while we waited, so
-- the results that arrive will be theirs: search again.
function Scanner.OnQuery()
  if Scanner.sending then return end
  if state == "wait" then state = "send" end
end
