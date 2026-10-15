local Mock = require("wow_mock")

local BAG, NET, CLOTH, THREAD = 41599, 41509, 33470, 38426

local function load()
  Mock.reset()
  Mock.installUI()
  local ns = Mock.load({ "Util.lua", "Profit.lua", "Prices.lua", "Recipes.lua", "Scanner.lua", "UI.lua" })
  local db, chardb = { cut = 0.05 }, {}
  ns.Prices.SetDB(db, "Icecrown-Alliance")
  ns.Recipes.SetDB(chardb)
  ns.Scanner.SetDB(db)
  ns.UI.SetDB(db)
  Mock.trade.rows = {
    { name = "Frostweave Bag", id = BAG, reagents = {
      { id = CLOTH, name = "Frostweave Cloth", count = 6 },
      { id = THREAD, name = "Eternium Thread", count = 1 } } },
    { name = "Frostweave Net", id = NET, reagents = { { id = THREAD, name = "Eternium Thread", count = 2 } } },
  }
  ns.Recipes.ReadTradeSkill()
  ns.Prices.SetAH(CLOTH, 1000, 5, Mock.now - 300)
  ns.Prices.SetAH(THREAD, 500, 5, Mock.now - 300)
  ns.Prices.SetAH(BAG, 10000, 2, Mock.now - 300)
  return ns, ns.UI, db
end

local function tooltipHas(text)
  for _, line in ipairs(Mock.tooltip) do
    if line:find(text, 1, true) then return true end
  end
  return false
end

return {
  panel_builds_and_lists_tracked_sorted = function(T)
    local ns, UI = load()
    ns.Recipes.SetTracked(NET, true)
    ns.Recipes.SetTracked(BAG, true)
    UI.EnsurePanel()
    UI.EnsurePanel()
    T.ok(CraftProfitPanel, "panel created")
    UI.Refresh()
    T.eq(#UI.rowsData, 2)
    T.eq(UI.rowsData[1].name, "Frostweave Bag")   -- profit 3000
    T.eq(UI.rowsData[2].name, "Frostweave Net")   -- no sell price
    T.eq(UI.rows[1].name:GetText(), "Frostweave Bag (ready-made)")
    T.eq(UI.rows[1].profit:GetText(), "|cff40ff4030s|r")
    T.eq(UI.rows[1].margin:GetText(), "|cff40ff4046%|r")
    T.eq(UI.rows[2].profit:GetText(), "|cff808080?|r")
    T.eq(UI.rows[3]:IsShown(), false)
  end,

  empty_state_message = function(T)
    local _, UI = load()
    UI.EnsurePanel()
    UI.Refresh()
    T.eq(#UI.rowsData, 0)
    T.eq(UI.emptyText:IsShown(), true)
  end,

  row_tooltip_breakdown = function(T)
    local ns, UI = load()
    ns.Recipes.SetTracked(BAG, true)
    ns.Recipes.SetTracked(NET, true)
    UI.EnsurePanel()
    UI.Refresh()
    UI.RowTooltip(UI.rowsData[1])
    T.ok(tooltipHas("Frostweave Bag"))
    T.ok(tooltipHas("6x Frostweave Cloth | 60s  (10s each, AH 5m)"))
    T.ok(tooltipHas("AH cut 5% | -5s"))
    T.ok(tooltipHas("Profit"))
    UI.RowTooltip(UI.rowsData[2])
    T.ok(tooltipHas("Missing prices: Frostweave Net"))
  end,

  right_click_menu_sets_depth_and_untracks = function(T)
    local ns, UI = load()
    ns.Recipes.SetTracked(BAG, true)
    UI.EnsurePanel()
    UI.Refresh()
    T.eq(UI.rows[1].name:GetText(), "Frostweave Bag (ready-made)")

    UI.rows[1]:GetScript("OnClick")(UI.rows[1], "RightButton")
    local menu = Mock.menu
    T.ok(menu, "menu opened")
    T.eq(#menu, 3)
    T.eq(menu[1].text, "Ready-made materials")
    T.eq(menu[2].text, "From scratch")
    T.eq(menu[3].text, "Stop tracking")
    T.eq(menu[1].checked, true)
    T.ok(not menu[2].checked, "scratch not checked")
    T.eq(Mock.menuAnchor, "cursor")

    menu[2].func()
    T.eq(ns.Recipes.Depth(BAG), "scratch")
    T.eq(UI.rows[1].name:GetText(), "Frostweave Bag (from scratch)")

    UI.rows[1]:GetScript("OnClick")(UI.rows[1], "RightButton")
    T.ok(not Mock.menu[1].checked, "ready not checked")
    T.eq(Mock.menu[2].checked, true)
    Mock.menu[1].func()
    T.eq(ns.Recipes.Depth(BAG), "ready")
    T.eq(UI.rows[1].name:GetText(), "Frostweave Bag (ready-made)")

    UI.rows[1]:GetScript("OnClick")(UI.rows[1], "RightButton")
    Mock.menu[3].func()
    T.eq(ns.Recipes.IsTracked(BAG), false)
    T.eq(#UI.rowsData, 0)
  end,

  track_checkbox_follows_selection = function(T)
    local ns, UI = load()
    ns.Recipes.WindowOpened()
    ns.Recipes.Tick(1.6)                      -- window settled
    UI.EnsureTrackButton()
    UI.EnsureTrackButton()
    local check = CraftProfitTrackCheck
    T.ok(check, "checkbox created")
    Mock.trade.selected = 1
    TradeSkillFrame_SetSelection(1)
    T.eq(check:IsShown(), true)
    T.ok(not check:GetChecked())
    check:SetChecked(1)
    check:GetScript("OnClick")(check)
    T.eq(ns.Recipes.IsTracked(BAG), true)
    Mock.trade.linked = 1
    UI.UpdateTrackButton()
    T.eq(check:IsShown(), false)
  end,

  scan_buttons_show_cooldown = function(T)
    local ns, UI, db = load()
    UI.EnsurePanel()
    Mock.ah.canQueryAll = false
    db.lastScanAll = Mock.now - 100
    UI.UpdateScanButtons()
    T.eq(UI.scanAllButton:GetText(), "Scan All (13:20)")
    T.eq(UI.scanAllButton:IsEnabled(), false)
    Mock.ah.canQueryAll = true
    UI.UpdateScanButtons()
    T.eq(UI.scanAllButton:GetText(), "Scan All")
    T.eq(UI.scanAllButton:IsEnabled(), true)
  end,

  scan_all_warns_first_time = function(T)
    local ns, UI, db = load()
    UI.EnsurePanel()
    UI.scanAllButton:GetScript("OnClick")(UI.scanAllButton)
    T.eq(Mock.popup, "CRAFTPROFIT_SCANALL")
    T.eq(ns.Scanner.IsBusy(), false)
    StaticPopupDialogs.CRAFTPROFIT_SCANALL.OnAccept()
    T.eq(db.scanAllWarned, true)
    T.eq(ns.Scanner.IsBusy(), true)
  end,

  scan_button_starts_and_stops = function(T)
    local ns, UI = load()
    ns.Recipes.SetTracked(BAG, true)
    UI.EnsurePanel()
    UI.scanButton:GetScript("OnClick")(UI.scanButton)
    T.eq(ns.Scanner.IsBusy(), true)
    UI.UpdateScanButtons()
    T.eq(UI.scanButton:GetText(), "Stop")
    UI.scanButton:GetScript("OnClick")(UI.scanButton)
    T.eq(ns.Scanner.IsBusy(), false)
  end,

  scan_with_nothing_tracked_explains = function(T)
    local ns, UI = load()
    UI.EnsurePanel()
    UI.scanButton:GetScript("OnClick")(UI.scanButton)
    T.eq(UI.statusText:GetText(), "Nothing tracked yet. Tick \"Track\" on a recipe in your profession window.")
  end,
}
