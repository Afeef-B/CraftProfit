-- Prices outside the Auction House: CraftProfit's last AH price and its age,
-- the craft cost of the player's recipes, and what a bag stack is worth, on
-- the game's item tooltips. Reads the price database only; never searches.
local addonName, ns = ...

ns.Tooltip = {}
local Tooltip = ns.Tooltip

local R, G, B = 0.4, 0.8, 1

local installed = false

local function ageText(seconds)
  local age = ns.Util.FormatAge(seconds)
  if age == "now" then return "just now" end
  return age .. " ago"
end

-- The lines for item `id`: its AH price (or why there is none) and, for a
-- recipe the player knows, what one costs to craft.
function Tooltip.Lines(id)
  local out = {}
  local unit, t = ns.Prices.GetAH(id)
  if unit then
    out[1] = "CraftProfit AH: " .. ns.Style.Money(unit) .. " (" .. ageText(ns.Now() - t) .. ")"
  elseif t then
    out[1] = "CraftProfit AH: none listed (" .. ageText(ns.Now() - t) .. ")"
  else
    out[1] = "CraftProfit AH: not seen yet"
  end
  if ns.Recipes.Get(id) then
    local result = ns.Profit.Evaluate(id, ns.Prices.MakeContext())
    if result and result.cost then
      local depth = ns.Recipes.Depth(id) == "scratch" and "from scratch" or "ready-made"
      out[#out + 1] = "Craft cost: " .. ns.Style.Money(result.cost / result.made) .. " (" .. depth .. ")"
    else
      out[#out + 1] = "Craft cost: missing prices"
    end
  end
  return out
end

-- "x20: 250g" for a stack of `count` with an AH price, else nil.
function Tooltip.StackLine(id, count)
  local unit = ns.Prices.GetAH(id)
  if not unit or not count or count <= 1 then return nil end
  return "x" .. count .. ": " .. ns.Style.Money(unit * count)
end

-- The client may set the same item twice in one show: add the lines once,
-- until the tooltip is cleared.
local function onSetItem(tip)
  if tip.craftProfitDone then return end
  local _, link = tip:GetItem()
  local id = ns.Util.ItemIDFromLink(link)
  if not id then return end
  tip.craftProfitDone = true
  for _, line in ipairs(Tooltip.Lines(id)) do tip:AddLine(line, R, G, B) end
end

local function onCleared(tip)
  tip.craftProfitDone, tip.craftProfitStack = nil, nil
end

-- Only a bag slot says how many there are: runs after the item's own lines.
local function onBagItem(tip, bag, slot)
  if tip.craftProfitStack then return end
  local _, count = GetContainerItemInfo(bag, slot)
  local id = ns.Util.ItemIDFromLink(GetContainerItemLink(bag, slot))
  local line = id and Tooltip.StackLine(id, count)
  if not line then return end
  tip.craftProfitStack = true
  tip:AddLine(line, R, G, B)
  tip:Show() -- resize to the new line
end

function Tooltip.Install()
  if installed then return end
  installed = true
  for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do
    tip:HookScript("OnTooltipSetItem", onSetItem)
    tip:HookScript("OnTooltipCleared", onCleared)
  end
  hooksecurefunc(GameTooltip, "SetBagItem", onBagItem)
end
