-- Mock of the WoW 3.3.5a API surface CraftProfit uses.
-- Mock.reset() installs fresh globals; Mock.load(files) runs addon files
-- the way the client does: each chunk receives (addonName, ns).
local Mock = {}
Mock.root = "CraftProfit/"

function Mock.reset()
  Mock.now = 1000000
  Mock.chat = {}
  Mock.hooks = {}

  time = function() return Mock.now end
  GetRealmName = function() return "Icecrown" end
  UnitFactionGroup = function() return "Alliance" end
  hooksecurefunc = function(name, fn)
    local orig = _G[name]
    Mock.hooks[name] = fn
    _G[name] = function(...)
      local a, b, c, d = orig(...)
      fn(...)
      return a, b, c, d
    end
  end
  DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) Mock.chat[#Mock.chat + 1] = msg end }
end

function Mock.load(files)
  local ns = {}
  for _, f in ipairs(files) do
    local chunk = assert(loadfile(Mock.root .. f))
    chunk("CraftProfit", ns)
  end
  return ns
end

return Mock
