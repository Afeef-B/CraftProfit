local Mock = require("wow_mock")

local function load()
  Mock.reset()
  Mock.installUI()
  return Mock.load({ "Util.lua", "Style.lua", "Tabs.lua" })
end

-- What another addon (Auctionator) does: a named tab with the next id.
local function addForeignTab(n)
  local tab = CreateFrame("Button", "AuctionFrameTab" .. n, AuctionFrame, "AuctionTabTemplate")
  tab:SetID(n)
  tab:SetPoint("TOPLEFT", _G["AuctionFrameTab" .. (n - 1)], "TOPRIGHT", -8, 0)
  return tab
end

local function anchor(frame, point)
  for _, p in ipairs(frame._points or {}) do
    if p.point == point then return p end
  end
  return nil
end

-- A real click: the tab's own OnClick script.
local function click(tab)
  tab:GetScript("OnClick")(tab)
end

local function recordShown(ns)
  local shown = {}
  ns.On("PAGE_SHOWN", function(key) shown[#shown + 1] = key end)
  return shown
end

return {
  tabs_after_blizzard = function(T)
    local ns = load()
    T.eq(ns.Tabs.Ensure(), true)
    local sell, auctions = AuctionFrameTab4, AuctionFrameTab5
    T.ok(sell and auctions, "tabs created")
    T.eq(AuctionFrameTab6:GetText(), "CP Buy", "CP Buy comes after CP Auctions")
    T.eq(AuctionFrameTab7, nil)
    T.eq(sell:GetID(), 4)
    T.eq(auctions:GetID(), 5)
    T.eq(sell:GetText(), "CP Sell")
    T.eq(auctions:GetText(), "CP Auctions")
    T.eq(sell._template, "AuctionTabTemplate")
    T.eq(sell._parent, AuctionFrame)
    T.eq(Mock.numTabs, 6)
    T.eq(AuctionFrame.numTabs, 6)

    local a = anchor(sell, "TOPLEFT")
    T.ok(a, "tab 4 anchored")
    T.eq(a.rel, AuctionFrameTab3)
    T.eq(a.relPoint, "TOPRIGHT")
    T.eq(a.x, -8)
    T.eq(a.y, 0)
    local b = anchor(auctions, "TOPLEFT")
    T.eq(b.rel, sell)
    T.eq(b.relPoint, "TOPRIGHT")
    T.eq(b.x, -8)

    -- the two page frames: hidden children of AuctionFrame with a backdrop
    local sellPage, auctionsPage = ns.Tabs.Page("sell"), ns.Tabs.Page("auctions")
    T.eq(sellPage, CraftProfitSellPage)
    T.eq(auctionsPage, CraftProfitAuctionsPage)
    T.eq(ns.Tabs.Page("bogus"), nil)
    for _, page in ipairs({ sellPage, auctionsPage }) do
      T.eq(page._parent, AuctionFrame)
      T.eq(page:IsShown(), false)
      T.ok(page._backdrop, "backdrop set")
      local tl = anchor(page, "TOPLEFT")
      T.eq(tl.rel, AuctionFrame)
      T.eq(tl.relPoint, "TOPLEFT")
      T.eq(tl.x, 20)
      T.eq(tl.y, -72)
      local br = anchor(page, "BOTTOMRIGHT")
      T.eq(br.rel, AuctionFrame)
      T.eq(br.relPoint, "BOTTOMRIGHT")
      T.eq(br.x, -10)
      T.eq(br.y, 40)
    end
    T.eq(ns.Tabs.IsShown("sell"), false)
    T.eq(ns.Tabs.IsShown("auctions"), false)
  end,

  tabs_after_auctionator = function(T)
    local ns = load()
    addForeignTab(4)
    addForeignTab(5)
    addForeignTab(6)
    PanelTemplates_SetNumTabs(AuctionFrame, 6)
    T.eq(ns.Tabs.Ensure(), true)
    T.eq(AuctionFrameTab7:GetID(), 7)
    T.eq(AuctionFrameTab8:GetID(), 8)
    T.eq(AuctionFrameTab7:GetText(), "CP Sell")
    T.eq(AuctionFrameTab8:GetText(), "CP Auctions")
    T.eq(AuctionFrameTab9:GetText(), "CP Buy")
    T.eq(Mock.numTabs, 9)
    T.eq(anchor(AuctionFrameTab7, "TOPLEFT").rel, AuctionFrameTab6)
    T.eq(anchor(AuctionFrameTab7, "TOPLEFT").relPoint, "TOPRIGHT")
    T.eq(anchor(AuctionFrameTab7, "TOPLEFT").x, -8)
    T.eq(anchor(AuctionFrameTab8, "TOPLEFT").rel, AuctionFrameTab7)

    -- clicking one of ours is told apart from the other addon's tab 4
    local shown = recordShown(ns)
    click(AuctionFrameTab8)
    T.eq(ns.Tabs.IsShown("auctions"), true)
    T.eq(#shown, 1)
    T.eq(shown[1], "auctions")
    click(AuctionFrameTab4)
    T.eq(ns.Tabs.IsShown("auctions"), false)
    T.eq(#shown, 1)
  end,

  ensure_is_idempotent_and_waits_for_frame = function(T)
    local ns = load()
    local frame = AuctionFrame
    AuctionFrame = nil                       -- Blizzard_AuctionUI not loaded yet
    T.eq(ns.Tabs.Ensure(), false)
    T.eq(AuctionFrameTab4, nil)
    T.eq(CraftProfitSellPage, nil)
    T.eq(ns.Tabs.Page("sell"), nil)
    T.eq(ns.Tabs.IsShown("sell"), false)
    ns.Tabs.Select("sell")                   -- nothing to select yet
    T.eq(Mock.lastTab, nil)

    AuctionFrame = frame
    T.eq(ns.Tabs.Ensure(), true)
    local sell = AuctionFrameTab4
    local page = CraftProfitSellPage
    T.eq(ns.Tabs.Ensure(), true)
    T.eq(ns.Tabs.Ensure(), true)
    T.eq(AuctionFrameTab4, sell, "same tab object")
    T.eq(CraftProfitSellPage, page, "same page object")
    T.eq(AuctionFrameTab7, nil, "no extra tabs")
    T.eq(Mock.numTabs, 6)

    -- hooked once: a click fires one event, not one per Ensure call
    local shown = recordShown(ns)
    click(sell)
    T.eq(#shown, 1)
  end,

  clicking_switches_pages_and_fires = function(T)
    local ns = load()
    ns.Tabs.Ensure()
    local shown = recordShown(ns)

    click(AuctionFrameTab4)
    T.eq(Mock.lastTab, 4, "Blizzard handler still ran")
    T.eq(ns.Tabs.IsShown("sell"), true)
    T.eq(ns.Tabs.IsShown("auctions"), false)
    T.eq(table.concat(shown, ","), "sell")

    click(AuctionFrameTab5)
    T.eq(Mock.lastTab, 5)
    T.eq(ns.Tabs.IsShown("sell"), false)
    T.eq(ns.Tabs.IsShown("auctions"), true)
    T.eq(CraftProfitSellPage:IsShown(), false)
    T.eq(CraftProfitAuctionsPage:IsShown(), true)
    T.eq(table.concat(shown, ","), "sell,auctions")

    -- any of Blizzard's tabs hides both pages and fires nothing
    for id = 1, 3 do
      click(AuctionFrameTab5)
      click(_G["AuctionFrameTab" .. id])
      T.eq(Mock.lastTab, id)
      T.eq(ns.Tabs.IsShown("sell"), false)
      T.eq(ns.Tabs.IsShown("auctions"), false)
    end
    T.eq(#shown, 5)                          -- sell, auctions, then auctions x3

    -- clicking our tab again keeps the page and tells listeners
    click(AuctionFrameTab4)
    click(AuctionFrameTab4)
    T.eq(ns.Tabs.IsShown("sell"), true)
    T.eq(#shown, 7)
  end,

  is_shown_means_visible_not_just_not_hidden = function(T)
    local ns = load()
    ns.Tabs.Ensure()
    click(AuctionFrameTab4)
    T.eq(ns.Tabs.IsShown("sell"), true)

    -- the Auction House closes; our page keeps its own shown flag
    AuctionFrame:Hide()
    T.eq(CraftProfitSellPage:IsShown(), true)
    T.eq(ns.Tabs.IsShown("sell"), false, "a page inside a closed AH is not shown")
    T.eq(ns.Tabs.IsShown("auctions"), false)

    -- it reopens on the same tab
    AuctionFrame:Show()
    T.eq(ns.Tabs.IsShown("sell"), true)
    T.eq(ns.Tabs.IsShown("auctions"), false)
  end,

  select_switches = function(T)
    local ns = load()
    ns.Tabs.Ensure()
    local shown = recordShown(ns)

    ns.Tabs.Select("auctions")
    T.eq(Mock.lastTab, 5)
    T.eq(Mock.selectedTab, 5)
    T.eq(ns.Tabs.IsShown("auctions"), true)
    T.eq(ns.Tabs.IsShown("sell"), false)

    ns.Tabs.Select("sell")
    T.eq(Mock.lastTab, 4)
    T.eq(ns.Tabs.IsShown("sell"), true)
    T.eq(ns.Tabs.IsShown("auctions"), false)
    T.eq(table.concat(shown, ","), "auctions,sell")

    ns.Tabs.Select("bogus")                  -- unknown key: nothing happens
    T.eq(Mock.lastTab, 4)
    T.eq(#shown, 2)
  end,

  three_tabs_in_order = function(T)
    local ns = load()
    T.eq(ns.Tabs.Ensure(), true)
    T.eq(AuctionFrameTab4:GetText(), "CP Sell")
    T.eq(AuctionFrameTab5:GetText(), "CP Auctions")
    T.eq(AuctionFrameTab6:GetText(), "CP Buy")
    T.eq(anchor(AuctionFrameTab6, "TOPLEFT").rel, AuctionFrameTab5)
    T.eq(ns.Tabs.Page("buy"), CraftProfitBuyPage)
    T.eq(ns.Tabs.Ensure(), true)
    T.eq(AuctionFrameTab7, nil, "no duplicates on a second Ensure")
    local shown = recordShown(ns)
    click(AuctionFrameTab6)
    T.eq(shown[#shown], "buy")
    T.eq(ns.Tabs.IsShown("buy"), true)
    T.eq(ns.Tabs.IsShown("sell"), false)
  end,
}
