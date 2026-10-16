local Mock = require("wow_mock")

local GOLD = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

local function load()
  Mock.reset()
  Mock.installUI()
  return Mock.load({ "Util.lua", "Style.lua" })
end

return {
  style_money_parts = function(T)
    local S = load().Style
    T.eq(S.Money(123456), "12" .. GOLD .. " 34" .. SILVER .. " 56" .. COPPER)
    T.eq(S.Money(50000), "5" .. GOLD)
    T.eq(S.Money(10203), "1" .. GOLD .. " 2" .. SILVER .. " 3" .. COPPER)
    T.eq(S.Money(99), "99" .. COPPER)
    T.eq(S.Money(0), "0" .. COPPER)
    T.eq(S.Money(nil), "-")
    T.eq(S.Money(1234.6), "12" .. SILVER .. " 35" .. COPPER, "rounded to whole copper")
  end,

  layout_fits_page = function(T)
    local S = load().Style
    T.eq(S.PAGE_W, 802)
    T.eq(S.PAGE_H, 335)
    T.ok(S.PAD + S.LEFT_W + S.GAP + S.RIGHT_W + S.PAD <= S.PAGE_W, "columns fit the width")
    T.ok(S.PAD + 20 + 18 + S.VISIBLE * S.ROW_H + S.GAP + S.STATUS_H + S.PAD <= S.PAGE_H,
      "a table plus the status bar fit the height")
    T.eq(S.ROW_H, 18)
    T.eq(S.VISIBLE, 12)
  end,

  panel_has_backdrop_and_title = function(T)
    local ns = load()
    local parent = CreateFrame("Frame", "CraftProfitStyleParent", UIParent)
    local p = ns.Style.Panel(parent, "CraftProfitStylePanel", "Price", 200, 100)
    T.eq(p:GetWidth(), 200)
    T.eq(p:GetHeight(), 100)
    T.ok(p._backdrop, "has a backdrop")
    T.eq(p._backdrop.edgeFile, "Interface\\Tooltips\\UI-Tooltip-Border")
    T.eq(p.title:GetText(), "Price")
  end,

  button_is_wide_enough = function(T)
    local ns = load()
    local parent = CreateFrame("Frame", "CraftProfitStyleParent2", UIParent)
    local b = ns.Style.Button(parent, "CraftProfitStyleButton", "Post", 80, true)
    T.ok(b:GetWidth() >= 120, "at least 120 px")
    T.eq(b:GetHeight(), 24)
    T.eq(b:GetText(), "Post")
  end,
}
