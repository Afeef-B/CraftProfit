-- Two extra Auction House tabs ("CP Sell", "CP Auctions") and the empty page
-- frame behind each. SellUI and AuctionsUI build into Tabs.Page(key) when
-- ns.Fire("PAGE_SHOWN", key) says the page was opened.
local addonName, ns = ...

ns.Tabs = {}
local Tabs = ns.Tabs

local KEYS = { "sell", "auctions" }
local LABEL = { sell = "CP Sell", auctions = "CP Auctions" }
local PAGE_NAME = { sell = "CraftProfitSellPage", auctions = "CraftProfitAuctionsPage" }

local tabs, pages, tabIDs = {}, {}, {}
local ready = false

local function createTab(key, id, previous)
  local tab = CreateFrame("Button", "AuctionFrameTab" .. id, AuctionFrame, "AuctionTabTemplate")
  tab:SetID(id)
  tab:SetText(LABEL[key])
  tab:SetPoint("TOPLEFT", previous, "TOPRIGHT", -8, 0)
  -- The template resizes a tab when it is shown, which was before it had text.
  PanelTemplates_TabResize(tab, 0)
  tabs[key], tabIDs[key] = tab, id
  return tab
end

local function createPage(key)
  local page = CreateFrame("Frame", PAGE_NAME[key], AuctionFrame)
  page:SetPoint("TOPLEFT", AuctionFrame, "TOPLEFT", 20, -72)
  page:SetPoint("BOTTOMRIGHT", AuctionFrame, "BOTTOMRIGHT", -10, 40)
  page:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  page:SetBackdropColor(0.05, 0.05, 0.08, 1)
  page:EnableMouse(true)
  page:Hide()
  pages[key] = page
  return page
end

-- Runs after Blizzard's handler, which only knows its own tabs 1 to 3 and
-- ignores any other id, so a click on ours is ours to finish.
local function onTabClick(self)
  local id = self and self:GetID()
  local active
  for _, key in ipairs(KEYS) do
    if tabIDs[key] == id then active = key end
  end
  for _, key in ipairs(KEYS) do
    if key ~= active then pages[key]:Hide() end
  end
  if active then
    pages[active]:Show()
    ns.Fire("PAGE_SHOWN", active)
  end
end

-- Builds the tabs and pages once the Auction House frame exists. Safe to call
-- repeatedly; false means the frame or its tabs are not there yet.
function Tabs.Ensure()
  if ready then return true end
  if not AuctionFrame then return false end

  -- Other addons (Auctionator) add tabs after Blizzard's three; take the next free ids.
  local n = 1
  while _G["AuctionFrameTab" .. n] do n = n + 1 end
  if n == 1 then return false end            -- Blizzard's own tabs are not built yet

  local previous = _G["AuctionFrameTab" .. (n - 1)]
  for i, key in ipairs(KEYS) do
    previous = createTab(key, n + i - 1, previous)
    createPage(key)
  end
  PanelTemplates_SetNumTabs(AuctionFrame, n + #KEYS - 1)

  hooksecurefunc("AuctionFrameTab_OnClick", onTabClick)
  ready = true
  return true
end

function Tabs.Page(key)
  return pages[key]
end

function Tabs.IsShown(key)
  local page = pages[key]
  return page ~= nil and page:IsShown() and true or false
end

-- Same as clicking the tab.
function Tabs.Select(key)
  local tab = tabs[key]
  if tab then AuctionFrameTab_OnClick(tab) end
end
