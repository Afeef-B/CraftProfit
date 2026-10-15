# CraftProfit Selling (CP Sell + CP Auctions) — Design Spec

Date: 2026-10-15
Target: WoW 3.3.5a (interface 30300), Warmane; extends the CraftProfit addon
Status: approved in chat, awaiting written-spec review
Builds on: `2026-10-15-craftprofit-design.md`

## Goal

First piece of "a better Auctionator with profession features": selling.
The tailor posts crafted items at 1 copper under the cheapest listing, sees
crafting cost and profit while posting, sees which of their auctions are
undercut and by whom, and cancels with one click each.

Also in scope (small change to existing profit code): per-recipe
**Ready-made vs From scratch** material pricing, so tracked recipes don't
scan the whole material tree by default.

Success: put a Glacial Bag in CP Sell → within a few seconds see all
listings, a price 1c under the cheapest other seller, the profit vs crafting
cost, and post with one click. In CP Auctions, click the bag → see every
listing with yours marked YOU and cheaper ones marked "⚠ under you".

## Decisions (from the brainstorm)

| Topic | Decision |
|---|---|
| Overall goal | Replace Auctionator over time; profession features are the differentiator |
| Build order | Selling first (this spec); Buy and a Craft Profit tab later |
| Placement | New AH tabs "CP Sell" and "CP Auctions" after any existing tabs |
| Undercut | Highest whole-silver price below the cheapest *other* seller (420g → 419g 99s; 419g 99s 57c → 419g 99s); below 1s: 1c under; never undercut yourself or your alts |
| Alts | Every character that logs in with CraftProfit (same realm) counts as "you" |
| Mistake listings | Other-seller listings under 50% of the next listing are "mistakes": never undercut, never count as undercutting you, shown as a flip with a one-click **Buy it** |
| Symbols | No ✓ ⚠ emoji in-game (3.3.5 fonts lack them): inline textures `ReadyCheck-Ready`, `UI-Dialog-Icon-AlertNew`, `UI-GoldIcon` |
| Below crafting cost | Warn in red with the loss; posting still allowed |
| My Auctions | Item list left; click an item → full listings right, yours = YOU, cheaper others = "⚠ under you" |
| Craft depth | Per tracked recipe; Ready-made (default) or From scratch |
| Every post/cancel | Triggered by the player's click (client rule + Warmane rules); no background automation |

## Files

New files in `CraftProfit/` (load order after `UI.lua`, before `Core.lua`):

```
Listings.lua     price-check results: per-item listing rows + undercut maths (pure)
Tabs.lua         adds the two AH tabs and switches our pages in/out
Sell.lua         Sell logic: item in slot, default price/stack/duration, Post
SellUI.lua       Sell page widgets
Auctions.lua     owner-list reading, grouping, undercut status, cancelling
AuctionsUI.lua   My Auctions page widgets
ListingsUI.lua   the shared listings table (used by both pages)
```

Changed: `Scanner.lua` (collect listing rows + seller), `Recipes.lua` and
`Profit.lua` (craft depth), `UI.lua` (row right-click menu), `Core.lua`
(events, wiring), `CraftProfit.toc`.

## Listings (Listings.lua — pure)

A price check of one item produces rows:

```lua
row = { count = 20, buyout = 40000, unit = 2000, seller = "Bob", mine = false }
```

- `unit = buyout / count`, rounded to copper; rows with `buyout == 0` are kept
  for display but never used for pricing.
- `mine = mineSet[seller] ~= nil` where `mineSet` holds this character and
  its alts (`CraftProfitDB.chars["<realm>-<faction>"][name] = true`, recorded
  at login). Rows whose seller is still nil after the link/owner wait count
  as other sellers but show seller "?".
- **Mistake listings:** among other sellers' rows with a buyout (sorted), find
  the largest `i <= 3` with `unit[i] < ratio * unit[i+1]` (`ratio` =
  `CraftProfitDB.outlierRatio`, default 0.5); rows `1..i` get `outlier = true`.
  When there is exactly one other-seller row, it is compared with your
  lowest listing priced above it (so a lone 50g listing next to your 420g is
  a mistake, but two sellers at 300g/310g next to your 800g are the market).
  `Summarize` also returns `flipRef`, the price the flip was measured against.
- Rows sorted by `unit` ascending, then `count` descending.

Functions:

- `Listings.Summarize(rows) -> { lowestOther, lowestOtherSeller, lowestMine, mineCount, flip }`
  — outlier rows never count as `lowestOther`; `flip` = the cheapest outlier row.
- `Listings.UndercutPrice(rows, fallback) -> unit|nil, reason`
  - no (non-outlier) other sellers with a buyout → `fallback` (may be nil), reason `"no-competition"`
  - `lowestMine and lowestMine <= lowestOther` → `lowestMine`, reason `"match-own"`
  - `lowestOther > 100` → `floor((lowestOther - 1) / 100) * 100`, reason `"undercut"`
  - otherwise `max(1, lowestOther - 1)`, reason `"undercut"`
- `Listings.Status(rows) -> "cheapest" | "tied" | "undercut", diff, seller`
  comparing `lowestOther` to `lowestMine` (`<` undercut, `==` tied, `>` cheapest;
  no other sellers → cheapest). Outliers are ignored (they are flips).
- `Listings.MarkUnderYou(rows)` sets `row.underYou = true` for other sellers'
  non-outlier rows with `unit < lowestMine`.

Results are cached in memory per item id with a timestamp
(`ns.Listings.cache[id] = { t = epoch, rows = {...} }`), shared by both pages.

## Scanner changes

- `Scanner.StartTargeted(items, opts)`; `opts.collect = true` makes the scan
  keep every row of the target item:
  `{ count, buyout, seller = owner (12th return of GetAuctionItemInfo) }`.
- When collecting, a page is read only when every row has a link **and** an
  owner, or after the existing 2 s wait (then nil sellers stay nil). Each raw
  row also records `page` (query page) and `index` (row on that page) for
  the flip buy.
- `Scanner.LoadPage(name, page) -> ok, err`: one plain query (no job), only
  when idle and `CanSendAuctionQuery()`; err `"busy"` / `"throttled"`.
- At the end of each item, collected rows go to `ns.Listings.Store(id, rows)`
  and `"LISTINGS_UPDATED", id` fires. Prices are saved as today.
- `Scanner.PriceCheck(item)` = `StartTargeted({ item }, { collect = true })`.

## Tabs (Tabs.lua)

- When `AuctionFrame` exists (login or `ADDON_LOADED` Blizzard_AuctionUI),
  find the first free `n` with `_G["AuctionFrameTab"..n] == nil`; create
  `AuctionFrameTab{n}` "CP Sell" and `AuctionFrameTab{n+1}` "CP Auctions"
  from `AuctionTabTemplate`, each anchored `TOPLEFT` to the previous tab's
  `TOPRIGHT` at x −8; `PanelTemplates_SetNumTabs(AuctionFrame, n+1)`.
- If another addon later adds tabs after ours, they anchor to our last tab.
- `hooksecurefunc("AuctionFrameTab_OnClick", ...)`: show our page for our tab
  id, hide both our pages for any other id. Blizzard's handler already hides
  its three pages for ids > 3.
- Our pages are children of `AuctionFrame` covering the content area
  (TOPLEFT 20,−72 to BOTTOMRIGHT −10,40 relative to the 832×447 frame), with
  their own dark backdrop so earlier tab textures don't show through.

## CP Sell (Sell.lua, SellUI.lua)

Layout: left column (item slot, inputs, money lines, Post), right column
(listings table).

**Item in**
- Drag an item onto our slot, or Alt+click an item in bags while CP Sell is
  shown (`hooksecurefunc("ContainerFrameItemButton_OnModifiedClick")`,
  `IsAltKeyDown()`; `PickupContainerItem(bag, slot)` then
  `ClickAuctionSellItemButton()`).
- If the game's sell slot already held an item, it lands on the cursor after
  the swap; `ClearCursor()` returns it to the bags.
- The game holds one sell item at a time; our slot shows
  `GetAuctionSellItemInfo()` and refreshes on `NEW_AUCTION_UPDATE`.
- Item id comes from the bag link we picked up (drag: `GetCursorInfo()` before
  dropping). Not auctionable (no sell info after the drop) → status
  "This item can't be auctioned."
- On item in: `Scanner.PriceCheck`; status "Searching…"; busy scanner →
  "Waiting for the current scan…" and the check starts when it finishes.

**Defaults**
- Price each: `Listings.UndercutPrice(rows, fallback)` where fallback =
  `Prices.ResolveSell(id)` (manual → last AH → Auctionator).
  Nil → field empty, Post disabled until a price is typed.
- Bid = buyout.
- Max stack from `GetItemInfo` (8th return), owned = `GetItemCount(id)`:
  max stack 1 → stack 1 × owned; else stack `min(maxStack, owned)` ×
  `floor(owned / stack)`.
- Duration 1/2/3 = 12/24/48 h; default 2; last choice saved in
  `CraftProfitDB.sell.duration`.
- Clicking a listings row sets price each = that row's unit − 1c (min 1c);
  clicking one of your own rows sets it equal.

**Money lines**
- Deposit `CalculateAuctionDeposit(duration, stackSize * numStacks)`.
- You get each = `price × (1 − cut)`.
- If the item is a known recipe: cost each = `Profit.Evaluate(id).cost / made`
  using stored prices and the recipe's craft depth; profit each =
  you-get − cost. Profit ≥ 0 green; < 0 red "loses Xg vs crafting cost".
  Missing material prices → grey "cost unknown – scan it in Craft Profit".

**Post**
- Button text "Post N auction(s)"; enabled when an item is in the slot,
  price ≥ 1c, stack size ≥ 1, stacks ≥ 1, `stackSize*stacks <= owned`,
  `GetMoney() >= deposit`.
- On click: `StartAuction(unit*stack, unit*stack, duration, stack, stacks)`.
- Progress from `AUCTION_MULTISELL_START/UPDATE/FAILURE`
  ("Posting 2/3…", "Posted 3 auctions", failure text); afterwards a fresh
  price check of the item so the listings show the new auctions.

## Flip buy (Flip.lua)

Shown wherever a cached listing set has a `flip` row (CP Sell under the
money lines; CP Auctions right panel): red notice "Possible mistake: Bob
sells 1 at 50g (next 420g). Flip profit ≈ 349g" (next listing × (1 − cut) −
buyout) and a **Buy it** button.

- `Flip.Buy(id, row) -> ok, msg` (button `OnClick` only):
  1. `GetMoney() < row.buyout` → "Not enough gold".
  2. Look for the exact auction on the loaded "list" page: same item id,
     count, buyout and seller → `PlaceAuctionBid("list", i, row.buyout)`,
     status "Bought for 50g", then a fresh price check of the item.
  3. Not on the page → `Scanner.LoadPage(name, row.page)`; button becomes
     "Finding it…", then "Buy now (50g)" once the page arrives and the
     auction is there (a second click buys — purchases need a click), or
     "That listing is gone" if not.
- Never buys anything that doesn't match the shown row exactly.

## CP Auctions (Auctions.lua, AuctionsUI.lua)

**Reading your auctions**
- On page show: `GetOwnerAuctionItems(0)`; on `AUCTION_OWNED_LIST_UPDATE`
  read `GetNumAuctionItems("owner")`; if `total > 50`, request the next page
  until all are read.
- Per auction: link → id, count, buyout, `saleStatus` (13th return; 1 = sold),
  `GetAuctionItemTimeLeft("owner", i)` (1 short … 4 very long), index.
- Grouped by item: name, icon, active count, sold count, lowest unit price
  of active ones, shortest time left.

**Left list**: item | yours | status. Status from the listings cache:
"cheapest", "tied", "undercut 10g (Bob)", "sold", or "—" (not checked), with
the tick / warning icons; a flip adds the gold-coin icon "flip: 50g listing".
**Check undercuts** = `StartTargeted(itemsOfMine, { collect = true })`.

**Right panel**: clicking an item runs `Scanner.PriceCheck(item)` (or uses a
cache entry younger than 60 s) and shows the shared listings table:
qty, price each, seller; your rows "YOU" / "YOU (Altname)", cheaper rows
"under you" (warning icon), mistake rows "flip" (gold icon).

**Cancelling (one auction per click)**
- Right panel **Cancel undercut (N)**: cancels the next active auction of
  the selected item whose unit price > its (non-outlier) `lowestOther`
  (`CanCancelAuction(i)` true, not sold). Auctions still cheapest are kept.
- Left **Cancel next undercut (N)**: the next active auction, across all
  items, whose unit price > that item's `lowestOther` (from the cache).
  Items without a cache entry don't count; with no checks yet the button
  shows "(0)" and is disabled until **Check undercuts** has run.
- Indexes are looked up fresh before every cancel (the owner list changes
  after each one); then `CancelAuction(i)`.
- A one-time StaticPopup explains: cancelled items go to your mailbox and the
  deposit is lost.
- Right panel **Undercut**: switches to CP Sell with the item if
  `GetItemCount(id) > 0`, else status "Collect it from your mailbox first."

## Ready-made vs From scratch (Recipes.lua, Profit.lua, UI.lua)

- Stored per character: `CraftProfitCharDB.depth[id] = "scratch"`; absent =
  ready-made.
- `Recipes.Depth(id)`, `Recipes.SetDepth(id, "ready"|"scratch")` (fires
  `TRACKING_CHANGED`).
- `Recipes.ScanList()`: ready-made recipe → product + direct reagents only;
  from scratch → today's recursive list.
- `Profit.Evaluate`: `ctx.depth(id)`; ready-made → direct reagents priced with
  `resolveBuy(reagentId, nil)` (no craft option). From scratch → today.
- Profit panel row right-click opens an `EasyMenu`: "Ready-made materials",
  "From scratch", "Stop tracking" (replaces right-click = untrack). The row
  name gets a suffix: "(ready-made)" or "(from scratch)".

## Errors

- Sell slot empty after a drop → can't be auctioned (soulbound, quest item).
- Not enough gold for the deposit → Post disabled, status says so.
- `UI_ERROR_MESSAGE` while posting/cancelling → shown in the page status.
- AH closes mid price-check → scanner stops (existing); pages clear status.
- Owner list empty → "You have no auctions."
- Tab creation when `AuctionFrame` isn't loaded yet → retried on
  `ADDON_LOADED` Blizzard_AuctionUI (same pattern as the profit panel).

## Testing

Same Lua 5.1 mock harness. Extend the mock with: owner list
(`GetOwnerAuctionItems`, "owner" list, `CancelAuction`, `CanCancelAuction`,
`GetAuctionItemTimeLeft`), sell slot (`ClickAuctionSellItemButton`,
`GetAuctionSellItemInfo`, `StartAuction` recording its args,
`CalculateAuctionDeposit`, `GetMoney`, `GetItemCount`, `GetCursorInfo`),
seller names in auction rows, `UnitName`, `AuctionFrameTab1..3`,
`PanelTemplates_SetNumTabs`, `EasyMenu`.

Unit tests:
- Listings: undercut price (others only, match own, no competition, 1c floor,
  bid-only rows ignored), status cheapest/tied/undercut, underYou marks, sort.
- Scanner: collect mode keeps seller/count/buyout, waits for owners, stores
  per item, `LISTINGS_UPDATED`.
- Tabs: first free index after 3 and after 6 (Auctionator), anchors, show/hide
  on tab clicks.
- Sell: defaults (stack for gear vs stackables, duration memory), Post args
  per stack, Post disabled cases, profit line ok/red/unknown, row click price.
- Auctions: grouping, paging > 50, sold handling, cancel picks the right fresh
  index, "cancel next undercut" order and count, Undercut → Sell or mailbox
  message.
- Craft depth: scan list sizes (Glacial-Bag-like tree), Evaluate per mode,
  menu sets depth.

In-game checklist added to the README (tabs next to Auctionator's, post 1
item, post 2 stacks, check undercuts, click an item, cancel one).

## Out of scope (later pieces)

Buy tab and shopping lists, Craft Profit as a tab (stays the side panel),
mail collection, automatic reposting, bid-only auctions, price history.
