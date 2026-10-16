-- Flip buy: another seller's "mistake listing" (far below the market) is
-- shown with a Buy button, and one click buys it out to resell.
-- A purchase needs a click, so the bid is placed only by Flip.Buy, which only
-- the widget's button OnClick calls. Events and Tick (OnListUpdate, Tick,
-- Reset) merely move the state along; they never buy. Nothing is bought
-- unless a row on the loaded page matches the shown listing exactly (item,
-- count, buyout, seller).
local addonName, ns = ...

local floor = math.floor

ns.Flip = {}
local Flip = ns.Flip

local RED = "|cffff4040"
local DEFAULT_CUT = 0.05
local WIDTH, HEIGHT = 340, 68
local BUTTON_WIDTH, BUTTON_HEIGHT = 170, 22
local PAGE_SIZE = NUM_AUCTION_ITEMS_PER_PAGE or 50
local FIND_TIMEOUT = 10 -- seconds to wait for the page we asked for
local LINK_WAIT = 2     -- seconds to wait for item links / seller names on it

local REFUSED_CHANGED = "Listing changed - check again"

-- track[id] = { state, row, waited, linkWait, stale }: state is "finding" |
-- "ready" | "gone" | "bought" and row is the flip row it is about. A fresh
-- price check replaces the rows, so an entry for an older row is void.
-- waited/linkWait/stale only matter while "finding": seconds since the search,
-- seconds since a page with unreadable rows came in, and the fingerprint of
-- the page we were looking at when we searched.
local track = {}

-- messages[id] = { row, state, text }: the last thing said about an item, shown
-- on the notice while that row is still shown in that state.
local messages = {}

-- { row, next, profit } for the item's mistake listing, or nil.
-- next is the price that marked it as a mistake (Listings.Summarize flipRef);
-- profit is what reselling it at that price nets after the AH cut.
function Flip.Info(id)
  local rows = ns.Listings.Get(id)
  if not rows then return nil end
  -- Random-enchant variants share the id, not the price: a cheap one is just a
  -- cheaper variant.
  if ns.Listings.MixedSuffix(rows) then return nil end
  local s = ns.Listings.Summarize(rows)
  if not s.flip or not s.flipRef then return nil end
  local cut = ns.db and ns.db.cut or DEFAULT_CUT
  local row = s.flip
  return {
    row = row,
    next = s.flipRef,
    profit = floor((s.flipRef * (1 - cut) - row.unit) * row.count),
  }
end

-- "idle" | "finding" | "ready" | "gone" | "bought"
function Flip.State(id)
  local entry = track[id]
  local info = entry and Flip.Info(id)
  if info and info.row == entry.row then return entry.state end
  return "idle"
end

local function setState(id, row, state, extra)
  local entry = { state = state, row = row, waited = 0 }
  if extra then
    for key, value in pairs(extra) do entry[key] = value end
  end
  track[id] = entry
  ns.Fire("FLIP_CHANGED", id)
end

-- Say something to the player: remembered for the notice while `row` is shown
-- in `state`, and sent to the page's status line.
local function say(id, row, state, text)
  if id and row then messages[id] = { row = row, state = state, text = text } end
  ns.Fire("PAGE_STATUS", text)
end

-- What was last said about the item's shown mistake listing, or nil.
function Flip.Message(id)
  local m = messages[id]
  if not m then return nil end
  local info = Flip.Info(id)
  if info and info.row == m.row and Flip.State(id) == m.state then return m.text end
  return nil
end

-- Fingerprint of the loaded "list" page, or nil for an empty one. The client
-- can fire a late update for the page we just left; an identical page is not
-- the answer to the search we sent. Names are left out: they load later.
local function pagePrint()
  local batch, total = GetNumAuctionItems("list")
  if not batch or batch == 0 then return nil end
  local _, _, firstCount, _, _, _, _, _, firstBuyout = GetAuctionItemInfo("list", 1)
  local _, _, lastCount, _, _, _, _, _, lastBuyout = GetAuctionItemInfo("list", batch)
  return table.concat({
    batch, total or 0,
    GetAuctionItemLink("list", 1) or "?", firstCount or 0, firstBuyout or 0,
    GetAuctionItemLink("list", batch) or "?", lastCount or 0, lastBuyout or 0,
  }, ":")
end

-- Index of the row on the loaded "list" page that is exactly `row` (same item,
-- count, buyout and seller), or nil. The second result is true when part of the
-- page cannot be read yet (item links or seller names still loading), so a
-- missing match proves nothing.
local function findOnPage(id, row)
  local unreadable = false
  local batch = GetNumAuctionItems("list")
  -- After Scan All the list is the whole Auction House, not a page. Walking it
  -- row by row would be ~100k API calls in one click: treat it as a page that
  -- cannot be read.
  if batch > PAGE_SIZE then return nil, true end
  for i = 1, batch do
    local link = GetAuctionItemLink("list", i)
    local _, _, count, _, _, _, _, _, buyout, _, _, owner = GetAuctionItemInfo("list", i)
    if not link or not owner then
      unreadable = true
    elseif ns.Util.ItemIDFromLink(link) == id and count == row.count
        and buyout == row.buyout and owner == row.seller then
      return i
    end
  end
  return nil, unreadable
end

local function loadFailure(err)
  if err == "busy" then return "The scanner is busy, try again in a moment." end
  if err == "throttled" then return "The Auction House is busy, try again in a moment." end
  return "Could not search the Auction House (" .. tostring(err) .. ")."
end

-- Every reply of Flip.Buy goes to the page status line as well.
local function reply(id, row, state, ok, msg)
  say(id, row, state, msg)
  return ok, msg
end

-- Buy the shown mistake listing. ok, msg. Call only from a button OnClick.
-- On the loaded page: buy it out and price-check the item again. Otherwise
-- load the page the listing was seen on; the player clicks again once it is
-- there (state "ready").
function Flip.Buy(id, name)
  local info = Flip.Info(id)
  if not info then return reply(id, nil, nil, false, "No mistake listing to buy.") end
  local row = info.row
  local state = Flip.State(id)
  -- The bought row stays cached until the fresh price check replaces it; a
  -- second click must not buy the next identical stack.
  if state == "bought" then return reply(id, row, state, false, "Already bought") end
  if GetMoney() < row.buyout then return reply(id, row, state, false, "Not enough gold") end
  -- Without the name there is no search to load the page or re-check with.
  if not name or name == "" then return reply(id, row, state, false, "Item name unknown.") end

  local index = findOnPage(id, row)
  if index then
    PlaceAuctionBid("list", index, row.buyout)
    -- The client refreshes the list after a buyout. A scan that is waiting for
    -- its own answer would take that refresh for it: have it ask again.
    if ns.Scanner.IsBusy() then ns.Scanner.Resend() end
    setState(id, row, "bought")
    ns.Scanner.PriceCheck({ id = id, name = name })
    return reply(id, row, "bought", true, "Bid placed for " .. ns.Util.FormatMoney(row.buyout))
  end

  local stale = pagePrint() -- before the search replaces what the client shows
  local ok, err = ns.Scanner.LoadPage(name, row.page)
  if not ok then return reply(id, row, state, false, loadFailure(err)) end
  setState(id, row, "finding", { stale = stale })
  return reply(id, row, "finding", false, "Finding it...")
end

-- Decide about a "finding" entry from the page the client shows now. A page
-- identical to the one we left is no answer. `force`: stop waiting for
-- unreadable rows and decide from the readable ones.
local function evaluate(id, entry, force)
  local print = pagePrint()
  if print and print == entry.stale then return end
  local index, unreadable = findOnPage(id, entry.row)
  if index then
    setState(id, entry.row, "ready")
  elseif force or not unreadable then
    say(id, entry.row, "gone", "That listing is gone.")
    setState(id, entry.row, "gone")
  else
    -- Names still loading; the client sends another update when they are.
    entry.linkWait = entry.linkWait or 0
  end
end

-- Ids whose search is still running. Nothing is allocated when there are none
-- (Tick asks every frame); the empty result is shared and must not be written to.
local NONE = {}
local function findingIds()
  local ids = NONE
  for id, entry in pairs(track) do
    if entry.state == "finding" then
      if Flip.State(id) == "finding" then
        if ids == NONE then ids = {} end
        ids[#ids + 1] = id
      else
        track[id] = nil -- the rows were replaced meanwhile
      end
    end
  end
  return ids
end

-- AUCTION_ITEM_LIST_UPDATE (routed by Core): a page arrived. Only moves
-- "finding" on to "ready" or "gone"; never buys.
function Flip.OnListUpdate()
  for _, id in ipairs(findingIds()) do
    evaluate(id, track[id], false)
  end
end

-- Driven by Core's OnUpdate. A search that gets no answer in FIND_TIMEOUT
-- seconds ends (the player can click again); a page that stays unreadable
-- for LINK_WAIT seconds is judged by its readable rows. Never buys.
function Flip.Tick(elapsed)
  if next(track) == nil then return end
  for _, id in ipairs(findingIds()) do
    local entry = track[id]
    entry.waited = entry.waited + elapsed
    if entry.linkWait then
      entry.linkWait = entry.linkWait + elapsed
      if entry.linkWait >= LINK_WAIT then evaluate(id, entry, true) end
    end
    if track[id] == entry and entry.waited >= FIND_TIMEOUT then
      say(id, entry.row, "idle", "Couldn't find it - try again")
      track[id] = nil
      ns.Fire("FLIP_CHANGED", id)
    end
  end
end

-- Forget the states that wait for an answer, e.g. when the Auction House
-- closes: no answer will come. A bought listing stays bought: the bid went
-- through, and the same stack must not be offered again when the AH reopens.
-- A fresh price check replaces its rows, which ends it.
function Flip.Reset()
  local kept, keptMessages, ids = {}, {}, {}
  for id, entry in pairs(track) do
    if entry.state == "bought" then
      kept[id], keptMessages[id] = entry, messages[id]
    else
      ids[#ids + 1] = id
    end
  end
  track, messages = kept, keptMessages
  for _, id in ipairs(ids) do ns.Fire("FLIP_CHANGED", id) end
end

local widgetCount = 0

-- The red notice and Buy button for the item a page shows. getItem() returns
-- id, name. Hidden while the item has no mistake listing. The reply to a
-- click ("Bid placed for ...", "Not enough gold", ...) is added to the notice
-- (and sent as PAGE_STATUS). The page calls w:Update() when the shown item
-- changes; a click only works on the listing that was drawn.
-- Returns w with w.frame, w.notice, w.button and w:Update().
function Flip.CreateWidget(parent, getItem)
  local Util = ns.Util
  widgetCount = widgetCount + 1
  local frameName = "CraftProfitFlip" .. widgetCount

  local w = {}
  local frame = CreateFrame("Frame", frameName, parent)
  frame:SetWidth(WIDTH)
  frame:SetHeight(HEIGHT)
  w.frame = frame

  local notice = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  notice:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  notice:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  notice:SetJustifyH("LEFT")
  notice:SetJustifyV("TOP")
  w.notice = notice

  local button = CreateFrame("Button", frameName .. "Buy", frame, "UIPanelButtonTemplate")
  button:SetWidth(BUTTON_WIDTH)
  button:SetHeight(BUTTON_HEIGHT)
  button:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
  w.button = button

  -- The listing on screen: a click may only act on exactly this.
  local drawnId, drawnRow

  function w.Update(self)
    local id = getItem()
    local info = id and Flip.Info(id)
    if not info then
      drawnId, drawnRow = nil, nil
      frame:Hide()
      return
    end
    local row = info.row
    drawnId, drawnRow = id, row

    -- A click spends the whole stack, not the price each: every label that can
    -- lead to a purchase says how much.
    local state = Flip.State(id)
    local total = " (" .. Util.FormatMoney(row.buyout) .. ")"
    local label, enabled
    if state == "finding" then
      label, enabled = "Finding it...", false
    elseif state == "ready" then
      label, enabled = "Buy now" .. total, true
    elseif state == "gone" then
      label, enabled = "Gone - try again" .. total, true
    elseif state == "bought" then
      label, enabled = "Bought", false
    else
      label, enabled = "Buy it" .. total, true
    end

    local text = RED .. Util.ICON_GOLD .. " Possible mistake: " .. (row.seller or "?")
      .. " sells " .. row.count .. " at " .. Util.FormatMoney(row.unit)
      .. " (next " .. Util.FormatMoney(info.next) .. "). Flip profit ~"
      .. Util.FormatMoney(info.profit) .. "|r"
    local message = Flip.Message(id)
    if message and message ~= label then text = text .. "\n" .. message end
    notice:SetText(text)

    button:SetText(label)
    if enabled then button:Enable() else button:Disable() end
    frame:Show()
  end

  button:SetScript("OnClick", function()
    local id, name = getItem()
    local info = id and Flip.Info(id)
    if not drawnRow or id ~= drawnId or not info or info.row ~= drawnRow then
      -- What is on screen is not what a click would buy: show the real thing.
      say(id, info and info.row, id and Flip.State(id), REFUSED_CHANGED)
      w:Update()
      return
    end
    Flip.Buy(id, name)
    w:Update()
  end)

  -- Redraw when the state or the listings of the shown item change.
  local function refresh(id)
    if id == getItem() then w:Update() end
  end
  ns.On("FLIP_CHANGED", refresh)
  ns.On("LISTINGS_UPDATED", refresh)

  frame:Hide()
  return w
end
