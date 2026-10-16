-- The "CP Sell" page: item slot, price / stack / duration inputs, money lines,
-- Post button, status line, flip notice and listings table. It only draws
-- Sell.State() and hands the player's input to ns.Sell; pricing and posting
-- logic live in Sell.lua. An auction is created only by the Post button's
-- OnClick (Sell.Post); no event or redraw posts.
local addonName, ns = ...

local Util = ns.Util
local Sell = ns.Sell

ns.SellUI = {}
local SellUI = ns.SellUI

local GOOD, BAD, GREY = "|cff40ff40", "|cffff4040", "|cff808080"
local LEFT, COLUMN = 14, 400  -- the left column: x offset on the page, width
local DURATIONS = { { 1, "12h" }, { 2, "24h" }, { 3, "48h" } }

-- Why the Post button is off (Sell.State().reason), in the player's words.
local REASONS = {
  ["no-item"] = "Drag an item here or Alt+click it in your bags.",
  ["slot-changed"] = "The sell slot changed - drop the item again.",
  posting = "Posting...",
  checking = "Checking prices...",
  ["no-check"] = "No answer from the AH - type a price.",
  ["no-price"] = "Type a price.",
  variant = "Random-enchant item - type a price.",
  ["no-gold"] = "Not enough gold for the deposit.",
}

local built = false
local drawing = false  -- the page is writing into its own inputs: that is not the player typing
local shownId          -- id of the item the page last drew
local drawnStatus      -- Sell's own status line as last drawn
local drawnCount = {}  -- box -> the count Sell had when the page last drew it

-- Widgets, set by Build: slot, icon, itemName, owned, price, stack, stacks,
-- radios, deposit, net, cost, profit, post, reason, status, flip, listings.

local function makeText(parent, font, width, height, x, y)
  local fs = parent:CreateFontString(nil, "OVERLAY", font)
  fs:SetWidth(width)
  fs:SetHeight(height)
  fs:SetJustifyH("LEFT")
  fs:SetJustifyV("TOP")
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  return fs
end

-- Input handlers. Each one reacts only to the player: a write the page made
-- itself (drawing) or a value Sell already holds is not passed on, so a redraw
-- never counts as a typed price or count.

local function onPriceChanged()
  if drawing then return end
  -- An empty box reads as 0c, which is what "no price yet" looks like.
  local copper = MoneyInputFrame_GetCopper(SellUI.price)
  if copper ~= (Sell.State().unit or 0) then Sell.SetUnit(copper) end
end

-- field is the State key, setter the Sell function that takes the new count.
local function onCountChanged(box, field, setter)
  if drawing then return end
  -- An empty box (or a 0) is the player on the way to a number.
  local n = box:GetNumber()
  if n < 1 then return end
  if n ~= Sell.State()[field] then Sell[setter](n) end
end

local function onSlotDrop()
  Sell.DropCursorItem()
end

local function shownItem()
  local item = Sell.State().item
  if item then return item.id, item.name end
end

local function createCountBox(page, name, x, field, setter)
  local box = CreateFrame("EditBox", name, page, "InputBoxTemplate")
  box:SetWidth(50)
  box:SetHeight(20)
  box:SetPoint("TOPLEFT", page, "TOPLEFT", x, -108)
  box:SetAutoFocus(false)
  box:SetNumeric(true)
  box:SetMaxLetters(4)
  box:SetScript("OnTextChanged", function(self) onCountChanged(self, field, setter) end)
  box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  -- Whatever was left in the box, show the count Sell really has.
  box:SetScript("OnEditFocusLost", function(self)
    self:HighlightText(0, 0)
    SellUI.Update()
  end)
  return box
end

local function createRadio(page, i, duration, label)
  local name = "CraftProfitSellDuration" .. i
  local radio = CreateFrame("CheckButton", name, page, "UIRadioButtonTemplate")
  radio:SetPoint("TOPLEFT", page, "TOPLEFT", 200 + (i - 1) * 62, -110)
  _G[name .. "Text"]:SetText(label)
  radio:SetScript("OnClick", function() Sell.SetDuration(duration) end)
  return radio
end

local function createItemRow(page)
  local slot = CreateFrame("Button", "CraftProfitSellSlot", page, "ItemButtonTemplate")
  slot:SetPoint("TOPLEFT", page, "TOPLEFT", LEFT, -10)
  slot:SetScript("OnClick", onSlotDrop)
  slot:SetScript("OnReceiveDrag", onSlotDrop)
  SellUI.slot = slot
  SellUI.icon = _G["CraftProfitSellSlotIconTexture"]

  SellUI.itemName = makeText(page, "GameFontNormal", 340, 16, LEFT + 44, -12)
  SellUI.owned = makeText(page, "GameFontHighlightSmall", 340, 14, LEFT + 44, -30)
end

local function createInputs(page)
  makeText(page, "GameFontNormalSmall", 120, 12, LEFT, -54):SetText("Price each")
  local price = CreateFrame("Frame", "CraftProfitSellPrice", page, "MoneyInputFrameTemplate")
  price:SetPoint("TOPLEFT", page, "TOPLEFT", LEFT + 6, -70)
  MoneyInputFrame_SetOnValueChangedFunc(price, onPriceChanged)
  SellUI.price = price

  makeText(page, "GameFontNormalSmall", 70, 12, LEFT, -94):SetText("Stack size")
  makeText(page, "GameFontNormalSmall", 70, 12, LEFT + 76, -94):SetText("Stacks")
  makeText(page, "GameFontHighlight", 12, 14, LEFT + 63, -111):SetText("x")
  SellUI.stack = createCountBox(page, "CraftProfitSellStack", LEFT + 6, "stack", "SetStack")
  SellUI.stacks = createCountBox(page, "CraftProfitSellStacks", LEFT + 82, "stacks", "SetStacks")

  makeText(page, "GameFontNormalSmall", 120, 12, 200, -94):SetText("Duration")
  SellUI.radios = {}
  for i, entry in ipairs(DURATIONS) do
    SellUI.radios[i] = createRadio(page, i, entry[1], entry[2])
  end
end

local function createOutputs(page)
  SellUI.deposit = makeText(page, "GameFontHighlightSmall", COLUMN, 14, LEFT, -134)
  SellUI.net = makeText(page, "GameFontHighlightSmall", COLUMN, 14, LEFT, -148)
  SellUI.cost = makeText(page, "GameFontHighlightSmall", COLUMN, 14, LEFT, -162)
  SellUI.profit = makeText(page, "GameFontHighlightSmall", COLUMN, 14, LEFT, -176)

  local post = CreateFrame("Button", "CraftProfitSellPost", page, "UIPanelButtonTemplate")
  post:SetWidth(170)
  post:SetHeight(22)
  post:SetPoint("TOPLEFT", page, "TOPLEFT", LEFT, -196)
  -- The only place an auction is created.
  post:SetScript("OnClick", function() Sell.Post() end)
  SellUI.post = post

  SellUI.reason = makeText(page, "GameFontNormalSmall", COLUMN - 178, 28, LEFT + 178, -197)
  SellUI.status = makeText(page, "GameFontHighlightSmall", COLUMN, 28, LEFT, -226)

  SellUI.flip = ns.Flip.CreateWidget(page, shownItem)
  SellUI.flip.frame:SetPoint("TOPLEFT", page, "TOPLEFT", LEFT, -258)
end

-- Builds the page into Tabs.Page("sell"), once.
function SellUI.Build()
  local page = ns.Tabs.Page("sell")
  if built or not page then return end
  built = true

  createItemRow(page)
  createInputs(page)
  createOutputs(page)

  SellUI.listings = ns.ListingsUI.Create(page, "CraftProfitSellListings", function(row)
    Sell.PickRow(row)
  end)
  SellUI.listings.frame:SetPoint("TOPRIGHT", page, "TOPRIGHT", -14, -10)
end

-- Writes into the price box and the count boxes echo to their change handlers;
-- `drawing` keeps those echoes from reaching Sell.
local function drawPrice(unit)
  local box = SellUI.price
  drawing = true
  if unit then
    if MoneyInputFrame_GetCopper(box) ~= unit then MoneyInputFrame_SetCopper(box, unit) end
  elseif MoneyInputFrame_GetCopper(box) ~= 0 then
    MoneyInputFrame_ResetMoney(box)
  end
  drawing = false
end

-- A box the player is typing in (it has the keyboard) is left alone while Sell's
-- count is the one already drawn; OnEditFocusLost shows it afterwards. A count
-- Sell changed on its own (another item, fewer in the bags) is drawn anyway.
local function drawCount(box, n)
  local moved = drawnCount[box] ~= n
  drawnCount[box] = n
  if box:GetNumber() == n or (box:HasFocus() and not moved) then return end
  drawing = true
  box:SetNumber(n)
  drawing = false
end

-- deposit, you get, cost and profit lines ("" when there is nothing to say).
local function moneyLines(s)
  if not s.item then return "", "", "", "" end
  local deposit = "Deposit: " .. Util.FormatMoney(s.deposit)
  local net = s.net and ("You get each: " .. Util.FormatMoney(s.net)) or ""
  local cost, profit = "", ""
  if s.costUnknown then
    profit = GREY .. "cost unknown - scan it in Craft Profit|r"
  elseif s.cost then
    cost = "Cost each: " .. Util.FormatMoney(s.cost)
    if s.loss then
      profit = BAD .. "Profit each: loses " .. Util.FormatMoney(-s.profit) .. " vs crafting cost|r"
    elseif s.profit then
      profit = GOOD .. "Profit each: " .. Util.FormatMoney(s.profit) .. "|r"
    end
  end
  return deposit, net, cost, profit
end

local function reasonText(s)
  if s.canPost then return "" end
  if s.reason == "too-many" then return "You only have " .. s.item.owned .. "." end
  if s.reason == "too-big" then return "Stack size is more than " .. s.item.maxStack .. "." end
  return REASONS[s.reason] or ""
end

-- A different item (or none): its listings start at the top and the flip
-- notice follows the new item at once.
local function itemChanged(id)
  shownId = id
  local scroll = SellUI.listings.scroll
  FauxScrollFrame_SetOffset(scroll, 0)
  local bar = _G[scroll:GetName() .. "ScrollBar"]
  if bar then bar:SetValue(0) end
  SellUI.flip:Update()
end

local function drawItem(s)
  local item = s.item
  if item then
    SellUI.icon:SetTexture(item.texture)
    SellUI.icon:Show()
    SellUI.itemName:SetText(item.name)
    SellUI.owned:SetText("You have " .. item.owned)
    SellUI.listings:SetTitle(item.name .. ": all listings")
  else
    SellUI.icon:Hide()
    SellUI.itemName:SetText("")
    SellUI.owned:SetText("")
    SellUI.listings:SetTitle("")
  end
  -- The marks follow the rows we show, whichever page drew them last.
  SellUI.listings:SetRows(item and s.listings and ns.Listings.MarkUnderYou(s.listings))
end

-- Redraws everything from Sell.State().
function SellUI.Update()
  if not built then return end
  local s = Sell.State()

  local id = s.item and s.item.id
  if id ~= shownId then itemChanged(id) end
  drawItem(s)

  drawPrice(s.unit)
  drawCount(SellUI.stack, s.stack)
  drawCount(SellUI.stacks, s.stacks)
  for i, entry in ipairs(DURATIONS) do
    SellUI.radios[i]:SetChecked(s.duration == entry[1])
  end

  local deposit, net, cost, profit = moneyLines(s)
  SellUI.deposit:SetText(deposit)
  SellUI.net:SetText(net)
  SellUI.cost:SetText(cost)
  SellUI.profit:SetText(profit)

  SellUI.post:SetText("Post " .. s.stacks .. (s.stacks == 1 and " auction" or " auctions"))
  if s.canPost then SellUI.post:Enable() else SellUI.post:Disable() end
  SellUI.reason:SetText(reasonText(s))

  -- A message from another module stays until Sell's own status changes.
  if s.status ~= drawnStatus then
    drawnStatus = s.status
    SellUI.status:SetText(s.status)
  end
end

-- PAGE_STATUS / PAGE_ERROR carry no page id: take them only while this page
-- is the one the player sees.
local function showMessage(text)
  if not built or not ns.Tabs.IsShown("sell") then return end
  SellUI.status:SetText(text)
end

-- Alt+click on a bag item puts it in the sell slot while CP Sell is shown.
-- Blizzard's handler runs first (self is the bag slot button, its parent the
-- bag frame); this only adds to it.
hooksecurefunc("ContainerFrameItemButton_OnModifiedClick", function(self)
  if not IsAltKeyDown() or not ns.Tabs.IsShown("sell") then return end
  Sell.PutItem(self:GetParent():GetID(), self:GetID())
end)

ns.On("PAGE_SHOWN", function(key)
  if key ~= "sell" then return end
  SellUI.Build()
  drawnStatus = nil  -- a message left from an earlier visit goes
  SellUI.Update()
end)
ns.On("SELL_CHANGED", SellUI.Update)
-- The cost lines follow the prices and Post follows the gold. Sell's own
-- PRICES_CHANGED listener was registered when Sell.lua loaded, before this one.
ns.On("PRICES_CHANGED", SellUI.Update)
ns.On("MONEY_CHANGED", SellUI.Update)
ns.On("PAGE_STATUS", function(text) showMessage(text or "") end)
ns.On("PAGE_ERROR", function(msg) showMessage(BAD .. (msg or "") .. "|r") end)
