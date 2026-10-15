-- The panel beside the Auction House and the "Track" checkbox in the
-- profession window.
local addonName, ns = ...

local Util = ns.Util
local floor = math.floor

ns.UI = {}
local UI = ns.UI

local WIDTH, HEIGHT = 400, 424
local ROWS, ROW_HEIGHT = 14, 20
local GOOD, BAD, GREY, WHITE = "|cff40ff40", "|cffff4040", "|cff808080", "|cffffffff"
local SOURCE_LABEL = { ah = "AH", vendor = "vendor", craft = "craft", manual = "manual", atr = "Atr" }
local NOTHING_TRACKED = "Nothing tracked yet. Tick \"Track\" on a recipe in your profession window."

local db
local panel, scroll

UI.rowsData = {}
UI.rows = {}

function UI.SetDB(savedDB)
  db = savedDB
end

local function colored(color, text)
  return color .. text .. "|r"
end

local function sourceText(source, age)
  local text = SOURCE_LABEL[source] or source or "?"
  if age then text = text .. " " .. Util.FormatAge(age) end
  return text
end

local function anyStale(result)
  if ns.Prices.IsStale(result.sellAge) then return true end
  for _, line in ipairs(result.lines) do
    if ns.Prices.IsStale(line.age) then return true end
  end
  return false
end

local function moneyCell(value, stale)
  if not value then return colored(GREY, "?") end
  return colored(stale and GREY or WHITE, Util.FormatMoneyShort(value))
end

local function fillRow(row, result)
  row.result = result
  local texture = select(10, GetItemInfo(result.id))
  row.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
  local name = result.name
  if result.made ~= 1 then name = name .. " x" .. result.made end
  row.name:SetText(name)

  local stale = anyStale(result)
  row.cost:SetText(moneyCell(result.cost, stale))
  row.sell:SetText(moneyCell(result.sell, ns.Prices.IsStale(result.sellAge)))
  if result.status == "ok" then
    local color = result.profit >= 0 and GOOD or BAD
    row.profit:SetText(colored(color, Util.FormatMoneyShort(result.profit)))
    row.margin:SetText(result.margin and colored(color, floor(result.margin * 100 + 0.5) .. "%") or "")
  else
    row.profit:SetText(colored(GREY, "?"))
    row.margin:SetText("")
  end
  row:Show()
end

function UI.Update()
  if not panel then return end
  local offset = FauxScrollFrame_GetOffset(scroll) or 0
  for i = 1, ROWS do
    local result = UI.rowsData[i + offset]
    if result then
      fillRow(UI.rows[i], result)
    else
      UI.rows[i].result = nil
      UI.rows[i]:Hide()
    end
  end
  FauxScrollFrame_Update(scroll, #UI.rowsData, ROWS, ROW_HEIGHT)
  if #UI.rowsData == 0 then UI.emptyText:Show() else UI.emptyText:Hide() end
  UI.footer:SetText("Right-click a row to stop tracking.  AH cut " .. floor((db.cut or 0.05) * 100 + 0.5) .. "%")
end

function UI.Refresh()
  if not panel then return end
  UI.rowsData = ns.Profit.EvaluateAll(ns.Recipes.TrackedIDs(), ns.Prices.MakeContext())
  UI.Update()
end

function UI.RowTooltip(result)
  GameTooltip:ClearLines()
  GameTooltip:AddLine(result.name)
  for _, line in ipairs(result.lines) do
    local left = line.count .. "x " .. line.name
    if line.unit then
      GameTooltip:AddDoubleLine(left, Util.FormatMoneyShort(line.total) .. "  ("
        .. Util.FormatMoneyShort(line.unit) .. " each, " .. sourceText(line.source, line.age) .. ")",
        1, 1, 1, 1, 1, 1)
      if line.saves and line.saves > 0 then
        GameTooltip:AddLine("   crafting it yourself saves " .. Util.FormatMoneyShort(line.saves), 0.25, 1, 0.25)
      end
    else
      GameTooltip:AddDoubleLine(left, "no price", 1, 1, 1, 1, 0.25, 0.25)
    end
  end
  GameTooltip:AddLine(" ")
  if result.cost then
    GameTooltip:AddDoubleLine("Material cost", Util.FormatMoneyShort(result.cost), 1, 0.82, 0, 1, 1, 1)
  end
  if result.sell then
    local made = result.made ~= 1 and (" x" .. result.made) or ""
    GameTooltip:AddDoubleLine("Sell (" .. sourceText(result.sellSource, result.sellAge) .. ")" .. made,
      Util.FormatMoneyShort(result.sell * result.made), 1, 0.82, 0, 1, 1, 1)
    local cutPercent = floor((db.cut or 0.05) * 100 + 0.5)
    GameTooltip:AddDoubleLine("AH cut " .. cutPercent .. "%",
      "-" .. Util.FormatMoneyShort(result.sell * result.made - result.revenue), 1, 0.82, 0, 1, 1, 1)
  end
  if result.status == "ok" then
    local good = result.profit >= 0
    GameTooltip:AddDoubleLine("Profit", Util.FormatMoneyShort(result.profit), 1, 0.82, 0,
      good and 0.25 or 1, good and 1 or 0.25, 0.25)
  else
    GameTooltip:AddLine("Missing prices: " .. table.concat(result.missing, ", "), 0.5, 0.5, 0.5, true)
  end
  GameTooltip:Show()
end

function UI.StartScanAll()
  local ok, err = ns.Scanner.StartScanAll()
  if not ok then
    UI.statusText:SetText(err == "busy" and "A scan is already running." or "Scan All is on cooldown.")
  end
end

local function onScanClick()
  if ns.Scanner.IsBusy() then
    ns.Scanner.Stop("stopped")
    return
  end
  local ok, err = ns.Scanner.StartTargeted(ns.Recipes.ScanList())
  if not ok and err == "empty" then UI.statusText:SetText(NOTHING_TRACKED) end
  UI.UpdateScanButtons()
end

local function onScanAllClick()
  if not db.scanAllWarned then
    StaticPopup_Show("CRAFTPROFIT_SCANALL")
    return
  end
  UI.StartScanAll()
end

StaticPopupDialogs["CRAFTPROFIT_SCANALL"] = {
  text = "Scan All downloads the whole Auction House at once. On busy realms the game can freeze "
    .. "for a while or even disconnect you, and it can only be used every 15 minutes.\n\nContinue?",
  button1 = "Scan All",
  button2 = "Cancel",
  OnAccept = function()
    db.scanAllWarned = true
    UI.StartScanAll()
  end,
  timeout = 0,
  whileDead = 1,
  hideOnEscape = 1,
}

function UI.UpdateScanButtons()
  if not panel then return end
  local busy = ns.Scanner.IsBusy()
  UI.scanButton:SetText(busy and "Stop" or "Scan tracked")

  local cooldown = ns.Scanner.ScanAllCooldown()
  if busy then
    UI.scanAllButton:SetText("Scan All")
    UI.scanAllButton:Disable()
  elseif cooldown == 0 then
    UI.scanAllButton:SetText("Scan All")
    UI.scanAllButton:Enable()
  elseif cooldown > 0 then
    UI.scanAllButton:SetText(string.format("Scan All (%d:%02d)", floor(cooldown / 60), floor(cooldown % 60)))
    UI.scanAllButton:Disable()
  else
    UI.scanAllButton:SetText("Scan All (wait)")
    UI.scanAllButton:Disable()
  end
end

local function makeText(parent, font, width, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", font)
  fs:SetWidth(width)
  fs:SetHeight(14)
  fs:SetJustifyH(justify)
  return fs
end

-- Column layout shared by the header and the rows: x offset, width, justify.
local COLUMNS = {
  { key = "name",   x = 20,  width = 124, justify = "LEFT",  title = "Item" },
  { key = "cost",   x = 146, width = 58,  justify = "RIGHT", title = "Cost" },
  { key = "sell",   x = 206, width = 58,  justify = "RIGHT", title = "Sell" },
  { key = "profit", x = 266, width = 60,  justify = "RIGHT", title = "Profit" },
  { key = "margin", x = 328, width = 34,  justify = "RIGHT", title = "%" },
}

local function createRow(i)
  local row = CreateFrame("Button", nil, panel)
  row:SetWidth(WIDTH - 50)
  row:SetHeight(ROW_HEIGHT)
  row:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -104 - (i - 1) * ROW_HEIGHT)
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetWidth(16)
  row.icon:SetHeight(16)
  row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)

  for _, col in ipairs(COLUMNS) do
    local fs = makeText(row, "GameFontHighlightSmall", col.width, col.justify)
    fs:SetPoint("LEFT", row, "LEFT", col.x, 0)
    row[col.key] = fs
  end

  row:SetScript("OnEnter", function(self)
    if not self.result then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    UI.RowTooltip(self.result)
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row:SetScript("OnClick", function(self, button)
    if button == "RightButton" and self.result then
      GameTooltip:Hide()
      ns.Recipes.SetTracked(self.result.id, false)
    end
  end)
  row:Hide()
  return row
end

local function createButton(name, text, width, x, onClick)
  local button = CreateFrame("Button", name, panel, "UIPanelButtonTemplate")
  button:SetWidth(width)
  button:SetHeight(22)
  button:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -40)
  button:SetText(text)
  button:SetScript("OnClick", onClick)
  return button
end

function UI.EnsurePanel()
  if panel or not AuctionFrame then return end

  panel = CreateFrame("Frame", "CraftProfitPanel", AuctionFrame)
  panel:SetWidth(WIDTH)
  panel:SetHeight(HEIGHT)
  panel:SetPoint("TOPLEFT", AuctionFrame, "TOPRIGHT", -2, -12)
  panel:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  panel:EnableMouse(true)
  panel:SetScript("OnShow", UI.Refresh)

  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", panel, "TOP", 0, -18)
  title:SetText(addonName)

  local close = CreateFrame("Button", "CraftProfitPanelClose", panel, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -6)

  UI.scanButton = createButton("CraftProfitScanButton", "Scan tracked", 130, 18, onScanClick)
  UI.scanAllButton = createButton("CraftProfitScanAllButton", "Scan All", 130, 152, onScanAllClick)

  UI.statusText = makeText(panel, "GameFontHighlightSmall", WIDTH - 40, "LEFT")
  UI.statusText:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -68)
  UI.statusText:SetText(ns.Scanner.statusText ~= "" and ns.Scanner.statusText or "Press \"Scan tracked\" to update prices.")

  for _, col in ipairs(COLUMNS) do
    local header = makeText(panel, "GameFontNormalSmall", col.width, col.justify)
    header:SetPoint("TOPLEFT", panel, "TOPLEFT", 16 + col.x, -88)
    header:SetText(col.title)
  end

  for i = 1, ROWS do UI.rows[i] = createRow(i) end

  scroll = CreateFrame("ScrollFrame", "CraftProfitScrollFrame", panel, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -104)
  scroll:SetPoint("BOTTOMRIGHT", panel, "TOPRIGHT", -38, -104 - ROWS * ROW_HEIGHT)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, UI.Update)
  end)

  UI.emptyText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  UI.emptyText:SetWidth(WIDTH - 80)
  UI.emptyText:SetPoint("TOP", panel, "TOP", 0, -150)
  UI.emptyText:SetText("Open Tailoring, select a recipe and tick \"Track\" to follow its profit here.")

  UI.footer = makeText(panel, "GameFontDisableSmall", WIDTH - 40, "LEFT")
  UI.footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 20, 18)
end

function UI.ShowPanel()
  UI.EnsurePanel()
  if not panel then return end
  panel:Show()
  UI.Refresh()
  UI.UpdateScanButtons()
end

function UI.Toggle()
  if not panel then return end
  if panel:IsShown() then panel:Hide() else panel:Show() end
end

function UI.IsVisible()
  return panel ~= nil and panel:IsShown() and AuctionFrame:IsShown()
end

-- "Track" checkbox in the recipe details of the profession window. The top
-- row next to "Have Materials" holds the search box in 3.3.5, so it sits at
-- the top right of the details instead.
local trackButton

function UI.UpdateTrackButton()
  if not trackButton then return end
  local id = not IsTradeSkillLinked() and ns.Recipes.SelectedProductID()
  if id then
    trackButton:SetChecked(ns.Recipes.IsTracked(id))
    trackButton:Show()
  else
    trackButton:Hide()
  end
end

function UI.EnsureTrackButton()
  if trackButton or not TradeSkillDetailScrollChildFrame then return end

  trackButton = CreateFrame("CheckButton", "CraftProfitTrackCheck", TradeSkillDetailScrollChildFrame, "UICheckButtonTemplate")
  trackButton:SetWidth(22)
  trackButton:SetHeight(22)
  trackButton:SetPoint("TOPRIGHT", TradeSkillDetailScrollChildFrame, "TOPRIGHT", -2, -2)
  local label = _G["CraftProfitTrackCheckText"]
  label:ClearAllPoints()
  label:SetPoint("RIGHT", trackButton, "LEFT", 0, 1)
  label:SetText("Track")
  -- Keep long recipe names from running under the checkbox.
  if TradeSkillSkillName then TradeSkillSkillName:SetWidth(190) end

  trackButton:SetScript("OnClick", function(self)
    local id = ns.Recipes.SelectedProductID()
    if not id then return end
    if not ns.Recipes.Get(id) then ns.Recipes.ReadTradeSkill() end
    ns.Recipes.SetTracked(id, self:GetChecked() and true or false)
  end)
  trackButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(addonName)
    GameTooltip:AddLine("Show this recipe's profit in the panel beside the Auction House.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  trackButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

  hooksecurefunc("TradeSkillFrame_SetSelection", UI.UpdateTrackButton)
  UI.UpdateTrackButton()
end

ns.On("SCAN_STATUS", function(text)
  if UI.statusText then UI.statusText:SetText(text) end
  UI.UpdateScanButtons()
end)
ns.On("PRICES_CHANGED", function() UI.Refresh() end)
ns.On("RECIPES_CHANGED", function() UI.Refresh() end)
ns.On("TRACKING_CHANGED", function()
  UI.Refresh()
  UI.UpdateTrackButton()
end)
