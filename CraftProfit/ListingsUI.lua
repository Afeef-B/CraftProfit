-- The "all listings for this item" table shared by the CP Sell and CP Auctions
-- pages. It only draws rows from ns.Listings and reports clicks; it never
-- touches the Auction House itself.
local addonName, ns = ...

local Util = ns.Util

ns.ListingsUI = {}
local ListingsUI = ns.ListingsUI

local VISIBLE, ROW_HEIGHT = 12, 16
local WIDTH = 340
local SCROLLBAR_WIDTH = 24
local TITLE_HEIGHT, HEADER_HEIGHT = 18, 16
local RED = "|cffff4040"

-- Column layout shared by the header and the lines: x offset, width, justify.
local COLUMNS = {
  { key = "qty",    x = 0,   width = 32,  justify = "RIGHT", title = "Qty" },
  { key = "price",  x = 38,  width = 100, justify = "RIGHT", title = "Price each" },
  { key = "seller", x = 146, width = 100, justify = "LEFT",  title = "Seller" },
  { key = "note",   x = 250, width = 66,  justify = "LEFT" },
}

local methods = {}
local meta = { __index = methods }

local function makeText(parent, font, column)
  local fs = parent:CreateFontString(nil, "OVERLAY", font)
  fs:SetWidth(column.width)
  fs:SetHeight(14)
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

local function noteText(row)
  if row.underYou then return RED .. Util.ICON_WARN .. " under you|r" end
  if row.outlier then return Util.ICON_GOLD .. " flip" end
  return ""
end

local function fillLine(line, row)
  line.row = row
  line.qty:SetText(tostring(row.count))
  line.price:SetText((row.unit or 0) > 0 and Util.FormatMoney(row.unit) or "bid only")
  line.seller:SetText(sellerText(row))
  if row.mine then
    line.seller:SetTextColor(0.25, 1, 0.25)
  else
    line.seller:SetTextColor(1, 1, 1)
  end
  line.note:SetText(noteText(row))
  line:Show()
end

local function createLine(tbl, i)
  local line = CreateFrame("Button", nil, tbl.frame)
  line:SetWidth(WIDTH - SCROLLBAR_WIDTH)
  line:SetHeight(ROW_HEIGHT)
  line:SetPoint("TOPLEFT", tbl.frame, "TOPLEFT", 0, -(TITLE_HEIGHT + HEADER_HEIGHT) - (i - 1) * ROW_HEIGHT)
  line:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  line:RegisterForClicks("LeftButtonUp")
  for _, col in ipairs(COLUMNS) do
    local fs = makeText(line, "GameFontHighlightSmall", col)
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
  local rows = self.rows
  local maxOffset = math.max(0, #rows - VISIBLE)
  local offset = math.min(FauxScrollFrame_GetOffset(self.scroll) or 0, maxOffset)
  for i = 1, VISIBLE do
    local line, row = self.lines[i], rows[i + offset]
    if row then
      fillLine(line, row)
    else
      line.row = nil
      line:Hide()
    end
  end
  FauxScrollFrame_Update(self.scroll, #rows, VISIBLE, ROW_HEIGHT)
  if #rows == 0 then self.emptyText:Show() else self.emptyText:Hide() end
end

-- rows from Listings.Get / Listings.Normalize; nil reads as "no listings".
function methods.SetRows(self, rows)
  self.rows = rows or {}
  self:Update()
end

function methods.SetTitle(self, text)
  self.title:SetText(text)
end

-- Builds the table inside `parent`; the caller positions tbl.frame.
-- onRowClick(row) runs on a left click of a row.
function ListingsUI.Create(parent, name, onRowClick)
  local tbl = setmetatable({ rows = {}, lines = {}, onRowClick = onRowClick }, meta)

  local frame = CreateFrame("Frame", name, parent)
  frame:SetWidth(WIDTH)
  frame:SetHeight(TITLE_HEIGHT + HEADER_HEIGHT + VISIBLE * ROW_HEIGHT)
  tbl.frame = frame

  tbl.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  tbl.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  tbl.title:SetText("")

  for _, col in ipairs(COLUMNS) do
    if col.title then
      local header = makeText(frame, "GameFontNormalSmall", col)
      header:SetPoint("TOPLEFT", frame, "TOPLEFT", col.x, -TITLE_HEIGHT)
      header:SetText(col.title)
    end
  end

  -- The scroll frame comes first so the lines sit above it and get the clicks.
  local scroll = CreateFrame("ScrollFrame", name .. "Scroll", frame, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(TITLE_HEIGHT + HEADER_HEIGHT))
  scroll:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -SCROLLBAR_WIDTH,
    -(TITLE_HEIGHT + HEADER_HEIGHT + VISIBLE * ROW_HEIGHT))
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, function() tbl:Update() end)
  end)
  tbl.scroll = scroll

  for i = 1, VISIBLE do tbl.lines[i] = createLine(tbl, i) end

  tbl.emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  tbl.emptyText:SetPoint("TOP", frame, "TOP", 0, -(TITLE_HEIGHT + HEADER_HEIGHT + 20))
  tbl.emptyText:SetText("No listings")

  return tbl
end
