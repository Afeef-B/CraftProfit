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
  -- addon, in Flip.lua / Sell.lua / Auctions.lua. (Each is reached only from a
  -- click; the module tests check which function the call sits in.)
  money_calls_have_one_call_site_each = function(T)
    local expected = {
      PlaceAuctionBid = "Flip.lua", StartAuction = "Sell.lua", CancelAuction = "Auctions.lua",
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
