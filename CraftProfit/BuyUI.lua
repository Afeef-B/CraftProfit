-- The "CP Buy" page: search box and materials list on the left, the item's
-- listings (cheapest per unit first) on the right, "Buy cheapest" and "Buy
-- this" buttons. It only draws ns.Buy and hands the player's input to it; a
-- purchase starts only from a Buy button's OnClick, never from an event.
local addonName, ns = ...

local Style = ns.Style
local Buy = ns.Buy

ns.BuyUI = {}
local BuyUI = ns.BuyUI

local BAD, GOOD = "|cffff4040", "|cff40ff40"
local MATERIAL_LINES = 6

local P, LEFT_W, RIGHT_X = Style.PAD, Style.LEFT_W, Style.PAD + Style.LEFT_W + Style.GAP
local LAYOUT = {
  search    = { x = P, y = 8,   w = LEFT_W, h = 56 },
  materials = { x = P, y = 70,  w = LEFT_W, h = 50 + MATERIAL_LINES * Style.ROW_H },
  buy       = { x = P, y = 236, w = LEFT_W, h = 64 },
  listings  = { x = RIGHT_X, y = 8, w = Style.RIGHT_W, h = 20 + 18 + Style.VISIBLE * Style.ROW_H },
  buyrow    = { x = RIGHT_X, y = 268, w = Style.RIGHT_W, h = 24 },
}
BuyUI.layout = LAYOUT

local built = false
local writing = false -- the page is writing into its own Need box: not the player typing
local recipeId     -- the recipe the materials list is for
local selected     -- the row the player clicked
local shownId      -- the item the table last drew

local function place(frame, page, r)
  frame:SetPoint("TOPLEFT", page, "TOPLEFT", r.x, -r.y)
end

local function panel(page, key, name, title)
  local r = LAYOUT[key]
  local frame = Style.Panel(page, name, title, r.w, r.h)
  place(frame, page, r)
  return frame
end

local function numberBox(parent, name, width, x, y)
  local box = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
  box:SetWidth(width)
  box:SetHeight(20)
  box:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  box:SetAutoFocus(false)
  box:SetNumeric(true)
  box:SetMaxLetters(5)
  box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  return box
end

local function buyable(row)
  return row and not row.mine and row.seller and (row.buyout or 0) > 0 and not ns.Buyer.IsBought(row)
end

-- Clicks: the only places that buy.

local function onSearch()
  selected = nil
  Buy.Search(BuyUI.search:GetText())
  BuyUI.search:ClearFocus()
  BuyUI.Update()
end

local function onBuyCheapest()
  Buy.BuyCheapest()
  BuyUI.Update()
end

local function onBuyRow()
  if buyable(selected) then Buy.BuyRow(selected) end
  BuyUI.Update()
end

local function onMaterial(self)
  local m = self.material
  if not m then return end
  selected = nil
  local _, link = GetItemInfo(m.id)
  if link then Buy.SearchLink(link) else Buy.Search(m.name) end
  Buy.SetNeed(math.max(0, m.need - m.have))
  BuyUI.Update()
end

local function chooseRecipe(id)
  recipeId = id
  BuyUI.Update()
end

local function onMaterialsFor(self)
  local menu = {}
  for _, id in ipairs(ns.Recipes.TrackedIDs()) do
    local recipe = ns.Recipes.Get(id)
    if recipe then
      menu[#menu + 1] = { text = recipe.name, checked = id == recipeId, func = function() chooseRecipe(id) end }
    end
  end
  if #menu == 0 then
    menu[1] = { text = "Track a recipe in your profession window first", notCheckable = true, disabled = true }
  end
  BuyUI.menuFrame = BuyUI.menuFrame or CreateFrame("Frame", "CraftProfitBuyMenu", UIParent, "UIDropDownMenuTemplate")
  EasyMenu(menu, BuyUI.menuFrame, self, 0, 0, "MENU")
end

-- Building

local function createSearch(page)
  local box = panel(page, "search", "CraftProfitBuySearchPanel", "Search")
  local edit = CreateFrame("EditBox", "CraftProfitBuySearch", box, "InputBoxTemplate")
  edit:SetWidth(220)
  edit:SetHeight(20)
  edit:SetPoint("TOPLEFT", box, "TOPLEFT", 14, -26)
  edit:SetAutoFocus(false)
  edit:SetScript("OnEnterPressed", onSearch)
  BuyUI.search = edit
  local go = Style.Button(box, "CraftProfitBuySearchButton", "Search", 120)
  go:SetPoint("TOPLEFT", box, "TOPLEFT", 246, -24)
  go:SetScript("OnClick", onSearch)
end

local function createMaterials(page)
  local box = panel(page, "materials", "CraftProfitBuyMaterialsPanel", "Materials")
  local pick = Style.Button(box, "CraftProfitBuyMaterialsFor", "Materials for: pick a recipe", 240)
  pick:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -22)
  pick:SetScript("OnClick", onMaterialsFor)
  BuyUI.materialsFor = pick
  local crafts = Style.Text(box, "label")
  crafts:SetPoint("TOPLEFT", box, "TOPLEFT", 260, -27)
  crafts:SetText("Crafts")
  BuyUI.crafts = numberBox(box, "CraftProfitBuyCrafts", 40, 310, -22)
  BuyUI.crafts:SetText("1")
  BuyUI.crafts:SetScript("OnTextChanged", function() BuyUI.Update() end)

  BuyUI.materials = {}
  for i = 1, MATERIAL_LINES do
    local line = CreateFrame("Button", nil, box)
    line:SetWidth(LEFT_W - 20)
    line:SetHeight(Style.ROW_H)
    line:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -50 - (i - 1) * Style.ROW_H)
    line:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    line.text = Style.Text(line, "value")
    line.text:SetWidth(LEFT_W - 24)
    line.text:SetHeight(Style.ROW_H)
    line.text:SetPoint("LEFT", line, "LEFT", 2, 0)
    line:SetScript("OnClick", onMaterial)
    line:Hide()
    BuyUI.materials[i] = line
  end
end

local function createBuy(page)
  local box = panel(page, "buy", "CraftProfitBuyPanel", "Buy")
  local label = Style.Text(box, "label")
  label:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -30)
  label:SetText("Need")
  BuyUI.need = numberBox(box, "CraftProfitBuyNeed", 50, 52, -26)
  BuyUI.need:SetScript("OnTextChanged", function(self)
    if writing then return end
    local n = tonumber(self:GetText())
    if n and n <= 0 then n = nil end
    -- Only a different need starts the count over (the box may echo its own text).
    if n ~= Buy.Target() then Buy.SetNeed(n) end
  end)
  local cheapest = Style.Button(box, "CraftProfitBuyCheapest", "Search an item first", 260, true)
  cheapest:SetPoint("TOPLEFT", box, "TOPLEFT", 110, -24)
  -- One of the two places a purchase starts.
  cheapest:SetScript("OnClick", onBuyCheapest)
  BuyUI.cheapest = cheapest
end

function BuyUI.Build()
  local page = ns.Tabs.Page("buy")
  if built or not page then return end
  built = true

  createSearch(page)
  createMaterials(page)
  createBuy(page)
  BuyUI.status = Style.StatusBar(page)

  BuyUI.listings = ns.ListingsUI.Create(page, "CraftProfitBuyListings", function(row)
    selected = row
    BuyUI.Update()
  end, { mode = "buy" })
  place(BuyUI.listings.frame, page, LAYOUT.listings)

  local r = LAYOUT.buyrow
  local buyRow = Style.Button(page, "CraftProfitBuyRow", "Buy this", 200)
  buyRow:SetPoint("TOPLEFT", page, "TOPLEFT", r.x, -r.y)
  -- The other place a purchase starts.
  buyRow:SetScript("OnClick", onBuyRow)
  BuyUI.buyRow = buyRow
end

-- Drawing

local function setEnabled(button, on)
  if on then button:Enable() else button:Disable() end
end

local function drawMaterials()
  local list = {}
  if recipeId then
    local recipe = ns.Recipes.Get(recipeId)
    if recipe then BuyUI.materialsFor:SetText("Materials for: " .. recipe.name) end
    list = Buy.Materials(recipeId, tonumber(BuyUI.crafts:GetText()) or 1)
  end
  for i, line in ipairs(BuyUI.materials) do
    local m = list[i]
    line.material = m
    if m then
      local color = m.have >= m.need and GOOD or "|cffffffff"
      line.text:SetText(m.name .. "  " .. color .. m.have .. "/" .. m.need .. "|r")
      line:Show()
    else
      line:Hide()
    end
  end
end

-- The Need box shows the need Buy holds (a materials click sets it, a new
-- search clears it), but never while the player is typing in it.
local function drawNeed()
  local box = BuyUI.need
  if box:HasFocus() then return end
  local target = Buy.Target()
  local text = target and tostring(target) or ""
  if box:GetText() ~= text then
    writing = true
    box:SetText(text)
    writing = false
  end
end

local function drawButtons(id)
  local row = id and Buy.Pick()
  local remaining = Buy.Need()
  if not id then
    BuyUI.cheapest:SetText("Search an item first")
    setEnabled(BuyUI.cheapest, false)
  elseif remaining == 0 then
    BuyUI.cheapest:SetText(Buy.Status())
    setEnabled(BuyUI.cheapest, false)
  elseif row then
    BuyUI.cheapest:SetText("Buy cheapest: " .. row.count .. " for " .. Style.Money(row.buyout))
    setEnabled(BuyUI.cheapest, true)
  else
    BuyUI.cheapest:SetText("Nothing to buy")
    setEnabled(BuyUI.cheapest, false)
  end

  if buyable(selected) then
    BuyUI.buyRow:SetText("Buy this (" .. Style.Money(selected.buyout) .. ")")
    setEnabled(BuyUI.buyRow, true)
  else
    BuyUI.buyRow:SetText("Buy this")
    setEnabled(BuyUI.buyRow, false)
  end
end

function BuyUI.Update()
  if not built or not ns.Tabs.IsShown("buy") then return end
  local id, name = Buy.Current()
  local rows = Buy.Rows()
  if id ~= shownId then
    shownId, selected = id, nil
    local scroll = BuyUI.listings.scroll
    FauxScrollFrame_SetOffset(scroll, 0)
    local bar = _G[scroll:GetName() .. "ScrollBar"]
    if bar then bar:SetValue(0) end
  end
  -- A selected row the fresh price check replaced is gone.
  if selected and rows then
    local still = false
    for _, row in ipairs(rows) do if row == selected then still = true end end
    if not still then selected = nil end
  end
  BuyUI.listings:SetTitle(name and (name .. ": cheapest first") or "",
    id and select(10, GetItemInfo(id)))
  BuyUI.listings:SetRows(rows and ns.Listings.MarkUnderYou(rows))
  BuyUI.listings:SetSelected(selected)
  drawMaterials()
  drawNeed()
  drawButtons(id)
  BuyUI.status:SetText(Buy.Status())
end

-- PAGE_STATUS / PAGE_ERROR carry no page id: shown only while this page is.
local function showMessage(text)
  if not built or not ns.Tabs.IsShown("buy") then return end
  BuyUI.status:SetText(text)
end

-- Shift-click on any item link (a Tailoring reagent, a bag item, a chat
-- link) searches it while CP Buy is open. With a chat box open the link goes
-- to chat as usual.
hooksecurefunc("ChatEdit_InsertLink", function(text)
  if not text or not text:find("item:", 1, true) then return end
  if ChatEdit_GetActiveWindow() or not ns.Tabs.IsShown("buy") then return end
  selected = nil
  Buy.SearchLink(text)
  BuyUI.Update()
end)

ns.On("PAGE_SHOWN", function(key)
  if key ~= "buy" then return end
  BuyUI.Build()
  BuyUI.Update()
end)
ns.On("BUY_CHANGED", BuyUI.Update)
ns.On("BUYER_CHANGED", BuyUI.Update)
ns.On("TRACKING_CHANGED", BuyUI.Update)
ns.On("PAGE_STATUS", function(text) showMessage(text or "") end)
ns.On("PAGE_ERROR", function(msg) showMessage(BAD .. (msg or "") .. "|r") end)
