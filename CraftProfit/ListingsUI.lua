-- The "all listings for this item" table shared by the CP Sell and CP Auctions
-- pages. It only draws rows from ns.Listings and reports clicks; it never
-- touches the Auction House itself.
local addonName, ns = ...

local Util = ns.Util
local Style = ns.Style

ns.ListingsUI = {}
local ListingsUI = ns.ListingsUI

local VISIBLE, ROW_HEIGHT = Style.VISIBLE, Style.ROW_H
local WIDTH = Style.RIGHT_W
local SCROLLBAR_WIDTH = 24
local TITLE_HEIGHT, HEADER_HEIGHT = 20, 18
local ICON_SIZE = 16
local RED = "|cffff4040"
local GREEN = "|cff40ff40"

-- Column layout shared by the header and the lines: x offset, width, justify.
-- They end at WIDTH - SCROLLBAR_WIDTH; a longer text is cut, never spilled.
local COLUMNS = {
  { key = "qty",    x = 0,   width = 26, justify = "RIGHT", title = "Qty" },
  { key = "price",  x = 30,  width = 90, justify = "RIGHT", title = "Each" },
  { key = "total",  x = 124, width = 90, justify = "RIGHT", title = "Stack" },
  { key = "seller", x = 218, width = 74, justify = "LEFT",  title = "Seller" },
  { key = "note",   x = 296, width = 70, justify = "LEFT" },
}
ListingsUI.COLUMNS = COLUMNS

local methods = {}
local meta = { __index = methods }

local function makeText(parent, kind, column)
  local fs = Style.Text(parent, kind)
  fs:SetWidth(column.width)
  fs:SetHeight(ROW_HEIGHT)
  fs:SetJustifyH(column.justify)
  return fs
end

-- "YOU" for this character, "YOU (<name>)" for one of its alts, "?" while the
-- client has not loaded the seller's name yet.
local function sellerText(row)
  if not row.seller then return "?" end
  if row.mine and row.seller ~= UnitName("player") then return "YOU (" .. row.seller .. ")" end
  if row.mine then return "YOU" end
  return row.seller
end

-- On CP Buy ("buy" mode) a mistake listing is simply the best buy, and a row
-- bought a moment ago stays greyed until the fresh price check replaces it.
local function bought(mode, row)
  return mode == "buy" and ns.Buyer and ns.Buyer.IsBought(row)
end

local function noteText(mode, row)
  if bought(mode, row) then return "bought" end
  if row.underYou then return RED .. Util.ICON_WARN .. " under you|r" end
  if row.outlier then
    if mode == "buy" then return GREEN .. "deal|r" end
    return Util.ICON_GOLD .. " flip"
  end
  return ""
end

local function fillLine(tbl, line, row)
  line.row = row
  local priced = (row.unit or 0) > 0
  line.qty:SetText(tostring(row.count))
  line.price:SetText(priced and Style.Money(row.unit) or "bid only")
  line.total:SetText(priced and Style.Money(row.buyout) or "-")
  line.seller:SetText(sellerText(row))
  if bought(tbl.mode, row) then
    line.seller:SetTextColor(0.5, 0.5, 0.5)
  elseif row.mine then
    line.seller:SetTextColor(0.25, 1, 0.25)
  else
    line.seller:SetTextColor(1, 1, 1)
  end
  line.note:SetText(noteText(tbl.mode, row))
  if row == tbl.selectedRow then line.selected:Show() else line.selected:Hide() end
  line:Show()
end

local function createLine(tbl, i)
  local line = CreateFrame("Button", nil, tbl.frame)
  line:SetWidth(WIDTH - SCROLLBAR_WIDTH)
  line:SetHeight(ROW_HEIGHT)
  line:SetPoint("TOPLEFT", tbl.frame, "TOPLEFT", 0, -(TITLE_HEIGHT + HEADER_HEIGHT) - (i - 1) * ROW_HEIGHT)
  line:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  line:RegisterForClicks("LeftButtonUp")
  -- Faint stripes on every other line make long rows easy to follow.
  if i % 2 == 0 then
    local stripe = line:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints(line)
    stripe:SetTexture(1, 1, 1, 0.06)
  end
  line.selected = line:CreateTexture(nil, "BORDER")
  line.selected:SetAllPoints(line)
  line.selected:SetTexture(1, 0.82, 0, 0.2)
  line.selected:Hide()
  for _, col in ipairs(COLUMNS) do
    local fs = makeText(line, "value", col)
    fs:SetPoint("LEFT", line, "LEFT", col.x, 0)
    line[col.key] = fs
  end
  line:SetScript("OnClick", function(self)
    if self.row and tbl.onRowClick then tbl.onRowClick(self.row) end
  end)
  line:Hide()
  return line
end

-- Redraw the visible window of rows.
function methods.Update(self)
  local rows, visible = self.rows, self.visible
  local maxOffset = math.max(0, #rows - visible)
  local offset = math.min(FauxScrollFrame_GetOffset(self.scroll) or 0, maxOffset)
  for i = 1, visible do
    local line, row = self.lines[i], rows[i + offset]
    if row then
      fillLine(self, line, row)
    else
      line.row = nil
      line:Hide()
    end
  end
  FauxScrollFrame_Update(self.scroll, #rows, visible, ROW_HEIGHT)
  if #rows == 0 then self.emptyText:Show() else self.emptyText:Hide() end
end

-- rows from Listings.Get / Listings.Normalize; nil reads as "no listings".
function methods.SetRows(self, rows)
  self.rows = rows or {}
  self:Update()
end

-- texture: the item's icon, shown before the title (every row is that item).
function methods.SetTitle(self, text, texture)
  self.title:SetText(text)
  if texture and text and text ~= "" then
    self.icon:SetTexture(texture)
    self.icon:Show()
  else
    self.icon:Hide()
  end
end

-- Highlight the line drawing `row` (nil: none).
function methods.SetSelected(self, row)
  self.selectedRow = row
  self:Update()
end

-- Builds the table inside `parent`; the caller positions tbl.frame.
-- onRowClick(row) runs on a left click of a row. opts.mode = "buy" for CP Buy;
-- opts.visible: how many rows show (default Style.VISIBLE), to leave room below.
function ListingsUI.Create(parent, name, onRowClick, opts)
  local visible = opts and opts.visible or VISIBLE
  local tbl = setmetatable({
    rows = {}, lines = {}, onRowClick = onRowClick, mode = opts and opts.mode, visible = visible,
  }, meta)

  local frame = CreateFrame("Frame", name, parent)
  frame:SetWidth(WIDTH)
  frame:SetHeight(TITLE_HEIGHT + HEADER_HEIGHT + visible * ROW_HEIGHT)
  tbl.frame = frame

  tbl.icon = frame:CreateTexture(nil, "ARTWORK")
  tbl.icon:SetWidth(ICON_SIZE)
  tbl.icon:SetHeight(ICON_SIZE)
  tbl.icon:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -1)
  tbl.icon:Hide()
  tbl.title = Style.Text(frame, "title")
  tbl.title:SetPoint("TOPLEFT", frame, "TOPLEFT", ICON_SIZE + 4, -2)
  tbl.title:SetWidth(WIDTH - ICON_SIZE - 4)
  tbl.title:SetText("")

  for _, col in ipairs(COLUMNS) do
    if col.title then
      local header = makeText(frame, "label", col)
      header:SetPoint("TOPLEFT", frame, "TOPLEFT", col.x, -TITLE_HEIGHT)
      header:SetText(col.title)
    end
  end

  -- The scroll frame comes first so the lines sit above it and get the clicks.
  local scroll = CreateFrame("ScrollFrame", name .. "Scroll", frame, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(TITLE_HEIGHT + HEADER_HEIGHT))
  scroll:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -SCROLLBAR_WIDTH,
    -(TITLE_HEIGHT + HEADER_HEIGHT + visible * ROW_HEIGHT))
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, function() tbl:Update() end)
  end)
  tbl.scroll = scroll

  for i = 1, visible do tbl.lines[i] = createLine(tbl, i) end

  tbl.emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  tbl.emptyText:SetPoint("TOP", frame, "TOP", 0, -(TITLE_HEIGHT + HEADER_HEIGHT + 20))
  tbl.emptyText:SetText("No listings")

  return tbl
end
