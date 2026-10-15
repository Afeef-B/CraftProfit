-- Minimal test runner for CraftProfit.
-- Usage: lua5.1 tests/run.lua [substring-filter]
package.path = "./tests/?.lua;" .. package.path

local write = io.write
local filter = arg[1]

local T = {}
function T.eq(actual, expected, msg)
  if actual ~= expected then
    error((msg and (msg .. ": ") or "") .. "expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end
function T.ok(value, msg)
  if not value then error(msg or "expected a truthy value", 2) end
end
function T.near(actual, expected, eps, msg)
  if type(actual) ~= "number" or math.abs(actual - expected) > (eps or 1e-9) then
    error((msg and (msg .. ": ") or "") .. "expected ~" .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local files = {}
local p = io.popen("ls tests/test_*.lua 2>/dev/null")
for f in p:lines() do files[#files + 1] = f end
p:close()

local pass, fail = 0, 0
for _, file in ipairs(files) do
  local ok, suite = pcall(dofile, file)
  if not ok then
    fail = fail + 1
    write("FAIL ", file, " (load)\n  ", tostring(suite), "\n")
  else
    local names = {}
    for name in pairs(suite) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local id = file .. ":" .. name
      if not filter or id:find(filter, 1, true) then
        local passed, err = xpcall(function() suite[name](T) end, debug.traceback)
        if passed then
          pass = pass + 1
        else
          fail = fail + 1
          write("FAIL ", id, "\n  ", tostring(err), "\n")
        end
      end
    end
  end
end

write(string.format("%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
