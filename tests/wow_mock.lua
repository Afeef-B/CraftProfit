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
  Mock.playerName = "Me"
  UnitName = function() return Mock.playerName or "Me" end
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
  -- Auction House: Mock.ah.auctions = { {id, name, count, buyout, seller?} }
  -- (seller defaults to "Seller"; Mock.ah.nilOwners hides every owner name, as
  -- the client does while names are still loading).
  -- QueryAuctionItems fills the "list" view; tests deliver the event.
  Mock.ah = { auctions = {}, canQuery = true, canQueryAll = true, nilLinks = false, nilOwners = false }
  Mock.queries = {}
  Mock.pending = false
  Mock.list, Mock.total = {}, 0
  NUM_AUCTION_ITEMS_PER_PAGE = 50
  QueryAuctionItems = function(...)
    local q = { n = select("#", ...), ... }
    Mock.queries[#Mock.queries + 1] = q
    local name, page, getAll = q[1], q[7] or 0, q[10]
    local matches = {}
    for _, a in ipairs(Mock.ah.auctions) do
      if getAll or a.name:lower():find((name or ""):lower(), 1, true) then
        matches[#matches + 1] = a
      end
    end
    Mock.list, Mock.total = {}, #matches
    if getAll then
      Mock.list = matches
    else
      for i = page * 50 + 1, math.min(#matches, page * 50 + 50) do
        Mock.list[#Mock.list + 1] = matches[i]
      end
    end
    Mock.pending = true
  end
  CanSendAuctionQuery = function() return Mock.ah.canQuery, Mock.ah.canQueryAll end
  GetNumAuctionItems = function(kind) return #Mock.list, Mock.total end
  GetAuctionItemInfo = function(kind, i)
    local a = Mock.list[i]
    local owner = nil
    if not Mock.ah.nilOwners then owner = a.seller or "Seller" end
    return a.name, "tex", a.count, 1, 1, 80, 1, 0, a.buyout, 0, nil, owner
  end
  GetAuctionItemLink = function(kind, i)
    local a = Mock.list[i]
    if Mock.ah.nilLinks or a.nilLink then return nil end
    return Mock.Link(a.id, a.name)
  end

  -- Buying out a row of the "list" page: recorded in Mock.bought (one
  -- { kind, index, amount, auction } per call), the auction leaves the page
  -- and the AH, and the money goes.
  Mock.money = 1000000000
  Mock.bought = {}
  GetMoney = function() return Mock.money end
  PlaceAuctionBid = function(kind, i, amount)
    local a = Mock.list[i]
    Mock.bought[#Mock.bought + 1] = { kind = kind, index = i, amount = amount, auction = a }
    if kind ~= "list" or not a then return end
    table.remove(Mock.list, i)
    Mock.total = math.max(0, Mock.total - 1)
    for j, auction in ipairs(Mock.ah.auctions) do
      if auction == a then
        table.remove(Mock.ah.auctions, j)
        break
      end
    end
    Mock.money = Mock.money - amount
  end

  Mock.reagentLinkCalls = 0
  GetTradeSkillReagentItemLink = function(i, j)
    Mock.reagentLinkCalls = Mock.reagentLinkCalls + 1
    local r = Mock.trade.rows[i].reagents[j]
    if r.uncached then return nil end
    return Mock.Link(r.id, r.name)
  end
end

-- Permissive widget mock: unknown methods are no-ops; the ones the UI reads
-- back (text, shown, checked, enabled, scripts) are tracked.
local FrameMethods = {}
local FrameMeta = {}
local function noop() end
-- WoW widget methods are CamelCase; lowercase keys are plain data fields.
FrameMeta.__index = function(_, key)
  if FrameMethods[key] then return FrameMethods[key] end
  if type(key) == "string" and key:match("^%u") then return noop end
  return nil
end

local function newObject(name)
  return setmetatable({ _name = name, _shown = true, _enabled = true, _scripts = {} }, FrameMeta)
end
Mock.newObject = newObject

function FrameMethods.CreateFontString(_, name) return newObject(name) end
function FrameMethods.CreateTexture(_, name) return newObject(name) end
function FrameMethods.GetName(self) return self._name end
function FrameMethods.Show(self) self._shown = true end
function FrameMethods.Hide(self) self._shown = false end
function FrameMethods.IsShown(self) return self._shown end
function FrameMethods.IsVisible(self) return self._shown end
function FrameMethods.SetShown(self, v) self._shown = v and true or false end
function FrameMethods.SetScript(self, kind, fn) self._scripts[kind] = fn end
function FrameMethods.GetScript(self, kind) return self._scripts[kind] end
function FrameMethods.SetText(self, text) self._text = text end
function FrameMethods.GetText(self) return self._text end
function FrameMethods.SetFormattedText(self, fmt, ...) self._text = string.format(fmt, ...) end
function FrameMethods.SetChecked(self, v) self._checked = v end
function FrameMethods.GetChecked(self) return self._checked end
function FrameMethods.Enable(self) self._enabled = true end
function FrameMethods.Disable(self) self._enabled = false end
function FrameMethods.IsEnabled(self) return self._enabled end
function FrameMethods.SetTexture(self, tex) self._texture = tex end
function FrameMethods.GetWidth() return 0 end
function FrameMethods.GetHeight() return 0 end
function FrameMethods.AddLine(self, text) table.insert(Mock.tooltip, text or "") end
function FrameMethods.AddDoubleLine(self, left, right) table.insert(Mock.tooltip, (left or "") .. " | " .. (right or "")) end
function FrameMethods.ClearLines() Mock.tooltip = {} end
function FrameMethods.SetID(self, id) self._id = id end
function FrameMethods.GetID(self) return self._id or 0 end
function FrameMethods.SetBackdrop(self, backdrop) self._backdrop = backdrop end
-- SetPoint(point [, relativeTo, relativePoint] [, x, y]): one entry per point,
-- a repeated point replaces the old anchor, as in the client.
function FrameMethods.SetPoint(self, point, relativeTo, relativePoint, x, y)
  if type(relativeTo) == "number" then
    relativeTo, relativePoint, x, y = nil, nil, relativeTo, relativePoint
  end
  local entry = { point = point, rel = relativeTo, relPoint = relativePoint or point, x = x or 0, y = y or 0 }
  self._points = self._points or {}
  for i, old in ipairs(self._points) do
    if old.point == point then
      self._points[i] = entry
      return
    end
  end
  self._points[#self._points + 1] = entry
end

function Mock.installUI()
  -- Named frames from earlier tests must not leak into this one.
  local stale = {}
  for key in pairs(_G) do
    if type(key) == "string" and key:match("^CraftProfit") then stale[#stale + 1] = key end
  end
  for _, key in ipairs(stale) do _G[key] = nil end
  for key in pairs(_G) do
    if type(key) == "string" and key:match("^AuctionFrameTab%d+$") then _G[key] = nil end
  end
  Mock.tooltip = {}
  Mock.popup = nil
  CreateFrame = function(kind, name, parent, template)
    local f = newObject(name)
    f._kind, f._parent, f._template = kind, parent, template
    if name then
      _G[name] = f
      if template == "FauxScrollFrameTemplate" then _G[name .. "ScrollBar"] = newObject(name .. "ScrollBar") end
      if template == "UICheckButtonTemplate" then _G[name .. "Text"] = newObject(name .. "Text") end
    end
    if template == "AuctionTabTemplate" then
      -- The template's OnClick forwards to the global (looked up at click time,
      -- so a hooksecurefunc wrapper is honoured).
      f._scripts.OnClick = function(self, button, down) AuctionFrameTab_OnClick(self, button, down) end
    end
    return f
  end
  UIParent = newObject("UIParent")
  AuctionFrame = newObject("AuctionFrame")
  -- Blizzard's tabs: ids 1-3, each anchored to the previous tab's TOPRIGHT at x -8.
  Mock.numTabs, Mock.selectedTab, Mock.lastTab = nil, nil, nil
  for i = 1, 3 do
    local tab = CreateFrame("Button", "AuctionFrameTab" .. i, AuctionFrame, "AuctionTabTemplate")
    tab:SetID(i)
    if i > 1 then tab:SetPoint("TOPLEFT", _G["AuctionFrameTab" .. (i - 1)], "TOPRIGHT", -8, 0) end
  end
  PanelTemplates_SetNumTabs = function(frame, n)
    frame.numTabs = n
    Mock.numTabs = n
  end
  PanelTemplates_SetTab = function(frame, id)
    frame.selectedTab = id
    Mock.selectedTab = id
  end
  PanelTemplates_TabResize = function(tab, padding) tab._resized = padding end
  -- Blizzard's handler would also hide/show its own pages; the mock only records.
  AuctionFrameTab_OnClick = function(self)
    local id = self:GetID()
    PanelTemplates_SetTab(AuctionFrame, id)
    Mock.lastTab = id
  end
  TradeSkillFrame = newObject("TradeSkillFrame")
  TradeSkillDetailScrollChildFrame = newObject("TradeSkillDetailScrollChildFrame")
  TradeSkillSkillName = newObject("TradeSkillSkillName")
  GameTooltip = newObject("GameTooltip")
  TradeSkillFrame_SetSelection = function() end
  FauxScrollFrame_Update = function() end
  FauxScrollFrame_GetOffset = function(frame) return frame.offset end
  FauxScrollFrame_OnVerticalScroll = function() end
  StaticPopupDialogs = {}
  StaticPopup_Show = function(which) Mock.popup = which end
  -- EasyMenu(menuList, menuFrame, anchor, x, y, displayMode): tests read Mock.menu.
  Mock.menu, Mock.menuAnchor = nil, nil
  EasyMenu = function(menuList, menuFrame, anchor)
    Mock.menu, Mock.menuFrame, Mock.menuAnchor = menuList, menuFrame, anchor
  end
  SlashCmdList = {}
  IsAddOnLoaded = function(name) return Mock.loadedAddOns and Mock.loadedAddOns[name] or nil end
  CraftProfitDB, CraftProfitCharDB = nil, nil
  SLASH_CRAFTPROFIT1, SLASH_CRAFTPROFIT2 = nil, nil
end

-- Answer the last query, as the server would.
function Mock.deliver(ns)
  if Mock.pending then
    Mock.pending = false
    ns.Scanner.HandleEvent("AUCTION_ITEM_LIST_UPDATE")
    return true
  end
  return false
end

-- Tick the scanner and answer queries until it goes idle.
function Mock.pump(ns, maxSteps)
  for _ = 1, maxSteps or 500 do
    ns.Scanner.Tick(0.1)
    Mock.deliver(ns)
    if not ns.Scanner.IsBusy() then return true end
  end
  return false
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
