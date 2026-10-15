-- Shared helpers: event bus, clock, money and item-link handling.
local addonName, ns = ...

local floor = math.floor

ns.Util = {}
local Util = ns.Util

-- Tiny synchronous event bus so modules don't reference each other's internals.
local listeners = {}

function ns.On(event, fn)
  listeners[event] = listeners[event] or {}
  table.insert(listeners[event], fn)
end

function ns.Fire(event, ...)
  local list = listeners[event]
  if not list then return end
  for i = 1, #list do
    list[i](...)
  end
end

function ns.Now()
  return time()
end

-- 12345 -> "1g 23s 45c"; zero units are left out.
function Util.FormatMoney(copper)
  copper = floor(copper + 0.5)
  local sign = ""
  if copper < 0 then
    sign = "-"
    copper = -copper
  end
  local gold = floor(copper / 10000)
  local silver = floor(copper / 100) % 100
  local cop = copper % 100
  local parts = {}
  if gold > 0 then parts[#parts + 1] = gold .. "g" end
  if silver > 0 then parts[#parts + 1] = silver .. "s" end
  if cop > 0 then parts[#parts + 1] = cop .. "c" end
  if #parts == 0 then return "0c" end
  return sign .. table.concat(parts, " ")
end

-- Compact form for table cells: gold+silver, or silver+copper below 1g.
function Util.FormatMoneyShort(copper)
  copper = floor(copper + 0.5)
  local sign = ""
  if copper < 0 then
    sign = "-"
    copper = -copper
  end
  local gold = floor(copper / 10000)
  local silver = floor(copper / 100) % 100
  local cop = copper % 100
  local text
  if gold > 0 then
    text = gold .. "g" .. (silver > 0 and (" " .. silver .. "s") or "")
  elseif silver > 0 then
    text = silver .. "s" .. (cop > 0 and (" " .. cop .. "c") or "")
  else
    text = cop .. "c"
  end
  return sign .. text
end

-- "1.5" (gold) or "1g 50s 20c" -> copper; nil when unreadable.
function Util.ParseMoney(str)
  if type(str) ~= "string" then return nil end
  str = str:gsub("%s+", ""):lower()
  if str == "" then return nil end

  local number = tonumber(str)
  if number then
    if number < 0 then return nil end
    return floor(number * 10000 + 0.5)
  end

  local total, matched = 0, false
  local rest = str:gsub("(%d+)([gsc])", function(amount, unit)
    matched = true
    local mult = (unit == "g" and 10000) or (unit == "s" and 100) or 1
    total = total + tonumber(amount) * mult
    return ""
  end)
  if not matched or rest ~= "" then return nil end
  return total
end

function Util.ItemIDFromLink(link)
  if type(link) ~= "string" then return nil end
  local id = link:match("item:(%d+)")
  return id and tonumber(id) or nil
end

-- "|Hitem:...|h[Frostweave Bag]|h" -> "Frostweave Bag"
function Util.ItemNameFromLink(link)
  if type(link) ~= "string" then return nil end
  return link:match("|h%[(.-)%]|h")
end

function Util.FormatAge(seconds)
  if seconds < 60 then return "now" end
  if seconds < 3600 then return floor(seconds / 60) .. "m" end
  if seconds < 86400 then return floor(seconds / 3600) .. "h" end
  return floor(seconds / 86400) .. "d"
end

-- Prices are kept per realm and faction because each AH is separate.
function Util.RealmKey()
  return GetRealmName() .. "-" .. (UnitFactionGroup("player") or "Neutral")
end

function Util.Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99" .. addonName .. "|r: " .. msg)
end
