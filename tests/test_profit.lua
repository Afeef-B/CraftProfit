local Mock = require("wow_mock")

local BAG, BOLT, CLOTH, THREAD = 41599, 41510, 33470, 38426

local function load()
  Mock.reset()
  return Mock.load({ "Util.lua", "Style.lua", "Profit.lua" })
end

-- Stand-in for Prices.ResolveBuy/ResolveSell: cheapest of AH and craft.
local function ctx(opts)
  return {
    recipes = opts.recipes,
    cut = opts.cut or 0.05,
    resolveBuy = function(id, craft)
      local best, source = opts.buy[id], opts.buy[id] and "ah"
      if craft and (not best or craft < best) then best, source = craft, "craft" end
      return best, source, source == "ah" and 60 or nil
    end,
    resolveSell = function(id)
      local p = opts.sell[id]
      return p, p and "ah", p and 60
    end,
  }
end

local function bagRecipe(made)
  return {
    name = "Frostweave Bag", made = made or 1,
    reagents = {
      { id = CLOTH, name = "Frostweave Cloth", count = 6 },
      { id = THREAD, name = "Eternium Thread", count = 1 },
    },
  }
end

return {
  basic_profit = function(T)
    local P = load().Profit
    local r = P.Evaluate(BAG, ctx({
      recipes = { [BAG] = bagRecipe() },
      buy = { [CLOTH] = 1000, [THREAD] = 500 },
      sell = { [BAG] = 10000 },
    }))
    T.eq(r.status, "ok")
    T.eq(r.cost, 6500)
    T.eq(r.revenue, 9500)
    T.eq(r.profit, 3000)
    T.near(r.margin, 3000 / 6500)
    T.eq(#r.lines, 2)
    T.eq(r.lines[1].unit, 1000)
    T.eq(r.lines[1].total, 6000)
    T.eq(r.lines[1].source, "ah")
    T.eq(r.sellSource, "ah")
  end,

  made_multiple = function(T)
    local P = load().Profit
    local r = P.Evaluate(BAG, ctx({
      recipes = { [BAG] = bagRecipe(2) },
      buy = { [CLOTH] = 100, [THREAD] = 100 },
      sell = { [BAG] = 1000 },
    }))
    T.eq(r.revenue, 1900)
    T.eq(r.made, 2)
  end,

  craft_cheaper_than_buy = function(T)
    local P = load().Profit
    local r = P.Evaluate(BAG, ctx({
      recipes = {
        [BAG] = { name = "Frostweave Bag", made = 1, reagents = { { id = BOLT, name = "Bolt of Frostweave", count = 2 } } },
        [BOLT] = { name = "Bolt of Frostweave", made = 1, reagents = { { id = CLOTH, name = "Frostweave Cloth", count = 5 } } },
      },
      buy = { [BOLT] = 6000, [CLOTH] = 1000 },
      sell = { [BAG] = 20000 },
    }))
    T.eq(r.lines[1].source, "craft")
    T.eq(r.lines[1].unit, 5000)
    T.eq(r.lines[1].saves, 2000)
    T.eq(r.cost, 10000)
  end,

  ready_made_ignores_craft_option = function(T)
    local P = load().Profit
    local c = ctx({
      recipes = {
        [BAG] = { name = "Frostweave Bag", made = 1, reagents = { { id = BOLT, name = "Bolt of Frostweave", count = 2 } } },
        [BOLT] = { name = "Bolt of Frostweave", made = 1, reagents = { { id = CLOTH, name = "Frostweave Cloth", count = 5 } } },
      },
      buy = { [BOLT] = 6000, [CLOTH] = 1000 },
      sell = { [BAG] = 20000 },
    })
    c.depth = function() return "ready" end
    local r = P.Evaluate(BAG, c)
    T.eq(r.depth, "ready")
    T.eq(r.lines[1].source, "ah")
    T.eq(r.lines[1].unit, 6000)
    T.eq(r.lines[1].saves, nil)
    T.eq(r.cost, 12000)

    c.depth = function() return "scratch" end
    r = P.Evaluate(BAG, c)
    T.eq(r.depth, "scratch")
    T.eq(r.lines[1].source, "craft")
    T.eq(r.cost, 10000)
  end,

  no_depth_in_context_behaves_as_scratch = function(T)
    local P = load().Profit
    local r = P.Evaluate(BAG, ctx({
      recipes = {
        [BAG] = { name = "Frostweave Bag", made = 1, reagents = { { id = BOLT, name = "Bolt of Frostweave", count = 2 } } },
        [BOLT] = { name = "Bolt of Frostweave", made = 1, reagents = { { id = CLOTH, name = "Frostweave Cloth", count = 5 } } },
      },
      buy = { [BOLT] = 6000, [CLOTH] = 1000 },
      sell = { [BAG] = 20000 },
    }))
    T.eq(r.depth, "scratch")
    T.eq(r.lines[1].source, "craft")
  end,

  buy_cheaper_than_craft = function(T)
    local P = load().Profit
    local r = P.Evaluate(BAG, ctx({
      recipes = {
        [BAG] = { name = "Frostweave Bag", made = 1, reagents = { { id = BOLT, name = "Bolt of Frostweave", count = 2 } } },
        [BOLT] = { name = "Bolt of Frostweave", made = 1, reagents = { { id = CLOTH, name = "Frostweave Cloth", count = 5 } } },
      },
      buy = { [BOLT] = 4000, [CLOTH] = 1000 },
      sell = { [BAG] = 20000 },
    }))
    T.eq(r.lines[1].source, "ah")
    T.eq(r.lines[1].unit, 4000)
    T.eq(r.lines[1].saves, nil)
  end,

  craft_cost_divides_by_made = function(T)
    local P = load().Profit
    local c = ctx({
      recipes = { [BOLT] = { name = "Bolt", made = 2, reagents = { { id = CLOTH, name = "Cloth", count = 5 } } } },
      buy = { [CLOTH] = 1000 },
      sell = {},
    })
    T.eq(P.CraftUnitCost(BOLT, c), 2500)
    T.eq(P.CraftUnitCost(CLOTH, c), nil)
  end,

  cycle_is_safe = function(T)
    local P = load().Profit
    local A, B = 1, 2
    local r = P.Evaluate(A, ctx({
      recipes = {
        [A] = { name = "A", made = 1, reagents = { { id = B, name = "B", count = 1 } } },
        [B] = { name = "B", made = 1, reagents = { { id = A, name = "A", count = 1 } } },
      },
      buy = { [A] = 100, [B] = 200 },
      sell = { [A] = 1000 },
    }))
    T.eq(r.status, "ok")
    -- B can be crafted from a bought A (100) which beats buying B (200).
    T.eq(r.cost, 100)
  end,

  missing_material_marks_recipe_missing = function(T)
    local P = load().Profit
    local r = P.Evaluate(BAG, ctx({
      recipes = { [BAG] = bagRecipe() },
      buy = { [CLOTH] = 1000 },
      sell = { [BAG] = 10000 },
    }))
    T.eq(r.status, "missing")
    T.eq(r.missing[1], "Eternium Thread")
    T.eq(r.cost, nil)
    T.eq(r.profit, nil)
    T.eq(r.lines[2].unit, nil)
  end,

  missing_sell_price = function(T)
    local P = load().Profit
    local r = P.Evaluate(BAG, ctx({
      recipes = { [BAG] = bagRecipe() },
      buy = { [CLOTH] = 1000, [THREAD] = 500 },
      sell = {},
    }))
    T.eq(r.status, "missing")
    T.eq(r.missing[1], "Frostweave Bag")
    T.eq(r.cost, 6500)
    T.eq(r.profit, nil)
  end,

  unknown_recipe_returns_nil = function(T)
    local P = load().Profit
    T.eq(P.Evaluate(999, ctx({ recipes = {}, buy = {}, sell = {} })), nil)
  end,

  evaluate_all_sorts = function(T)
    local P = load().Profit
    local function simple(name, reagent)
      return { name = name, made = 1, reagents = { { id = reagent, name = "r" .. reagent, count = 1 } } }
    end
    local list = P.EvaluateAll({ 10, 20, 30, 999 }, ctx({
      recipes = { [10] = simple("Low", 1), [20] = simple("High", 2), [30] = simple("Gone", 3) },
      buy = { [1] = 1000, [2] = 1000 },
      sell = { [10] = 2000, [20] = 10000, [30] = 5000 },
      cut = 0,
    }))
    T.eq(#list, 3)
    T.eq(list[1].name, "High")
    T.eq(list[2].name, "Low")
    T.eq(list[3].name, "Gone")
  end,
}
