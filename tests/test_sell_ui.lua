local Mock = require("wow_mock")

local REALM = "Icecrown-Alliance"
local BAG, BAG_NAME = 41599, "Frostweave Bag"
local OTHER, OTHER_NAME = 41600, "Glacial Bag"
local CLOTH, CLOTH_NAME = 33470, "Frostweave Cloth"

local GOOD, BAD, GREY = "|cff40ff40", "|cffff4040", "|cff808080"

local function gold(g, s, c) return g * 10000 + (s or 0) * 100 + (c or 0) end

-- A fresh namespace with the tabs built (CP Sell is tab 4, CP Auctions tab 5).
-- The player has 1000000g, no bags, an empty sell slot.
local function setup()
  Mock.reset()
  Mock.installUI()
  local ns = Mock.load({
    "Util.lua", "Profit.lua", "Prices.lua", "Recipes.lua", "Scanner.lua", "Listings.lua",
    "UI.lua", "ListingsUI.lua", "Tabs.lua", "Flip.lua", "Sell.lua", "SellUI.lua",
  })
  local db = { cut = 0.05 }
  ns.db = db
  ns.Prices.SetDB(db, REALM)
  ns.Recipes.SetDB({})
  ns.Scanner.SetDB(db)
  ns.Listings.SetDB(db, REALM, "Me")
  ns.Sell.SetDB(db)
  hooksecurefunc("QueryAuctionItems", ns.Scanner.OnQuery)
  Mock.items[BAG] = { name = BAG_NAME, maxStack = 1 }
  Mock.items[OTHER] = { name = OTHER_NAME, maxStack = 1 }
  Mock.items[CLOTH] = { name = CLOTH_NAME, maxStack = 20 }
  assert(ns.Tabs.Ensure())
  return ns, db
end

local function click(frame)
  frame:GetScript("OnClick")(frame)
end

-- The player clicks the CP Sell tab / one of Blizzard's tabs.
local function openSell() click(AuctionFrameTab4) end
local function openBrowse() click(AuctionFrameTab1) end

local function inBag(bag, slot, id, name, count)
  Mock.bags[bag] = Mock.bags[bag] or {}
  Mock.bags[bag][slot] = { id = id, name = name, count = count }
end

local function auction(id, name, seller, count, buyout)
  return { id = id, name = name, count = count or 1, buyout = buyout, seller = seller }
end

local function bagAuction(seller, buyout)
  return auction(BAG, BAG_NAME, seller, 1, buyout)
end

-- The player alt+clicks bag slot (0, 1) holding `count` bags; the price check
-- finishes unless pump == false.
local function putBag(ns, count, pump)
  inBag(0, 1, BAG, BAG_NAME, count or 3)
  assert(ns.Sell.PutItem(0, 1), "item accepted")
  if pump ~= false then assert(Mock.pump(ns), "price check finished") end
end

-- Frostweave Bag is a known recipe: 5 cloth per craft, 2 bags per craft.
local function knowRecipe(ns, clothPrice)
  ns.Recipes.All()[BAG] = {
    name = BAG_NAME, made = 2,
    reagents = { { id = CLOTH, name = CLOTH_NAME, count = 5 } },
  }
  if clothPrice then ns.Prices.SetManual(CLOTH, clothPrice) end
end

-- Count the calls the page makes into Sell (the page must call through the
-- ns.Sell table so this sees them).
local function countCalls(ns)
  local calls = { SetUnit = 0, SetStack = 0, SetStacks = 0, Post = 0 }
  for name in pairs(calls) do
    local original = ns.Sell[name]
    ns.Sell[name] = function(...)
      calls[name] = calls[name] + 1
      return original(...)
    end
  end
  return calls
end

-- What the player types: the price box and the two edit boxes echo it to the
-- page as the client does.
local function typePrice(copper) MoneyInputFrame_SetCopper(CraftProfitSellPrice, copper) end

return {
  build_once_on_page_shown = function(T)
    local ns = setup()
    local created = 0
    local create = CreateFrame
    CreateFrame = function(kind, name, ...)
      if name == "CraftProfitSellSlot" then created = created + 1 end
      return create(kind, name, ...)
    end

    T.eq(CraftProfitSellSlot, nil, "nothing is built before the page is shown")
    ns.Fire("PAGE_SHOWN", "auctions")
    T.eq(CraftProfitSellSlot, nil, "the other page does not build ours")

    openSell()
    local page = ns.Tabs.Page("sell")
    T.eq(created, 1)
    T.eq(CraftProfitSellSlot._parent, page)
    T.eq(CraftProfitSellPrice._template, "MoneyInputFrameTemplate")
    T.eq(CraftProfitSellPost._template, "UIPanelButtonTemplate")
    T.ok(CraftProfitSellStack and CraftProfitSellStacks, "stack size and number of stacks")
    T.ok(CraftProfitSellDuration1 and CraftProfitSellDuration2 and CraftProfitSellDuration3, "radios")
    T.eq(ns.SellUI.listings.frame._parent, page)
    T.eq(ns.SellUI.flip.frame._parent, page)
    T.ok(CraftProfitSellPrice.onValueChangedFunc, "price changes are heard")

    local slot = CraftProfitSellSlot
    openBrowse()
    openSell()
    ns.Fire("PAGE_SHOWN", "sell")
    ns.SellUI.Build()
    T.eq(created, 1, "built once")
    T.eq(CraftProfitSellSlot, slot)
  end,

  post_button_reflects_can_post = function(T)
    local ns = setup()
    openSell()
    local post, reason = CraftProfitSellPost, ns.SellUI.reason

    -- nothing in the slot
    T.eq(post:IsEnabled(), false)
    T.eq(post:GetText(), "Post 1 auction")
    T.eq(reason:GetText(), "Drag an item here or Alt+click it in your bags.")

    -- the price check has not answered
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    putBag(ns, 3, false)
    T.eq(post:IsEnabled(), false)
    T.eq(reason:GetText(), "Checking prices...")
    T.eq(post:GetText(), "Post 3 auctions")

    -- ready to post
    T.ok(Mock.pump(ns))
    T.eq(post:IsEnabled(), true)
    T.eq(reason:GetText(), "")
    T.eq(post:GetText(), "Post 3 auctions")

    -- one auction reads in the singular
    CraftProfitSellStacks:SetText("1")
    T.eq(post:GetText(), "Post 1 auction")

    -- more than the bags hold
    CraftProfitSellStacks:SetText("4")
    T.eq(post:IsEnabled(), false)
    T.eq(post:GetText(), "Post 4 auctions")
    T.eq(reason:GetText(), "You only have 3.")

    -- cannot pay the deposit
    CraftProfitSellStacks:SetText("3")
    T.eq(post:IsEnabled(), true)
    Mock.money = 0
    ns.SellUI.Update()
    T.eq(post:IsEnabled(), false)
    T.eq(reason:GetText(), "Not enough gold for the deposit.")
    Mock.money = 1000000000

    -- the game's slot holds something else and we have not heard about it
    Mock.sellSlot = { id = OTHER, name = OTHER_NAME, count = 1, bag = 0, slot = 2 }
    ns.SellUI.Update()
    T.eq(post:IsEnabled(), false)
    T.eq(reason:GetText(), "The sell slot changed - drop the item again.")
  end,

  post_button_reasons_without_a_price = function(T)
    -- nobody sells it and nothing is known: type a price
    local ns = setup()
    openSell()
    putBag(ns, 1)
    T.eq(CraftProfitSellPost:IsEnabled(), false)
    T.eq(ns.SellUI.reason:GetText(), "Type a price.")
    T.eq(MoneyInputFrame_GetCopper(CraftProfitSellPrice), 0, "the price field is empty")
    typePrice(gold(5))
    T.eq(CraftProfitSellPost:IsEnabled(), true)
    T.eq(ns.SellUI.reason:GetText(), "")

    -- the check ended without an answer
    local ns2 = setup()
    openSell()
    inBag(0, 1, BAG, BAG_NAME, 1)
    T.ok(ns2.Sell.PutItem(0, 1))
    ns2.Scanner.Stop("AH closed")
    T.eq(CraftProfitSellPost:IsEnabled(), false)
    T.eq(ns2.SellUI.reason:GetText(), "No answer from the AH - type a price.")
    typePrice(gold(5))
    T.eq(CraftProfitSellPost:IsEnabled(), true, "a typed price needs no check")
  end,

  post_button_click_posts = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    openSell()
    putBag(ns, 3)
    local calls = countCalls(ns)
    T.eq(#Mock.started, 0, "nothing posts by itself")
    T.eq(CraftProfitSellPost:IsEnabled(), true)

    click(CraftProfitSellPost)
    T.eq(calls.Post, 1)
    T.eq(#Mock.started, 1)
    local started = Mock.started[1]
    T.eq(started[1], gold(419, 99), "bid = buyout = price each * stack size")
    T.eq(started[2], gold(419, 99))
    T.eq(started[3], 2, "24 h")
    T.eq(started[4], 1, "stack size")
    T.eq(started[5], 3, "stacks")
    T.eq(ns.SellUI.reason:GetText(), "Posting...", "the page follows the post")
    T.eq(CraftProfitSellPost:IsEnabled(), false)

    -- no other control posts
    T.eq(calls.SetUnit + calls.SetStack + calls.SetStacks, 0)
    typePrice(gold(300))
    CraftProfitSellStack:SetText("1")
    T.eq(#Mock.started, 1)
  end,

  post_button_click_without_item_posts_nothing = function(T)
    local ns = setup()
    openSell()
    click(CraftProfitSellPost)
    T.eq(#Mock.started, 0)
    T.eq(CraftProfitSellPost:IsEnabled(), false)
  end,

  profit_text_colors = function(T)
    local ns = setup()
    knowRecipe(ns, 2000)                      -- 5 cloth = 10000 per craft, 2 bags per craft
    openSell()
    putBag(ns, 2, false)
    local ui = ns.SellUI

    typePrice(41999)
    T.eq(ui.deposit:GetText(), "Deposit: 4s")
    T.eq(ui.net:GetText(), "You get each: 3g 98s 99c")
    T.eq(ui.cost:GetText(), "Cost each: 50s")
    T.eq(ui.profit:GetText(), GOOD .. "Profit each: 3g 48s 99c|r")

    -- exactly at cost still counts as a profit
    typePrice(math.ceil(5000 / 0.95))
    T.eq(ui.profit:GetText():sub(1, #GOOD), GOOD)

    -- below the crafting cost
    typePrice(4000)
    T.eq(ui.net:GetText(), "You get each: 38s")
    T.eq(ui.cost:GetText(), "Cost each: 50s")
    T.eq(ui.profit:GetText(), BAD .. "Profit each: loses 12s vs crafting cost|r")

    -- materials without a price
    local ns2 = setup()
    knowRecipe(ns2)
    openSell()
    putBag(ns2, 2, false)
    typePrice(41999)
    T.eq(ns2.SellUI.cost:GetText(), "")
    T.eq(ns2.SellUI.profit:GetText(), GREY .. "cost unknown - scan it in Craft Profit|r")
    T.eq(ns2.SellUI.net:GetText(), "You get each: 3g 98s 99c")

    -- not a recipe: no cost, no profit
    local ns3 = setup()
    openSell()
    putBag(ns3, 2, false)
    typePrice(41999)
    T.eq(ns3.SellUI.deposit:GetText(), "Deposit: 4s")
    T.eq(ns3.SellUI.cost:GetText(), "")
    T.eq(ns3.SellUI.profit:GetText(), "")
  end,

  money_lines_clear_when_the_slot_empties = function(T)
    local ns = setup()
    knowRecipe(ns, 2000)
    openSell()
    putBag(ns, 2, false)
    typePrice(41999)
    T.ok(ns.SellUI.deposit:GetText() ~= "")
    Mock.sellSlot = nil                       -- emptied without an event
    ns.SellUI.Update()
    T.eq(ns.SellUI.deposit:GetText(), "")
    T.eq(ns.SellUI.net:GetText(), "")
    T.eq(ns.SellUI.cost:GetText(), "")
    T.eq(ns.SellUI.profit:GetText(), "")
    T.eq(ns.SellUI.itemName:GetText(), "")
  end,

  alt_click_puts_item_only_on_sell_page = function(T)
    local ns = setup()
    inBag(0, 1, BAG, BAG_NAME, 3)
    local bagFrame = CreateFrame("Frame", nil, UIParent)
    bagFrame:SetID(0)
    local button = CreateFrame("Button", nil, bagFrame)
    button:SetID(1)
    local function altClick() ContainerFrameItemButton_OnModifiedClick(button, "LeftButton") end

    -- another tab (or no AH at all): Blizzard's handler alone
    Mock.alt = true
    altClick()
    T.eq(ns.Sell.State().item, nil, "the sell page is not shown")
    openBrowse()
    altClick()
    T.eq(ns.Sell.State().item, nil, "another tab is shown")

    -- the sell page, without Alt
    openSell()
    Mock.alt = false
    altClick()
    T.eq(ns.Sell.State().item, nil, "no Alt key")

    -- the sell page with Alt
    Mock.alt = true
    altClick()
    local s = ns.Sell.State()
    T.ok(s.item, "the item went into the sell slot")
    T.eq(s.item.id, BAG)
    T.eq(Mock.sellSlot.id, BAG)
    T.eq(ns.SellUI.itemName:GetText(), BAG_NAME, "and the page shows it")

    -- the item is picked from the clicked bag and slot
    inBag(2, 5, OTHER, OTHER_NAME, 1)
    local bag2 = CreateFrame("Frame", nil, UIParent)
    bag2:SetID(2)
    local button2 = CreateFrame("Button", nil, bag2)
    button2:SetID(5)
    ContainerFrameItemButton_OnModifiedClick(button2, "LeftButton")
    T.eq(ns.Sell.State().item.id, OTHER)
  end,

  alt_click_ignored_when_ah_closed = function(T)
    local ns = setup()
    inBag(0, 1, BAG, BAG_NAME, 3)
    local bagFrame = CreateFrame("Frame", nil, UIParent)
    bagFrame:SetID(0)
    local button = CreateFrame("Button", nil, bagFrame)
    button:SetID(1)

    -- CP Sell was the selected tab when the Auction House closed
    openSell()
    AuctionFrame:Hide()
    Mock.alt = true
    ContainerFrameItemButton_OnModifiedClick(button, "LeftButton")
    T.eq(ns.Sell.State().item, nil, "the AH is closed: bags are not ours")
    T.eq(Mock.sellSlot, nil)

    -- opened again on the same tab, Alt+click works
    AuctionFrame:Show()
    ContainerFrameItemButton_OnModifiedClick(button, "LeftButton")
    T.eq(ns.Sell.State().item.id, BAG)
  end,

  slot_takes_the_dragged_item = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    openSell()
    local slot = CraftProfitSellSlot
    T.eq(ns.SellUI.icon:IsShown(), false, "empty slot shows no icon")

    -- nothing on the cursor: nothing happens
    click(slot)
    T.eq(ns.Sell.State().item, nil)

    inBag(0, 1, BAG, BAG_NAME, 3)
    PickupContainerItem(0, 1)
    slot:GetScript("OnReceiveDrag")(slot)
    local s = ns.Sell.State()
    T.eq(s.item.id, BAG)
    T.eq(ns.SellUI.icon:IsShown(), true)
    T.eq(ns.SellUI.icon._texture, "tex")
    T.eq(ns.SellUI.itemName:GetText(), BAG_NAME)
    T.eq(ns.SellUI.owned:GetText(), "You have 3")

    -- a click with an item on the cursor drops it too
    inBag(0, 2, OTHER, OTHER_NAME, 1)
    PickupContainerItem(0, 2)
    click(slot)
    T.eq(ns.Sell.State().item.id, OTHER)
    T.eq(ns.SellUI.itemName:GetText(), OTHER_NAME)
  end,

  inputs_show_the_defaults = function(T)
    local ns = setup()
    Mock.ah.auctions = { auction(CLOTH, CLOTH_NAME, "Bob", 20, 20 * 300) }
    openSell()
    inBag(0, 1, CLOTH, CLOTH_NAME, 45)
    T.ok(ns.Sell.PutItem(0, 1))
    T.ok(Mock.pump(ns))
    T.eq(MoneyInputFrame_GetCopper(CraftProfitSellPrice), 200, "3s each: the whole silver below")
    T.eq(CraftProfitSellStack:GetNumber(), 20)
    T.eq(CraftProfitSellStacks:GetNumber(), 2)
    T.eq(ns.SellUI.owned:GetText(), "You have 45")
  end,

  typed_inputs_reach_sell = function(T)
    local ns = setup()
    Mock.ah.auctions = { auction(CLOTH, CLOTH_NAME, "Bob", 20, 20 * 300) }
    openSell()
    inBag(0, 1, CLOTH, CLOTH_NAME, 45)
    T.ok(ns.Sell.PutItem(0, 1))
    T.ok(Mock.pump(ns))

    typePrice(gold(1, 50))
    T.eq(ns.Sell.State().unit, gold(1, 50))
    T.eq(MoneyInputFrame_GetCopper(CraftProfitSellPrice), gold(1, 50))

    CraftProfitSellStack:SetText("10")
    T.eq(ns.Sell.State().stack, 10)
    CraftProfitSellStacks:SetText("4")
    T.eq(ns.Sell.State().stacks, 4)

    -- a typed price is not replaced by a later price check
    Mock.ah.auctions = { auction(CLOTH, CLOTH_NAME, "Bob", 20, 20 * 100) }
    T.ok(ns.Scanner.PriceCheck({ id = CLOTH, name = CLOTH_NAME }))
    T.ok(Mock.pump(ns))
    T.eq(ns.Sell.State().unit, gold(1, 50))
    T.eq(MoneyInputFrame_GetCopper(CraftProfitSellPrice), gold(1, 50))
  end,

  emptied_count_box_waits_for_the_next_digit = function(T)
    local ns = setup()
    Mock.ah.auctions = { auction(CLOTH, CLOTH_NAME, "Bob", 20, 20 * 300) }
    openSell()
    inBag(0, 1, CLOTH, CLOTH_NAME, 45)
    T.ok(ns.Sell.PutItem(0, 1))
    T.ok(Mock.pump(ns))
    local calls = countCalls(ns)

    -- the player clears the box to type another number
    CraftProfitSellStack:SetText("")
    T.eq(calls.SetStack, 0, "an empty box is not a count")
    T.eq(ns.Sell.State().stack, 20)
    T.eq(CraftProfitSellStack:GetText(), "", "the box is left alone while typing")

    -- leaving the box empty puts the real count back
    CraftProfitSellStack:GetScript("OnEditFocusLost")(CraftProfitSellStack)
    T.eq(CraftProfitSellStack:GetNumber(), 20)
    T.eq(calls.SetStack, 0)
  end,

  focused_count_box_is_left_alone = function(T)
    local ns = setup()
    Mock.ah.auctions = { auction(CLOTH, CLOTH_NAME, "Bob", 20, 20 * 300) }
    openSell()
    inBag(0, 1, CLOTH, CLOTH_NAME, 45)
    T.ok(ns.Sell.PutItem(0, 1))
    T.ok(Mock.pump(ns))
    local calls = countCalls(ns)
    local box = CraftProfitSellStacks
    T.eq(box:GetNumber(), 2)

    -- the player clears the box to type a new number
    box:SetFocus()
    box:SetText("")
    -- a price check lands in the meantime
    Mock.ah.auctions = { auction(CLOTH, CLOTH_NAME, "Bob", 20, 20 * 500) }
    T.ok(ns.Scanner.PriceCheck({ id = CLOTH, name = CLOTH_NAME }))
    T.ok(Mock.pump(ns))
    T.eq(ns.Sell.State().unit, 400, "the check did redraw the page")
    T.eq(box:GetText(), "", "the box being typed in is not refilled")

    -- the typed number is the count (not "2" followed by 5)
    box:SetText("5")
    T.eq(ns.Sell.State().stacks, 5)
    T.eq(calls.SetStacks, 1)

    -- a 0 on the way to e.g. 10 is not a count and not bumped to 1
    box:SetText("0")
    ns.SellUI.Update()
    T.eq(box:GetText(), "0")
    T.eq(ns.Sell.State().stacks, 5)
    T.eq(calls.SetStacks, 1)

    -- leaving the box shows the count Sell really has
    box:ClearFocus()
    T.eq(box:GetNumber(), 5)
    T.eq(calls.SetStacks, 1)
    box:SetFocus()
    box:SetText("")
    box:ClearFocus()
    T.eq(box:GetNumber(), 5)

    -- the stack size box is the same
    local stack = CraftProfitSellStack
    stack:SetFocus()
    stack:SetText("")
    ns.SellUI.Update()
    T.eq(stack:GetText(), "")
    stack:ClearFocus()
    T.eq(stack:GetNumber(), 20)
    T.eq(calls.SetStack, 0)
  end,

  focused_count_box_follows_a_count_sell_changed = function(T)
    local ns = setup()
    Mock.ah.auctions = { auction(CLOTH, CLOTH_NAME, "Bob", 20, 20 * 300) }
    openSell()
    inBag(0, 1, CLOTH, CLOTH_NAME, 45)
    T.ok(ns.Sell.PutItem(0, 1))
    T.ok(Mock.pump(ns))

    -- the player typed 2 in the stacks box, clicked Post and the box kept the
    -- keyboard; the game then reports fewer items in the bags
    local box = CraftProfitSellStacks
    box:SetFocus()
    box:SetText("2")
    inBag(0, 1, CLOTH, CLOTH_NAME, 25)
    ns.Sell.OnSlotChanged(nil)
    T.eq(ns.Sell.State().stacks, 1)
    T.eq(box:GetNumber(), 1, "Sell's new count shows even in a focused box")
  end,

  unchanged_value_is_not_a_typed_one = function(T)
    local ns = setup()
    Mock.ah.auctions = { auction(CLOTH, CLOTH_NAME, "Bob", 20, 20 * 300) }
    openSell()
    inBag(0, 1, CLOTH, CLOTH_NAME, 45)
    T.ok(ns.Sell.PutItem(0, 1))
    T.ok(Mock.pump(ns))
    local calls = countCalls(ns)

    -- the boxes report what they already hold (same number, other spelling)
    CraftProfitSellStack:SetText("020")
    CraftProfitSellStacks:SetText("2")
    CraftProfitSellPrice.onValueChangedFunc()
    T.eq(calls.SetStack + calls.SetStacks + calls.SetUnit, 0)

    -- so the price is still the market's, not the player's
    Mock.ah.auctions = { auction(CLOTH, CLOTH_NAME, "Bob", 20, 20 * 500) }
    T.ok(ns.Scanner.PriceCheck({ id = CLOTH, name = CLOTH_NAME }))
    T.ok(Mock.pump(ns))
    T.eq(ns.Sell.State().unit, 400)
  end,

  redraw_is_not_a_typed_price = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    openSell()
    local calls = countCalls(ns)
    putBag(ns, 3)
    T.eq(ns.Sell.State().unit, gold(419, 99))
    T.eq(MoneyInputFrame_GetCopper(CraftProfitSellPrice), gold(419, 99), "the page shows the price")
    T.eq(CraftProfitSellStack:GetNumber(), 1)
    T.eq(CraftProfitSellStacks:GetNumber(), 3)
    T.eq(calls.SetUnit, 0, "drawing the price is not typing it")
    T.eq(calls.SetStack, 0)
    T.eq(calls.SetStacks, 0)

    -- the next price check still re-prices the item
    Mock.ah.auctions = { bagAuction("Bob", gold(300)) }
    T.ok(ns.Scanner.PriceCheck({ id = BAG, name = BAG_NAME }))
    T.ok(Mock.pump(ns))
    T.eq(ns.Sell.State().unit, gold(299, 99), "the first redraw did not mark the price as typed")
    T.eq(MoneyInputFrame_GetCopper(CraftProfitSellPrice), gold(299, 99))
    T.eq(calls.SetUnit, 0)

    -- a price that goes away clears the field, again without "typing"
    Mock.sellSlot = nil
    ns.Sell.OnSlotChanged(nil)
    T.eq(ns.Sell.State().item, nil)
    T.eq(MoneyInputFrame_GetCopper(CraftProfitSellPrice), 0)
    T.eq(calls.SetUnit, 0)
    T.eq(ns.Sell.State().unit, nil)

    -- the client may deliver the box's change after the redraw is over: an
    -- empty field with no price is not a typed 0c either
    CraftProfitSellPrice.onValueChangedFunc()
    T.eq(calls.SetUnit, 0)
    T.eq(ns.Sell.State().unit, nil)
  end,

  duration_radios = function(T)
    local ns, db = setup()
    openSell()
    local radios = { CraftProfitSellDuration1, CraftProfitSellDuration2, CraftProfitSellDuration3 }
    T.eq(_G.CraftProfitSellDuration1Text:GetText(), "12h")
    T.eq(_G.CraftProfitSellDuration2Text:GetText(), "24h")
    T.eq(_G.CraftProfitSellDuration3Text:GetText(), "48h")
    for i = 1, 3 do T.eq(radios[i]._template, "UIRadioButtonTemplate") end
    T.eq(radios[1]:GetChecked(), false)
    T.eq(radios[2]:GetChecked(), true, "24 h is the default")
    T.eq(radios[3]:GetChecked(), false)

    click(radios[3])
    T.eq(ns.Sell.State().duration, 3)
    T.eq(db.sell.duration, 3)
    T.eq(radios[2]:GetChecked(), false)
    T.eq(radios[3]:GetChecked(), true)

    click(radios[1])
    T.eq(ns.Sell.State().duration, 1)
    T.eq(radios[1]:GetChecked(), true)
    T.eq(radios[3]:GetChecked(), false)

    -- a click on the checked one (the client unchecks it) leaves it checked
    radios[1]:SetChecked(false)
    click(radios[1])
    T.eq(radios[1]:GetChecked(), true)
  end,

  listings_table_follows_the_item = function(T)
    local ns = setup()
    Mock.ah.auctions = {
      bagAuction("Flipper", gold(50)), bagAuction("Bob", gold(420)), bagAuction("Carl", gold(430)),
    }
    openSell()
    local tbl = ns.SellUI.listings
    T.eq(tbl.frame, CraftProfitSellListings)
    T.eq(#tbl.rows, 0)
    T.eq(tbl.title:GetText(), "")

    putBag(ns, 1)
    T.eq(tbl.title:GetText(), BAG_NAME .. ": all listings")
    T.eq(#tbl.rows, 3)
    T.eq(tbl.lines[1].seller:GetText(), "Flipper")
    T.eq(tbl.lines[3].seller:GetText(), "Carl")
  end,

  listings_row_click_picks_the_price = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)), bagAuction("Carl", gold(500)) }
    openSell()
    putBag(ns, 1)
    typePrice(gold(1))
    local line = ns.SellUI.listings.lines[2]
    T.eq(line.row.seller, "Carl")
    click(line)
    T.eq(ns.Sell.State().unit, gold(499, 99), "one step under the clicked row")
    T.eq(MoneyInputFrame_GetCopper(CraftProfitSellPrice), gold(499, 99))
  end,

  item_change_resets_scroll_and_flip_widget = function(T)
    local ns = setup()
    Mock.ah.auctions = {
      bagAuction("Flipper", gold(50)), bagAuction("Bob", gold(420)), bagAuction("Carl", gold(430)),
    }
    openSell()
    putBag(ns, 1)
    local tbl, flip = ns.SellUI.listings, ns.SellUI.flip
    T.eq(flip.frame:IsShown(), true, "the mistake listing is offered")

    -- the same item redrawn keeps the scroll position
    tbl.scroll.offset = 3
    typePrice(gold(300))
    T.eq(tbl.scroll.offset, 3)
    T.eq(flip.frame:IsShown(), true)

    -- another item: back to the top, and the old item's notice goes at once
    inBag(0, 2, OTHER, OTHER_NAME, 1)
    T.ok(ns.Sell.PutItem(0, 2))
    T.eq(ns.Sell.State().item.id, OTHER)
    T.eq(tbl.scroll.offset, 0)
    T.eq(flip.frame:IsShown(), false, "the price check for the new item has not answered")

    -- and back again: the cached listings show the notice again
    T.ok(Mock.pump(ns))
    T.ok(ns.Sell.PutItem(0, 1))
    T.eq(ns.Sell.State().item.id, BAG)
    T.eq(flip.frame:IsShown(), true)
  end,

  status_line = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    openSell()
    local status = ns.SellUI.status
    T.eq(status:GetText(), "")

    putBag(ns, 3, false)
    T.eq(status:GetText(), "Searching...")
    T.ok(Mock.pump(ns))
    T.eq(status:GetText(), "")

    -- messages from other modules, while this page is the one shown
    ns.Fire("PAGE_STATUS", "Bought for 50g")
    T.eq(status:GetText(), "Bought for 50g")
    typePrice(gold(300))
    T.eq(status:GetText(), "Bought for 50g", "an unrelated redraw keeps it")
    ns.Fire("PAGE_ERROR", "Not enough money")
    T.eq(status:GetText(), BAD .. "Not enough money|r")

    -- the page's own status wins when it changes
    click(CraftProfitSellPost)
    T.eq(status:GetText(), "Posting...")

    -- coming back to the page shows its own status again
    ns.Fire("PAGE_ERROR", "Item not found")
    openBrowse()
    openSell()
    T.eq(status:GetText(), "Posting...")
  end,

  page_status_ignored_while_the_sell_page_is_hidden = function(T)
    local ns = setup()
    openSell()
    local status = ns.SellUI.status
    ns.Fire("PAGE_STATUS", "first")
    T.eq(status:GetText(), "first")

    openBrowse()
    ns.Fire("PAGE_STATUS", "meant for another page")
    ns.Fire("PAGE_ERROR", "also for another page")
    T.eq(status:GetText(), "first")

    -- the Auction House closed on this tab: not the page the player sees
    openSell()
    ns.Fire("PAGE_STATUS", "second")
    T.eq(status:GetText(), "second")
    AuctionFrame:Hide()
    ns.Fire("PAGE_STATUS", "while closed")
    ns.Fire("PAGE_ERROR", "while closed")
    T.eq(status:GetText(), "second")

    -- before the page was ever shown there is nothing to write to
    local fresh = setup()
    fresh.Fire("PAGE_STATUS", "early")
    fresh.Fire("PAGE_ERROR", "early")
    T.eq(fresh.SellUI.status, nil)
  end,

  price_changes_redraw_the_cost_line = function(T)
    local ns = setup()
    knowRecipe(ns)                            -- no cloth price anywhere
    openSell()
    putBag(ns, 2, false)
    typePrice(41999)                          -- the player's price: Sell has nothing to redo
    T.eq(ns.SellUI.profit:GetText(), GREY .. "cost unknown - scan it in Craft Profit|r")
    T.eq(ns.SellUI.cost:GetText(), "")

    -- a scan (or /cp price) gives the cloth a price
    ns.Prices.SetManual(CLOTH, 2000)
    ns.Fire("PRICES_CHANGED")
    T.eq(ns.SellUI.cost:GetText(), "Cost each: 50s")
    T.eq(ns.SellUI.profit:GetText(), GOOD .. "Profit each: 3g 48s 99c|r")

    -- a price Sell takes over (manual price of the item itself) is drawn once
    local ns2 = setup()
    openSell()
    putBag(ns2, 1, false)
    ns2.Scanner.Stop("AH closed")
    T.eq(MoneyInputFrame_GetCopper(CraftProfitSellPrice), 0)
    ns2.Prices.SetManual(BAG, gold(7))
    ns2.Fire("PRICES_CHANGED")
    T.eq(ns2.Sell.State().unit, gold(7))
    T.eq(MoneyInputFrame_GetCopper(CraftProfitSellPrice), gold(7))
  end,

  money_changes_redraw_post_button = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    openSell()
    putBag(ns, 3)
    T.eq(CraftProfitSellPost:IsEnabled(), true)
    T.eq(ns.SellUI.reason:GetText(), "")

    -- the player spends their gold; Core fires MONEY_CHANGED on PLAYER_MONEY
    Mock.money = 599                          -- the deposit is 600
    ns.Fire("MONEY_CHANGED")
    T.eq(CraftProfitSellPost:IsEnabled(), false)
    T.eq(ns.SellUI.reason:GetText(), "Not enough gold for the deposit.")

    Mock.money = 600
    ns.Fire("MONEY_CHANGED")
    T.eq(CraftProfitSellPost:IsEnabled(), true)
    T.eq(ns.SellUI.reason:GetText(), "")

    -- before the page was built the event is harmless
    local fresh = setup()
    fresh.Fire("MONEY_CHANGED")
    fresh.Fire("PRICES_CHANGED")
    T.eq(CraftProfitSellPost, nil)
  end,

  updates_follow_sell_changed_only_after_build = function(T)
    local ns = setup()
    Mock.ah.auctions = { bagAuction("Bob", gold(420)) }
    -- before the page is shown nothing is built, and Sell events are harmless
    putBag(ns, 3)
    T.eq(CraftProfitSellPost, nil)
    ns.SellUI.Update()

    -- opening the page draws the item that is already in the slot
    openSell()
    T.eq(ns.SellUI.itemName:GetText(), BAG_NAME)
    T.eq(CraftProfitSellPost:GetText(), "Post 3 auctions")
    T.eq(CraftProfitSellPost:IsEnabled(), true)
    T.eq(MoneyInputFrame_GetCopper(CraftProfitSellPrice), gold(419, 99))
    T.eq(ns.SellUI.listings.title:GetText(), BAG_NAME .. ": all listings")
  end,
}
