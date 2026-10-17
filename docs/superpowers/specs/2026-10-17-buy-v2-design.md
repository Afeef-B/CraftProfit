# CraftProfit 1.3.0: CP Buy like Auctionator, prices on tooltips, no needless rescans — Design Spec

## Goal

After trying 1.2, the user wants three changes:

1. **CP Buy "like Auctionator".** The list takes the full page width.
   - A search first shows every matching item as one line.
   - Clicking an item shows its listings, with identical listings grouped
     ("3 stacks of 20 @ 9s").
   - Shopping lists hold items to search. They are made automatically from
     tracked recipes, and the player can also make their own.
2. **Price database outside the AH.** Hovering any item shows its last AH
   price and how old that price is, and for the player's crafts, the
   crafting cost.
3. **No needless rescans.** An item scanned within the last 3 minutes is not
   searched again. Scan tracked skips it and CP Buy reuses its listings.
4. **CP Sell remembers post sizes** (added after the spec was approved). The
   player picks how many items per auction and how many auctions, and CP Sell
   keeps that per item, with a default the player sets.

## Decisions (from the brainstorm)

| Question | Answer |
|---|---|
| Auctionator parts wanted | Item list first; grouped listings; shopping lists |
| Something else | Full-width list; a price database usable outside the AH |
| Where prices show outside the AH | Item tooltips |
| How recent counts as "just scanned" | 3 minutes |
| Shopping lists | Automatic (one per tracked recipe) plus the player's own |
| Confirm box before buying | Not picked: one click per purchase, as today, with the total on the button |
| How CP Sell remembers stack size x auctions | Both: per item (what was last posted) plus a default setting for items not posted yet |

## Files

| File | Change |
|---|---|
| `Scanner.lua` | New `Scanner.Search(text)` that reads every page of a name search and keeps all items' rows (capped). `StartTargeted` skips fresh items. |
| `Prices.lua` | `Prices.IsFresh(id)`; `db.freshSeconds` (default 180) |
| `Listings.lua` | `Listings.Group(rows)` merges identical listings |
| `Lists.lua` (new, after Listings) | Shopping lists: automatic per tracked recipe plus the player's own; stored in `CraftProfitDB.lists` |
| `Buy.lua` | Rewritten around three views: results, item and list. It keeps the pick rule, Need, the countdown and every 1.2 safety. |
| `BuyUI.lua` | Rewritten as a full-width page |
| `Tooltip.lua` (new, after Lists) | Adds price lines to GameTooltip and ItemRefTooltip |
| `Sell.lua` | Post sizes per item plus a default (`db.sell.sizes`, `db.sell.defaultStack`, `db.sell.defaultStacks`) |
| `SellUI.lua` | A "Set as default" button next to the stack x auctions boxes |
| `Core.lua` | `/cp fresh <minutes>`; `/cp post <items> <auctions>`; wiring; version 1.3.0 |
| `README.md` | New CP Buy, tooltips, fresh window |

Every 1.2 money rule stays:
- one `PlaceAuctionBid` call site, in Buyer;
- one purchase per click;
- the exact row match;
- the player's own and alts' listings are never bought;
- the stale-index skip;
- vanished listings are searched again.

## CP Buy (full width)

```
+-----------------------------------------------------------------------------+
| [ search box .................... ] [Search] [Lists v] [+ To list] [< Back] |
+-----------------------------------------------------------------------------+
|  (the view: results / item / list), 11 rows, full width, 18 px rows         |
+-----------------------------------------------------------------------------+
| (the view's actions: Need box, Buy cheapest, Buy one, Crafts, Search all)   |
+-----------------------------------------------------------------------------+
| status bar                                                                  |
+-----------------------------------------------------------------------------+
```

**Results view** (after a search, unless the text is an exact item name)
- `Scanner.Search(text)` reads every page of the name search and groups
  the rows by item id.
- Each item's cheapest price (not a mistake listing) goes into the price
  database with `Prices.SetAH`, so one search fills it for every item it
  saw. The rows themselves are not kept as the item's listings: their page
  numbers belong to the name search, and a purchase loads pages of the
  item's own category search. The item view therefore checks the item
  again unless it already has fresh listings from a price check.
- A search that stopped early (the cap, or an exact name, below) stores no
  prices: some items' listings were not all read.
- One line per item: icon, name, cheapest each, the number of listings,
  the total quantity, and the age. Sorted by name.
- Clicking a line opens the item view for that item.
- Cap: at most 20 pages (1000 listings). Past that, the status line says
  "Showing the first 1000 listings - type more of the name."
- **Exact names go straight to the item view.** If the text is the exact
  name of an item the client knows (`GetItemInfo(text)`), or of a tracked
  recipe or one of its materials (any case), the search goes straight to
  the item view. That view uses a category search, so a search for
  "King's Amber" reads one or two pages. For other text the name search
  stops at the first page that has an item with exactly that name and
  opens its item view.

**Item view** (one item's listings)
- Rows are grouped by identical (count, buyout, mine) with
  `Listings.Group`. A line shows the stack size, the number of stacks,
  the price each, the price per stack, the seller (or "Bob +2"), and a
  note: YOU, deal, under you, or bought.
- Groups are sorted by price each.
- Clicking a group selects it. **Buy one (X)** buys one listing of that
  group per click: the first one that is not bought and not mine. The
  group's stack count goes down.
- **Need** box plus **Buy cheapest** work as in 1.2, using the same pick
  rule, countdown and status texts.
- Listings younger than the fresh window (3 minutes) are reused without
  searching. Otherwise the item is searched (`PriceCheck`, category
  search).
- **< Back** returns to the results or list view the player came from.

**List view** (a shopping list picked from **Lists v**)
- **Lists v** opens a menu:
  - one automatic list per tracked recipe ("Glacial Bag materials");
  - the player's own lists;
  - "New list...", which asks for a name in a StaticPopup with an edit
    box;
  - "Delete <list>" for the player's lists only.
- A line per item: name, have / need, cheapest each and age (from the
  price database).
  - Automatic lists compute need from the recipe's materials × the
    **Crafts** box, with the 1.2 materials logic (depth, whole crafts).
  - The player's own lists have no need. They show have only.
- Clicking an item opens its item view. For an automatic list, Need is
  set to need − have; 0 means "You have enough."
- **Search all** price-checks every item on the list, skipping the fresh
  ones, so the cheapest column fills in.
- **+ To list** (in the item view) adds the shown item to one of the
  player's lists, chosen from a menu. Right-clicking an item in one of
  the player's lists removes it.

## Price database and tooltips (Tooltip.lua)

- The database is the existing `Prices` store per realm and faction:
  price, time, count. It is filled by every scan, search and Scan All.
- **Tooltip lines** are added on `OnTooltipSetItem` for GameTooltip and
  ItemRefTooltip:
  - `CraftProfit AH: 12g 50s (2h ago)`, the cheapest non-mistake buyout
    each. With no data the line reads `CraftProfit AH: not seen yet`.
  - If the item is a known recipe:
    `Craft cost: 8g (ready-made)` or `(from scratch)`. Its sell profit
    each is already in the profit panel, so it is not repeated here.
  - For a stack in the bags (count > 1): `x20: 250g`.
- The lines are added once per tooltip show, with no duplicates when the
  client calls SetItem twice. Money uses `Style.Money`; ages use
  `Util.FormatAge`.

## Fresh window (no needless rescans)

- `Prices.IsFresh(id)` is true when the stored AH time is younger than
  `db.freshSeconds`, which defaults to 180.
- `/cp fresh <minutes>` sets it (0-60). 0 always rescans.
- **Scan tracked** (and the list view's Search all) skips fresh items. The
  status line says "Scan done: 5 items (3 still fresh, skipped)".
- **CP Buy item view and CP Auctions Select** reuse cached listings
  younger than the window. CP Auctions' 60 s becomes this setting.
- **CP Sell always searches when an item goes in.** Posting needs a
  check, and the 1.1 rule stays.

## CP Sell post sizes (stack size x auctions)

- The two boxes stay where they are: items per auction and number of
  auctions.
- **Per item:** clicking Post saves that item's stack size and number of
  auctions in `db.sell.sizes[id] = { stack, stacks }`. The next time the
  item goes in the slot, CP Sell starts from those numbers.
- **Default:** for an item not posted before, CP Sell starts from the
  default. It is 2 items x 1 auction until the player changes it.
  - A **Set as default** button next to the boxes saves the numbers in the
    boxes as the default (`db.sell.defaultStack`, `db.sell.defaultStacks`).
    The status line says "Default post: 2 x 1".
  - `/cp post <items> <auctions>` sets the default from chat; `/cp post`
    alone prints it. Both numbers are whole, at least 1; items at most
    1000 and auctions at most 100.
- **The start numbers fit what the player has.**
  - Stack = min(saved stack, the item's max stack, owned).
  - Auctions = min(saved auctions, floor(owned / stack)), at least 1.
  - A bag (max stack 1) with a default of 2 x 1 starts at 1 x 1.
  - 60 cloth saved at 20 x 5 starts at 20 x 3.
- Typing in the boxes changes only this post until Post is clicked. The
  1.1 checks ("too-big", "too-many") stay.

## Testing

- `Scanner.Search` collects every item's rows across pages, groups them
  by id, stops at the cap, and stores the prices.
- An exact cached name goes straight to the item view (category search,
  one query).
- `Listings.Group`:
  - groups identical rows and counts them;
  - keeps mine separate from others;
  - "Buy one" picks an unbought, non-mine row of the group;
  - the group shrinks after a buy.
- Lists:
  - automatic lists follow tracked recipes, with need = materials ×
    crafts;
  - the player's lists support add, remove, new and delete, and persist
    in db;
  - "Search all" skips fresh items.
- Tooltip lines:
  - the price and age;
  - "not seen yet";
  - the craft cost for a recipe;
  - the stack total;
  - no duplicate lines on a double SetItem.
- Fresh window:
  - Scan tracked skips items younger than 180 s;
  - `/cp fresh 5` gives 300;
  - `/cp fresh 0` gives always.
- Post sizes:
  - an item posted at 20 x 5 starts at 20 x 5 next time;
  - an item not posted before starts at the default;
  - Set as default and `/cp post 5 3` change the default and persist in db;
  - start numbers are cut to the max stack and to what the player owns;
  - typing in the boxes without posting saves nothing.
- Guards:
  - one PlaceAuctionBid site;
  - `Buyer.Buy` called only from Flip.Buy and Buy;
  - Buy's buy functions called only from BuyUI OnClick handlers.
- Layout: the full-width rows and bars fit 802 × 335 with no overlaps.

## Out of scope

- A confirm popup on purchases (the player buys with one click).
- Price history graphs.
- A separate price window.
- Cross-realm prices.
- Bidding.
