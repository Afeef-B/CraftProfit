# CraftProfit — Design Spec

Date: 2026-10-15
Target: World of Warcraft 3.3.5a (interface 30300), Warmane realms
Status: approved in chat

## Goal

A tailor wants to know, for the items they craft and sell, whether crafting is
profitable: the AH sell price (after the AH cut) versus the cost of buying the
materials. The addon learns recipes from the profession window, scans the
Auction House for current prices, and shows a profit table next to the AH.

Success: open the AH, press **Scan tracked**, and within ~30 s see each
tracked craft with material cost, sell price, profit and margin, with a
per-material breakdown on hover.

## Decisions (from the brainstorm)

| Topic | Decision |
|---|---|
| Client | WotLK 3.3.5a, Lua 5.1, no `C_Timer`, no `BackdropTemplate` |
| Recipe source | Read from the profession window; user ticks which to track |
| Display | Panel docked to the right of `AuctionFrame` |
| Material price | Cheapest buyout per unit |
| Scanning | Targeted name search per item (default) + optional Scan All (`getAll`) |
| Other addons | Auctionator installed — used only as a fallback price source |
| Crafted materials | Priced at min(buy on AH, craft yourself), recursive |

## Files

```
CraftProfit/
  CraftProfit.toc   manifest; SavedVariables: CraftProfitDB;
                    SavedVariablesPerCharacter: CraftProfitCharDB
  Util.lua          money formatting/parsing, item-link parsing, small helpers
  Profit.lua        pure profit math (no WoW API)
  Prices.lua        price store + price resolution (source priority)
  Recipes.lua       read profession window -> recipe records; tracking
  Scanner.lua       targeted scan queue + Scan All
  UI.lua            AH panel, Track checkbox in profession window, tooltips
  Core.lua          events, saved-variable init, slash commands
```

Load order: Util, Profit, Prices, Recipes, Scanner, UI, Core. All modules
share the addon namespace table (`local _, ns = ...`). The only globals
created are `CraftProfitDB`, `CraftProfitCharDB`, `SLASH_CRAFTPROFIT1/2`
and frame names prefixed `CraftProfit`.

## Data model

```lua
CraftProfitDB = {                     -- account-wide
  version = 1,
  prices  = { ["<realm>-<faction>"] = { [itemID] = { p = copperPerUnit|nil, t = epoch, n = listings } } },
  vendor  = { [itemID] = copperPerUnit },      -- learned at merchants
  manual  = { [itemID] = copperPerUnit },      -- /cp price
  cut     = 0.05,                               -- AH cut
  lastScanAll = epoch,
  scanAllWarned = bool,
}
CraftProfitCharDB = {                 -- per character
  recipes = { [productItemID] = {
      name = "Frostweave Bag", made = 1,           -- average of min/max made
      reagents = { { id = 33470, name = "Frostweave Cloth", count = 6 }, ... },
      profession = "Tailoring",
  } },
  tracked = { [productItemID] = true },
}
```

A price record with `p == nil` and `n == 0` means "scanned, no listings".

## Recipe learning (Recipes.lua)

- Event handlers never read every row: a full read is slow on the 3.3.5
  client and `TRADE_SKILL_UPDATE` fires repeatedly, which froze the game
  (fixed in 1.0.1). Instead:
  - nothing touches the window while it opens. Even deferred by a few
    frames, our setup hung the game (1.0.2, user with ElvUI); run seconds
    later by hand (`/cp diag` + `/cp step`, 1.0.3) it worked. So the window
    is "ready" only after 1.5 s without `TRADE_SKILL_UPDATE`
    (`PROFESSION_READY`), and the `TradeSkillFrame_SetSelection` hook does
    nothing until then (also on later re-opens);
  - when ready: add the Track checkbox, read the selected row, start the
    background scan; afterwards the hook reads the selected row on clicks;
  - the background scan reads one row per frame (`OnUpdate`), stops on
    `TRADE_SKILL_CLOSE`, and runs once per profession per session unless the
    row count changes.
- Rows are skipped when `IsTradeSkillLinked()` or `skillType == "header"`.
- Product id from `GetTradeSkillItemLink(i)` (`item:(%d+)`; non-item links
  such as enchants are skipped). `made` = average of `GetTradeSkillNumMade(i)`.
- Reagents from `GetTradeSkillNumReagents`, `GetTradeSkillReagentInfo`
  (name, count) and `GetTradeSkillReagentItemLink` (id). If any reagent link
  is not cached yet, the recipe is skipped this pass and picked up on the next
  update.
- Records are merged (insert/overwrite by product id), never wiped, so recipes
  in collapsed or filtered categories are kept.
- Tracking: a "Track profit" check button on `TradeSkillFrame` (top row,
  right of "Have Materials") reflects/toggles the selected recipe. Also
  `/cp track` (selected recipe) and right-click on a panel row to untrack.

## Prices (Prices.lua)

Stored lowest per-unit buyout per item per realm-faction, with timestamp.

Resolution for a **material** (`ResolveBuy(id)`), returns `price, source, age`:
1. manual price → source `manual`
2. otherwise the cheapest of: AH price (`ah`), vendor price (`vendor`),
   craft cost (`craft`, computed by Profit, see below)
3. otherwise Auctionator (`atr`)
4. otherwise `nil` (missing)

Resolution for a **product** (`ResolveSell(id)`): manual → AH → Auctionator → nil.

Vendor prices: on `MERCHANT_SHOW`/`MERCHANT_UPDATE` record
`price / quantity` for every merchant item with `price > 0` and no
`extendedCost`.

Auctionator fallback (both tried, each wrapped in `pcall`, accept only
positive numbers):
- `Auctionator.API.v1.GetAuctionPriceByItemID("CraftProfit", id)`
- `Atr_GetAuctionBuyout(itemName or link)`

Prices older than 24 h are flagged stale (shown grey) but still used.

## Profit math (Profit.lua — pure)

```
unitCost(id)   = ResolveBuy(id), where craft option = recipeCost(recipe(id)) / made
recipeCost(r)  = Σ count_i × unitCost(reagent_i)        (nil if any reagent missing)
revenue(r)     = sellPrice × made × (1 − cut)
profit(r)      = revenue − recipeCost
margin(r)      = profit / recipeCost
```

- Recursion uses a visiting set; a cycle disables the craft option for that
  item. Depth is naturally bounded by the recipe graph.
- Result object per recipe: `{ id, name, cost, sell, revenue, profit, margin,
  status = "ok"|"missing", missing = {names}, lines = {per-reagent breakdown} }`.
- Deposit is ignored (refunded on sale). Cut defaults to 5%, `/cp cut 15` for
  neutral AHs.

## Scanning (Scanner.lua)

Common: listen to `AUCTION_ITEM_LIST_UPDATE`, `AUCTION_HOUSE_CLOSED`. A
`hooksecurefunc("QueryAuctionItems")` hook detects queries sent by other
addons (Auctionator) or the Browse tab while we wait; our pending query is
then re-sent. Results are only read when we have a pending query of our own.

**Targeted scan** ("Scan tracked"):
1. Work list = unique item ids of tracked products, their reagents, and
   reagents of crafted reagents (recursive).
2. For each item: wait until `CanSendAuctionQuery()`; send
   `QueryAuctionItems(name, "", "", nil, nil, nil, page, nil, -1, false)`
   (mirrors Blizzard's default browse search; `0` would be truthy for `isUsable`).
3. On the result: for each row, item id from `GetAuctionItemLink("list", i)`
   must equal the target; `buyout > 0`; unit = `buyout / count`; keep min.
   If any link is nil, wait for the next update (max 2 s) then read anyway.
4. Page while `(page+1) × 50 < total`. Save `{p, t, n}`; `n = 0` → no listings.
5. 10 s timeout per query → one retry, then skip with a warning.
6. AH closed → stop; keep what was saved.

**Scan All**:
- Enabled when `select(2, CanSendAuctionQuery())` is true; otherwise shows a
  countdown from `lastScanAll + 15 min`.
- First use shows a StaticPopup warning about possible disconnects.
- Sends `QueryAuctionItems("", "", "", nil, nil, nil, 0, nil, -1, true)`; on the first
  following update, reads all `GetNumAuctionItems("list")` rows in chunks of
  500 per `OnUpdate`, keeping the min unit buyout per item id.
- When finished, writes all prices. If every row resolved (no nil links),
  items previously stored but absent from the dump are marked "no listings".

## UI (UI.lua)

- Panel `CraftProfitPanel`, 360 × 424, anchored `TOPLEFT` to
  `AuctionFrame` `TOPRIGHT` (offset −2, −12), shown on `AUCTION_HOUSE_SHOW`,
  hidden with the AH. Toggle via `/cp`.
- Top: [Scan tracked] [Scan All (mm:ss)], status line.
- Table (FauxScrollFrame, 16 rows): item (icon, name, "×N" when made > 1),
  cost, sell, profit, margin. Sorted by profit desc, missing rows last.
  Colors: profit > 0 green, < 0 red, missing grey; stale prices grey.
- Row hover: GameTooltip breakdown — each reagent: count × unit price
  (source, age), cost, sell, AH cut, profit. Craft-vs-buy note when the craft
  option was chosen ("craft: saves 3g").
- Right-click row: untrack.
- Empty state: "Open Tailoring and tick 'Track profit' on a recipe."

## Slash commands (Core.lua)

```
/cp                    toggle panel
/cp scan               targeted scan (AH must be open)
/cp track              track/untrack selected recipe in the profession window
/cp price <item> <g>   manual price (e.g. 1.5 or 1g50s); "/cp price <item> clear"
/cp cut <percent>      AH cut (default 5)
/cp list               print tracked results to chat
/cp reset prices       wipe stored AH prices for this realm-faction
```

## Error handling

- AH closed mid-scan: stop, status "Scan stopped (AH closed) — N/M done".
- Query throttled: polled via `OnUpdate` until `CanSendAuctionQuery()`.
- Item names unknown (uncached): fall back to recipe-stored names; if none,
  skip with a chat warning.
- Saved-variable corruption/old versions: `version` field; missing tables are
  recreated on load.

## Testing

- Lua 5.1 test runner in `tests/` with a mock WoW API.
- Unit tests: Util (money format/parse, link parsing), Profit (cost, cut,
  recursion, cycles, missing), Prices (priority, vendor/manual/atr, stale),
  Recipes (reading a mocked profession window, merge, linked skip),
  Scanner (targeted state machine incl. paging, wrong-item filter, foreign
  query, timeout, AH close; Scan All chunking and "no listings" marking).
- Smoke test: load all files with a permissive frame mock and build the UI.
- Static check: no unintended global writes (`luac -l`).
- In-game checklist in README (cannot run the 3.3.5 client here).

## Out of scope

Tooltips on items outside the panel, posting/buying automation, price
history/averages, multiple professions' UI beyond what the profession window
gives for free.
