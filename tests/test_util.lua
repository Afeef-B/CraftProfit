local Mock = require("wow_mock")

local function load()
  Mock.reset()
  return Mock.load({ "Util.lua" })
end

return {
  format_money = function(T)
    local U = load().Util
    T.eq(U.FormatMoney(12345), "1g 23s 45c")
    T.eq(U.FormatMoney(10000), "1g")
    T.eq(U.FormatMoney(10050), "1g 50c")
    T.eq(U.FormatMoney(0), "0c")
    T.eq(U.FormatMoney(-10200), "-1g 2s")
    T.eq(U.FormatMoney(1234.6), "12s 35c")
  end,

  format_money_short = function(T)
    local U = load().Util
    T.eq(U.FormatMoneyShort(123456), "12g 34s")
    T.eq(U.FormatMoneyShort(120056), "12g")
    T.eq(U.FormatMoneyShort(520), "5s 20c")
    T.eq(U.FormatMoneyShort(500), "5s")
    T.eq(U.FormatMoneyShort(7), "7c")
    T.eq(U.FormatMoneyShort(0), "0c")
    T.eq(U.FormatMoneyShort(-15000), "-1g 50s")
  end,

  parse_money = function(T)
    local U = load().Util
    T.eq(U.ParseMoney("1.5"), 15000)
    T.eq(U.ParseMoney("1g50s"), 15000)
    T.eq(U.ParseMoney("1g 50s 20c"), 15020)
    T.eq(U.ParseMoney("75s"), 7500)
    T.eq(U.ParseMoney("20c"), 20)
    T.eq(U.ParseMoney("12"), 120000)
    T.eq(U.ParseMoney("abc"), nil)
    T.eq(U.ParseMoney(""), nil)
    T.eq(U.ParseMoney(nil), nil)
    T.eq(U.ParseMoney("1g abc"), nil)
  end,

  item_id_from_link = function(T)
    local U = load().Util
    T.eq(U.ItemIDFromLink("|cffffffff|Hitem:33470:0:0:0:0:0:0:0:80|h[Frostweave Cloth]|h|r"), 33470)
    T.eq(U.ItemIDFromLink("|cffffd000|Henchant:7418|h[Enchant Ring]|h|r"), nil)
    T.eq(U.ItemIDFromLink(nil), nil)
  end,

  item_name_from_link = function(T)
    local U = load().Util
    T.eq(U.ItemNameFromLink("|cff1eff00|Hitem:41599:0:0:0:0:0:0:0:80|h[Frostweave Bag]|h|r"), "Frostweave Bag")
    T.eq(U.ItemNameFromLink("garbage"), nil)
    T.eq(U.ItemNameFromLink(nil), nil)
  end,

  format_age = function(T)
    local U = load().Util
    T.eq(U.FormatAge(30), "now")
    T.eq(U.FormatAge(300), "5m")
    T.eq(U.FormatAge(7200), "2h")
    T.eq(U.FormatAge(3 * 86400), "3d")
  end,

  event_bus = function(T)
    local ns = load()
    local got
    ns.On("X", function(a, b) got = a .. b end)
    ns.Fire("X", "1", "2")
    T.eq(got, "12")
    ns.Fire("UNHEARD")
  end,

  realm_key = function(T)
    local U = load().Util
    T.eq(U.RealmKey(), "Icecrown-Alliance")
    UnitFactionGroup = function() return nil end
    T.eq(U.RealmKey(), "Icecrown-Neutral")
  end,

  print_prefixes = function(T)
    local U = load().Util
    U.Print("hello")
    T.eq(Mock.chat[1], "|cff33ff99CraftProfit|r: hello")
  end,

  icons_are_texture_escapes = function(T)
    local U = load().Util
    T.eq(U.ICON_OK, "|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t")
    T.eq(U.ICON_WARN, "|TInterface\\DialogFrame\\UI-Dialog-Icon-AlertNew:14|t")
    T.eq(U.ICON_GOLD, "|TInterface\\MoneyFrame\\UI-GoldIcon:14|t")
  end,

  now_uses_time = function(T)
    local ns = load()
    Mock.now = 42
    T.eq(ns.Now(), 42)
  end,
  -- item:id:enchant:gem1:gem2:gem3:gem4:suffix:unique:level
  suffix_from_link = function(T)
    local U = load().Util
    T.eq(U.SuffixFromLink("|cffffffff|Hitem:33470:0:0:0:0:0:0:0:80|h[Frostweave Cloth]|h|r"), 0)
    T.eq(U.SuffixFromLink("|cff1eff00|Hitem:10001:0:0:0:0:0:-9:123456:80|h[Belt of the Monkey]|h|r"), -9)
    T.eq(U.SuffixFromLink("|cff1eff00|Hitem:10001:3225:0:0:0:0:1221:98765:80|h[Belt of the Bear]|h|r"), 1221,
      "an enchant on the item does not move the field")
    T.eq(U.SuffixFromLink("|cff1eff00|Hitem:10001:-5:0:0:0:0:7|h[Belt]|h|r"), 7, "no trailing fields")
    T.eq(U.SuffixFromLink("|cffffd000|Henchant:7418|h[Enchant Ring]|h|r"), nil)
    T.eq(U.SuffixFromLink("|Hitem:33470|h[Short]|h"), nil, "too short to carry a suffix")
    T.eq(U.SuffixFromLink("garbage"), nil)
    T.eq(U.SuffixFromLink(nil), nil)
    T.eq(U.SuffixFromLink(42), nil)
  end,
}
