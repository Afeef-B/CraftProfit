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
  -- CP Sell and CP Auctions
  "NEW_AUCTION_UPDATE", "AUCTION_OWNED_LIST_UPDATE",
  "AUCTION_MULTISELL_START", "AUCTION_MULTISELL_UPDATE", "AUCTION_MULTISELL_FAILURE",
  "PLAYER_MONEY", "UI_ERROR_MESSAGE",
}
local BUTTON_REFRESH = 0.5

local frame = CreateFrame("Frame", "CraftProfitEventFrame")
local sinceButtons = 0

-- /cp diag: opening the profession window runs none of the setup below;
-- each /cp step runs the next step, so if the game hangs the player knows
-- exactly which step they just started.
local DIAG_STEPS = {
  { "create Track checkbox", function() ns.UI.CreateTrackButton() end },
  { "position Track label", function() ns.UI.PlaceTrackLabel() end },
  { "narrow recipe name", function() ns.UI.NarrowSkillName() end },
  { "hook recipe selection", function() ns.UI.HookSelection() end },
  { "read selected recipe", function() ns.Recipes.ReadSelected(true) end },
  { "refresh AH panel", function() ns.UI.Refresh() end },
  { "update Track checkbox", function() ns.UI.UpdateTrackButton() end },
  { "start background scan", function() ns.Recipes.StartBackgroundScan() end },
}

local function diagAnnounceNext()
  local step = ns.diag.step
  Util.Diag("Next: " .. step .. "/" .. #DIAG_STEPS .. " " .. DIAG_STEPS[step][1] .. " - type /cp step")
end

local function diagStartTailoring()
  local diag = ns.diag
  diag.updates, diag.step = 0, 1
  Util.Diag(string.format("0/%d Tailoring opened: %s rows, selected %s, ElvUI %s, AH panel %s",
    #DIAG_STEPS, tostring(GetNumTradeSkills()), tostring(GetTradeSkillSelectionIndex()),
    IsAddOnLoaded("ElvUI") and "yes" or "no", ns.UI.HasPanel() and "yes" or "no"))
  diagAnnounceNext()
end

local function diagStep()
  local diag = ns.diag
  if not diag or not diag.step then
    Util.Print("No diagnostic step waiting. Type /cp diag, then open Tailoring.")
    return
  end
  local index = diag.step
  local step = DIAG_STEPS[index]
  step[2]()
  Util.Diag(index .. "/" .. #DIAG_STEPS .. " " .. step[1] .. ": done")
  diag.step = index + 1
  if diag.step > #DIAG_STEPS then
    diag.step = nil
    Util.Diag("all " .. #DIAG_STEPS .. " steps ran without freezing. Background scan progress follows.")
  else
    diagAnnounceNext()
  end
end

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
  -- This character joins the ones whose auctions count as "you".
  ns.Listings.SetDB(db, Util.RealmKey(), UnitName("player"))
  ns.Lists.SetDB(db)
  ns.Sell.SetDB(db)
  ns.Auctions.SetDB(db)
end

function Core.OnUpdate(_, elapsed)
  ns.Scanner.Tick(elapsed)
  ns.Buyer.Tick(elapsed)
  ns.Buy.Tick(elapsed)
  ns.Recipes.Tick(elapsed)
  sinceButtons = sinceButtons + elapsed
  if sinceButtons >= BUTTON_REFRESH then
    sinceButtons = 0
    if ns.UI.IsVisible() then ns.UI.UpdateScanButtons() end
  end
end

function Core.OnEvent(event, arg1, arg2)
  if event == "PLAYER_LOGIN" then
    Core.InitDB()
    ns.Tooltip.Install()
    for _, e in ipairs(RUNTIME_EVENTS) do frame:RegisterEvent(e) end
    hooksecurefunc("QueryAuctionItems", ns.Scanner.OnQuery)
    frame:SetScript("OnUpdate", Core.OnUpdate)
    -- Another addon may already have loaded the (load-on-demand) AH UI.
    ns.UI.EnsurePanel()
  elseif event == "ADDON_LOADED" then
    if arg1 == "Blizzard_AuctionUI" then ns.UI.EnsurePanel() end
  elseif event == "TRADE_SKILL_SHOW" then
    -- Setup waits for PROFESSION_READY (window quiet for a moment).
    ns.Recipes.WindowOpened()
    if ns.diag then diagStartTailoring() end
  elseif event == "TRADE_SKILL_UPDATE" then
    if ns.diag then
      ns.diag.updates = (ns.diag.updates or 0) + 1
      if ns.diag.updates <= 3 then Util.Diag("TRADE_SKILL_UPDATE #" .. ns.diag.updates) end
    end
    ns.Recipes.NoteUpdate()
  elseif event == "TRADE_SKILL_CLOSE" then
    ns.Recipes.WindowClosed()
  elseif event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
    ns.Prices.RecordMerchant()
  elseif event == "AUCTION_HOUSE_SHOW" then
    ns.Scanner.SetAHOpen(true)
    ns.UI.ShowPanel()
    -- Not before the first show: addons that add AH tabs (Auctionator) build
    -- theirs when the AH UI loads, and ours take the first ids left after them.
    ns.Tabs.Ensure()
  elseif event == "AUCTION_ITEM_LIST_UPDATE" then
    ns.Scanner.HandleEvent(event)
    ns.Buyer.OnListUpdate()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    -- Told first: stopping the scan lets the pages that waited for it start
    -- theirs, and none may start now.
    ns.Scanner.SetAHOpen(false)
    ns.Scanner.HandleEvent(event)   -- stops a running scan
    ns.Buyer.Reset()
    ns.Sell.OnAuctionHouseClosed()
  elseif event == "NEW_AUCTION_UPDATE" then
    ns.Sell.OnSlotChanged(nil)      -- no new item: the one shown stays
  elseif event == "AUCTION_OWNED_LIST_UPDATE" then
    ns.Auctions.OnOwnedListUpdate()
  elseif event == "AUCTION_MULTISELL_START" or event == "AUCTION_MULTISELL_UPDATE"
      or event == "AUCTION_MULTISELL_FAILURE" then
    ns.Sell.OnMultisell(event, arg1, arg2)
  elseif event == "PLAYER_MONEY" then
    ns.Fire("MONEY_CHANGED")
  elseif event == "UI_ERROR_MESSAGE" then
    -- arg1 is the message in 3.3.5. Sell first: if the error ends a refused
    -- post, the page's red error line is drawn after Sell's own status.
    ns.Sell.OnPostError(arg1)
    ns.Fire("PAGE_ERROR", arg1)
  end
end

ns.On("PROFESSION_READY", function()
  if ns.diag then
    Util.Diag("window settled")
    return
  end
  ns.UI.EnsureTrackButton()
  ns.Recipes.ReadSelected()
  ns.UI.UpdateTrackButton()
  ns.Recipes.StartBackgroundScan()
end)

frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, ...) Core.OnEvent(event, ...) end)

-- Item id for a known recipe/material name (any case), else the item cache.
local function lookupName(name)
  local id = ns.Recipes.IdByName(name)
  if id then return id end
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
  "/cp outlier <percent> - a listing under this % of the next one is a mistake (1-99, default 50)",
  "/cp fresh <minutes> - don't rescan items scanned this recently (0-60, default 3)",
  "/cp post <items> <auctions> - stack size x auctions CP Sell starts with (default 2 x 1)",
  "/cp list - print profit for tracked crafts",
  "/cp reset prices - forget scanned AH prices for this realm and faction",
}

local commands = {}

function commands.scan()
  if not auctionHouseOpen() then
    Util.Print("Open the Auction House first.")
    return
  end
  local ok, err = ns.Scanner.StartTargeted(ns.Recipes.ScanList(), { skipFresh = true })
  if not ok then
    if err == "fresh" then
      Util.Print(ns.Scanner.statusText)
    else
      Util.Print(err == "busy" and "A scan is already running."
        or "Nothing tracked yet. Tick \"Track\" on a recipe in your profession window.")
    end
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

-- A listing under this share of the next one is a "mistake listing" (a flip).
-- Price checks already stored keep their marks until they are made again.
function commands.outlier(rest)
  local percent = tonumber(rest)
  if not percent or percent < 1 or percent > 99 or percent ~= floor(percent) then
    Util.Print("Usage: /cp outlier <1-99> (a listing under this % of the next one is a mistake; now "
      .. floor(ns.Listings.Ratio() * 100 + 0.5) .. ")")
    return
  end
  ns.db.outlierRatio = percent / 100
  Util.Print("Mistake listings: a listing under " .. percent .. "% of the next one. "
    .. "Applies to the next price check.")
end

-- Items scanned this recently are not searched again (Scan tracked, Search
-- all, cached listings); 0 always searches.
function commands.fresh(rest)
  if rest == "" then
    Util.Print("Items scanned in the last " .. floor(ns.Prices.FreshSeconds() / 60)
      .. " min are not scanned again. Change it with /cp fresh <0-60>.")
    return
  end
  local minutes = tonumber(rest)
  if not minutes or minutes < 0 or minutes > 60 or minutes ~= floor(minutes) then
    Util.Print("Usage: /cp fresh <0-60> (minutes; 0 always rescans)")
    return
  end
  ns.Prices.SetFreshSeconds(minutes * 60)
  Util.Print(minutes == 0 and "Every scan searches again now."
    or ("Items scanned in the last " .. minutes .. " min are not scanned again."))
end

-- The stack size x auctions CP Sell starts items not posted before at.
function commands.post(rest)
  local size, count = rest:match("^(%d+)%s+(%d+)$")
  if size and ns.Sell.SetDefault(size, count) then
    Util.Print("Default post: " .. size .. " x " .. count)
    return
  end
  local stack, stacks = ns.Sell.Default()
  Util.Print("Default post: " .. stack .. " x " .. stacks)
  Util.Print("Usage: /cp post <items> <auctions> (items 1-1000, auctions 1-100)")
end

function commands.diag()
  if ns.diag then
    ns.diag = nil
    Util.Print("Diagnostic mode is OFF.")
    return
  end
  ns.diag = { hooks = 0, updates = 0 }
  Util.Print("Diagnostic mode is ON. Now open Tailoring, then type /cp step to run one setup "
    .. "step at a time. If the game freezes, the step you just ran is the culprit.")
end

function commands.step()
  diagStep()
end

local function yesNo(value)
  return value and "yes" or "no"
end

function commands.status()
  local state, quiet, updates = ns.Recipes.WindowStatus()
  if state == "closed" then
    Util.Print("Profession window: closed")
  elseif state == "opening" then
    Util.Print(string.format("Profession window: opening (quiet %.1f s, %d updates since it opened)", quiet, updates))
  else
    Util.Print(string.format("Profession window: ready (%d updates since it opened)", updates))
  end

  local shown, visible, left, top = ns.UI.TrackButtonStatus()
  if shown == nil then
    Util.Print("Track checkbox: not created yet")
  else
    local where = ""
    if left and top then where = string.format(", at x %d y %d", left, top) end
    Util.Print("Track checkbox: created, shown " .. yesNo(shown) .. ", visible " .. yesNo(visible) .. where)
  end

  local index = GetTradeSkillSelectionIndex()
  local id = ns.Recipes.SelectedProductID()
  if id then
    Util.Print(string.format("Selected recipe: row %d, item %d (%s)%s", index, id, itemName(id),
      IsTradeSkillLinked() and ", linked profession" or ""))
  else
    Util.Print("Selected recipe: none (row " .. tostring(index) .. ")")
  end

  local known = 0
  for _ in pairs(ns.Recipes.All()) do known = known + 1 end
  Util.Print("Recipes known: " .. known .. ", tracked: " .. #ns.Recipes.TrackedIDs()
    .. ", ElvUI: " .. yesNo(IsAddOnLoaded("ElvUI")))
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
