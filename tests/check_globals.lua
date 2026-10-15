-- Static check: every global the addon reads must be a known Lua/WoW name
-- (catches typos like GetAuctonItemInfo), and the only globals it writes
-- are the saved variables and slash-command names.
-- Usage: lua5.1 tests/check_globals.lua [files...]  (default: CraftProfit/*.lua)

local ALLOWED_WRITES = {
  CraftProfitDB = true, CraftProfitCharDB = true,
  SLASH_CRAFTPROFIT1 = true, SLASH_CRAFTPROFIT2 = true,
}

local KNOWN_READS = {}
for name in ([[
  _G assert error ipairs next pairs pcall print rawget rawset select setmetatable
  getmetatable tonumber tostring type unpack xpcall math string table wipe
  time date strsplit hooksecurefunc
  GetRealmName UnitFactionGroup DEFAULT_CHAT_FRAME
]]):gmatch("%S+") do KNOWN_READS[name] = true end

local files = { ... }
if #files == 0 then
  local p = io.popen("ls CraftProfit/*.lua")
  for f in p:lines() do files[#files + 1] = f end
  p:close()
end

local problems = 0
for _, file in ipairs(files) do
  local p = io.popen("luac5.1 -l -p " .. file .. " 2>&1")
  local out = p:read("*a")
  p:close()
  for op, name in out:gmatch("([GS]ETGLOBAL)%s+[^;\n]*;%s*([%w_]+)") do
    if op == "SETGLOBAL" and not ALLOWED_WRITES[name] then
      problems = problems + 1
      print(file .. ": writes global '" .. name .. "'")
    elseif op == "GETGLOBAL" and not KNOWN_READS[name] and not ALLOWED_WRITES[name] then
      problems = problems + 1
      print(file .. ": reads unknown global '" .. name .. "'")
    end
  end
end

if problems == 0 then
  print("globals OK (" .. #files .. " files)")
  os.exit(0)
end
os.exit(1)
