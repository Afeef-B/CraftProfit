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

  -- Item cache: Mock.items[id] = { name = "..." }
  Mock.items = {}
  GetItemInfo = function(id)
    if type(id) == "string" then
      for itemID, item in pairs(Mock.items) do
        if item.name == id then id = itemID break end
      end
    end
    local item = Mock.items[id]
    if not item then return nil end
    return item.name, Mock.Link(id, item.name)
  end

  -- Merchant: Mock.merchant = { { id, name, price, quantity, extendedCost } }
  Mock.merchant = {}
  GetMerchantNumItems = function() return #Mock.merchant end
  GetMerchantItemInfo = function(i)
    local m = Mock.merchant[i]
    return m.name, "tex", m.price, m.quantity, -1, 1, m.extendedCost
  end
  GetMerchantItemLink = function(i)
    local m = Mock.merchant[i]
    return Mock.Link(m.id, m.name)
  end

  Auctionator = nil
  Atr_GetAuctionBuyout = nil

  -- Profession window: Mock.trade.rows = { {type="header", name=...} or
  --   {name, id, link?, min?, max?, reagents = { {id, name, count, uncached?} }} }
  Mock.trade = { line = "Tailoring", linked = nil, selected = 0, rows = {} }
  GetTradeSkillLine = function() return Mock.trade.line, 400, 450 end
  IsTradeSkillLinked = function() return Mock.trade.linked end
  GetNumTradeSkills = function() return #Mock.trade.rows end
  GetTradeSkillSelectionIndex = function() return Mock.trade.selected end
  GetTradeSkillInfo = function(i)
    local row = Mock.trade.rows[i]
    if not row then return nil end
    return row.recipeName or row.name, row.type or "optimal", 0, true
  end
  GetTradeSkillItemLink = function(i)
    local row = Mock.trade.rows[i]
    if not row or row.type == "header" then return nil end
    return row.link or Mock.Link(row.id, row.name)
  end
  GetTradeSkillNumMade = function(i)
    local row = Mock.trade.rows[i]
    return row.min or 1, row.max or row.min or 1
  end
  GetTradeSkillNumReagents = function(i) return #(Mock.trade.rows[i].reagents or {}) end
  GetTradeSkillReagentInfo = function(i, j)
    local r = Mock.trade.rows[i].reagents[j]
    return r.name, "tex", r.count, 0
  end
  GetTradeSkillReagentItemLink = function(i, j)
    local r = Mock.trade.rows[i].reagents[j]
    if r.uncached then return nil end
    return Mock.Link(r.id, r.name)
  end
end

function Mock.Link(id, name)
  return "|cffffffff|Hitem:" .. id .. ":0:0:0:0:0:0:0:80|h[" .. (name or "?") .. "]|h|r"
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
