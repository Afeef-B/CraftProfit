# CraftProfit 1.2.0: CP Buy, a cleaner UI, smaller posts — Design Spec

## Goal

Three changes requested after trying 1.1.0:

1. **CP Buy tab.** The normal AH search doesn't sort by price per unit, so
   finding the cheapest materials is slow. CP Buy searches an item, lists
   every listing cheapest-per-unit first, and buys the cheapest one per
   click until the player has as many as they need.
2. **Better UI.** The pages look plain and the text is too small. Keep
   everything inside the AH window (the player keeps Tailoring open beside
   it and shift-clicks materials into the AH), but make it organized, well
   fitted and readable.
3. **Smaller posts.** When undercutting, CP Sell defaults to one auction of
   2 items, not everything in the bags, "so if someone undercuts me I can
   always undercut back."

## Decisions (from the brainstorm)

| Question | Answer |
|---|---|
| UI problems | Looks plain or ugly; too small to read |
| Where pages live | Inside the AH; organized and well fitted |
| Post amount | Smaller stacks |
| Default stack size | Always 2 (1 if the item doesn't stack or only 1 is owned) |
| Default number of auctions | Always 1 |
| Finding what to buy | Search box + materials list from tracked recipes |
| Buy flow | "Buy cheapest" button, with a "need" count that counts down; a row click buys that exact row |
| Cheapest stack bigger than needed | Cheapest that fits: skip stacks bigger than what's still needed when a smaller one exists |
| Mockups | Skipped (go straight to building) |

## Files

| File | Change |
|---|---|
| `Style.lua` (new, toc after Util) | Shared look: panel backdrops, fonts, row stripes, colours, `Style.Money(copper)` with coin icons |
| `Buyer.lua` (new, toc after Listings) | One shared purchase path: exact-match find on the loaded page, `PlaceAuctionBid`, finding/ready/gone/bought states. Flip and CP Buy both use it. |
| `Flip.lua` | Keeps the flip rules (`Info`, notice), but buys through Buyer. Its own find/buy code moves to Buyer. |
| `Buy.lua` (new, after Flip) | CP Buy logic: search, need count, next-pick rule, material list |
| `BuyUI.lua` (new, after Buy) | CP Buy page |
| `Tabs.lua` | Third tab "CP Buy" (first of our tabs): CP Buy, CP Sell, CP Auctions |
| `Sell.lua` | Default counts: stack 2, 1 auction |
| `ListingsUI.lua`, `SellUI.lua`, `AuctionsUI.lua`, `UI.lua` | Restyled with Style.lua |
| `Core.lua` | Shift-click hook, Buy wiring, version 1.2.0 |
| `README.md` | CP Buy, new defaults, checklist |

Toc order: Util, Style, Profit, Prices, Recipes, Scanner, Listings, Buyer,
UI, ListingsUI, Tabs, Flip, Buy, BuyUI, Sell, SellUI, Auctions, AuctionsUI,
Core.

## Shared purchase path (Buyer.lua)

The 1.1.0 flip code already does the hard part safely. It moves to
`ns.Buyer`, and Flip and CP Buy both call it:

- `Buyer.Buy(key, row, name)`: `key` names the caller's entry, e.g.
  `"flip:<id>"` or `"buy:<id>"`. `row` is the exact row drawn on screen.
  - If the row is on the loaded "list" page and matches id, count, buyout
    and seller exactly, check the gold, call `PlaceAuctionBid("list", i,
    buyout)`, and set the state to "bought".
  - Otherwise call `Scanner.LoadPage(name, row.page)` and set the state to
    "finding". When the page arrives the state becomes "ready", meaning the
    next click buys. If the row is gone, the state becomes "gone".
- It keeps every 1.1.0 safety:
  - exactly one `PlaceAuctionBid` call site in the addon (it moves from
    Flip.lua to Buyer.lua; test_guards updated);
  - the drawn-row identity check;
  - no buy on a whole-AH list (more than 50 rows);
  - the 10 s find timeout and the 2 s wait for unreadable rows;
  - `Scanner.Resend` after a buy while a scan is busy, and the Scan All
    stop;
  - "Bid placed for X" status;
  - Reset keeps "bought".
- It fires `BUYER_CHANGED(key)` and `PAGE_STATUS(text)`.
- Flip's behaviour and texts stay exactly as in 1.1.0. Its tests keep
  passing, with only call sites moved.

## CP Buy (Buy.lua, BuyUI.lua)

**Searching**
- A search box and a Search button. Enter or the button runs
  `Scanner.PriceCheck({ id?, name })`, which reuses collect mode, so rows
  come back normalized and sorted by unit price, with mistake marks and
  YOU tags.
  - A typed name has no id. Buy resolves it with `GetItemInfo(name)` when
    the item is cached; otherwise it uses the id of the first row whose
    name matches.
- **Shift-click:** while CP Buy is shown, shift-clicking any item link
  (Tailoring reagents, bags, chat) fills the box and searches. This uses
  `hooksecurefunc("ChatEdit_InsertLink", fn)`. When a chat edit box is
  active, the link goes to chat as usual and no search runs.
- **Materials list:** a dropdown "Materials for:" lists tracked recipes.
  Picking one shows its reagents with "have / need", where need =
  reagent count × the "Crafts" box (default 1) and have = `GetItemCount`.
  Clicking a material searches it and sets Need to (need − have, min 0).
  The reagents follow the recipe's craft depth: ready-made = direct
  reagents; from scratch = the expanded list, as Profit already computes.

**Results table** (the shared listings table, restyled)
- Columns: icon, qty, price each, stack total, seller.
- Your own rows show YOU and can't be bought.
- Mistake rows show a green "deal" tag. On CP Buy a mistake listing is
  simply the best buy. The flip widget is not shown on this page.
- A row click selects it. "Buy this (X)" then buys exactly that row.

**Need and Buy cheapest**
- A "Need" number box: empty = no target.
- The button reads "Buy cheapest: 5 for 1g 20s".
- Pick rule: among the buyable priced rows (not mine, has a buyout), keep
  those with count ≤ remaining need. Take the cheapest per unit of those.
  If none fits, take the row with the lowest stack total. With no need
  set, take the cheapest per unit.
- After a "bought" result, remaining = remaining − count. At ≤ 0 the
  button reads "Done (bought 40)" and is disabled until Need changes.
- A bought row is removed from the shown list at once: the post-buy check
  refreshes the rows, and the bought row is skipped until then, so the
  next click picks the next row.
- Every purchase is one click through Buyer.Buy. Nothing buys on its own.
- Status line: "Bought 5 of 40 (spent 1g 20s)". PAGE_STATUS and PAGE_ERROR
  show only while CP Buy is shown.

**Errors**
- Not enough gold → "Not enough gold", and nothing is bought.
- Row gone → "Gone - search again" (the search reruns on the next click).
- Search while scanning → "Waiting for the current scan...", then it runs
  when the scan ends (same as CP Auctions' retry).

## Smaller posts (Sell.lua)

- `defaultCounts(maxStack, owned)` becomes: stack = min(2, maxStack,
  owned), stacks = 1.
  - 5 Glacial Bags → 1 × 1. 40 bolts → 1 auction of 2.
- The player can still type any stack size and count.

## UI rework (Style.lua + the pages)

Everything stays inside the AH frame and fits its content area (about
760 × 335 below the tab row). Each page uses the same layout.

```
+----------------------------------------------------------------+
| [Section: item / search]        | [Listings: "<item>: all ..."] |
|  big icon + name + have         |  icon  qty  price each  seller |
| [Section: price / amounts]      |  ...   (12 rows, 18 px,       |
| [Section: deposit / profit]     |        striped, hover glow)    |
| [Action buttons, wide]          |                                |
+----------------------------------------------------------------+
| status bar (full width)                                         |
+----------------------------------------------------------------+
```

- **Panels:** each section is a dark box drawn with 3.3.5 `SetBackdrop`:
  - background `Interface\Tooltips\UI-Tooltip-Background` at 0.85
    alpha;
  - edge `Interface\Tooltips\UI-Tooltip-Border`, 12 px;
  - a gold section title in `GameFontNormal`.
- **Fonts:** body text moves from 10 pt (`*Small`) to `GameFontHighlight`
  (12 pt); key numbers (price, profit) use `GameFontNormalLarge`.
  - Nothing uses `*Small` for content.
  - Labels are grey, values white, money gold, profit green or red.
- **Rows:** 18 px tall (was 14), with a 16 px item icon, alternating faint
  stripes, a hover highlight, and a gold highlight on the selected row.
  - 12 visible rows; the columns are re-measured to fit the larger fonts.
  - Long text truncates with "..." (SetWidth + no wrap); it never spills
    out.
- **Money:** `Style.Money(copper)` uses coin icons (gold, silver and
  copper textures), with zero parts left out.
- **Buttons:** wider (at least 120 px), with one primary action per page in
  a highlighted button: Post, Buy cheapest, Cancel undercut.
- **Status bar:** one full-width line at the bottom of every page, in the
  same place on all three.
- **Profit panel (UI.lua):** the same fonts, rows and backdrop; no
  behaviour change.
- No textures outside the stock 3.3.5 client files. No new libraries.

## Testing

- The same plain-lua harness.
- New tests:
  - Buyer: the moved flip tests plus the CP Buy key.
  - Buy pick rule:
    - need 4 with stacks 20 and 5: the 5 when it is cheaper in total, and
      the "fits" case;
    - no need set;
    - own rows skipped.
  - Buy countdown and the "Done" state.
  - Bought-row skip until refresh.
  - Shift-click search only while CP Buy is shown and no chat box is
    active.
  - Materials list need = count × crafts − have.
  - Sell default counts (bag → 1×1, bolts → 1 auction of 2, owned 1 →
    1×1).
  - Style.Money formatting.
  - Tabs: three tabs in order with no collision.
  - test_guards: one PlaceAuctionBid (Buyer.lua), one StartAuction
    (Sell.lua), one CancelAuction (Auctions.lua).
- README in-game checklist additions:
  - Shift-click a Tailoring reagent with CP Buy open.
  - Buy cheapest counts down.
  - The pages fit with no overlaps or clipped text.
  - Text is readable.

## Out of scope

- A separate window, a scale slider, mockups.
- Bidding, as opposed to buyout.
- Buying across several items in one click.
- Auto-buy of any kind.
