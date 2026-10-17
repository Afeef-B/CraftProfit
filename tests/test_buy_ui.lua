local Mock = require("wow_mock")

local REALM = "Icecrown-Alliance"
local CLOTH, CLOTH_NAME = 33470, "Frostweave Cloth"
local BOLT, BOLT_NAME = 41510, "Bolt of Frostweave"
local BAG, BAG_NAME = 41599, "Frostweave Bag"
local THREAD, THREAD_NAME = 38426, "Eternium Thread"

local function silver(s) return s * 100 end

local function auction(id, name, seller, count, unit)
  return { id = id, name = name, count = count, buyout = count * unit, seller = seller }
end
local function cloth(seller, count, unit) return auction(CLOTH, CLOTH_NAME, seller, count, unit) end

local function setup(auctions)
  Mock.reset()
  Mock.installUI()
  local ns = Mock.load({
    "Util.lua", "Style.lua", "Profit.lua", "Prices.lua", "Recipes.lua", "Scanner.lua", "Listings.lua",
    "Lists.lua", "Buyer.lua", "UI.lua", "ListingsUI.lua", "Tabs.lua", "Flip.lua", "Buy.lua", "BuyUI.lua",
    "Sell.lua", "SellUI.lua",
  })
  local db = { cut = 0.05 }
  ns.db = db
  ns.Prices.SetDB(db, REALM)
  ns.Recipes.SetDB({})
  ns.Scanner.SetDB(db)
  ns.Listings.SetDB(db, REALM, "Me")
  ns.Sell.SetDB(db)
  hooksecurefunc("QueryAuctionItems", ns.Scanner.OnQuery)
  Mock.items[CLOTH] = { name = CLOTH_NAME, maxStack = 20 }
  Mock.items[BOLT] = { name = BOLT_NAME, maxStack = 20 }
  Mock.ah.auctions = auctions or {}
  Mock.money = 1000 * 10000
  assert(ns.Tabs.Ensure())
  return ns
end

local function click(frame) frame:GetScript("OnClick")(frame, "LeftButton") end
local function openBuy() click(AuctionFrameTab6) end
local function openSell() click(AuctionFrameTab4) end

local function search(ns, text)
  CraftProfitBuySearch:SetText(text)
  CraftProfitBuySearch:GetScript("OnEnterPressed")(CraftProfitBuySearch)
  assert(Mock.pump(ns), "price check finished")
end

local function spy(tbl, name)
  local calls, orig = {}, tbl[name]
  tbl[name] = function(...) calls[#calls + 1] = { ... } return orig(...) end
  return calls
end

return {
  build_once_on_page_shown = function(T)
    local ns = setup()
    T.eq(CraftProfitBuySearch, nil, "nothing built before the page is shown")
    openBuy()
    T.ok(CraftProfitBuySearch and CraftProfitBuyCheapest and CraftProfitBuyRow, "built")
    local first = CraftProfitBuyCheapest
    openSell()
    openBuy()
    T.ok(CraftProfitBuyCheapest == first, "built once")
    T.eq(AuctionFrameTab6:GetText(), "CP Buy")
  end,

  buy_cheapest_label_and_click = function(T)
    local ns = setup({ cloth("A", 5, silver(9)), cloth("B", 20, silver(8)) })
    openBuy()
    T.eq(CraftProfitBuyCheapest:GetText(), "Search an item first")
    T.eq(CraftProfitBuyCheapest:IsEnabled(), false)
    local calls = spy(ns.Buy, "BuyCheapest")
    search(ns, CLOTH_NAME)
    T.eq(CraftProfitBuyCheapest:GetText(), "Buy cheapest: 20 for " .. ns.Style.Money(20 * silver(8)))
    T.eq(CraftProfitBuyCheapest:IsEnabled(), true)
    for _, e in ipairs({ "LISTINGS_UPDATED", "BUY_CHANGED", "BUYER_CHANGED", "SCAN_FINISHED" }) do ns.Fire(e, CLOTH) end
    T.eq(#calls, 0, "events never buy")
    click(CraftProfitBuyCheapest)
    T.eq(#calls, 1)
    T.eq(#Mock.bought, 1)
    T.eq(Mock.bought[1].amount, 20 * silver(8))
  end,

  done_disables_button = function(T)
    local ns = setup({ cloth("A", 5, silver(9)), cloth("B", 5, silver(10)) })
    openBuy()
    search(ns, CLOTH_NAME)
    CraftProfitBuyNeed:SetText("5")
    click(CraftProfitBuyCheapest)
    T.eq(CraftProfitBuyCheapest:GetText(), "Done (bought 5)")
    T.eq(CraftProfitBuyCheapest:IsEnabled(), false)
  end,

  buy_row_needs_selection = function(T)
    local ns = setup({ cloth("A", 5, silver(9)), cloth("Me", 5, silver(7)) })
    openBuy()
    search(ns, CLOTH_NAME)
    T.eq(CraftProfitBuyRow:IsEnabled(), false, "nothing selected")
    local tbl = ns.BuyUI.listings
    click(tbl.lines[1])                          -- my own listing (7s)
    T.eq(CraftProfitBuyRow:IsEnabled(), false, "own listing can't be bought")
    click(tbl.lines[2])                          -- A's 5 @ 9s
    T.eq(CraftProfitBuyRow:IsEnabled(), true)
    T.eq(CraftProfitBuyRow:GetText(), "Buy this (" .. ns.Style.Money(5 * silver(9)) .. ")")
    click(CraftProfitBuyRow)
    T.eq(#Mock.bought, 1)
    T.eq(Mock.bought[1].auction.seller, "A")
  end,

  materials_lines_have_need = function(T)
    local ns = setup({ auction(BOLT, BOLT_NAME, "Bob", 10, silver(80)) })
    local recipes = ns.Recipes.All()
    recipes[BAG] = { name = BAG_NAME, made = 1, reagents = {
      { id = BOLT, name = BOLT_NAME, count = 2 }, { id = THREAD, name = THREAD_NAME, count = 1 } } }
    ns.Recipes.SetTracked(BAG, true)
    Mock.bags[0] = { [1] = { id = BOLT, name = BOLT_NAME, count = 2 } }
    openBuy()
    click(CraftProfitBuyMaterialsFor)
    T.ok(Mock.menu and Mock.menu[1].text == BAG_NAME, "the tracked recipe is offered")
    Mock.menu[1].func()
    CraftProfitBuyCrafts:SetText("3")
    local line = ns.BuyUI.materials[1]
    T.ok(line.text:GetText():find(BOLT_NAME, 1, true))
    T.ok(line.text:GetText():find("2/6", 1, true), line.text:GetText())
    click(line)
    T.ok(Mock.pump(ns))
    T.eq((ns.Buy.Current()), BOLT)
    T.eq(ns.Buy.Need(), 4, "6 needed, 2 in the bags")
  end,

  shift_click_only_on_buy_page_without_chat = function(T)
    local ns = setup({ cloth("A", 5, silver(9)) })
    local calls = spy(ns.Buy, "SearchLink")
    local link = Mock.Link(CLOTH, CLOTH_NAME)
    openBuy()
    ChatEdit_InsertLink(link)
    T.eq(#calls, 1, "searched")
    Mock.chatOpen = true
    ChatEdit_InsertLink(link)
    T.eq(#calls, 1, "the link went to chat")
    T.eq(#Mock.inserted, 1)
    Mock.chatOpen = false
    openSell()
    ChatEdit_InsertLink(link)
    T.eq(#calls, 1, "not on another page")
  end,

  status_only_while_shown = function(T)
    local ns = setup()
    openBuy()
    ns.Fire("PAGE_STATUS", "hello")
    T.eq(ns.BuyUI.status:GetText(), "hello")
    openSell()
    ns.Fire("PAGE_STATUS", "elsewhere")
    T.eq(ns.BuyUI.status:GetText(), "hello", "not while hidden")
  end,

  buy_layout_fits = function(T)
    local ns = setup()
    openBuy()
    local S, L = ns.Style, ns.BuyUI.layout
    local names = {}
    for name in pairs(L) do names[#names + 1] = name end
    T.ok(#names >= 5, "search, materials, buy, listings, buyrow")
    local bottom = S.PAGE_H - S.PAD - S.STATUS_H
    for _, name in ipairs(names) do
      local r = L[name]
      T.ok(r.x >= S.PAD and r.x + r.w <= S.PAGE_W - S.PAD, name .. " fits the width")
      T.ok(r.y >= S.PAD and r.y + r.h <= bottom, name .. " ends above the status bar")
    end
    for i = 1, #names do
      for j = i + 1, #names do
        local a, b = L[names[i]], L[names[j]]
        local apart = a.x + a.w <= b.x or b.x + b.w <= a.x or a.y + a.h <= b.y or b.y + b.h <= a.y
        T.ok(apart, names[i] .. " and " .. names[j] .. " do not overlap")
      end
    end
  end,

  need_box_follows_buy_without_resetting_the_count = function(T)
    local ns = setup({ auction(BOLT, BOLT_NAME, "Bob", 2, silver(80)), auction(BOLT, BOLT_NAME, "Kim", 2, silver(90)) })
    local recipes = ns.Recipes.All()
    recipes[BAG] = { name = BAG_NAME, made = 1, reagents = { { id = BOLT, name = BOLT_NAME, count = 4 } } }
    ns.Recipes.SetTracked(BAG, true)
    openBuy()
    click(CraftProfitBuyMaterialsFor)
    Mock.menu[1].func()
    click(ns.BuyUI.materials[1])
    T.ok(Mock.pump(ns))
    T.eq(CraftProfitBuyNeed:GetText(), "4", "the box shows the need the click set")
    click(CraftProfitBuyCheapest)
    T.eq(ns.Buy.Need(), 2, "2 of 4 bought")
    ns.BuyUI.Update()
    T.eq(ns.Buy.Need(), 2, "redrawing the box does not start the count over")
    T.eq(CraftProfitBuyNeed:GetText(), "4")
    -- a search of another item clears the need and the box
    Mock.items[CLOTH] = { name = CLOTH_NAME }
    search(ns, CLOTH_NAME)
    T.eq(ns.Buy.Need(), nil)
    T.eq(CraftProfitBuyNeed:GetText(), "")
  end,

  replies_stay_on_the_status_line_with_a_need = function(T)
    local ns = setup({ cloth("A", 5, silver(9)) })
    openBuy()
    search(ns, CLOTH_NAME)
    CraftProfitBuyNeed:SetText("40")
    Mock.money = 10
    click(CraftProfitBuyCheapest)
    local zero = "Bought 0 of 40 (spent " .. ns.Style.Money(0) .. ")"
    T.eq(ns.BuyUI.status:GetText(), "Not enough gold - " .. zero)
    ns.Fire("BUY_CHANGED")                     -- a redraw keeps the reply
    T.eq(ns.BuyUI.status:GetText(), "Not enough gold - " .. zero)
    -- a purchase: the reply and the new count
    Mock.money = 1000 * 10000
    click(CraftProfitBuyCheapest)
    T.eq(ns.BuyUI.status:GetText(), "Bid placed for " .. ns.Util.FormatMoney(5 * silver(9))
      .. " - Bought 5 of 40 (spent " .. ns.Style.Money(5 * silver(9)) .. ")")
  end,

  recipe_label_fits_its_button = function(T)
    local ns = setup()
    local long = "Mystic Frostwoven Shoulderpads of the Long Name"
    ns.Recipes.All()[BAG] = { name = long, made = 1, reagents = { { id = BOLT, name = BOLT_NAME, count = 2 } } }
    ns.Recipes.SetTracked(BAG, true)
    openBuy()
    click(CraftProfitBuyMaterialsFor)
    Mock.menu[1].func()
    local label = ns.BuyUI.materialsLabel
    T.ok(label:GetText():find(long, 1, true))
    T.ok(label:GetWidth() > 0 and label:GetWidth() <= CraftProfitBuyMaterialsFor:GetWidth() - 16,
      "the label is cut to the button, it does not spill over the Crafts box")
    T.eq(CraftProfitBuyMaterialsFor:GetText(), "", "the button's own label is not used")
  end,

  more_materials_than_lines_says_so = function(T)
    local ns = setup()
    local reagents = {}
    for i = 1, 8 do reagents[i] = { id = 50000 + i, name = "Thing " .. i, count = 1 } end
    ns.Recipes.All()[BAG] = { name = BAG_NAME, made = 1, reagents = reagents }
    ns.Recipes.SetTracked(BAG, true)
    openBuy()
    click(CraftProfitBuyMaterialsFor)
    Mock.menu[1].func()
    local lines = ns.BuyUI.materials
    T.ok(lines[5].material, "the first five are materials")
    T.eq(lines[#lines].material, nil, "the last line is not a material")
    T.ok(lines[#lines].text:GetText():find("and 3 more", 1, true), lines[#lines].text:GetText())
  end,
}
