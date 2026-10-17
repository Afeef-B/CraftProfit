-- The "CP Buy" page, full width: a search bar, one table for the view
-- ns.Buy shows (a search's results, an item's grouped listings, or a
-- shopping list), that view's buttons and the status line. It only draws
-- ns.Buy and hands the player's input to it; a purchase starts only from a
-- Buy button's OnClick (Buy cheapest, Buy one), never from an event.
local addonName, ns = ...

local Util = ns.Util
local Style = ns.Style
local Buy = ns.Buy

ns.BuyUI = {}
local BuyUI = ns.BuyUI

local BAD, GOOD, GREEN, RED = "|cffff4040", "|cff40ff40", "|cff40ff40", "|cffff4040"
local NO_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local ROWS = 11

-- Where each strip sits on the page: x, y from the top-left, width, height.
local P = Style.PAD
local W = Style.PAGE_W - 2 * P
local LAYOUT = {
  bar     = { x = P, y = 8,   w = W, h = 28 },
  view    = { x = P, y = 40,  w = W, h = 20 + 18 + ROWS * Style.ROW_H },
  actions = { x = P, y = 280, w = W, h = 24 },
}
BuyUI.layout = LAYOUT

-- Columns of the three tables (x, width; the scroll bar starts at W - 24).
local RESULT_COLUMNS = {
  { key = "name",     x = 20,  width = 300, justify = "LEFT",  title = "Item" },
  { key = "each",     x = 330, width = 110, justify = "RIGHT", title = "Each" },
  { key = "auctions", x = 450, width = 70,  justify = "RIGHT", title = "Auctions" },
  { key = "qty",      x = 530, width = 70,  justify = "RIGHT", title = "Qty" },
  { key = "seen",     x = 610, width = 60,  justify = "RIGHT", title = "Seen" },
}
local ITEM_COLUMNS = {
  { key = "stack",    x = 0,   width = 50,  justify = "RIGHT", title = "Stack" },
  { key = "auctions", x = 60,  width = 70,  justify = "RIGHT", title = "Auctions" },
  { key = "each",     x = 140, width = 120, justify = "RIGHT", title = "Each" },
  { key = "total",    x = 270, width = 120, justify = "RIGHT", title = "Per stack" },
  { key = "seller",   x = 400, width = 160, justify = "LEFT",  title = "Seller" },
  { key = "note",     x = 570, width = 120, justify = "LEFT" },
}
local LIST_COLUMNS = {
  { key = "name",     x = 20,  width = 300, justify = "LEFT",  title = "Item" },
  { key = "have",     x = 330, width = 100, justify = "RIGHT", title = "Have" },
  { key = "cheapest", x = 440, width = 120, justify = "RIGHT", title = "Cheapest" },
  { key = "seen",     x = 570, width = 80,  justify = "RIGHT", title = "Seen" },
}

local built = false
local writing = false  -- the page is writing into its own boxes: not the player typing
local selectedKey      -- the group the player clicked (Listings.Group key)
local drawnView        -- the view (and its item or list) the tables last drew
local drawnStatus      -- Buy.Status() as last drawn: a reply on the line stays until it changes
local searchedText = "" -- what the results are for

local function setEnabled(button, on)
  if on then button:Enable() else button:Disable() end
end

local function setShown(frames, on)
  for _, frame in ipairs(frames) do
    if on then frame:Show() else frame:Hide() end
  end
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- PAGE_STATUS / PAGE_ERROR carry no page id: shown only while this page is.
-- With a need set the count stays in view after the reply.
local function showMessage(text)
  if not built or not ns.Tabs.IsShown("buy") then return end
  if Buy.Target() and text ~= "" then text = text .. " - " .. Buy.Status() end
  BuyUI.status:SetText(text)
end

local function selectedGroup()
  if not selectedKey then return nil end
  for _, group in ipairs(Buy.Groups()) do
    if group.key == selectedKey then return group end
  end
end

local function ownListName()
  return Buy.View() == "list" and (Buy.ListKey() or ""):match("^own:(.+)$")
end

-- Clicks: the only places that buy are onBuyCheapest and onBuyOne.

local function onSearch()
  selectedKey = nil
  searchedText = trim(BuyUI.search:GetText())
  Buy.Search(BuyUI.search:GetText())
  BuyUI.search:ClearFocus()
  BuyUI.Update()
end

local function onBuyCheapest()
  Buy.BuyCheapest()
  BuyUI.Update()
end

local function onBuyOne()
  local group = selectedGroup()
  if group and Buy.GroupPick(group) then Buy.BuyGroup(group) end
  BuyUI.Update()
end

local function onBack()
  selectedKey = nil
  Buy.Back()
  BuyUI.Update()
end

local function onResultClick(result)
  selectedKey = nil
  Buy.OpenItem(result.id, result.name)
  BuyUI.Update()
end

local function onGroupClick(group)
  selectedKey = group.key
  BuyUI.Update()
end

-- Left: open the item. Right, on one of the player's lists: take it off.
local function onListClick(line, button)
  if button == "RightButton" then
    local name = ownListName()
    if name then ns.Lists.Remove(name, line.id) end
    return
  end
  selectedKey = nil
  Buy.OpenLine(line)
  BuyUI.Update()
end

local function onSearchAll()
  Buy.SearchAll()
  BuyUI.Update()
end

local function openList(key)
  selectedKey = nil
  Buy.OpenList(key)
  BuyUI.Update()
end

local function showMenu(anchor, menu)
  BuyUI.menuFrame = BuyUI.menuFrame or CreateFrame("Frame", "CraftProfitBuyMenu", UIParent, "UIDropDownMenuTemplate")
  EasyMenu(menu, BuyUI.menuFrame, anchor, 0, 0, "MENU")
end

-- data: { id, name } of an item to put on the new list, or nil.
local function newList(data)
  StaticPopup_Show("CRAFTPROFIT_NEW_LIST", nil, nil, data)
end

local function addTo(listName, id, name)
  local ok, err = ns.Lists.Add(listName, id, name)
  if ok then
    showMessage("Added " .. name .. " to " .. listName .. ".")
  elseif err == "already" then
    showMessage(name .. " is already on " .. listName .. ".")
  end
end

-- The new list from the popup, with the item it was opened for, then shown.
local function createList(text, data)
  local ok, err = ns.Lists.Create(text)
  if not ok then
    showMessage(err == "exists" and ("There is already a list called " .. trim(text) .. ".")
      or "Type a name for the list.")
    return
  end
  local name = err -- Create's second result: the name as stored
  if data then ns.Lists.Add(name, data.id, data.name) end
  openList("own:" .. name)
end

local function onLists(self)
  local menu, all = {}, ns.Lists.All()
  local shown = Buy.View() == "list" and Buy.ListKey()
  for _, list in ipairs(all) do
    local key = list.key
    menu[#menu + 1] = { text = list.name, checked = key == shown, func = function() openList(key) end }
  end
  menu[#menu + 1] = { text = "New list...", notCheckable = true, func = function() newList(nil) end }
  for _, list in ipairs(all) do
    if not list.auto then
      local name = list.name
      menu[#menu + 1] = { text = "Delete " .. name, notCheckable = true, func = function() ns.Lists.Delete(name) end }
    end
  end
  showMenu(self, menu)
end

local function onToList(self)
  local id, name = Buy.Current()
  if Buy.View() ~= "item" or not id then return end
  local menu = {}
  for _, list in ipairs(ns.Lists.All()) do
    if not list.auto then
      local listName = list.name
      menu[#menu + 1] = { text = listName, notCheckable = true, func = function() addTo(listName, id, name) end }
    end
  end
  menu[#menu + 1] = { text = "New list...", notCheckable = true, func = function() newList({ id = id, name = name }) end }
  showMenu(self, menu)
end

StaticPopupDialogs["CRAFTPROFIT_NEW_LIST"] = {
  text = "Name of the new shopping list:",
  button1 = ACCEPT,
  button2 = CANCEL,
  hasEditBox = 1,
  maxLetters = 40,
  OnShow = function(self) _G[self:GetName() .. "EditBox"]:SetFocus() end,
  OnAccept = function(self, data) createList(_G[self:GetName() .. "EditBox"]:GetText(), data) end,
  EditBoxOnEnterPressed = function(self)
    local dialog = self:GetParent()
    createList(self:GetText(), dialog.data)
    dialog:Hide()
  end,
  EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
  timeout = 0,
  whileDead = 1,
  hideOnEscape = 1,
}

-- Lines of the three tables

local function fillResult(_, line, result)
  line.icon:SetTexture(result.texture or NO_ICON)
  line.name:SetText(result.name)
  line.each:SetText(Style.Money(result.unit))
  line.auctions:SetText(tostring(result.auctions))
  line.qty:SetText(tostring(result.quantity))
  line.seen:SetText(Util.FormatAge(ns.Now() - result.t))
end

-- "YOU" (or "YOU (<alt>)"), else the first seller; "+2" for two more.
local function groupSeller(group)
  local seller = group.seller
  local text
  if not seller then
    text = "?"
  elseif group.mine then
    text = seller == UnitName("player") and "YOU" or ("YOU (" .. seller .. ")")
  else
    text = seller
  end
  if group.sellers > 1 then text = text .. " +" .. (group.sellers - 1) end
  return text
end

local function fillGroup(_, line, group)
  local priced = (group.unit or 0) > 0
  line.stack:SetText(tostring(group.count))
  line.auctions:SetText(tostring(#group.rows))
  line.each:SetText(priced and Style.Money(group.unit) or "bid only")
  line.total:SetText(priced and Style.Money(group.buyout) or "-")
  line.seller:SetText(groupSeller(group))
  if group.mine then line.seller:SetTextColor(0.25, 1, 0.25) else line.seller:SetTextColor(1, 1, 1) end
  if group.underYou then
    line.note:SetText(RED .. Util.ICON_WARN .. " under you|r")
  elseif group.outlier then
    line.note:SetText(GREEN .. "deal|r")
  else
    line.note:SetText("")
  end
end

local function fillListLine(_, line, item)
  line.icon:SetTexture(select(10, GetItemInfo(item.id)) or NO_ICON)
  line.name:SetText(item.name)
  if item.need then
    local color = item.have >= item.need and GOOD or "|cffffffff"
    line.have:SetText(color .. item.have .. "/" .. item.need .. "|r")
  else
    line.have:SetText(tostring(item.have))
  end
  line.cheapest:SetText(Style.Money(item.unit))
  line.seen:SetText(item.age and Util.FormatAge(item.age) or "-")
end

local function groupKey(group) return group.key end

-- Building

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

local function barButton(page, name, text, x, onClick)
  local button = Style.Button(page, name, text, 120)
  button:SetPoint("TOPLEFT", page, "TOPLEFT", x, -(LAYOUT.bar.y + 2))
  button:SetScript("OnClick", onClick)
  return button
end

local function createBar(page)
  local edit = CreateFrame("EditBox", "CraftProfitBuySearch", page, "InputBoxTemplate")
  edit:SetWidth(250)
  edit:SetHeight(20)
  edit:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -(LAYOUT.bar.y + 4))
  edit:SetAutoFocus(false)
  edit:SetScript("OnEnterPressed", onSearch)
  BuyUI.search = edit
  barButton(page, "CraftProfitBuySearchButton", "Search", 272, onSearch)
  BuyUI.lists = barButton(page, "CraftProfitBuyLists", "Lists v", 400, onLists)
  BuyUI.toList = barButton(page, "CraftProfitBuyToList", "+ To list", 528, onToList)
  BuyUI.back = barButton(page, "CraftProfitBuyBack", "< Back", 656, onBack)
end

local function createTable(page, name, columns, icon, fill, onClick, empty, keyOf)
  local tbl = ns.ListingsUI.CreateTable(page, name, {
    width = LAYOUT.view.w, visible = ROWS, columns = columns, icon = icon,
    fill = fill, onClick = onClick, empty = empty, keyOf = keyOf,
  })
  tbl.frame:SetPoint("TOPLEFT", page, "TOPLEFT", LAYOUT.view.x, -LAYOUT.view.y)
  tbl:Hide()
  return tbl
end

local function createActions(page)
  local r = LAYOUT.actions
  local y = -r.y
  local function label(text, x)
    local fs = Style.Text(page, "label")
    fs:SetPoint("TOPLEFT", page, "TOPLEFT", r.x + x, y - 5)
    fs:SetText(text)
    return fs
  end

  -- the item view
  BuyUI.needLabel = label("Need", 6)
  BuyUI.need = numberBox(page, "CraftProfitBuyNeed", 50, r.x + 46, y - 2)
  BuyUI.need:SetScript("OnTextChanged", function(self)
    if writing then return end
    local n = tonumber(self:GetText())
    if n and n <= 0 then n = nil end
    -- Only a different need starts the count over (the box may echo its own text).
    if n ~= Buy.Target() then Buy.SetNeed(n) end
  end)
  local cheapest = Style.Button(page, "CraftProfitBuyCheapest", "Search an item first", 260, true)
  cheapest:SetPoint("TOPLEFT", page, "TOPLEFT", r.x + 106, y)
  -- One of the two places a purchase starts.
  cheapest:SetScript("OnClick", onBuyCheapest)
  BuyUI.cheapest = cheapest
  local one = Style.Button(page, "CraftProfitBuyOne", "Buy one", 200)
  one:SetPoint("TOPLEFT", page, "TOPLEFT", r.x + 374, y)
  -- The other place a purchase starts.
  one:SetScript("OnClick", onBuyOne)
  BuyUI.buyOne = one

  -- the list view
  BuyUI.craftsLabel = label("Crafts", 6)
  BuyUI.crafts = numberBox(page, "CraftProfitBuyCrafts", 40, r.x + 52, y - 2)
  BuyUI.crafts:SetText("1")
  BuyUI.crafts:SetScript("OnTextChanged", function(self)
    if writing then return end
    Buy.SetCrafts(self:GetText())
  end)
  BuyUI.searchAll = Style.Button(page, "CraftProfitBuySearchAll", "Search all", 140)
  BuyUI.searchAll:SetPoint("TOPLEFT", page, "TOPLEFT", r.x + 106, y)
  BuyUI.searchAll:SetScript("OnClick", onSearchAll)

  -- the results view, or nothing shown yet
  BuyUI.hint = Style.Text(page, "label")
  BuyUI.hint:SetPoint("TOPLEFT", page, "TOPLEFT", r.x + 6, y - 5)
  BuyUI.hint:SetWidth(r.w - 12)

  BuyUI.itemActions = { BuyUI.needLabel, BuyUI.need, cheapest, one }
  BuyUI.listActions = { BuyUI.craftsLabel, BuyUI.crafts, BuyUI.searchAll }
end

function BuyUI.Build()
  local page = ns.Tabs.Page("buy")
  if built or not page then return end
  built = true

  createBar(page)
  BuyUI.results = createTable(page, "CraftProfitBuyResults", RESULT_COLUMNS, true, fillResult,
    onResultClick, "No items found.")
  BuyUI.item = createTable(page, "CraftProfitBuyItem", ITEM_COLUMNS, false, fillGroup,
    onGroupClick, "No listings", groupKey)
  BuyUI.list = createTable(page, "CraftProfitBuyList", LIST_COLUMNS, true, fillListLine,
    onListClick, "Nothing on this list yet. Use + To list on an item.")
  createActions(page)
  BuyUI.status = Style.StatusBar(page)
end

-- Drawing

local function drawResults()
  local results, capped, done = Buy.Results()
  local tbl = BuyUI.results
  if done then
    tbl:SetTitle('Results for "' .. searchedText .. '": ' .. #results .. " items"
      .. (capped and " (the first 1000 listings)" or ""))
  else
    tbl:SetTitle('Searching for "' .. searchedText .. '"...')
  end
  tbl:SetRows(results)
end

local function drawItem(id, name)
  local tbl = BuyUI.item
  local groups = Buy.Groups()
  -- a selected group the purchases or a fresh check emptied is gone
  local still = false
  for _, group in ipairs(groups) do
    if group.key == selectedKey then still = true end
  end
  if not still then selectedKey = nil end
  tbl:SetTitle(name or "", id and select(10, GetItemInfo(id)))
  tbl:SetRows(groups)
  tbl:SetSelected(selectedKey)
end

local function drawList()
  local key, title = Buy.ListKey(), ""
  for _, list in ipairs(ns.Lists.All()) do
    if list.key == key then title = list.name end
  end
  BuyUI.list:SetTitle(title)
  BuyUI.list:SetRows(Buy.ListLines())
end

-- A box shows what Buy holds (a list click sets the need, a new item clears
-- it), but never while the player is typing in it.
local function drawBox(box, text)
  if box:HasFocus() or box:GetText() == text then return end
  writing = true
  box:SetText(text)
  writing = false
end

local function drawItemButtons(id)
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

  local pick = Buy.GroupPick(selectedGroup())
  if pick then
    BuyUI.buyOne:SetText("Buy one (" .. Style.Money(pick.buyout) .. ")")
    setEnabled(BuyUI.buyOne, true)
  else
    BuyUI.buyOne:SetText("Buy one")
    setEnabled(BuyUI.buyOne, false)
  end
end

function BuyUI.Update()
  if not built or not ns.Tabs.IsShown("buy") then return end
  local view = Buy.View()
  local id, name = Buy.Current()
  local shown = tostring(view) .. ":" .. tostring(view == "item" and id or view == "list" and Buy.ListKey() or "")
  if shown ~= drawnView then
    drawnView = shown
    if view ~= "item" then selectedKey = nil end
    BuyUI.results:ScrollTop()
    BuyUI.item:ScrollTop()
    BuyUI.list:ScrollTop()
  end

  if view == "results" then BuyUI.results:Show() else BuyUI.results:Hide() end
  if view == "item" then BuyUI.item:Show() else BuyUI.item:Hide() end
  if view == "list" then BuyUI.list:Show() else BuyUI.list:Hide() end
  setShown(BuyUI.itemActions, view == "item")
  setShown(BuyUI.listActions, view == "list")
  if view == "results" or not view then
    BuyUI.hint:SetText(view and "Click an item to see its listings."
      or "Search for an item, or pick a shopping list from Lists v.")
    BuyUI.hint:Show()
  else
    BuyUI.hint:Hide()
  end

  if view == "results" then
    drawResults()
  elseif view == "item" then
    drawItem(id, name)
    local target = Buy.Target()
    drawBox(BuyUI.need, target and tostring(target) or "")
    drawItemButtons(id)
  elseif view == "list" then
    drawList()
    drawBox(BuyUI.crafts, tostring(Buy.Crafts()))
  end
  setEnabled(BuyUI.back, Buy.CanGoBack())
  setEnabled(BuyUI.toList, view == "item" and id ~= nil)

  -- A reply ("Not enough gold", "Finding it...") stays on the line until
  -- Buy's own status moves on (a purchase, a new search).
  local status = Buy.Status()
  if status ~= drawnStatus then
    drawnStatus = status
    BuyUI.status:SetText(status)
  end
end

-- Shift-click on any item link (a Tailoring reagent, a bag item, a chat
-- link) opens it while CP Buy is open. With a chat box open the link goes
-- to chat as usual.
hooksecurefunc("ChatEdit_InsertLink", function(text)
  if not text or not text:find("item:", 1, true) then return end
  if ChatEdit_GetActiveWindow() or not ns.Tabs.IsShown("buy") then return end
  selectedKey = nil
  Buy.SearchLink(text)
  BuyUI.Update()
end)

ns.On("PAGE_SHOWN", function(key)
  if key ~= "buy" then return end
  BuyUI.Build()
  drawnStatus = nil -- a message left from an earlier visit goes
  BuyUI.Update()
end)
ns.On("BUY_CHANGED", BuyUI.Update)
ns.On("BUYER_CHANGED", BuyUI.Update)
ns.On("TRACKING_CHANGED", BuyUI.Update)
ns.On("LISTS_CHANGED", BuyUI.Update)
ns.On("PRICES_CHANGED", BuyUI.Update)
ns.On("PAGE_STATUS", function(text) showMessage(text or "") end)
ns.On("PAGE_ERROR", function(msg) showMessage(BAD .. (msg or "") .. "|r") end)
