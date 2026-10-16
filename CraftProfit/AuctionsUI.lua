-- The "CP Auctions" page: the player's auctions grouped by item on the left, the
-- picked item's listings on the right. It only draws Auctions.Groups() and the
-- listings cache and hands the player's clicks to ns.Auctions; the cancel and
-- undercut logic lives in Auctions.lua. A cancel, an undercut or a check of all
-- items starts only from its button's OnClick; no event or redraw does.
local addonName, ns = ...

local Util = ns.Util
local Auctions = ns.Auctions
local Listings = ns.Listings

ns.AuctionsUI = {}
local AuctionsUI = ns.AuctionsUI

local BAD = "|cffff4040"
local VISIBLE, ROW_HEIGHT = 12, 16
local TITLE_HEIGHT, HEADER_HEIGHT = 18, 16
local LEFT, TOP = 10, -6               -- the page's inner margin
local LIST_WIDTH, SCROLLBAR_WIDTH = 380, 24
local ROW_WIDTH = LIST_WIDTH - SCROLLBAR_WIDTH
local FLIP_WIDTH = 40                  -- the flip marker's own cell at the right end of a row
local REDRAW = 15                      -- seconds between the page's own redraws (ages grow)

local WAIT_LIST = "Waiting for the auction list to update..."
local WAIT_SCAN = "Waiting for the current scan..."
local NO_ACTIVE = "You have no active auctions."

-- Cells of a list row (after the icon): key, x offset, width, header. The
-- status text clips before it can reach the flip cell.
local CELLS = {
  { "name", 18, 90, "Item" },
  { "yours", 112, 58, "Yours" },
  { "status", 174, ROW_WIDTH - 174 - FLIP_WIDTH, "Status" },
}

local built = false
local shownId   -- id of the item the right panel last drew
local sinceDraw = 0 -- seconds since the list was last drawn
local message   -- a reply or notice shown instead of Auctions.status
local seenStatus -- Auctions.status as last drawn: a new one replaces the message
local retryId   -- a picked item whose search waits for the running scan to end

-- Widgets, set by Build: list, scroll, rows, empty, check, cancelNext, oldest,
-- listings, cancelUndercut, undercut, flip, status.

local drawList, drawTitle, drawOldest  -- below

local function makeText(parent, font, width, height)
  local fs = parent:CreateFontString(nil, "OVERLAY", font)
  fs:SetWidth(width)
  fs:SetHeight(height)
  fs:SetJustifyH("LEFT")
  fs:SetJustifyV("TOP")
  return fs
end

local function createButton(page, name, text, width)
  local button = CreateFrame("Button", name, page, "UIPanelButtonTemplate")
  button:SetWidth(width)
  button:SetHeight(22)
  button:SetText(text)
  return button
end

local function setEnabled(button, on)
  if on then button:Enable() else button:Disable() end
end

local function scrollTo(scroll, offset)
  FauxScrollFrame_SetOffset(scroll, offset)
  local bar = _G[scroll:GetName() .. "ScrollBar"]
  if bar then bar:SetValue(offset * ROW_HEIGHT) end
end

-- The name of an item of ours, or of one that is no longer listed.
local function itemName(id)
  for _, g in ipairs(Auctions.Groups()) do
    if g.id == id then return g.name end
  end
  return (GetItemInfo(id))
end

local function pickedItem()
  local id = Auctions.Selected()
  if id then return id, itemName(id) end
end

-- Clicks. act() runs one action and puts a failed reply on the status line;
-- the scanner's progress (SCAN_STATUS) lands there while the action runs.

local function act(action, busyText)
  message = nil
  local ok, err = action()
  if not ok then
    if err == "busy" then
      message = busyText
    elseif err == "empty" then
      message = NO_ACTIVE
    end                                  -- "confirm": the popup speaks
  end
  AuctionsUI.Update()
  return ok, err
end

-- A pick while a scan runs is searched when the scan ends (SCAN_FINISHED).
local function pick(id)
  retryId = nil
  local ok, err = act(function() return Auctions.Select(id) end, WAIT_SCAN)
  if not ok and err == "busy" then retryId = id end
end

local function onCheck()
  act(function() return Auctions.CheckUndercuts() end, WAIT_SCAN)
end

local function onCancelNext()
  act(function() return Auctions.CancelNextUndercut() end, WAIT_LIST)
end

local function onCancelUndercut()
  act(function() return Auctions.CancelUndercut(Auctions.Selected()) end, WAIT_LIST)
end

local function onUndercut()
  local id = Auctions.Selected()
  if id then act(function() return Auctions.Undercut(id) end) end
end

-- The check ages (title, oldest-check line) grow with no event to say so: every
-- REDRAW seconds the shown page draws them again. Display only; it never calls
-- an action.
local function onTick(_, elapsed)
  if not ns.Tabs.IsShown("auctions") then return end
  sinceDraw = sinceDraw + elapsed
  if sinceDraw < REDRAW then return end
  sinceDraw = 0
  drawList()
  drawTitle(Auctions.Selected())
  drawOldest(Auctions.Groups(), (Auctions.UndercutCounts()))
end

-- Building

local function createRow(list, i)
  local row = CreateFrame("Button", nil, list)
  row:SetWidth(ROW_WIDTH)
  row:SetHeight(ROW_HEIGHT)
  row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(TITLE_HEIGHT + HEADER_HEIGHT) - (i - 1) * ROW_HEIGHT)
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  row:RegisterForClicks("LeftButtonUp")

  row.selected = row:CreateTexture(nil, "BACKGROUND")
  row.selected:SetAllPoints(row)
  row.selected:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
  row.selected:SetBlendMode("ADD")
  row.selected:SetVertexColor(1, 0.82, 0, 0.6)
  row.selected:Hide()

  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetWidth(14)
  row.icon:SetHeight(14)
  row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
  for _, cell in ipairs(CELLS) do
    local fs = makeText(row, "GameFontHighlightSmall", cell[3], 14)
    fs:SetPoint("LEFT", row, "LEFT", cell[2], 0)
    row[cell[1]] = fs
  end
  row.flip = makeText(row, "GameFontHighlightSmall", FLIP_WIDTH, 14)
  row.flip:SetJustifyH("RIGHT")
  row.flip:SetPoint("RIGHT", row, "RIGHT", 0, 0)

  row:SetScript("OnClick", function(self)
    if self.group then pick(self.group.id) end
  end)
  row:Hide()
  return row
end

local function createList(page)
  local list = CreateFrame("Frame", "CraftProfitAuctionsList", page)
  list:SetWidth(LIST_WIDTH)
  list:SetHeight(TITLE_HEIGHT + HEADER_HEIGHT + VISIBLE * ROW_HEIGHT)
  list:SetPoint("TOPLEFT", page, "TOPLEFT", LEFT, TOP)
  AuctionsUI.list = list

  local title = list:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
  title:SetText("Your auctions")
  for _, cell in ipairs(CELLS) do
    local header = makeText(list, "GameFontNormalSmall", cell[3], 14)
    header:SetPoint("TOPLEFT", list, "TOPLEFT", cell[2], -TITLE_HEIGHT)
    header:SetText(cell[4])
  end

  -- The scroll frame comes first so the rows sit above it and get the clicks.
  local scroll = CreateFrame("ScrollFrame", "CraftProfitAuctionsListScroll", list, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(TITLE_HEIGHT + HEADER_HEIGHT))
  scroll:SetPoint("BOTTOMRIGHT", list, "TOPRIGHT", -SCROLLBAR_WIDTH,
    -(TITLE_HEIGHT + HEADER_HEIGHT + VISIBLE * ROW_HEIGHT))
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, drawList)
  end)
  AuctionsUI.scroll = scroll

  AuctionsUI.rows = {}
  for i = 1, VISIBLE do AuctionsUI.rows[i] = createRow(list, i) end

  AuctionsUI.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  AuctionsUI.empty:SetPoint("TOP", list, "TOP", 0, -(TITLE_HEIGHT + HEADER_HEIGHT + 20))
  AuctionsUI.empty:SetText("You have no auctions.")
end

-- Builds the page into Tabs.Page("auctions"), once.
function AuctionsUI.Build()
  local page = ns.Tabs.Page("auctions")
  if built or not page then return end
  built = true

  createList(page)
  local list = AuctionsUI.list

  AuctionsUI.check = createButton(page, "CraftProfitCheckUndercuts", "Check undercuts", 120)
  AuctionsUI.check:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -4)
  AuctionsUI.check:SetScript("OnClick", onCheck)
  AuctionsUI.cancelNext = createButton(page, "CraftProfitCancelNext", "Cancel next undercut (0)", 190)
  AuctionsUI.cancelNext:SetPoint("LEFT", AuctionsUI.check, "RIGHT", 6, 0)
  AuctionsUI.cancelNext:SetScript("OnClick", onCancelNext)
  AuctionsUI.oldest = makeText(page, "GameFontHighlightSmall", 190, 12)
  AuctionsUI.oldest:SetPoint("TOPLEFT", AuctionsUI.cancelNext, "BOTTOMLEFT", 0, -4)
  AuctionsUI.status = makeText(page, "GameFontHighlightSmall", LIST_WIDTH, 40)
  AuctionsUI.status:SetPoint("TOPLEFT", AuctionsUI.check, "BOTTOMLEFT", 0, -20)

  local tbl = ns.ListingsUI.Create(page, "CraftProfitAuctionsListings")
  tbl.frame:SetPoint("TOPRIGHT", page, "TOPRIGHT", -LEFT, TOP)
  AuctionsUI.listings = tbl
  AuctionsUI.cancelUndercut = createButton(page, "CraftProfitCancelUndercut", "Cancel undercut (0)", 170)
  AuctionsUI.cancelUndercut:SetPoint("TOPLEFT", tbl.frame, "BOTTOMLEFT", 0, -4)
  AuctionsUI.cancelUndercut:SetScript("OnClick", onCancelUndercut)
  AuctionsUI.undercut = createButton(page, "CraftProfitUndercutButton", "Undercut", 100)
  AuctionsUI.undercut:SetPoint("LEFT", AuctionsUI.cancelUndercut, "RIGHT", 6, 0)
  AuctionsUI.undercut:SetScript("OnClick", onUndercut)
  AuctionsUI.flip = ns.Flip.CreateWidget(page, pickedItem)
  AuctionsUI.flip.frame:SetPoint("TOPLEFT", AuctionsUI.cancelUndercut, "BOTTOMLEFT", 0, -4)

  page:SetScript("OnUpdate", onTick)
end

-- Drawing

-- "now" or "5m ago".
local function ago(age)
  if age < 60 then return "now" end
  return Util.FormatAge(age) .. " ago"
end

local function statusText(g)
  local s, text = g.status
  if s == "cheapest" then
    text = Util.ICON_OK .. " cheapest"
  elseif s == "tied" then
    text = Util.ICON_WARN .. " tied"
  elseif s == "undercut" then
    text = Util.ICON_WARN .. " undercut " .. Util.FormatMoneyShort(g.diff)
      .. " (" .. (g.seller or "?") .. ")"
  elseif s == "sold" then
    text = "sold"
  else
    text = "-"
  end
  return text
end

local function yoursText(g)
  return g.active .. (g.sold > 0 and (" (+" .. g.sold .. " sold)") or "")
end

-- The window of rows. Called by the scroll bar too, so it draws only the list.
-- The scroll position stays across redraws; a list that has become too short
-- to reach it puts the position at its own end.
function drawList()
  local groups, selected = Auctions.Groups(), Auctions.Selected()
  local scroll = AuctionsUI.scroll
  local maxOffset = math.max(0, #groups - VISIBLE)
  local offset = FauxScrollFrame_GetOffset(scroll) or 0
  if offset > maxOffset then
    scrollTo(scroll, maxOffset)
    offset = maxOffset
  end
  for i = 1, VISIBLE do
    local row, g = AuctionsUI.rows[i], groups[i + offset]
    row.group = g
    if g then
      row.icon:SetTexture(g.texture)
      row.name:SetText(g.name)
      row.yours:SetText(yoursText(g))
      row.status:SetText(statusText(g))
      row.flip:SetText(g.flip and (Util.ICON_GOLD .. " flip") or "")
      if g.id == selected then row.selected:Show() else row.selected:Hide() end
      row:Show()
    else
      row:Hide()
    end
  end
  FauxScrollFrame_Update(scroll, #groups, VISIBLE, ROW_HEIGHT)
  if #groups == 0 then AuctionsUI.empty:Show() else AuctionsUI.empty:Hide() end
end

-- A different item (or none): its listings start at the top and the flip
-- notice follows the new item at once.
local function itemChanged(id)
  shownId = id
  scrollTo(AuctionsUI.listings.scroll, 0)
  AuctionsUI.flip:Update()
end

-- "<item>: all listings (checked 5m ago)": how old the shown listings are.
function drawTitle(id)
  if not id then
    AuctionsUI.listings:SetTitle("")
    return
  end
  local title = (itemName(id) or ("item " .. id)) .. ": all listings"
  local rows, age = Listings.Get(id)
  if rows then title = title .. " (checked " .. ago(age) .. ")" end
  AuctionsUI.listings:SetTitle(title)
end

local function drawListings(id)
  drawTitle(id)
  local rows = id and Listings.Get(id)
  AuctionsUI.listings:SetRows(rows and Listings.MarkUnderYou(rows))
end

-- "Oldest check: 5m ago", beside Cancel next undercut: the oldest check among
-- the items it would cancel on (counts[id] > 0, from Auctions.UndercutCounts),
-- so a stale one is seen before the player cancels (and loses a deposit). Empty
-- when there is nothing to cancel.
function drawOldest(groups, counts)
  local oldest
  for _, g in ipairs(groups) do
    local _, age = Listings.Get(g.id)
    if counts[g.id] and age and (not oldest or age > oldest) then oldest = age end
  end
  AuctionsUI.oldest:SetText(oldest and ("Oldest check: " .. ago(oldest)) or "")
end

local function drawButtons(groups, selected)
  local active = false
  for _, g in ipairs(groups) do
    if g.active > 0 then active = true break end
  end
  setEnabled(AuctionsUI.check, active)

  -- one pass over the owner list for every count on the page
  local counts, all = Auctions.UndercutCounts()
  AuctionsUI.cancelNext:SetText("Cancel next undercut (" .. all .. ")")
  setEnabled(AuctionsUI.cancelNext, all > 0)

  local own = selected and counts[selected] or 0
  AuctionsUI.cancelUndercut:SetText("Cancel undercut (" .. own .. ")")
  setEnabled(AuctionsUI.cancelUndercut, own > 0)

  setEnabled(AuctionsUI.undercut, selected ~= nil)
  drawOldest(groups, counts)
end

-- A reply or notice stays until Auctions' own status changes.
local function drawStatus()
  if Auctions.status ~= seenStatus then
    seenStatus = Auctions.status
    message = nil
  end
  AuctionsUI.status:SetText(message or Auctions.status)
end

-- Redraws everything from Auctions, while the page is the one shown (showing it
-- redraws, so nothing is lost; a price check from another page costs nothing).
function AuctionsUI.Update()
  if not built or not ns.Tabs.IsShown("auctions") then return end
  local groups, selected = Auctions.Groups(), Auctions.Selected()
  if selected ~= shownId then itemChanged(selected) end
  sinceDraw = 0
  drawList()
  drawListings(selected)
  drawButtons(groups, selected)
  drawStatus()
end

-- PAGE_STATUS / PAGE_ERROR / SCAN_STATUS carry no page id: take them only
-- while this page is the one the player sees.
local function showMessage(text)
  if not built or not ns.Tabs.IsShown("auctions") then return end
  message = text ~= "" and text or nil
  drawStatus()
end

ns.On("PAGE_SHOWN", function(key)
  if key ~= "auctions" then return end
  AuctionsUI.Build()
  message = nil  -- a reply left from an earlier visit goes
  Auctions.Refresh()
  AuctionsUI.Update()
end)
ns.On("AUCTIONS_CHANGED", function()
  if message == WAIT_LIST then message = nil end  -- the owner list answered
  AuctionsUI.Update()
end)
-- An item in the list is redrawn by AUCTIONS_CHANGED (Auctions rebuilds its groups
-- and fires it); this covers the picked item when it is not in the list any more.
ns.On("LISTINGS_UPDATED", function(id)
  if id ~= Auctions.Selected() then return end
  for _, g in ipairs(Auctions.Groups()) do
    if g.id == id then return end
  end
  AuctionsUI.Update()
end)
ns.On("PAGE_STATUS", function(text) showMessage(text or "") end)
ns.On("PAGE_ERROR", function(msg) showMessage(BAD .. (msg or "") .. "|r") end)
ns.On("SCAN_STATUS", function(text) showMessage(text or "") end)

-- The scan that kept a pick waiting is over: search it now, if it is still the
-- pick and the page is still the one shown. A scan the close of the Auction
-- House stopped leaves nothing to search: the pick is dropped, not kept for the
-- next open (Core tells the scanner before it stops the scan).
ns.On("SCAN_FINISHED", function()
  local id = retryId
  retryId = nil
  if id and built and ns.Scanner.IsAHOpen() and ns.Tabs.IsShown("auctions")
      and Auctions.Selected() == id then
    pick(id)
  end
end)
