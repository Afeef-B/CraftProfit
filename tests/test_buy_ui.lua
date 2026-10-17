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
  ns.Lists.SetDB(db)
  hooksecurefunc("QueryAuctionItems", ns.Scanner.OnQuery)
  Mock.items[CLOTH] = { name = CLOTH_NAME, maxStack = 20 }
  Mock.items[BOLT] = { name = BOLT_NAME, maxStack = 20 }
  Mock.ah.auctions = auctions or {}
  Mock.money = 1000 * 10000
  assert(ns.Tabs.Ensure())
  return ns
end

local function click(frame) frame:GetScript("OnClick")(frame, "LeftButton") end
local function rightClick(frame) frame:GetScript("OnClick")(frame, "RightButton") end
local function openBuy() click(AuctionFrameTab6) end
local function openSell() click(AuctionFrameTab4) end

local function search(ns, text)
  CraftProfitBuySearch:SetText(text)
  CraftProfitBuySearch:GetScript("OnEnterPressed")(CraftProfitBuySearch)
  assert(Mock.pump(ns), "search finished")
end

-- Texts of the menu EasyMenu was last given.
local function menuTexts()
  local texts = {}
  for i, entry in ipairs(Mock.menu or {}) do texts[i] = entry.text end
  return table.concat(texts, " | ")
end

local function menuEntry(text)
  for _, entry in ipairs(Mock.menu or {}) do
    if entry.text == text then return entry end
  end
end

local function shownTables(ns)
  local shown = {}
  for _, key in ipairs({ "results", "item", "list" }) do
    if ns.BuyUI[key].frame:IsShown() then shown[#shown + 1] = key end
  end
  return table.concat(shown, " ")
end

local GLACIAL, GLACIAL_NAME = 41600, "Glacial Bag"
local function trackGlacial(ns)
  ns.Recipes.All()[GLACIAL] = { name = GLACIAL_NAME, made = 1, reagents = { { id = CLOTH, name = CLOTH_NAME, count = 5 } } }
  ns.Recipes.SetTracked(GLACIAL, true)
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
    T.ok(CraftProfitBuySearch and CraftProfitBuyCheapest and CraftProfitBuyOne, "built")
    T.ok(CraftProfitBuyLists and CraftProfitBuyToList and CraftProfitBuyBack, "the bar")
    T.eq(CraftProfitBuyLists:GetText(), "Lists v")
    T.eq(CraftProfitBuyBack:GetText(), "< Back")
    local first = CraftProfitBuyCheapest
    openSell()
    openBuy()
    T.ok(CraftProfitBuyCheapest == first, "built once")
    T.eq(AuctionFrameTab6:GetText(), "CP Buy")
    T.eq(shownTables(ns), "", "nothing searched yet")
  end,

  results_view_lists_items = function(T)
    local ns = setup({
      cloth("Kim", 20, silver(9)), auction(BOLT, BOLT_NAME, "Bob", 5, silver(80)), auction(BAG, BAG_NAME, "Ann", 1, 4000000),
    })
    openBuy()
    search(ns, "frostweave")
    T.eq(shownTables(ns), "results")
    local tbl = ns.BuyUI.results
    T.eq(tbl.title:GetText(), 'Results for "frostweave": 3 items')
    T.eq(tbl.lines[1].name:GetText(), BOLT_NAME)
    T.eq(tbl.lines[2].name:GetText(), BAG_NAME)
    local line = tbl.lines[3]
    T.eq(line.name:GetText(), CLOTH_NAME)
    T.eq(line.each:GetText(), ns.Style.Money(silver(9)))
    T.eq(line.auctions:GetText(), "1")
    T.eq(line.qty:GetText(), "20")
    T.eq(line.seen:GetText(), "now")
    T.ok(line.icon, "an icon per line")
    T.eq(CraftProfitBuyCheapest:IsShown(), false, "no buy buttons on the results")
    T.eq(ns.BuyUI.hint:IsShown(), true)
  end,

  click_result_opens_item_view = function(T)
    local ns = setup({ cloth("Kim", 20, silver(9)), auction(BOLT, BOLT_NAME, "Bob", 5, silver(80)) })
    openBuy()
    search(ns, "frostweave")
    T.eq(CraftProfitBuyBack:IsEnabled(), false)
    click(ns.BuyUI.results.lines[2])          -- the cloth
    T.ok(Mock.pump(ns))
    T.eq(shownTables(ns), "item")
    T.eq(ns.BuyUI.item.title:GetText(), CLOTH_NAME)
    T.eq(CraftProfitBuyBack:IsEnabled(), true)
    T.eq(CraftProfitBuyCheapest:IsShown(), true)
    click(CraftProfitBuyBack)
    T.eq(shownTables(ns), "results")
    T.eq(CraftProfitBuyBack:IsEnabled(), false)
  end,

  item_view_groups_listings = function(T)
    local ns = setup({
      cloth("A", 20, silver(9)), cloth("B", 20, silver(9)), cloth("C", 20, silver(9)), cloth("D", 5, silver(10)),
    })
    openBuy()
    search(ns, CLOTH_NAME)
    local tbl = ns.BuyUI.item
    local line = tbl.lines[1]
    T.eq(line.stack:GetText(), "20")
    T.eq(line.auctions:GetText(), "3")
    T.eq(line.each:GetText(), ns.Style.Money(silver(9)))
    T.eq(line.total:GetText(), ns.Style.Money(20 * silver(9)))
    T.eq(line.seller:GetText(), "A +2")
    T.eq(tbl.lines[2].stack:GetText(), "5")
    T.eq(tbl.lines[2].seller:GetText(), "D")
    T.eq(tbl.lines[3]:IsShown(), false)
  end,

  buy_one_buys_one_stack = function(T)
    local ns = setup({ cloth("A", 20, silver(9)), cloth("B", 20, silver(9)), cloth("C", 20, silver(9)) })
    openBuy()
    search(ns, CLOTH_NAME)
    T.eq(CraftProfitBuyOne:IsEnabled(), false, "nothing selected")
    T.eq(CraftProfitBuyOne:GetText(), "Buy one")
    local tbl = ns.BuyUI.item
    click(tbl.lines[1])
    T.eq(tbl.lines[1].selected:IsShown(), true)
    T.eq(CraftProfitBuyOne:IsEnabled(), true)
    T.eq(CraftProfitBuyOne:GetText(), "Buy one (" .. ns.Style.Money(20 * silver(9)) .. ")")
    local calls = spy(ns.Buy, "BuyGroup")
    for _, e in ipairs({ "LISTINGS_UPDATED", "BUY_CHANGED", "BUYER_CHANGED", "SCAN_FINISHED", "LISTS_CHANGED" }) do
      ns.Fire(e, CLOTH)
    end
    T.eq(#calls, 0, "events never buy")
    T.eq(#Mock.bought, 0)
    click(CraftProfitBuyOne)
    T.eq(#calls, 1)
    T.eq(#Mock.bought, 1)
    T.eq(tbl.lines[1].auctions:GetText(), "2", "one stack left the group")
    T.ok(Mock.pump(ns), "the post-buy check")
    T.eq(tbl.lines[1].auctions:GetText(), "2")
    T.eq(tbl.lines[1].selected:IsShown(), true, "the group stays selected")
  end,

  own_group_cannot_be_bought = function(T)
    local ns = setup({ cloth("Me", 20, silver(7)), cloth("A", 20, silver(9)) })
    openBuy()
    search(ns, CLOTH_NAME)
    local tbl = ns.BuyUI.item
    T.eq(tbl.lines[1].seller:GetText(), "YOU")
    click(tbl.lines[1])
    T.eq(CraftProfitBuyOne:IsEnabled(), false, "own listing can't be bought")
    click(tbl.lines[2])
    T.eq(CraftProfitBuyOne:IsEnabled(), true)
    click(CraftProfitBuyOne)
    T.eq(Mock.bought[1].auction.seller, "A")
  end,

  buy_cheapest_and_need = function(T)
    local ns = setup({ cloth("A", 5, silver(9)), cloth("B", 20, silver(8)) })
    openBuy()
    local calls = spy(ns.Buy, "BuyCheapest")
    search(ns, CLOTH_NAME)
    T.eq(CraftProfitBuyCheapest:GetText(), "Buy cheapest: 20 for " .. ns.Style.Money(20 * silver(8)))
    T.eq(CraftProfitBuyCheapest:IsEnabled(), true)
    CraftProfitBuyNeed:SetText("5")
    T.eq(CraftProfitBuyCheapest:GetText(), "Buy cheapest: 5 for " .. ns.Style.Money(5 * silver(9)))
    click(CraftProfitBuyCheapest)
    T.eq(#calls, 1)
    T.eq(#Mock.bought, 1)
    T.eq(CraftProfitBuyCheapest:GetText(), "Done (bought 5)")
    T.eq(CraftProfitBuyCheapest:IsEnabled(), false)
  end,

  lists_menu_entries = function(T)
    local ns = setup()
    trackGlacial(ns)
    ns.Lists.Create("Cloth run")
    openBuy()
    click(CraftProfitBuyLists)
    T.eq(menuTexts(), "Glacial Bag materials | Cloth run | New list... | Delete Cloth run")
    menuEntry("Glacial Bag materials").func()
    T.eq(shownTables(ns), "list")
    T.eq(ns.BuyUI.list.title:GetText(), "Glacial Bag materials")
    click(CraftProfitBuyLists)
    T.eq(menuEntry("Glacial Bag materials").checked, true, "the list shown")
    menuEntry("New list...").func()
    T.eq(Mock.popup, "CRAFTPROFIT_NEW_LIST")
    T.eq(StaticPopupDialogs.CRAFTPROFIT_NEW_LIST.hasEditBox, 1)
  end,

  new_list_popup_creates_and_adds = function(T)
    local ns = setup({ cloth("Kim", 20, silver(9)) })
    openBuy()
    search(ns, CLOTH_NAME)
    T.eq(CraftProfitBuyToList:IsEnabled(), true)
    click(CraftProfitBuyToList)
    T.eq(menuTexts(), "New list...")
    menuEntry("New list...").func()
    Mock.acceptPopup("Mats")
    T.eq(ns.db.lists[1].name, "Mats")
    T.eq(ns.db.lists[1].items[1].id, CLOTH)
    T.eq(shownTables(ns), "list")
    T.eq(ns.BuyUI.list.lines[1].name:GetText(), CLOTH_NAME)
    -- with a list there: add to it from the menu
    ns.Lists.Create("Other")
    search(ns, CLOTH_NAME)
    click(CraftProfitBuyToList)
    T.eq(menuTexts(), "Mats | Other | New list...")
    menuEntry("Other").func()
    T.eq(ns.db.lists[2].items[1].id, CLOTH)
    T.eq(ns.BuyUI.status:GetText(), "Added " .. CLOTH_NAME .. " to Other.")
  end,

  to_list_only_in_the_item_view = function(T)
    local ns = setup({ cloth("Kim", 20, silver(9)), auction(BOLT, BOLT_NAME, "Bob", 5, silver(80)) })
    openBuy()
    T.eq(CraftProfitBuyToList:IsEnabled(), false)
    search(ns, "frostweave")
    T.eq(CraftProfitBuyToList:IsEnabled(), false, "results view")
  end,

  right_click_removes_from_own_list = function(T)
    local ns = setup({ cloth("Kim", 20, silver(9)) })
    ns.Lists.Create("Run")
    ns.Lists.Add("Run", CLOTH, CLOTH_NAME)
    ns.Lists.Add("Run", BOLT, BOLT_NAME)
    openBuy()
    click(CraftProfitBuyLists)
    menuEntry("Run").func()
    local tbl = ns.BuyUI.list
    T.eq(tbl.lines[1].name:GetText(), CLOTH_NAME)
    rightClick(tbl.lines[1])
    T.eq(#ns.db.lists[1].items, 1)
    T.eq(tbl.lines[1].name:GetText(), BOLT_NAME)
    T.eq(tbl.lines[2]:IsShown(), false)
    click(tbl.lines[1])
    T.eq(shownTables(ns), "item")
    T.eq((ns.Buy.Current()), BOLT)
  end,

  list_view_search_all = function(T)
    local ns = setup({ cloth("Kim", 20, silver(9)) })
    trackGlacial(ns)
    Mock.bags[0] = { [1] = { id = CLOTH, name = CLOTH_NAME, count = 4 } }
    openBuy()
    click(CraftProfitBuyLists)
    menuEntry("Glacial Bag materials").func()
    T.eq(CraftProfitBuySearchAll:IsShown(), true)
    T.eq(CraftProfitBuyCheapest:IsShown(), false)
    CraftProfitBuyCrafts:SetText("3")
    local line = ns.BuyUI.list.lines[1]
    T.ok(line.have:GetText():find("4/15", 1, true), line.have:GetText())
    T.eq(line.cheapest:GetText(), "-")
    click(CraftProfitBuySearchAll)
    T.ok(Mock.pump(ns))
    T.eq(line.cheapest:GetText(), ns.Style.Money(silver(9)))
    T.eq(line.seen:GetText(), "now")
    T.eq(ns.BuyUI.status:GetText(), "Scan done: 1 items")
    click(line)
    T.eq(ns.Buy.Target(), 11, "15 needed, 4 in the bags")
    T.eq(CraftProfitBuyNeed:GetText(), "11")
  end,

  deleting_the_shown_list_leaves_it = function(T)
    local ns = setup()
    ns.Lists.Create("Cloth run")
    openBuy()
    click(CraftProfitBuyLists)
    menuEntry("Cloth run").func()
    T.eq(shownTables(ns), "list")
    click(CraftProfitBuyLists)
    menuEntry("Delete Cloth run").func()
    T.eq(#ns.db.lists, 0)
    T.eq(shownTables(ns), "", "no table shows the deleted list")
    ns.BuyUI.Update()
    click(CraftProfitBuyLists)
    T.eq(menuTexts(), "New list...")
  end,

  shift_click_opens_item_view = function(T)
    local ns = setup({ cloth("A", 5, silver(9)) })
    local calls = spy(ns.Buy, "SearchLink")
    local link = Mock.Link(CLOTH, CLOTH_NAME)
    openBuy()
    ChatEdit_InsertLink(link)
    T.eq(#calls, 1, "searched")
    T.ok(Mock.pump(ns))
    T.eq(shownTables(ns), "item")
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

  layout_fits_the_page = function(T)
    local ns = setup()
    openBuy()
    local S, L = ns.Style, ns.BuyUI.layout
    local names = {}
    for name in pairs(L) do names[#names + 1] = name end
    T.eq(#names, 3, "bar, view, actions")
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
    -- the columns end before the scroll bar
    for _, key in ipairs({ "results", "item", "list" }) do
      for _, col in ipairs(ns.BuyUI[key].columns) do
        T.ok(col.x + col.width <= L.view.w - 24, key .. " column " .. col.key .. " fits")
      end
    end
  end,

  need_box_follows_buy_without_resetting_the_count = function(T)
    local ns = setup({ auction(BOLT, BOLT_NAME, "Bob", 2, silver(80)), auction(BOLT, BOLT_NAME, "Kim", 2, silver(90)) })
    ns.Recipes.All()[BAG] = { name = BAG_NAME, made = 1, reagents = { { id = BOLT, name = BOLT_NAME, count = 4 } } }
    ns.Recipes.SetTracked(BAG, true)
    openBuy()
    click(CraftProfitBuyLists)
    menuEntry(BAG_NAME .. " materials").func()
    click(ns.BuyUI.list.lines[1])
    T.ok(Mock.pump(ns))
    T.eq(CraftProfitBuyNeed:GetText(), "4", "the box shows the need the click set")
    click(CraftProfitBuyCheapest)
    T.eq(ns.Buy.Need(), 2, "2 of 4 bought")
    ns.BuyUI.Update()
    T.eq(ns.Buy.Need(), 2, "redrawing the box does not start the count over")
    T.eq(CraftProfitBuyNeed:GetText(), "4")
    -- a search of another item clears the need and the box
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
}
