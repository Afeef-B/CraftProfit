# CraftProfit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A WoW 3.3.5a addon that learns tailoring recipes, scans the Auction House, and shows per-craft profit in a panel beside the AH.

**Architecture:** Seven Lua files sharing one addon namespace. Pure logic
(Util, Profit, price resolution) is separated from WoW-API glue so it can be
tested with Lua 5.1 and a mock WoW API. Modules talk through a tiny event bus
(`ns.On` / `ns.Fire`) and explicit function interfaces listed per task.

**Tech Stack:** Lua 5.1 (WoW 3.3.5a client), FrameXML 3.3.5 widgets; tests with
plain `lua5.1` and a hand-written mock (no external test libs).

**Spec:** `docs/superpowers/specs/2026-10-15-craftprofit-design.md`

## Global Constraints

- Interface `30300`; Lua 5.1 only: no `goto`, no `C_Timer`, no `BackdropTemplate`, no `//` integer division.
- Every file starts `local addonName, ns = ...`; globals created only: `CraftProfitDB`, `CraftProfitCharDB`, `SLASH_CRAFTPROFIT1`, `SLASH_CRAFTPROFIT2`, frame names prefixed `CraftProfit`.
- Money is integer copper everywhere; per-unit AH prices rounded with `math.floor(x + 0.5)`.
- AH query call is exactly `QueryAuctionItems(name, "", "", nil, nil, nil, page, nil, -1, getAll)`.
- `NUM_AUCTION_ITEMS_PER_PAGE` = 50; query timeout 10 s, one retry; link-wait 2 s; Scan All chunk 500 rows per tick; Scan All cooldown 900 s; stale after 86400 s.
- Default AH cut `0.05`.
- Test command: `lua5.1 tests/run.lua` (exit code 0 = all pass). Global check: `lua5.1 tests/check_globals.lua`.

## Review Focus

1. Substring name matches ("Silk Cloth" search returns "Bolt of Silk Cloth") must not pollute prices → Task 5 test `targeted_filters_other_items`.
2. Stacked listings (20 for 40g) must be priced per unit, bid-only listings (buyout 0) ignored → Task 5 test `targeted_per_unit_and_skips_bid_only`.
3. Another addon (Auctionator) or the Browse tab sends a query while we wait → resend, never read their results as ours → Task 5 test `foreign_query_resends`.
4. A crafted material with no AH, vendor, manual or Atr price and no own recipe → recipe shows "missing", never a fake profit → Task 2 test `missing_material_marks_recipe_missing`.
5. `/cp price` with an item link containing spaces, or a plain name, plus "1.5"/"1g50s"/"clear" → Task 8 test `parse_price_command`.

---

### Task 1: Scaffold, test harness, Util

**Files:**
- Create: `CraftProfit/CraftProfit.toc`, `CraftProfit/Util.lua`
- Create: `tests/run.lua`, `tests/wow_mock.lua`, `tests/test_util.lua`, `tests/check_globals.lua`

**Interfaces:**
- Produces (Util.lua, on `ns`):
  - `ns.On(event, fn)`, `ns.Fire(event, ...)` — synchronous bus.
  - `ns.Now() -> number` (wraps `time()`; tests override `ns.Now`).
  - `ns.Util.FormatMoney(copper) -> string` — `"1g 20s 5c"`, omits zero units, `0 -> "0c"`, negative prefixed `"-"`.
  - `ns.Util.ParseMoney(str) -> copper|nil` — `"1.5"->15000`, `"1g50s"->15000`, `"1g 50s 20c"->15020`, `"75s"->7500`, `"20c"->20`, `"abc"->nil`, `""->nil`.
  - `ns.Util.ItemIDFromLink(link) -> number|nil` — `item:(%d+)`.
  - `ns.Util.FormatAge(seconds) -> string` — `<60 "now"`, `<3600 "Nm"`, `<86400 "Nh"`, else `"Nd"`.
- Produces (tests): `tests/run.lua` runs every `tests/test_*.lua`; each returns `{ [name] = function(T) end }`; `T.eq(actual, expected, msg)`, `T.ok(v, msg)`. `tests/wow_mock.lua` returns `Mock` with `Mock.reset()`, `Mock.load(files) -> ns` (runs `CraftProfit/<file>` via `loadfile(path)("CraftProfit", ns)` in order).

- [ ] Step 1: write `tests/run.lua`, `tests/wow_mock.lua` (empty WoW surface for now: `time`, `GetRealmName`, `UnitFactionGroup`, `hooksecurefunc`, `print`), `tests/test_util.lua` with the values above.
- [ ] Step 2: `lua5.1 tests/run.lua` → FAIL (Util.lua missing).
- [ ] Step 3: write `CraftProfit.toc` (Interface 30300, Title, Notes, SavedVariables, SavedVariablesPerCharacter, file order Util, Profit, Prices, Recipes, Scanner, UI, Core) and `Util.lua`.
- [ ] Step 4: `lua5.1 tests/run.lua` → all util tests PASS.
- [ ] Step 5: write `tests/check_globals.lua`: run `luac5.1 -l -p` per file, fail on any `SETGLOBAL` not in the allowed list, and on `GETGLOBAL` names missing from an allowlist of Lua std + the WoW API used (catches typos). Run → PASS.
- [ ] Step 6: commit `feat: scaffold, test harness and Util`.

### Task 2: Profit (pure)

**Files:** Create `CraftProfit/Profit.lua`, `tests/test_profit.lua`

**Interfaces:**
- Consumes: nothing from WoW.
- Produces:
  - `ctx = { recipes = {[id]=recipe}, resolveBuy = fn(id, craftUnitCost|nil) -> price|nil, source, age; resolveSell = fn(id) -> price|nil, source, age; cut = number }`
  - `recipe = { name, made, reagents = { {id, name, count}, ... } }`
  - `ns.Profit.CraftUnitCost(id, ctx, visiting) -> copper|nil` — recipe cost / made; nil if no recipe, a cycle, or a missing reagent.
  - `ns.Profit.Evaluate(id, ctx) -> result` with fields `id, name, made, cost, sell, sellSource, sellAge, revenue, profit, margin, status ("ok"|"missing"), missing ({names}), lines ({ {id, name, count, unit, source, age, total, saves} })`.
  - `ns.Profit.EvaluateAll(ids, ctx) -> list` sorted: ok rows by profit desc, then missing rows by name.

- [ ] Step 1: tests:
  - `basic_profit`: bag = 6 cloth@1000 + 1 thread@500 → cost 6500; sell 10000, cut .05 → revenue 9500, profit 3000, margin 3000/6500.
  - `made_multiple`: made=2, sell 1000 → revenue 1900.
  - `craft_cheaper_than_buy`: bolt AH 6000, bolt recipe 5 cloth@1000 → bolt line source "craft", unit 5000, saves (6000−5000)×count.
  - `buy_cheaper_than_craft`: bolt AH 4000 → source "ah".
  - `cycle_is_safe`: A needs B, B needs A, both with AH prices → evaluates without error, craft option ignored.
  - `missing_material_marks_recipe_missing`: reagent with no price → status "missing", missing = {"Eternium Thread"}, profit nil.
  - `missing_sell_price`: status "missing", missing contains the product name.
  - `evaluate_all_sorts`.
- [ ] Step 2: run → FAIL.
- [ ] Step 3: implement. `resolveBuy` decides priority; Profit only supplies the craft unit cost and computes `saves = (resolveBuy(id, nil) - unit) * count` when source is "craft" and the buy price exists.
- [ ] Step 4: run → PASS. Step 5: commit `feat: profit math`.

### Task 3: Prices

**Files:** Create `CraftProfit/Prices.lua`, `tests/test_prices.lua`; extend `tests/wow_mock.lua` (merchant API, `GetItemInfo`, Auctionator stubs).

**Interfaces:**
- Produces:
  - `ns.Prices.SetDB(db, realmKey)` — `db` is `CraftProfitDB`; creates `db.prices[realmKey]`, `db.vendor`, `db.manual` if missing.
  - `ns.Prices.SetAH(id, unit|nil, listings, t)`; `ns.Prices.GetAH(id) -> unit|nil, t|nil, listings|nil`; `ns.Prices.AllAH() -> table`.
  - `ns.Prices.SetVendor(id, unit)`; `ns.Prices.SetManual(id, unit|nil)`.
  - `ns.Prices.Auctionator(id) -> unit|nil` — tries `Auctionator.API.v1.GetAuctionPriceByItemID("CraftProfit", id)` then `Atr_GetAuctionBuyout(name or link)` via `pcall`; only positive numbers count.
  - `ns.Prices.ResolveBuy(id, craftUnit) -> price, source, age` — manual; else min of ah/vendor/craft (ties prefer ah, vendor, craft); else atr; else nil. `age` set for "ah" only.
  - `ns.Prices.ResolveSell(id) -> price, source, age` — manual, ah, atr.
  - `ns.Prices.IsStale(age) -> bool` (`age > 86400`).
  - `ns.Prices.RecordMerchant() -> count` — `GetMerchantNumItems`, `GetMerchantItemInfo`, `GetMerchantItemLink`; record `floor(price/quantity + .5)` when `price > 0` and not `extendedCost`.
  - `ns.Prices.MakeContext() -> ctx` (Task 2 shape; recipes from `ns.Recipes.All()`, cut from db).
- [ ] Step 1: tests: `manual_wins`, `cheapest_of_ah_vendor_craft`, `atr_fallback_only_when_nothing_else`, `sell_ignores_vendor_and_craft`, `none_listing_is_no_price` (SetAH(id, nil, 0, t) → ResolveBuy falls through), `stale_flag`, `merchant_records_unit_price_skips_tokens`, `auctionator_api_shapes` (each stub alone, plus erroring stub → nil).
- [ ] Step 2: run → FAIL. Step 3: implement. Step 4: run → PASS. Step 5: commit `feat: price store and resolution`.

### Task 4: Recipes

**Files:** Create `CraftProfit/Recipes.lua`, `tests/test_recipes.lua`; extend mock with a scripted profession window.

**Interfaces:**
- Produces:
  - `ns.Recipes.SetDB(chardb)` — creates `chardb.recipes`, `chardb.tracked`.
  - `ns.Recipes.ReadTradeSkill() -> learnedCount` — rules from spec "Recipe learning"; sets `recipe.profession = GetTradeSkillLine()`; fires `"RECIPES_CHANGED"` when anything changed.
  - `ns.Recipes.Get(id)`, `ns.Recipes.All() -> {[id]=recipe}`.
  - `ns.Recipes.SelectedProductID() -> id|nil`.
  - `ns.Recipes.IsTracked(id)`, `ns.Recipes.SetTracked(id, bool)` (fires `"TRACKING_CHANGED"`), `ns.Recipes.TrackedIDs() -> {ids}`.
  - `ns.Recipes.ScanList() -> { {id=, name=}, ... }` — unique ids: tracked products, their reagents, recursing into reagents that are known recipes (visited set); name from recipe/reagent record, else `GetItemInfo(id)`.
- [ ] Step 1: tests: `reads_recipes_skips_headers`, `made_is_average`, `skips_uncached_reagent_link`, `merge_keeps_old_recipes`, `linked_tradeskill_ignored`, `enchant_link_skipped`, `tracking_roundtrip_fires_event`, `scan_list_recurses_and_dedupes` (bag→bolt→cloth gives bag, bolt, cloth, thread once each).
- [ ] Step 2–4: FAIL → implement → PASS. Step 5: commit `feat: recipe learning and tracking`.

### Task 5: Scanner — targeted scan

**Files:** Create `CraftProfit/Scanner.lua`, `tests/test_scanner.lua`; extend mock with an AH (`Mock.ah.auctions = { {id, name, count, buyout} }`, `canQuery`, `canQueryAll`, `nilLinks`, `Mock.queries` log; `QueryAuctionItems` filters by case-insensitive substring, pages of 50; getAll returns everything).

**Interfaces:**
- Consumes: `ns.Prices.SetAH`, `ns.Prices.AllAH`, `ns.Now`, `ns.Fire`.
- Produces:
  - `ns.Scanner.SetDB(db)` (for `lastScanAll`, `scanAllWarned`).
  - `ns.Scanner.StartTargeted(items) -> ok, err` — `items` from `Recipes.ScanList()`; err `"busy"` or `"empty"`.
  - `ns.Scanner.Stop(reason)`; `ns.Scanner.IsBusy() -> bool`.
  - `ns.Scanner.Tick(elapsed)`; `ns.Scanner.HandleEvent(event)` (`AUCTION_ITEM_LIST_UPDATE`, `AUCTION_HOUSE_CLOSED`).
  - `ns.Scanner.OnQuery()` — installed by Core via `hooksecurefunc("QueryAuctionItems", ...)`; ignores our own sends (`ns.Scanner.sending` flag).
  - Fires `"SCAN_STATUS", text` and `"PRICES_CHANGED"` (after each item and at the end).
- State machine and constants: spec "Scanning", Global Constraints.
- [ ] Step 1: tests (driven by `Tick` + delivering `AUCTION_ITEM_LIST_UPDATE` after each mock query):
  - `targeted_finds_lowest_unit_price`
  - `targeted_per_unit_and_skips_bid_only` (stack of 20 for 40g = 2g/unit; buyout 0 ignored)
  - `targeted_filters_other_items` (Silk Cloth vs Bolt of Silk Cloth)
  - `targeted_pages` (120 auctions → pages 0,1,2 queried)
  - `targeted_no_listings_records_none`
  - `waits_for_can_send`
  - `foreign_query_resends`
  - `nil_links_wait_then_read` (links nil on first update, present on second)
  - `timeout_retries_once_then_skips`
  - `ah_closed_stops_keeps_saved`
  - `uses_exact_query_args` (asserts the 10-arg call from Global Constraints)
- [ ] Step 2–4: FAIL → implement → PASS. Step 5: commit `feat: targeted AH scan`.

### Task 6: Scanner — Scan All

**Files:** Modify `CraftProfit/Scanner.lua`, `tests/test_scanner.lua`.

**Interfaces:**
- Produces: `ns.Scanner.StartScanAll() -> ok, err` (err `"busy"`, `"cooldown"`); `ns.Scanner.ScanAllCooldown() -> 0 if ready, seconds remaining, or -1 when unknown (server says no, no local timestamp)`.
- [ ] Step 1: tests: `scan_all_chunks_500_per_tick` (1200 auctions → 3 ticks), `scan_all_min_per_item`, `scan_all_marks_absent_as_none_when_complete`, `scan_all_no_none_marking_with_nil_links`, `scan_all_cooldown_values`, `scan_all_aborts_on_foreign_query`, `scan_all_sets_lastScanAll`.
- [ ] Step 2–4: FAIL → implement → PASS. Step 5: commit `feat: Scan All`.

### Task 7: UI

**Files:** Create `CraftProfit/UI.lua`, `tests/test_ui_smoke.lua`; extend mock with a permissive frame factory (`CreateFrame` returning objects that accept any method; `Create*` methods return child objects; `Get*` numeric getters return 0) and `AuctionFrame`, `TradeSkillFrame`, `GameTooltip`, `StaticPopupDialogs`, `FauxScrollFrame_*`.

**Interfaces:**
- Consumes: `ns.Prices.MakeContext`, `ns.Profit.EvaluateAll`, `ns.Recipes.*`, `ns.Scanner.*`, `ns.Util.*`, bus events `PRICES_CHANGED`, `RECIPES_CHANGED`, `TRACKING_CHANGED`, `SCAN_STATUS`.
- Produces:
  - `ns.UI.EnsurePanel()` — builds `CraftProfitPanel` once (layout per spec "UI"); safe to call repeatedly.
  - `ns.UI.Refresh()`; `ns.UI.Toggle()`; `ns.UI.UpdateScanButtons()` (called each ~0.5 s by Core).
  - `ns.UI.EnsureTrackButton()` — creates `CraftProfitTrackCheck` on `TradeSkillFrame` at `TOPLEFT` (210, −46), label "Track profit"; `ns.UI.UpdateTrackButton()`; hooks `TradeSkillFrame_SetSelection` once.
  - `ns.UI.RowTooltip(result)` — fills `GameTooltip` with the breakdown (source labels: ah "AH", vendor "vendor", craft "craft", manual "manual", atr "Atr").
  - `StaticPopupDialogs["CRAFTPROFIT_SCANALL"]` confirmation, shown when `not db.scanAllWarned`.
- [ ] Step 1: smoke test: load all modules, set data for two recipes, call `EnsurePanel`, `Refresh`, `RowTooltip` for an ok and a missing result, `EnsureTrackButton`, `UpdateTrackButton`, `UpdateScanButtons` — no errors; Refresh produces rows in sorted order (inspect `ns.UI.rowsData`).
- [ ] Step 2–4: FAIL → implement → PASS. Step 5: commit `feat: AH panel and track checkbox`.

### Task 8: Core — events and slash commands

**Files:** Create `CraftProfit/Core.lua`, `tests/test_core.lua`.

**Interfaces:**
- Consumes: everything above.
- Produces:
  - Event frame handling `PLAYER_LOGIN` (init DBs: `CraftProfitDB` defaults `{version=1, prices={}, vendor={}, manual={}, cut=0.05}`, `CraftProfitCharDB` defaults; realm key `GetRealmName().."-"..UnitFactionGroup("player")`), `TRADE_SKILL_SHOW/UPDATE`, `MERCHANT_SHOW/UPDATE`, `AUCTION_HOUSE_SHOW/CLOSED`, `AUCTION_ITEM_LIST_UPDATE`; `OnUpdate` → `Scanner.Tick`, UI button refresh every 0.5 s; `hooksecurefunc("QueryAuctionItems", ns.Scanner.OnQuery)`.
  - `ns.Core.ParseItemArg(msg) -> id|nil, rest` — item link (`|Hitem:ID...|h[...]|h|r`), else longest prefix matching a known recipe/reagent name or `GetItemInfo(name)`.
  - `ns.Core.Slash(msg)` — commands per spec "Slash commands".
- [ ] Step 1: tests: `parse_price_command` (link with spaces + "1g50s"; plain known name + "1.5"; "clear"), `slash_cut_sets_fraction` (`/cp cut 15` → 0.15; invalid → unchanged), `login_initialises_defaults`, `slash_track_toggles_selected`.
- [ ] Step 2–4: FAIL → implement → PASS. Run `lua5.1 tests/check_globals.lua` → PASS. Step 5: commit `feat: core events and slash commands`.

### Task 9: README, packaging, final verification

**Files:** Create `README.md`, `tools/package.sh`.

- [ ] Step 1: README: install (unzip into `Interface/AddOns/CraftProfit`), usage, slash commands, how prices are chosen, Scan All warning, in-game checklist (enable addon → open Tailoring → tick Track profit → open AH → Scan tracked → verify one row by hand → hover breakdown → right-click untrack → Scan All once → visit a thread vendor → `/cp price` → check "(Atr)" shows if a material has no listings).
- [ ] Step 2: `tools/package.sh` builds `dist/CraftProfit.zip` containing only `CraftProfit/`.
- [ ] Step 3: run all tests, global check, `luac5.1 -p` on every file, package; confirm zip listing.
- [ ] Step 4: commit `docs: README and packaging`.
