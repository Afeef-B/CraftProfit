-- Flip buy: another seller's "mistake listing" (far below the market) is
-- shown with a Buy button, and one click buys it out to resell.
-- A purchase needs a click, so the bid is placed only by Flip.Buy, which only
-- the widget's button OnClick calls. Events (OnListUpdate) merely move the
-- state along: finding -> ready, or gone. Nothing is bought unless a row on
-- the loaded page matches the shown listing exactly (item, count, buyout,
-- seller).
local addonName, ns = ...

local floor = math.floor

ns.Flip = {}
local Flip = ns.Flip

local RED = "|cffff4040"
local DEFAULT_CUT = 0.05
local WIDTH, HEIGHT = 340, 68
local BUTTON_WIDTH, BUTTON_HEIGHT = 170, 22

-- track[id] = { state = "finding" | "ready" | "gone", row = <the flip row it is about> }.
-- A fresh price check replaces the rows, so an entry for an older row is void.
local track = {}

-- { row, next, profit } for the item's mistake listing, or nil.
-- next is the price that marked it as a mistake (Listings.Summarize flipRef);
-- profit is what reselling it at that price nets after the AH cut.
function Flip.Info(id)
  local rows = ns.Listings.Get(id)
  if not rows then return nil end
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

-- "idle" | "finding" | "ready" | "gone"
function Flip.State(id)
  local entry = track[id]
  local info = entry and Flip.Info(id)
  if info and info.row == entry.row then return entry.state end
  return "idle"
end

local function setState(id, row, state)
  track[id] = { state = state, row = row }
  ns.Fire("FLIP_CHANGED", id)
end

-- Index of the row on the loaded "list" page that is exactly `row` (same item,
-- count, buyout and seller), or nil. The second result is true when part of the
-- page cannot be read yet (item links or seller names still loading), so a
-- missing match proves nothing.
local function findOnPage(id, row)
  local unreadable = false
  local batch = GetNumAuctionItems("list")
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

-- Buy the shown mistake listing. ok, msg. Call only from a button OnClick.
-- On the loaded page: buy it out and price-check the item again. Otherwise
-- load the page the listing was seen on; the player clicks again once it is
-- there (state "ready").
function Flip.Buy(id, name)
  local info = Flip.Info(id)
  if not info then return false, "No mistake listing to buy." end
  local row = info.row
  if GetMoney() < row.buyout then return false, "Not enough gold" end

  local index = findOnPage(id, row)
  if index then
    PlaceAuctionBid("list", index, row.buyout)
    if track[id] then
      track[id] = nil
      ns.Fire("FLIP_CHANGED", id)
    end
    ns.Scanner.PriceCheck({ id = id, name = name })
    return true, "Bought for " .. ns.Util.FormatMoney(row.buyout)
  end

  local ok, err = ns.Scanner.LoadPage(name, row.page)
  if not ok then return false, loadFailure(err) end
  setState(id, row, "finding")
  return false, "Finding it..."
end

-- AUCTION_ITEM_LIST_UPDATE (routed by Core): a page we asked for arrived.
-- Only moves "finding" to "ready" or "gone"; never buys.
function Flip.OnListUpdate()
  local finding = {}
  for id in pairs(track) do
    if Flip.State(id) == "finding" then finding[#finding + 1] = id end
  end
  for _, id in ipairs(finding) do
    local entry = track[id]
    local index, unreadable = findOnPage(id, entry.row)
    if index then
      setState(id, entry.row, "ready")
    elseif not unreadable then
      setState(id, entry.row, "gone")
    end
    -- else: names still loading; the client sends another update when they are.
  end
end

local widgetCount = 0

-- The red notice and Buy button for the item a page shows. getItem() returns
-- id, name. Hidden while the item has no mistake listing. The reply to a
-- click ("Bought for ...", "Not enough gold", ...) is added to the notice.
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

  -- Reply to the last click; shown while the listing it was about is shown.
  local message, messageRow

  function w.Update(self)
    local id = getItem()
    local info = id and Flip.Info(id)
    if not info then
      message, messageRow = nil, nil
      frame:Hide()
      return
    end
    local row = info.row

    local state = Flip.State(id)
    local label, enabled
    if state == "finding" then
      label, enabled = "Finding it...", false
    elseif state == "ready" then
      label, enabled = "Buy now (" .. Util.FormatMoney(row.buyout) .. ")", true
    elseif state == "gone" then
      label, enabled = "That listing is gone.", false
    else
      label, enabled = "Buy it", true
    end

    local text = RED .. Util.ICON_GOLD .. " Possible mistake: " .. (row.seller or "?")
      .. " sells " .. row.count .. " at " .. Util.FormatMoney(row.unit)
      .. " (next " .. Util.FormatMoney(info.next) .. "). Flip profit ~"
      .. Util.FormatMoney(info.profit) .. "|r"
    if message and messageRow == row and message ~= label then
      text = text .. "\n" .. message
    end
    notice:SetText(text)

    button:SetText(label)
    if enabled then button:Enable() else button:Disable() end
    frame:Show()
  end

  button:SetScript("OnClick", function()
    local id, name = getItem()
    if not id then return end
    local before = Flip.Info(id)
    local _, msg = Flip.Buy(id, name)
    message, messageRow = msg, before and before.row
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
