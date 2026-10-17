-- Whole-addon guards: the three calls that spend or cancel exist once each, in
-- the one module that is allowed to make them. Comments don't count.
local Mock = require("wow_mock")

local function read(path)
  local f = assert(io.open(path, "r"))
  local src = f:read("*a")
  f:close()
  return src
end

-- The source with block comments, line comments and string contents blanked.
-- (The addon has no long strings.)
local function code(src)
  src = src:gsub("%-%-%[(=*)%[.-%]%1%]", "")
  local lines = {}
  for line in (src .. "\n"):gmatch("(.-)\n") do
    -- a "--" inside a string is text, not a comment
    local out, quote = {}, nil
    local i = 1
    while i <= #line do
      local c = line:sub(i, i)
      if quote then
        if c == "\\" then
          i = i + 1
        elseif c == quote then
          quote = nil
        end
        out[#out + 1] = " "
      elseif c == '"' or c == "'" then
        quote = c
        out[#out + 1] = c
      elseif c == "-" and line:sub(i + 1, i + 1) == "-" then
        break
      else
        out[#out + 1] = c
      end
      i = i + 1
    end
    lines[#lines + 1] = table.concat(out)
  end
  return table.concat(lines, "\n")
end

-- How many times `name` appears as a whole identifier, and how many of those
-- are calls (followed by an opening bracket).
local function uses(src, name)
  local all, calls = 0, 0
  local pos = 1
  while true do
    local s, e = src:find(name, pos, true)
    if not s then break end
    local before, after = src:sub(s - 1, s - 1), src:sub(e + 1, e + 1)
    if not before:match("[%w_]") and not after:match("[%w_]") then
      all = all + 1
      if src:sub(e + 1):match("^%s*%(") then calls = calls + 1 end
    end
    pos = e + 1
  end
  return all, calls
end

local function addonFiles()
  local files = {}
  local p = io.popen("ls " .. Mock.root .. "*.lua")
  for f in p:lines() do files[#files + 1] = f end
  p:close()
  return files
end

return {
  -- A purchase, a new auction and a cancel each have one call site in the whole
  -- addon, in Buyer.lua / Sell.lua / Auctions.lua. (Each is reached only from a
  -- click; the module tests check which function the call sits in.)
  money_calls_have_one_call_site_each = function(T)
    local expected = {
      PlaceAuctionBid = "Buyer.lua", StartAuction = "Sell.lua", CancelAuction = "Auctions.lua",
    }
    local files = addonFiles()
    T.ok(#files >= 15, "found the addon files")
    for name, owner in pairs(expected) do
      local total = 0
      for _, path in ipairs(files) do
        local all, calls = uses(code(read(path)), name)
        local base = path:match("[^/]+$")
        if base == owner then
          T.eq(calls, 1, name .. " is called once in " .. owner)
          T.eq(all, 1, name .. " is not passed around in " .. owner)
        else
          T.eq(all, 0, name .. " does not appear in " .. base)
        end
        total = total + calls
      end
      T.eq(total, 1, name .. " has exactly one call site")
    end
  end,

  -- Who may start a purchase: Buyer.Buy is called by Flip.Buy and by CP Buy's
  -- two buy functions only, and those are called only from their buttons'
  -- click handlers in FlipUI / BuyUI.
  purchase_callers_are_pinned = function(T)
    local callers = {
      ["Buyer.Buy"] = {}, ["Buy.BuyCheapest"] = {}, ["Buy.BuyRow"] = {}, ["Buy.BuyGroup"] = {}, ["Flip.Buy"] = {},
    }
    for _, path in ipairs(addonFiles()) do
      local src = code(read(path))
      local base = path:match("[^/]+$")
      for name, where in pairs(callers) do
        local _, calls = uses(src, name)
        -- the definition "function X(" is not a call site
        local defs = 0
        for _ in src:gmatch("function%s+" .. name:gsub("%.", "%%.") .. "%s*%(") do defs = defs + 1 end
        if calls - defs > 0 then where[base] = (where[base] or 0) + calls - defs end
      end
    end
    local function only(name, expected)
      local got = {}
      for base, n in pairs(callers[name]) do got[#got + 1] = base .. "=" .. n end
      table.sort(got)
      T.eq(table.concat(got, " "), expected, name .. " call sites")
    end
    only("Buyer.Buy", "Buy.lua=1 Flip.lua=1")
    only("Flip.Buy", "Flip.lua=1")
    only("Buy.BuyCheapest", "BuyUI.lua=1")
    only("Buy.BuyRow", "BuyUI.lua=1")
    only("Buy.BuyGroup", "")

    -- in Buy.lua the one Buyer.Buy sits in buyRow, which only the three buy
    -- functions call
    local buy = code(read(Mock.root .. "Buy.lua"))
    local body = buy:match("local function buyRow%(row%)(.-)\nend")
    T.ok(body and body:find("Buyer.Buy(", 1, true), "Buyer.Buy inside buyRow")
    local _, rowCalls = buy:gsub("buyRow%(", "")
    T.eq(rowCalls - 1, 3, "buyRow: BuyCheapest, BuyGroup, BuyRow")
    for _, fn in ipairs({ "BuyCheapest", "BuyGroup", "BuyRow" }) do
      local f = buy:match("function Buy%." .. fn .. "%(.-%)(.-)\nend")
      T.ok(f and f:find("buyRow(", 1, true), fn .. " goes through buyRow")
    end

    -- and in BuyUI they sit inside the click handlers wired to the buttons
    local ui = code(read(Mock.root .. "BuyUI.lua"))
    local cheapest = ui:match("local function onBuyCheapest%(%)(.-)\nend")
    local row = ui:match("local function onBuyRow%(%)(.-)\nend")
    T.ok(cheapest and cheapest:find("Buy.BuyCheapest(", 1, true), "BuyCheapest in onBuyCheapest")
    T.ok(row and row:find("Buy.BuyRow(", 1, true), "BuyRow in onBuyRow")
    local raw = read(Mock.root .. "BuyUI.lua")
    T.ok(raw:find('SetScript("OnClick", onBuyCheapest)', 1, true), "wired to a click")
    T.ok(raw:find('SetScript("OnClick", onBuyRow)', 1, true), "wired to a click")
    for _, handler in ipairs({ "onBuyCheapest", "onBuyRow" }) do
      local _, calls = uses(ui, handler)
      local _, defs = ui:gsub("local function " .. handler .. "%(", "")
      T.eq(calls - defs, 0, handler .. " is only passed to SetScript, never called by other code")
    end
  end,

  -- The scrubber behind the test above: a mention in a comment or a string is
  -- not a call, a call is, and the neighbours of the names are told apart.
  call_site_counter = function(T)
    local function count(src, name)
      local all, calls = uses(code(src), name)
      return all, calls
    end
    local all, calls = count("-- PlaceAuctionBid(\"list\", 1, 2)\nlocal x = 1", "PlaceAuctionBid")
    T.eq(all, 0); T.eq(calls, 0)
    all, calls = count("--[[ StartAuction(1) ]] local y = 2", "StartAuction")
    T.eq(all, 0)
    all, calls = count("--[==[\nStartAuction(1)\n]==]\nlocal y", "StartAuction")
    T.eq(all, 0)
    all, calls = count('local s = "CancelAuction(1) -- not a comment"\nlocal z = 1', "CancelAuction")
    T.eq(all, 0, "text in a string")
    all, calls = count("CancelAuction(index)", "CancelAuction")
    T.eq(all, 1); T.eq(calls, 1)
    all, calls = count("if CanCancelAuction(index) then end", "CancelAuction")
    T.eq(all, 0, "CanCancelAuction is another function")
    all, calls = count("local bid = PlaceAuctionBid\nbid(1)", "PlaceAuctionBid")
    T.eq(all, 1); T.eq(calls, 0)
    all, calls = count("PlaceAuctionBid ( \"list\" ) -- bid", "PlaceAuctionBid")
    T.eq(all, 1); T.eq(calls, 1)
    all, calls = count("x = 1 -- StartAuction(1)\nStartAuction(2)", "StartAuction")
    T.eq(all, 1); T.eq(calls, 1)
  end,
}
