-- The "CP Sell" page: item slot, price / stack / duration inputs, money lines,
-- Post button, status line, flip notice and listings table. It only draws
-- Sell.State() and hands the player's input to ns.Sell; pricing and posting
-- logic live in Sell.lua. An auction is created only by the Post button's
-- OnClick (Sell.Post); no event or redraw posts.
local addonName, ns = ...

local Util = ns.Util
local Style = ns.Style
local Sell = ns.Sell

ns.SellUI = {}
local SellUI = ns.SellUI

local GOOD, BAD, GREY = "|cff40ff40", "|cffff4040", "|cff808080"
-- Where each section sits on the page: x, y from the top-left, width, height.
-- Left column: the item, its price and amounts, what it earns, Post. Right
-- column: the listings, with room under them for the flip notice.
local P, LEFT_W, RIGHT_X = Style.PAD, Style.LEFT_W, Style.PAD + Style.LEFT_W + Style.GAP
local LISTING_ROWS = 10
local LAYOUT = {
  item     = { x = P, y = 8,   w = LEFT_W, h = 60 },
  price    = { x = P, y = 74,  w = LEFT_W, h = 96 },
  result   = { x = P, y = 176, w = LEFT_W, h = 80 },
  post     = { x = P, y = 262, w = LEFT_W, h = 36 },
  listings = { x = RIGHT_X, y = 8, w = Style.RIGHT_W, h = 20 + 18 + LISTING_ROWS * Style.ROW_H },
  flip     = { x = RIGHT_X, y = 232, w = Style.RIGHT_W, h = 68 },
}
SellUI.layout = LAYOUT

local function place(frame, page, r)
  frame:SetPoint("TOPLEFT", page, "TOPLEFT", r.x, -r.y)
end
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
local shownId          -- id of the item in the slot the page last drew
local listedId         -- id of the item whose listings the table last drew
local drawnStatus      -- Sell's own status line as last drawn
local drawnCount = {}  -- box -> the count Sell had when the page last drew it

-- Widgets, set by Build: slot, icon, itemName, owned, price, stack, stacks,
-- radios, deposit, net, cost, profit, post, reason, status, flip, listings.

-- A line of text of one Style kind at (x, y) inside `parent`.
local function makeText(parent, kind, width, height, x, y)
  local fs = Style.Text(parent, kind)
  fs:SetWidth(width)
  fs:SetHeight(height)
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

local function createCountBox(panel, name, x, y, field, setter)
  local box = CreateFrame("EditBox", name, panel, "InputBoxTemplate")
  box:SetWidth(50)
  box:SetHeight(20)
  box:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
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

local function createRadio(panel, i, duration, label)
  local name = "CraftProfitSellDuration" .. i
  local radio = CreateFrame("CheckButton", name, panel, "UIRadioButtonTemplate")
  radio:SetPoint("TOPLEFT", panel, "TOPLEFT", 90 + (i - 1) * 70, -74)
  _G[name .. "Text"]:SetText(label)
  radio:SetScript("OnClick", function() Sell.SetDuration(duration) end)
  return radio
end

local function panel(page, key, name, title)
  local r = LAYOUT[key]
  local frame = Style.Panel(page, name, title, r.w, r.h)
  place(frame, page, r)
  return frame
end

local function createItemPanel(page)
  local box = panel(page, "item", "CraftProfitSellItemPanel", "Item")
  local slot = CreateFrame("Button", "CraftProfitSellSlot", box, "ItemButtonTemplate")
  slot:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -20)
  slot:SetScript("OnClick", onSlotDrop)
  slot:SetScript("OnReceiveDrag", onSlotDrop)
  SellUI.slot = slot
  SellUI.icon = _G["CraftProfitSellSlotIconTexture"]

  SellUI.itemName = makeText(box, "big", LEFT_W - 64, 18, 56, -20)
  SellUI.owned = makeText(box, "label", LEFT_W - 64, 14, 56, -40)
end

local function createPricePanel(page)
  local box = panel(page, "price", "CraftProfitSellPricePanel", "Price")
  makeText(box, "label", 70, 14, 10, -28):SetText("Each")
  local price = CreateFrame("Frame", "CraftProfitSellPrice", box, "MoneyInputFrameTemplate")
  price:SetPoint("TOPLEFT", box, "TOPLEFT", 90, -24)
  MoneyInputFrame_SetOnValueChangedFunc(price, onPriceChanged)
  SellUI.price = price

  makeText(box, "label", 70, 14, 10, -54):SetText("Amount")
  SellUI.stack = createCountBox(box, "CraftProfitSellStack", 96, -50, "stack", "SetStack")
  makeText(box, "value", 12, 14, 152, -54):SetText("x")
  SellUI.stacks = createCountBox(box, "CraftProfitSellStacks", 170, -50, "stacks", "SetStacks")
  local default = Style.Button(box, "CraftProfitSellDefault", "Set as default", 120)
  default:SetPoint("TOPLEFT", box, "TOPLEFT", 226, -48)
  default:SetScript("OnClick", function()
    local s = Sell.State()
    Sell.SetDefault(s.stack, s.stacks)
  end)
  default:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Set as default")
    GameTooltip:AddLine("Start items you haven't posted yet at this stack size x auctions.", 1, 1, 1, true)
    GameTooltip:AddLine("Each item remembers what you last posted it with.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  default:SetScript("OnLeave", function() GameTooltip:Hide() end)
  SellUI.default = default

  makeText(box, "label", 70, 14, 10, -78):SetText("Duration")
  SellUI.radios = {}
  for i, entry in ipairs(DURATIONS) do
    SellUI.radios[i] = createRadio(box, i, entry[1], entry[2])
  end
end

local function createResultPanel(page)
  local box = panel(page, "result", "CraftProfitSellResultPanel", "Result")
  local w = LEFT_W - 20
  SellUI.deposit = makeText(box, "value", w, 14, 10, -24)
  SellUI.net = makeText(box, "value", w, 14, 10, -38)
  SellUI.cost = makeText(box, "value", w, 14, 10, -52)
  SellUI.profit = makeText(box, "value", w, 14, 10, -66)
end

local function createPostRow(page)
  local r = LAYOUT.post
  local post = Style.Button(page, "CraftProfitSellPost", "Post", 170, true)
  post:SetPoint("TOPLEFT", page, "TOPLEFT", r.x, -r.y)
  -- The only place an auction is created.
  post:SetScript("OnClick", function() Sell.Post() end)
  SellUI.post = post
  SellUI.reason = makeText(page, "label", r.w - 180, 32, r.x + 180, -r.y - 2)
end

-- Builds the page into Tabs.Page("sell"), once.
function SellUI.Build()
  local page = ns.Tabs.Page("sell")
  if built or not page then return end
  built = true

  createItemPanel(page)
  createPricePanel(page)
  createResultPanel(page)
  createPostRow(page)
  SellUI.status = Style.StatusBar(page)

  SellUI.listings = ns.ListingsUI.Create(page, "CraftProfitSellListings", function(row)
    Sell.PickRow(row)
  end, { visible = LISTING_ROWS })
  place(SellUI.listings.frame, page, LAYOUT.listings)

  SellUI.flip = ns.Flip.CreateWidget(page, shownItem)
  place(SellUI.flip.frame, page, LAYOUT.flip)
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
  local deposit = "Deposit: " .. Style.Money(s.deposit)
  local net = s.net and ("You get each: " .. Style.Money(s.net)) or ""
  local cost, profit = "", ""
  if s.costUnknown then
    profit = GREY .. "cost unknown - scan it in Craft Profit|r"
  elseif s.cost then
    cost = "Cost each: " .. Style.Money(s.cost)
    if s.loss then
      profit = BAD .. "Profit each: loses " .. Style.Money(-s.profit) .. " vs crafting cost|r"
    elseif s.profit then
      profit = GOOD .. "Profit each: " .. Style.Money(s.profit) .. "|r"
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

-- A different item in the slot (or none): the flip notice follows it at once.
local function itemChanged(id)
  shownId = id
  SellUI.flip:Update()
end

-- The table shows another item's listings: they start at the top. (An emptied
-- slot leaves the table on the last item, so this is not itemChanged.)
local function listedChanged(id)
  listedId = id
  local scroll = SellUI.listings.scroll
  FauxScrollFrame_SetOffset(scroll, 0)
  local bar = _G[scroll:GetName() .. "ScrollBar"]
  if bar then bar:SetValue(0) end
end

local function drawItem(s)
  local item = s.item
  if item then
    SellUI.icon:SetTexture(item.texture)
    SellUI.icon:Show()
    SellUI.itemName:SetText(item.name)
    SellUI.owned:SetText("You have " .. item.owned)
  else
    SellUI.icon:Hide()
    SellUI.itemName:SetText("")
    SellUI.owned:SetText("")
  end
  -- Once the slot has emptied after a post, the table keeps the last item (its
  -- new auctions show up as YOU when the check after posting answers).
  SellUI.listings:SetTitle(s.shownName and (s.shownName .. ": all listings") or "")
  -- The marks follow the rows we show, whichever page drew them last.
  SellUI.listings:SetRows(s.listings and ns.Listings.MarkUnderYou(s.listings))
end

-- Redraws everything from Sell.State().
function SellUI.Update()
  if not built then return end
  local s = Sell.State()

  local id = s.item and s.item.id
  if id ~= shownId then itemChanged(id) end
  if s.shownId ~= listedId then listedChanged(s.shownId) end
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
