-- Flip buy: another seller's "mistake listing" (far below the market) is
-- shown with a Buy button, and one click buys it out to resell.
-- The purchase itself goes through ns.Buyer, which places the bid only for a
-- row on the loaded page that matches the shown listing exactly (item, count,
-- buyout, seller), and only from the widget's button OnClick.
local addonName, ns = ...

local floor = math.floor

ns.Flip = {}
local Flip = ns.Flip

local RED = "|cffff4040"
local DEFAULT_CUT = 0.05
local WIDTH, HEIGHT = 340, 68
local BUTTON_WIDTH, BUTTON_HEIGHT = 170, 22

local REFUSED_CHANGED = "Listing changed - check again"

-- messages[id] = { row, state, text }: the last thing said about an item, shown
-- on the notice while that row is still shown in that state.
local messages = {}

-- { row, next, profit } for the item's mistake listing, or nil.
-- next is the price that marked it as a mistake (Listings.Summarize flipRef);
-- profit is what reselling it at that price nets after the AH cut.
function Flip.Info(id)
  local rows = ns.Listings.Get(id)
  if not rows then return nil end
  -- Random-enchant variants share the id, not the price: a cheap one is just a
  -- cheaper variant.
  if ns.Listings.MixedSuffix(rows) then return nil end
  local s = ns.Listings.Summarize(rows)
  if not s.flip or not s.flipRef then return nil end
  local cut = ns.db and ns.db.cut or DEFAULT_CUT
  local row = s.flip
  return {
    row = row,
    next = s.flipRef,
    profit = floor((s.flipRef * (1 - cut) - row.unit) * row.count),
  }
end

-- "idle" | "finding" | "ready" | "gone" | "bought"
function Flip.State(id)
  local info = Flip.Info(id)
  if not info then return "idle" end
  return ns.Buyer.State(info.row)
end

local function remember(id, row, state, text)
  if id and row then messages[id] = { row = row, state = state, text = text } end
end

-- Say something to the player: remembered for the notice while `row` is shown
-- in `state`, and sent to the page's status line.
local function say(id, row, state, text)
  remember(id, row, state, text)
  ns.Fire("PAGE_STATUS", text)
end

-- What was last said about the item's shown mistake listing, or nil.
function Flip.Message(id)
  local m = messages[id]
  if not m then return nil end
  local info = Flip.Info(id)
  if info and info.row == m.row and Flip.State(id) == m.state then return m.text end
  return nil
end

-- Buy the shown mistake listing. ok, msg. Call only from a button OnClick.
function Flip.Buy(id, name)
  local info = Flip.Info(id)
  if not info then
    local msg = "No mistake listing to buy."
    say(id, nil, nil, msg)
    return false, msg
  end
  return ns.Buyer.Buy(id, info.row, name)
end

-- The page-moving and timing now live in Buyer; these stay for old callers.
function Flip.OnListUpdate() ns.Buyer.OnListUpdate() end
function Flip.Tick(elapsed) ns.Buyer.Tick(elapsed) end
function Flip.Reset() ns.Buyer.Reset() end

ns.On("BUYER_CHANGED", function(id) ns.Fire("FLIP_CHANGED", id) end)
ns.On("BUYER_SAID", function(id, row, state, text) remember(id, row, state, text) end)
-- After a reset only what was said about bought listings still applies.
ns.On("BUYER_RESET", function()
  local kept = {}
  for id, m in pairs(messages) do
    if ns.Buyer.State(m.row) == "bought" then kept[id] = m end
  end
  messages = kept
end)

local widgetCount = 0

-- The red notice and Buy button for the item a page shows. getItem() returns
-- id, name. Hidden while the item has no mistake listing. The reply to a
-- click ("Bid placed for ...", "Not enough gold", ...) is added to the notice
-- (and sent as PAGE_STATUS). The page calls w:Update() when the shown item
-- changes; a click only works on the listing that was drawn.
-- Returns w with w.frame, w.notice, w.button and w:Update().
function Flip.CreateWidget(parent, getItem)
  local Util = ns.Util
  widgetCount = widgetCount + 1
  local frameName = "CraftProfitFlip" .. widgetCount

  local w = {}
  local frame = CreateFrame("Frame", frameName, parent)
  frame:SetWidth(WIDTH)
  frame:SetHeight(HEIGHT)
  w.frame = frame

  local notice = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  notice:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  notice:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  notice:SetJustifyH("LEFT")
  notice:SetJustifyV("TOP")
  w.notice = notice

  local button = CreateFrame("Button", frameName .. "Buy", frame, "UIPanelButtonTemplate")
  button:SetWidth(BUTTON_WIDTH)
  button:SetHeight(BUTTON_HEIGHT)
  button:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
  w.button = button

  -- The listing on screen: a click may only act on exactly this.
  local drawnId, drawnRow

  function w.Update(self)
    local id = getItem()
    local info = id and Flip.Info(id)
    if not info then
      drawnId, drawnRow = nil, nil
      frame:Hide()
      return
    end
    local row = info.row
    drawnId, drawnRow = id, row

    -- A click spends the whole stack, not the price each: every label that can
    -- lead to a purchase says how much.
    local state = Flip.State(id)
    local total = " (" .. Util.FormatMoney(row.buyout) .. ")"
    local label, enabled
    if state == "finding" then
      label, enabled = "Finding it...", false
    elseif state == "ready" then
      label, enabled = "Buy now" .. total, true
    elseif state == "gone" then
      label, enabled = "Gone - try again" .. total, true
    elseif state == "bought" then
      label, enabled = "Bought", false
    else
      label, enabled = "Buy it" .. total, true
    end

    local text = RED .. Util.ICON_GOLD .. " Possible mistake: " .. (row.seller or "?")
      .. " sells " .. row.count .. " at " .. Util.FormatMoney(row.unit)
      .. " (next " .. Util.FormatMoney(info.next) .. "). Flip profit ~"
      .. Util.FormatMoney(info.profit) .. "|r"
    local message = Flip.Message(id)
    if message and message ~= label then text = text .. "\n" .. message end
    notice:SetText(text)

    button:SetText(label)
    if enabled then button:Enable() else button:Disable() end
    frame:Show()
  end

  button:SetScript("OnClick", function()
    local id, name = getItem()
    local info = id and Flip.Info(id)
    if not drawnRow or id ~= drawnId or not info or info.row ~= drawnRow then
      -- What is on screen is not what a click would buy: show the real thing.
      say(id, info and info.row, id and Flip.State(id), REFUSED_CHANGED)
      w:Update()
      return
    end
    Flip.Buy(id, name)
    w:Update()
  end)

  -- Redraw when the state or the listings of the shown item change.
  local function refresh(id)
    if id == getItem() then w:Update() end
  end
  ns.On("FLIP_CHANGED", refresh)
  ns.On("LISTINGS_UPDATED", refresh)

  frame:Hide()
  return w
end
