local Mock = require("wow_mock")

local REALM = "Icecrown-Alliance"
local NAME = "CraftProfitTestListings"
local RED = "|cffff4040"

local function load()
  Mock.reset()
  Mock.installUI()
  local ns = Mock.load({ "Util.lua", "Style.lua", "Listings.lua", "ListingsUI.lua" })
  ns.Listings.SetDB({ chars = { [REALM] = { Twink = true } } }, REALM, "Me")
  return ns
end

local function raw(count, buyout, seller, page, index)
  return { count = count, buyout = buyout, seller = seller, page = page, index = index }
end

-- Sorted rows (cheapest first) after Normalize + MarkUnderYou:
--   1 Flip   500 each  other seller, mistake listing (outlier)
--   2 Bob   2000 each  other seller, cheaper than ours (underYou)
--   3 ?     2200 each  seller name not loaded yet (underYou)
--   4 Me    3000 each  this character
--   5 Twink 3500 each  an alt
--   6 Zed   bid only
local function sampleRows(ns)
  local rows = ns.Listings.Normalize({
    raw(1, 500, "Flip", 0, 1),
    raw(2, 4000, "Bob", 0, 2),
    raw(1, 2200, nil, 0, 3),
    raw(5, 15000, "Me", 0, 4),
    raw(1, 3500, "Twink", 0, 5),
    raw(3, 0, "Zed", 0, 6),
  }, ns.Listings.MineSet(), ns.Listings.Ratio())
  return ns.Listings.MarkUnderYou(rows)
end

local function manyRows(ns, n)
  local raws = {}
  for i = 1, n do raws[i] = raw(1, 1000 + i, "Seller" .. i, 0, i) end
  return ns.Listings.Normalize(raws, ns.Listings.MineSet(), ns.Listings.Ratio())
end

return {
  builds_twelve_lines_and_a_faux_scroll_frame = function(T)
    local ns = load()
    local tbl = ns.ListingsUI.Create(UIParent, NAME)
    T.eq(tbl.frame, _G[NAME])
    T.eq(tbl.frame._parent, UIParent)
    T.eq(#tbl.lines, 12)
    local scroll = _G[NAME .. "Scroll"]
    T.ok(scroll, "scroll frame is named name..Scroll")
    T.eq(scroll._template, "FauxScrollFrameTemplate")
    T.eq(scroll._parent, tbl.frame)
    T.ok(scroll:GetScript("OnVerticalScroll"), "scrolls")
    for i = 1, 12 do
      T.eq(tbl.lines[i]:IsShown(), false, "line " .. i .. " hidden until it has a row")
      T.eq(tbl.lines[i]._kind, "Button")
    end
    tbl:SetTitle("Frostweave Bag")
    T.eq(tbl.title:GetText(), "Frostweave Bag")
  end,

  rows_render_you_and_under_you = function(T)
    local ns = load()
    local U = ns.Util
    local tbl = ns.ListingsUI.Create(UIParent, NAME)
    tbl:SetRows(sampleRows(ns))
    local L = tbl.lines

    -- Flip: another seller's mistake listing
    T.eq(L[1].qty:GetText(), "1")
    T.eq(L[1].price:GetText(), ns.Style.Money(500))
    T.eq(L[1].seller:GetText(), "Flip")
    T.eq(L[1].note:GetText(), U.ICON_GOLD .. " flip")

    -- Bob: cheaper than our listing
    T.eq(L[2].qty:GetText(), "2")
    T.eq(L[2].price:GetText(), ns.Style.Money(2000))
    T.eq(L[2].seller:GetText(), "Bob")
    T.eq(L[2].note:GetText(), RED .. U.ICON_WARN .. " under you|r")

    -- seller not loaded yet
    T.eq(L[3].seller:GetText(), "?")
    T.eq(L[3].note:GetText(), RED .. U.ICON_WARN .. " under you|r")

    -- this character, then an alt
    T.eq(L[4].qty:GetText(), "5")
    T.eq(L[4].price:GetText(), ns.Style.Money(3000))
    T.eq(L[4].seller:GetText(), "YOU")
    T.eq(L[4].note:GetText(), "")
    T.eq(L[5].seller:GetText(), "YOU (Twink)")
    T.eq(L[5].note:GetText(), "")

    -- bid only: no unit price to show
    T.eq(L[6].qty:GetText(), "3")
    T.eq(L[6].price:GetText(), "bid only")
    T.eq(L[6].seller:GetText(), "Zed")
    T.eq(L[6].note:GetText(), "")

    for i = 1, 6 do T.eq(L[i]:IsShown(), true, "line " .. i .. " shown") end
    for i = 7, 12 do T.eq(L[i]:IsShown(), false, "line " .. i .. " hidden") end
    T.eq(tbl.emptyText:IsShown(), false)
  end,

  stale_text_is_cleared_when_rows_shrink = function(T)
    local ns = load()
    local tbl = ns.ListingsUI.Create(UIParent, NAME)
    tbl:SetRows(sampleRows(ns))
    tbl:SetRows({ sampleRows(ns)[4] })
    T.eq(#tbl.lines, 12)
    T.eq(tbl.lines[1].seller:GetText(), "YOU")
    T.eq(tbl.lines[1]:IsShown(), true)
    for i = 2, 12 do T.eq(tbl.lines[i]:IsShown(), false) end
    -- an under-you mark from the old rows must not linger on the reused line
    T.eq(tbl.lines[1].note:GetText(), "")
  end,

  row_click_calls_back_with_row = function(T)
    local ns = load()
    local clicked = {}
    local tbl = ns.ListingsUI.Create(UIParent, NAME, function(row) clicked[#clicked + 1] = row end)
    local rows = sampleRows(ns)
    tbl:SetRows(rows)

    local line = tbl.lines[2]
    T.eq(line._scripts.OnClick ~= nil, true, "line has an OnClick")
    line:GetScript("OnClick")(line, "LeftButton")
    T.eq(#clicked, 1)
    T.eq(clicked[1], rows[2])

    tbl.lines[6]:GetScript("OnClick")(tbl.lines[6], "LeftButton")
    T.eq(clicked[2], rows[6])
    T.eq(clicked[2].unit, 0, "bid-only rows are reported too; the caller decides")

    -- a line that has no row (hidden) reports nothing
    tbl.lines[9]:GetScript("OnClick")(tbl.lines[9], "LeftButton")
    T.eq(#clicked, 2)
  end,

  row_click_without_callback_is_harmless = function(T)
    local ns = load()
    local tbl = ns.ListingsUI.Create(UIParent, NAME)
    tbl:SetRows(sampleRows(ns))
    tbl.lines[1]:GetScript("OnClick")(tbl.lines[1], "LeftButton")
  end,

  empty_rows_show_message = function(T)
    local ns = load()
    local tbl = ns.ListingsUI.Create(UIParent, NAME)
    tbl:SetRows({})
    T.eq(tbl.emptyText:GetText(), "No listings")
    T.eq(tbl.emptyText:IsShown(), true)
    for i = 1, 12 do T.eq(tbl.lines[i]:IsShown(), false) end

    tbl:SetRows(sampleRows(ns))
    T.eq(tbl.emptyText:IsShown(), false)

    -- nil (item never price-checked) reads as empty
    tbl:SetRows(nil)
    T.eq(tbl.emptyText:IsShown(), true)
    for i = 1, 12 do T.eq(tbl.lines[i]:IsShown(), false) end
  end,

  scroll_offset_picks_the_rows = function(T)
    local ns = load()
    local clicked
    local tbl = ns.ListingsUI.Create(UIParent, NAME, function(row) clicked = row end)
    local rows = manyRows(ns, 20)
    local updates = {}
    FauxScrollFrame_Update = function(frame, numItems, numToDisplay, itemHeight)
      updates[#updates + 1] = { frame = frame, n = numItems, shown = numToDisplay, h = itemHeight }
    end
    tbl:SetRows(rows)
    local scroll = _G[NAME .. "Scroll"]
    local last = updates[#updates]
    T.eq(last.frame, scroll)
    T.eq(last.n, 20)
    T.eq(last.shown, 12)
    T.ok(last.h and last.h > 0, "row height passed to the scroll frame")
    T.eq(tbl.lines[1].seller:GetText(), "Seller1")    -- offset is nil before the first scroll

    scroll.offset = 5
    tbl:Update()
    T.eq(tbl.lines[1].seller:GetText(), "Seller6")
    T.eq(tbl.lines[12].seller:GetText(), "Seller17")
    tbl.lines[3]:GetScript("OnClick")(tbl.lines[3], "LeftButton")
    T.eq(clicked, rows[8], "click maps through the scroll offset")

    -- last page: fewer rows than lines
    scroll.offset = 8
    tbl:Update()
    T.eq(tbl.lines[12].seller:GetText(), "Seller20")
    scroll.offset = 12                                   -- past the end: clamped
    tbl:Update()
    T.eq(tbl.lines[1].seller:GetText(), "Seller9")
    T.eq(tbl.lines[12].seller:GetText(), "Seller20")
  end,

  scroll_script_redraws_through_faux_scroll = function(T)
    local ns = load()
    local tbl = ns.ListingsUI.Create(UIParent, NAME)
    tbl:SetRows(manyRows(ns, 20))
    local scroll = _G[NAME .. "Scroll"]
    local args
    FauxScrollFrame_OnVerticalScroll = function(self, offset, height, update)
      args = { self = self, offset = offset, height = height }
      self.offset = 3                                    -- what the real one does
      update(self)
    end
    scroll:GetScript("OnVerticalScroll")(scroll, 48)
    T.eq(args.self, scroll)
    T.eq(args.offset, 48)
    T.ok(args.height and args.height > 0)
    T.eq(tbl.lines[1].seller:GetText(), "Seller4")
  end,

  never_calls_an_auction_api = function(T)
    local f = assert(io.open(Mock.root .. "ListingsUI.lua", "r"))
    local src = f:read("*a")
    f:close()
    for _, api in ipairs({ "PlaceAuctionBid", "StartAuction", "CancelAuction", "ClickAuctionSellItemButton" }) do
      T.eq(src:find(api, 1, true), nil, api .. " must not appear")
    end
  end,

  listings_columns_fit = function(T)
    local ns = load()
    local total = 0
    for _, col in ipairs(ns.ListingsUI.COLUMNS) do total = math.max(total, col.x + col.width) end
    T.ok(total <= ns.Style.RIGHT_W - 24, "columns end at " .. total)
    local tbl = ns.ListingsUI.Create(UIParent, NAME)
    T.eq(tbl.frame:GetWidth(), ns.Style.RIGHT_W)
    T.eq(tbl.lines[1]:GetHeight(), ns.Style.ROW_H)
    T.eq(#tbl.lines, ns.Style.VISIBLE)
  end,

  stack_total_column = function(T)
    local ns = load()
    local tbl = ns.ListingsUI.Create(UIParent, NAME)
    tbl:SetRows(sampleRows(ns))
    T.eq(tbl.lines[2].total:GetText(), ns.Style.Money(4000), "Bob's 2 for 40s")
    T.eq(tbl.lines[6].total:GetText(), "-", "bid only has no buyout")
  end,

  buy_mode_tags_deal = function(T)
    local ns = load()
    local buy = ns.ListingsUI.Create(UIParent, NAME .. "Buy", nil, { mode = "buy" })
    buy:SetRows(sampleRows(ns))
    T.ok(buy.lines[1].note:GetText():find("deal", 1, true), "mistake listing is a deal on CP Buy")
    T.ok(not buy.lines[1].note:GetText():find("flip", 1, true))
    local sell = ns.ListingsUI.Create(UIParent, NAME .. "Sell")
    sell:SetRows(sampleRows(ns))
    T.ok(sell.lines[1].note:GetText():find("flip", 1, true), "elsewhere it is still a flip")
  end,

  bought_row_greyed_in_buy_mode = function(T)
    local ns = load()
    local rows = sampleRows(ns)
    ns.Buyer = { IsBought = function(row) return row == rows[2] end }
    local buy = ns.ListingsUI.Create(UIParent, NAME .. "Buy", nil, { mode = "buy" })
    buy:SetRows(rows)
    T.eq(buy.lines[2].note:GetText(), "bought")
    T.ok(buy.lines[1].note:GetText() ~= "bought")
  end,

  set_selected_highlights_one_row = function(T)
    local ns = load()
    local rows = sampleRows(ns)
    local tbl = ns.ListingsUI.Create(UIParent, NAME)
    tbl:SetRows(rows)
    tbl:SetSelected(rows[3])
    for i = 1, 6 do
      T.eq(tbl.lines[i].selected:IsShown(), i == 3, "line " .. i)
    end
    tbl:SetSelected(nil)
    T.eq(tbl.lines[3].selected:IsShown(), false)
  end,

  title_with_icon = function(T)
    local ns = load()
    local tbl = ns.ListingsUI.Create(UIParent, NAME)
    tbl:SetTitle("Frostweave Bag: all listings", "Interface\\Icons\\INV_Misc_Bag_10")
    T.eq(tbl.title:GetText(), "Frostweave Bag: all listings")
    T.eq(tbl.icon._texture, "Interface\\Icons\\INV_Misc_Bag_10")
    T.eq(tbl.icon:IsShown(), true)
    tbl:SetTitle("")
    T.eq(tbl.icon:IsShown(), false)
  end,

  visible_rows_option = function(T)
    local ns = load()
    local tbl = ns.ListingsUI.Create(UIParent, NAME .. "Short", nil, { visible = 10 })
    T.eq(#tbl.lines, 10)
    T.eq(tbl.frame:GetHeight(), 20 + 18 + 10 * ns.Style.ROW_H)
    tbl:SetRows(manyRows(ns, 15))
    T.eq(tbl.lines[10]:IsShown(), true)
  end,
}
