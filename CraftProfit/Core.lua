-- Startup, game events and /cp slash commands.
local addonName, ns = ...

local Util = ns.Util
local floor = math.floor

ns.Core = {}
local Core = ns.Core

local RUNTIME_EVENTS = {
  "ADDON_LOADED",
  "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_CLOSE",
  "MERCHANT_SHOW", "MERCHANT_UPDATE",
  "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "AUCTION_ITEM_LIST_UPDATE",
}
local BUTTON_REFRESH = 0.5

local frame = CreateFrame("Frame", "CraftProfitEventFrame")
local sinceButtons = 0

function Core.InitDB()
  CraftProfitDB = CraftProfitDB or {}
  CraftProfitCharDB = CraftProfitCharDB or {}
  local db = CraftProfitDB
  db.version = db.version or 1
  db.cut = db.cut or 0.05
  ns.db = db
  ns.Prices.SetDB(db, Util.RealmKey())
  ns.Recipes.SetDB(CraftProfitCharDB)
  ns.Scanner.SetDB(db)
  ns.UI.SetDB(db)
end

function Core.OnUpdate(_, elapsed)
  ns.Scanner.Tick(elapsed)
  ns.Recipes.Tick(elapsed)
  sinceButtons = sinceButtons + elapsed
  if sinceButtons >= BUTTON_REFRESH then
    sinceButtons = 0
    if ns.UI.IsVisible() then ns.UI.UpdateScanButtons() end
  end
end

function Core.OnEvent(event, arg1)
  if event == "PLAYER_LOGIN" then
    Core.InitDB()
    for _, e in ipairs(RUNTIME_EVENTS) do frame:RegisterEvent(e) end
    hooksecurefunc("QueryAuctionItems", ns.Scanner.OnQuery)
    frame:SetScript("OnUpdate", Core.OnUpdate)
    -- Another addon may already have loaded the (load-on-demand) AH UI.
    ns.UI.EnsurePanel()
  elseif event == "ADDON_LOADED" then
    if arg1 == "Blizzard_AuctionUI" then ns.UI.EnsurePanel() end
  elseif event == "TRADE_SKILL_SHOW" then
    ns.UI.EnsureTrackButton()
    ns.Recipes.ReadSelected()
    ns.Recipes.StartBackgroundScan()
    ns.UI.UpdateTrackButton()
  elseif event == "TRADE_SKILL_UPDATE" then
    -- Fires often (every craft, filter change); keep it cheap. The selected
    -- recipe is re-read by the TradeSkillFrame_SetSelection hook.
    ns.UI.EnsureTrackButton()
    ns.Recipes.NoteUpdate()
  elseif event == "TRADE_SKILL_CLOSE" then
    ns.Recipes.StopBackgroundScan()
  elseif event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
    ns.Prices.RecordMerchant()
  elseif event == "AUCTION_HOUSE_SHOW" then
    ns.UI.ShowPanel()
  elseif event == "AUCTION_HOUSE_CLOSED" or event == "AUCTION_ITEM_LIST_UPDATE" then
    ns.Scanner.HandleEvent(event)
  end
end

frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, arg1) Core.OnEvent(event, arg1) end)

-- Item id for a known recipe/material name (any case), else the item cache.
local function lookupName(name)
  local wanted = name:lower()
  for id, recipe in pairs(ns.Recipes.All()) do
    if recipe.name:lower() == wanted then return id end
    for _, reagent in ipairs(recipe.reagents) do
      if reagent.name:lower() == wanted then return reagent.id end
    end
  end
  local _, link = GetItemInfo(name)
  return Util.ItemIDFromLink(link)
end

-- "<item link or name> <rest>" -> itemID, rest. Names may contain spaces,
-- so the longest leading run of words that names an item wins.
function Core.ParseItemArg(msg)
  local link, rest = msg:match("^(|c%x+|Hitem:.-|h|r)%s*(.*)$")
  if link then return Util.ItemIDFromLink(link), rest end

  local words = {}
  for word in msg:gmatch("%S+") do words[#words + 1] = word end
  for n = #words, 1, -1 do
    local id = lookupName(table.concat(words, " ", 1, n))
    if id then return id, table.concat(words, " ", n + 1) end
  end
  return nil, msg
end

local function itemName(id)
  local recipe = ns.Recipes.Get(id)
  return (recipe and recipe.name) or GetItemInfo(id) or ("item " .. id)
end

function Core.PrintList()
  local results = ns.Profit.EvaluateAll(ns.Recipes.TrackedIDs(), ns.Prices.MakeContext())
  if #results == 0 then
    Util.Print("Nothing tracked yet. Tick \"Track\" on a recipe in your profession window.")
    return
  end
  for _, r in ipairs(results) do
    if r.status == "ok" then
      local margin = r.margin and (" (" .. floor(r.margin * 100 + 0.5) .. "%)") or ""
      Util.Print(r.name .. ": profit " .. Util.FormatMoneyShort(r.profit) .. margin
        .. ", cost " .. Util.FormatMoneyShort(r.cost) .. ", sell " .. Util.FormatMoneyShort(r.sell))
    else
      Util.Print(r.name .. ": missing prices for " .. table.concat(r.missing, ", "))
    end
  end
end

local function auctionHouseOpen()
  return AuctionFrame and AuctionFrame:IsShown()
end

local HELP = {
  "/cp - show or hide the panel (prints the list when the AH is closed)",
  "/cp scan - scan prices for your tracked crafts (AH open)",
  "/cp track - track or untrack the selected recipe in your profession window",
  "/cp price <item> <price> - set your own price, e.g. 1.5 or 1g50s; 'clear' removes it",
  "/cp cut <percent> - AH cut (5 normally, 15 at neutral AHs)",
  "/cp list - print profit for tracked crafts",
  "/cp reset prices - forget scanned AH prices for this realm and faction",
}

local commands = {}

function commands.scan()
  if not auctionHouseOpen() then
    Util.Print("Open the Auction House first.")
    return
  end
  local ok, err = ns.Scanner.StartTargeted(ns.Recipes.ScanList())
  if not ok then
    Util.Print(err == "busy" and "A scan is already running."
      or "Nothing tracked yet. Tick \"Track\" on a recipe in your profession window.")
  end
end

function commands.track()
  local id = ns.Recipes.SelectedProductID()
  if not id then
    Util.Print("Open your profession window and select a recipe first.")
    return
  end
  ns.Recipes.ReadSelected()
  local on = not ns.Recipes.IsTracked(id)
  ns.Recipes.SetTracked(id, on)
  Util.Print((on and "Now tracking " or "Stopped tracking ") .. itemName(id) .. ".")
end

function commands.price(rest)
  local id, value = Core.ParseItemArg(rest)
  local usage = "Usage: /cp price <item link or name> <price like 1.5 or 1g50s, or 'clear'>"
  if not id then
    Util.Print(usage)
    return
  end
  if value:lower() == "clear" then
    ns.Prices.SetManual(id, nil)
    Util.Print("Removed your price for " .. itemName(id) .. ".")
  else
    local copper = Util.ParseMoney(value)
    if not copper then
      Util.Print(usage)
      return
    end
    ns.Prices.SetManual(id, copper)
    Util.Print("Your price for " .. itemName(id) .. ": " .. Util.FormatMoney(copper))
  end
  ns.Fire("PRICES_CHANGED")
end

function commands.cut(rest)
  local percent = tonumber(rest)
  if not percent or percent < 0 or percent >= 100 then
    Util.Print("Usage: /cp cut <percent>, e.g. /cp cut 5")
    return
  end
  ns.db.cut = percent / 100
  Util.Print("AH cut set to " .. percent .. "%.")
  ns.Fire("PRICES_CHANGED")
end

function commands.list()
  Core.PrintList()
end

function commands.reset(rest)
  if rest:lower() ~= "prices" then
    Util.Print("Usage: /cp reset prices")
    return
  end
  local prices = ns.Prices.AllAH()
  for id in pairs(prices) do prices[id] = nil end
  Util.Print("Scanned AH prices cleared for " .. Util.RealmKey() .. ".")
  ns.Fire("PRICES_CHANGED")
end

function Core.Slash(msg)
  local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  if cmd == "" then
    if auctionHouseOpen() then
      ns.UI.EnsurePanel()
      ns.UI.Toggle()
    else
      Core.PrintList()
      Util.Print("Open the Auction House to see the panel.")
    end
  elseif commands[cmd] then
    commands[cmd](rest)
  else
    for _, line in ipairs(HELP) do Util.Print(line) end
  end
end

SLASH_CRAFTPROFIT1 = "/cp"
SLASH_CRAFTPROFIT2 = "/craftprofit"
SlashCmdList["CRAFTPROFIT"] = Core.Slash
