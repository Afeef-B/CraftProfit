-- One look for every CraftProfit page: the layout grid inside the Auction
-- House, dark boxed sections, readable fonts and money with coin icons.
-- Builds widgets only; knows nothing about auctions.
local addonName, ns = ...

local floor = math.floor

ns.Style = {}
local Style = ns.Style

-- The page frame: AuctionFrame TOPLEFT (20,-72) to BOTTOMRIGHT (-10,40).
Style.PAGE_W, Style.PAGE_H = 802, 335
Style.PAD, Style.GAP = 8, 8
Style.LEFT_W, Style.RIGHT_W = 380, 390
Style.ROW_H, Style.VISIBLE = 18, 12
Style.STATUS_H = 20

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

local BACKDROP = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
}
Style.BACKDROP = BACKDROP

-- kind -> font object, r, g, b
local TEXT = {
  label = { "GameFontHighlight", 0.7, 0.7, 0.7 },
  value = { "GameFontHighlight", 1, 1, 1 },
  big   = { "GameFontNormalLarge" },
  title = { "GameFontNormal", 1, 0.82, 0 },
}

-- "12g 34s 56c" with coin icons; zero parts left out, "0c" for nothing, "-"
-- for no price at all.
function Style.Money(copper)
  if not copper then return "-" end
  copper = floor(copper + 0.5)
  local g = floor(copper / 10000)
  local s = floor(copper / 100) % 100
  local c = copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. GOLD_ICON end
  if s > 0 then parts[#parts + 1] = s .. SILVER_ICON end
  if c > 0 or #parts == 0 then parts[#parts + 1] = c .. COPPER_ICON end
  return table.concat(parts, " ")
end

-- A FontString of one kind: "label" (grey), "value" (white), "big", "title"
-- (gold). Left-justified, on one line: a too-long text is cut, never wrapped.
function Style.Text(parent, kind)
  local spec = TEXT[kind] or TEXT.value
  local fs = parent:CreateFontString(nil, "OVERLAY", spec[1])
  fs:SetJustifyH("LEFT")
  fs:SetNonSpaceWrap(false)
  if spec[2] then fs:SetTextColor(spec[2], spec[3], spec[4]) end
  return fs
end

-- A dark boxed section with a gold title in its top-left corner.
function Style.Panel(parent, name, title, width, height)
  local frame = CreateFrame("Frame", name, parent)
  frame:SetWidth(width)
  frame:SetHeight(height)
  frame:SetBackdrop(BACKDROP)
  frame:SetBackdropColor(0.06, 0.06, 0.09, 0.85)
  frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
  frame.title = Style.Text(frame, "title")
  frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -6)
  frame.title:SetText(title or "")
  return frame
end

-- A standard button, at least 120 px wide; the page's main action has a gold
-- label.
function Style.Button(parent, name, text, width, primary)
  local button = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
  button:SetWidth(math.max(120, width or 0))
  button:SetHeight(24)
  button:SetText(text)
  if primary then
    local label = button:GetFontString()
    if label then label:SetTextColor(1, 0.82, 0) end
  end
  return button
end

-- The page's status line: full width along the bottom, the same place on
-- every page.
function Style.StatusBar(page)
  local fs = Style.Text(page, "value")
  fs:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", Style.PAD + 4, Style.PAD)
  fs:SetWidth(Style.PAGE_W - 2 * Style.PAD - 8)
  fs:SetHeight(Style.STATUS_H)
  fs:SetText("")
  return fs
end
