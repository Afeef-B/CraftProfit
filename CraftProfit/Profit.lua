-- Profit math. Pure: prices come in through ctx.resolveBuy / ctx.resolveSell.
--
-- ctx = {
--   recipes     = { [itemID] = { name, made, reagents = { {id, name, count}, ... } } },
--   resolveBuy  = function(itemID, craftUnitCost) -> price, source, age
--   resolveSell = function(itemID) -> price, source, age
--   depth       = function(itemID) -> "ready" | "scratch"   (optional)
--   cut         = 0.05,
-- }
-- "ready": the direct materials are priced as bought. "scratch" (also when
-- ctx.depth is missing): each material is priced at the cheaper of buying or
-- crafting it, all the way down.
local addonName, ns = ...

ns.Profit = {}
local Profit = ns.Profit

-- Cost to craft one unit of itemID from bought/crafted materials, or nil when
-- there is no recipe, a material has no price, or the recipe loops back.
-- `visiting` holds the recipes on the current path so cycles stop.
function Profit.CraftUnitCost(id, ctx, visiting)
  local recipe = ctx.recipes[id]
  if not recipe then return nil end
  visiting = visiting or {}
  if visiting[id] then return nil end

  visiting[id] = true
  local total = 0
  for _, reagent in ipairs(recipe.reagents) do
    local craft = Profit.CraftUnitCost(reagent.id, ctx, visiting)
    local price = ctx.resolveBuy(reagent.id, craft)
    if not price then
      total = nil
      break
    end
    total = total + price * reagent.count
  end
  visiting[id] = nil

  if not total then return nil end
  return total / (recipe.made or 1)
end

function Profit.Evaluate(id, ctx)
  local recipe = ctx.recipes[id]
  if not recipe then return nil end

  local result = {
    id = id, name = recipe.name, made = recipe.made or 1,
    lines = {}, missing = {},
  }
  local visiting = { [id] = true }
  local cost = 0
  local ready = ctx.depth ~= nil and ctx.depth(id) == "ready"
  result.depth = ready and "ready" or "scratch"

  for _, reagent in ipairs(recipe.reagents) do
    local craft = not ready and Profit.CraftUnitCost(reagent.id, ctx, visiting) or nil
    local unit, source, age = ctx.resolveBuy(reagent.id, craft)
    local line = {
      id = reagent.id, name = reagent.name, count = reagent.count,
      unit = unit, source = source, age = age,
    }
    if unit then
      line.total = unit * reagent.count
      if source == "craft" then
        local buy = ctx.resolveBuy(reagent.id, nil)
        if buy then line.saves = (buy - unit) * reagent.count end
      end
      if cost then cost = cost + line.total end
    else
      cost = nil
      table.insert(result.missing, reagent.name)
    end
    table.insert(result.lines, line)
  end
  result.cost = cost

  local sell, sellSource, sellAge = ctx.resolveSell(id)
  result.sell, result.sellSource, result.sellAge = sell, sellSource, sellAge
  if sell then
    result.revenue = sell * result.made * (1 - ctx.cut)
  else
    table.insert(result.missing, recipe.name)
  end

  if cost and sell then
    result.profit = result.revenue - cost
    if cost > 0 then result.margin = result.profit / cost end
    result.status = "ok"
  else
    result.status = "missing"
  end
  return result
end

-- Most profitable first; rows with missing prices last, by name.
function Profit.EvaluateAll(ids, ctx)
  local list = {}
  for _, id in ipairs(ids) do
    local result = Profit.Evaluate(id, ctx)
    if result then list[#list + 1] = result end
  end
  table.sort(list, function(a, b)
    if (a.status == "ok") ~= (b.status == "ok") then return a.status == "ok" end
    if a.status == "ok" and a.profit ~= b.profit then return a.profit > b.profit end
    return (a.name or "") < (b.name or "")
  end)
  return list
end
