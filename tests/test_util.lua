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

  now_uses_time = function(T)
    local ns = load()
    Mock.now = 42
    T.eq(ns.Now(), 42)
  end,
}
