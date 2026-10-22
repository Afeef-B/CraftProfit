# CraftProfit

A World of Warcraft **3.3.5a** (Warmane) addon that tells you whether your
crafts make money. It reads your recipes from the profession window, scans
the Auction House for the materials and the finished item, and shows the
profit for each craft you track in a panel beside the Auction House.

Since version 1.1 it also helps you **sell**, and since 1.2 **buy**: three
extra Auction House tabs, **CP Sell** (post an item at the right price),
**CP Auctions** (see which of your auctions got undercut, and cancel them)
and **CP Buy** (search the Auction House like Auctionator, with shopping
lists; the cheapest listings first, bought one click at a time). Since 1.3
the prices it has seen also show on **item tooltips**, outside the Auction
House too. Everything that spends or posts something happens only when you
click a button. CraftProfit never posts, cancels or buys by itself.

Every CP page fits inside the Auction House window, with a status line along
the bottom. CP Sell and CP Auctions have boxed sections on the left and the
item's listings on the right; CP Buy uses the whole width for its list.

## Install

1. Download `CraftProfit.zip`.
2. Unzip it into `World of Warcraft\Interface\AddOns\`, so that this file
   exists: `World of Warcraft\Interface\AddOns\CraftProfit\CraftProfit.toc`.
   The folder must be called exactly `CraftProfit`.
3. Restart the game (or log out to the character screen), click **AddOns**
   and make sure **CraftProfit** is ticked.

## Use

1. **Pick what to track.** Open Tailoring, click a recipe, and tick
   **Track** at the top right of the recipe details. The checkbox appears
   about 1.5 seconds after the window opens: CraftProfit waits until
   Tailoring has finished loading before touching it. The recipe you click
   is learned right away. The rest of your recipes are learned quietly in
   the background over the next 10–20 seconds, one per frame, which is how
   the addon knows you can weave your own bolts. This happens once per
   session, and again only after you learn a new recipe.
2. **Open the Auction House.** The CraftProfit panel appears on the right.
3. Press **Scan tracked**. The addon searches the AH for every tracked
   item and its materials, one search at a time (about 10–30 s). Recipes
   set to **From scratch** (see below) also search the materials of their
   materials. Press **Stop** to cancel.
4. Read the table:

   | Column | Meaning |
   |---|---|
   | Item | The craft (`x2` if one craft makes two) |
   | Cost | What the materials cost for one craft |
   | Sell | Lowest buyout of the finished item on the AH |
   | Profit | Sell × number made − 5% AH cut − Cost. Green = profit, red = loss |
   | % | Profit as a percentage of the material cost |

   Grey `?` means a price is missing. Grey numbers are prices older than 24 hours.
5. **Hover a row** to see each material with its quantity, unit price and
   where the price came from. **Right-click a row** for the menu: choose how
   the craft is costed (next section) or **Stop tracking**.

### Scan All

**Scan All** downloads the entire Auction House in one go and saves the
lowest price of every item. Then a recipe you start tracking later already
has prices. The server allows it once every 15 minutes, and the button
shows the countdown. On busy realms it can freeze the game for a while or
disconnect you, so the first time you press it you'll be asked to confirm.

## Ready-made or from scratch

Each tracked craft is costed one of two ways. Right-click its row in the
panel and pick:

- **Ready-made materials** (the default). The materials are bought as they
  are. A Frostweave Bag costs its Bolts of Frostweave at the Bolt price. The
  scan only searches the bag and its direct materials, so it stays short.
- **From scratch.** Each material that you can craft yourself is priced at the
  cheaper of buying it or crafting it, all the way down, so the Bolts are
  priced at the cheaper of buying bolts or buying cloth and weaving them.
  The scan searches that whole tree.
- **Stop tracking** removes the row.

A row costed from scratch starts with a light blue `[S]` in the panel, so
you can tell at a glance. Ready-made rows have no marker. The tooltip also
says "Materials: ready-made" or "Materials: from scratch".

## CP Sell

Open the Auction House and click the **CP Sell** tab. It is the first of
three new tabs (CP Sell, CP Auctions, CP Buy); they come after the tabs
already there, so with Auctionator installed they sit to the right of
Auctionator's.

1. **Put an item in.** Drag it from your bags onto the slot, or hold **Alt**
   and click it in your bags. If it can't be auctioned (a soulbound item, a
   quest item) the page says "This item can't be auctioned."
2. **Wait a moment.** The page searches the Auction House for that item
   ("Searching...") and lists every auction for it on the right: quantity,
   price each and seller. Auctions of yours and of your alts show **YOU**
   or **YOU (Name)**.
3. **Price each fills itself in.** It is just under the cheapest other
   seller, rounded down to a whole silver: if the cheapest is 420g it
   suggests 419g 99s, and if the cheapest is 419g 99s 57c it suggests
   419g 99s. For cheap items (1 silver or less) it is 1 copper under. It
   never undercuts you: if an auction of yours or your alts' is already the
   cheapest, it uses the same price as that one. If nobody else sells the
   item it matches the cheapest listing of your own, if you have one;
   otherwise it uses your own price (`/cp price`), then Auctionator's, and
   otherwise the box stays empty until you type one. A price you type is
   never overwritten by the search. Items with a random enchant ("of the
   Monkey", "of the Bear") share one item id but not a price, so the box
   stays empty and the page says "Random-enchant item - type a price." You
   can type one, or click a row of the list.
4. **Mistake listings are not the market.** A listing under 50% of the next
   one (for example 50g next to 420g) is almost always a mistake by the
   seller. It is ignored when working out your price, marked **flip** in the
   list, and a red notice appears under the money lines:
   "Possible mistake: Bob sells 1 at 50g (next 420g). Flip profit ~349g",
   with a **Buy it (50g)** button. The amount in brackets is what the whole
   stack costs, which is what a click spends: for 20 at 5g each the button
   says "Buy it (100g)". The notice assumes you resell at the next price
   after the AH cut. Clicking **Buy it** buys exactly that listing. If the
   game is already showing it, the bid is placed at once ("Bid placed for
   50g"). Otherwise the button says "Finding it...", then "Buy now (50g)":
   click once more to buy. If someone beat you to it, it says "Gone - try
   again (50g)". Once bought the button reads "Bought" and stays off, also
   after you close the Auction House and open it again, until the next price
   check replaces the list. It only ever buys when you click, and only the
   listing shown. Be quick: other players see the mistake too, and the chance
   goes. Clicking the flip row in the list does not use it for your price:
   it says "That's a mistake listing - use Buy it to flip it." Listings of
   random-enchant items are never marked or offered as a flip.
   Change the 50% with `/cp outlier`.
5. **Amount (stack x auctions).** Out of the box it posts **one auction of
   2** (one of 1 for things that don't stack, like bags), so the rest stays in
   your bags and you can undercut back when someone undercuts you. Change
   either box to post more. **Each item remembers** what you last posted it
   with: post cloth as 20 x 5 once, and the next time you put cloth in it
   starts at 20 x 5. For items you haven't posted yet, set your own start
   numbers: type them in the boxes and click **Set as default** (or type
   `/cp post 5 3` in chat). The numbers are always cut to what you have: with
   20 x 5 saved and 60 cloth in your bags it starts at 20 x 3. If you
   ask for more than you have, Post is off and the page says "You only have N."
   A stack size above the item's maximum stack says "Stack size is more than
   N."
6. **Duration**: 12h, 24h or 48h. The default is 24h, and it remembers your
   last choice.
7. **Money lines.**
   - **Deposit** for the auctions you are about to post.
   - **You get each**: the price minus the AH cut.
   - For something you can craft: **Cost each** (what one costs to craft,
     using the prices CraftProfit has stored and the craft setting above) and
     **Profit each** in green, or in red as "loses 12g vs crafting cost". You
     can still post below cost. If material prices are missing it says "cost
     unknown - scan it in Craft Profit".
8. **Click a row in the listings** to use it for your price: one step under
   that seller's price, or exactly the same price when the row is yours. (A
   mistake listing is for **Buy it**, see 4.)
9. **Post.** The button says "Post 2 auctions" (or "Post 1 auction"). When it
   is off, the page says why next to it ("Type a price.", "Checking
   prices...", "Not enough gold for the deposit."). While posting you see
   "Posting 2/3", then "Posted 3 auctions", and the item is searched again so
   the list shows your new auctions. When the last one is up the sell slot is
   empty, and the list stays on that item, with your new auctions as **YOU**,
   until you put another item in. You can't put another item in while the
   post is going ("Wait until the post finishes."). If the server refuses the
   post, the page shows the game's message and Post comes back. If
   "Posting..." ever stays on for good, close the Auction House and open it
   again: that resets CP Sell.

## CP Auctions

The second new tab shows your own auctions. Click it and wait a moment for
the list.

- **Your auctions** (left): one line per item, with how many you have up
  (and "(+1 sold)" for sold ones) and a status:
  - **cheapest**: nobody else is lower.
  - **tied**: someone else has the same price.
  - **undercut 10g (Bob)**: Bob is 10g cheaper than your cheapest.
  - **sold**: all of that item's auctions are sold; collect the gold by mail.
  - **-**: not checked yet.
  A gold coin and "flip" at the right end means a mistake listing of that
  item is on sale, so you could buy it. Random-enchant items ("of the
  Monkey") never get one, and their listings count as competition like any
  other.
- **Check undercuts** searches every item you have up and fills in the
  statuses (a few seconds per item). Statuses are only as fresh as the last
  check.
- **Click an item** to see all its listings on the right, titled "<item>: all
  listings (checked 5m ago)". Yours are **YOU** or **YOU (Name)** for an alt.
  Cheaper ones are marked "under you", mistake listings "flip".
- **Cancel undercut (N)** (right) cancels one undercut auction of the picked
  item per click; N is how many are undercut. **Cancel next undercut (N)**
  (left) does the same for the next undercut auction across all items. It
  says (0) and stays off until you have pressed **Check undercuts**.
  Each click cancels only one auction, so you can stop whenever you want.
  It never cancels an auction that is still the cheapest or tied, a sold
  one, one that has a bid on it, or an item with a random suffix ("of the
  Eagle" and the like). The first time, a window warns you: cancelled items come back by
  mail and **the deposit is lost**. Think twice before cancelling for a tiny
  undercut.
- **"checked 5m ago" and "Oldest check: 5m ago"** tell you how old the
  prices behind the buttons are. The line next to **Cancel next undercut**
  shows the oldest check among the items it would cancel. If it is old, press
  **Check undercuts** again first: the other seller may have cancelled or
  raised the price already.
- **Undercut** (right) puts the item in CP Sell, ready to relist under the
  others. If you don't have any in your bags (a cancelled auction comes by
  mail) it says "Collect it from your mailbox first."

## CP Buy

CP Buy works like Auctionator's Buy tab, across the whole Auction House
window: search first, see every matching item, then click one to see its
listings, cheapest per item first.

1. **Search.** Type a name in the search box and press Enter (or Search).
   - **An exact item name opens that item at once**, for example "King's
     Amber" or "Frostweave Cloth". It searches only the item's own category
     (Gem > Simple for an uncut King's Amber), so it reads one or two pages,
     not every cut King's Amber. This works for any item the game already
     knows, and for your tracked recipes and their materials.
   - **Any other text lists every item it finds**: "frost" shows Frostweave
     Cloth, Bolt of Frostweave, Frostweave Bag and so on, one line each with
     the cheapest price each, how many auctions, how many items in total and
     how long ago it was seen. Click a line to open that item. A search reads
     at most 20 pages (1000 listings); past that it says "Showing the first
     1000 listings - type more of the name."
   - Or keep your Tailoring window open next to the Auction House and
     **shift-click** a reagent in it (or any item in your bags or a chat link)
     while CP Buy is open: it opens that item.
2. **The item's listings** are grouped: identical stacks are one line, like
   "20 | 3 auctions | 9s each | 1g 80s per stack | Bob +2". A mistake listing
   shows a green **deal**: on this page it is simply the best buy. Your own
   and your alts' listings show **YOU** and can't be bought. An item checked
   in the last 3 minutes is shown as it was, without searching again.
3. **Buy one** buys one stack of the line you clicked, per click; the line's
   auction count goes down. The button shows what it will spend ("Buy one
   (1g 80s)").
4. **Buy cheapest** buys the cheapest listing, one per click ("Buy cheapest:
   5 for 1g 20s"). With a **Need** set it skips stacks bigger than what you
   still need when a smaller one is there, and counts down: "Bought 20 of 40
   (spent ...)", then "Done (bought 40)". A bought listing is never bought
   twice.
5. **< Back** returns to the results or the shopping list you came from.

**Shopping lists.** Click **Lists v**:

- Every tracked recipe has its own list, "Glacial Bag materials". Type how
  many **Crafts** you want; each material shows "have / need" (green when you
  have enough). It follows the recipe's ready-made / from-scratch choice.
  Click a material to open it with **Need** already filled in (what you still
  lack); if you already have enough it says "You have enough."
- **New list...** makes your own list. In an item, **+ To list** puts it on
  one of your lists (or on a new one). Right-click an item in your own list
  to take it off. **Delete <list>** removes a list.
- Every list shows the cheapest price each and how long ago it was seen.
  **Search all** checks the prices of everything on the list, except items
  checked in the last 3 minutes.

Items you buy arrive by **mail**, so "have" only goes up once you collect
them. If the listing isn't on the Auction House page that's loaded, the first
click says "Finding it..." and loads it; click again to buy. If a listing has
already been bought by someone else, the page says "That listing is gone."
and searches the item again by itself, so the next click buys the next
cheapest. Shift-clicking a stackable item in your bags also opens the game's
"split stack" box; just close it (or shift-click the reagent in your
Tailoring window instead).

## Prices on tooltips

Every price CraftProfit sees (Scan tracked, Scan All, CP Buy searches, price
checks) is saved per realm and faction. Hover over any item, in your bags, a
chat link or a vendor, and the tooltip shows:

- `CraftProfit AH: 12g 50s (2h ago)`: the cheapest buyout each when it was
  last seen, or "not seen yet", or "none listed" when the last check found
  none. A price check or a CP Buy search leaves mistake listings out; Scan
  tracked and Scan All take the cheapest listing there was, mistake or not.
- `Craft cost: 8g (ready-made)` or `(from scratch)` for your own recipes.
- `x20: 250g` for a stack in your bags: what the whole stack is worth.

## No needless rescans

An item checked in the last **3 minutes** is not searched again: **Scan
tracked** skips it ("Scan done: 5 items (3 still fresh, skipped)"), and CP
Buy and CP Auctions show what they found a moment ago. Change the time with
`/cp fresh <minutes>` (0-60); `/cp fresh 0` always searches again. CP Sell
always checks when you put an item in, because the price you post must be
current.

### Alts

Auctions of your other characters on the same realm and faction count as
yours: CraftProfit never undercuts them, and shows them as **YOU (Name)**.
For that, **log in each alt once with CraftProfit switched on**. It remembers
the name.

## How prices are chosen

For each **material**, the addon uses:

1. Your own price, if you set one with `/cp price`.
2. Otherwise, the cheapest of:
   - the **AH** (lowest buyout per unit)
   - the **vendor** price (remembered automatically whenever you open a
     vendor that sells it, e.g. Eternium Thread)
   - **crafting it yourself**, if it's one of your own recipes and the
     craft is set to **From scratch**. For example, Bolts of Frostweave are
     priced at the cheaper of buying bolts or buying cloth and weaving them.
     The tooltip tells you how much crafting saves. (Ready-made crafts don't
     do this: they buy the bolts as they are.)
3. Otherwise **Auctionator**'s last-seen price, labelled "Atr".

For the **finished item** it uses your own price, then the AH, then
Auctionator.

Deposits are ignored because you get them back when the item sells. The AH
cut is 5%. At the neutral auction houses (Booty Bay, Gadgetzan, Everlook)
it is 15%, so use `/cp cut 15` there.

## Slash commands

| Command | What it does |
|---|---|
| `/cp` | Show or hide the panel (with the AH closed it prints the list) |
| `/cp scan` | Scan prices for your tracked crafts |
| `/cp track` | Track or untrack the recipe selected in the profession window |
| `/cp price <item> <price>` | Set your own price: `/cp price Eternium Thread 1.5` or shift-click the item: `/cp price [Bolt of Frostweave] 1g50s`. Use `clear` to remove it |
| `/cp cut <percent>` | AH cut, default 5 |
| `/cp fresh <minutes>` | Don't search again for items checked this recently: 0-60, default 3. 0 always searches |
| `/cp post <items> <auctions>` | The stack size x auctions CP Sell starts items at that you haven't posted before: default 2 x 1. `/cp post` alone shows it |
| `/cp outlier <percent>` | How low a listing must be, compared with the next one, to count as a mistake (a flip): 1-99, default 50. Applies from the next price check |
| `/cp list` | Print the profit of every tracked craft to chat |
| `/cp reset prices` | Forget scanned AH prices for this realm and faction |
| `/cp diag` | Diagnostic mode for the profession window: opening it runs none of CraftProfit's setup; each `/cp step` then runs one step, so a freeze points at the step you just ran |
| `/cp step` | Run the next diagnostic step |
| `/cp status` | Show the profession window state, the Track checkbox state and the selected recipe |

## In-game checklist (first run)

I couldn't run the 3.3.5 client while building this, so please check these
once:

- [ ] At login there are no Lua errors, and the addon list shows CraftProfit.
- [ ] In Tailoring, the **Track** checkbox appears at the top right of the
      recipe details. It turns on and off, and follows the recipe you select.
- [ ] At the Auction House, the panel sits on the right of the AH window
      without covering it.
- [ ] **Scan tracked** shows "Scanning 1/N …", then "Scan done", and rows fill in.
- [ ] Pick one row and check it by hand: search the AH yourself for one
      material and compare its lowest price per item with the tooltip.
- [ ] Hover shows the breakdown, and right-click opens the menu (Ready-made
      materials, From scratch, Stop tracking). Pick From scratch on a row: a
      light blue `[S]` appears in front of its name.
- [ ] Visit a thread vendor, then check the thread's source in the tooltip
      says "vendor".
- [ ] `/cp price [some item] 1` changes that row. `/cp price [some item] clear` undoes it.
- [ ] Optional: press **Scan All** once on a quiet moment and confirm it
      finishes ("Scan All done: … items").
- [ ] If a material has no AH listings but Auctionator knows a price, the
      tooltip says "Atr". If it says "no price" instead, Auctionator's
      interface wasn't found, which is harmless.

### Selling (version 1.1)

Same warning: this was built without the 3.3.5 client, so please check these
once. Use something cheap you don't mind posting, such as a Glacial Bag.

- [ ] The **CP Sell** and **CP Auctions** tabs appear to the right of
      Auctionator's tabs and don't overlap them.
- [ ] Open CP Sell and **Alt+click** an item in your bags: it lands in the
      slot. If Alt+click does nothing (some bag addons replace the bag
      buttons), drag the item onto the slot instead.
- [ ] After the first price check, put a **different** item in. The price
      fills itself in again. (If it stops filling itself in, please report it.)
- [ ] In the **Stacks** box, clear it and type a number. It stays as typed
      after a price check, and when you click somewhere else the box shows the
      real number.
- [ ] Post **1 Glacial Bag**: "Posting..." then "Posted 1 auction". It must
      not stay on "Posting...".
- [ ] After posting, the sell slot is empty and CP Sell still lists that
      item, now with your new auction as YOU.
- [ ] Post **2 stacks** of Bolts of Frostweave (or Bolts of Imbued Frostweave): "Posting
      1/2", "Posting 2/2", "Posted 2 auctions". While it runs, dropping
      another item on the slot is refused ("Wait until the post finishes.").
- [ ] Type a stack size above the item's maximum (for example 21 of a
      20-stack): Post is off and the page says "Stack size is more than 20."
- [ ] A random-enchant item ("of the Monkey") leaves the price empty and the
      page says "Random-enchant item - type a price."
- [ ] A post the server refuses shows the game's message and doesn't leave
      "Posting..." stuck. Hard to provoke (Post is off when you can't pay the
      deposit), so skip it if you can't.
- [ ] On CP Auctions press **Check undercuts**: every item gets a status.
- [ ] Click an item: its listings show, with your auctions as **YOU**.
- [ ] **Cancel** one undercut auction (the deposit warning appears the first
      time only) and check it arrives in your mailbox.
- [ ] **Undercut**: the item goes into CP Sell. With none in your bags it
      says "Collect it from your mailbox first."
- [ ] Log in an alt, post something, then back on your main check that the
      alt's auction shows as **YOU (altname)** and isn't undercut.
- [ ] A **flip** notice appears on a mistake listing, with a Buy it button
      that names the price of the whole stack. Only press it if you really
      want that item.
- [ ] After buying a flip, the list refreshes, and a scan that was running
      (for example Check undercuts on CP Auctions) carries on to the end.
- [ ] Close the Auction House while on CP Sell and open it again: no Lua
      errors, it opens on the Browse tab, and nothing is searched until you
      ask.

### Buying and the new look (version 1.2)

- [ ] The tabs read CP Sell, CP Auctions, CP Buy, after Auctionator's tabs.
- [ ] Every CP page fits the Auction House window: no overlapping boxes, no
      text running out of its box, and the text is easy to read.
- [ ] CP Sell with 40 bolts fills in **1 auction of 2**; a bag fills in 1 of 1.
- [ ] With CP Buy open, shift-click a reagent in your Tailoring window: it
      searches that item. With the chat box open, the link goes to chat.
- [ ] Search "Frostweave Cloth": only cloth is listed, cheapest per item first.
- [ ] Set Need 40 and press **Buy cheapest** until it says "Done (bought 40)".

### CP Buy like Auctionator, tooltips and post sizes (version 1.3)

- [ ] CP Buy fills the Auction House window: search bar at the top, the list,
      the buttons, the status line, nothing overlapping.
- [ ] Search "King's Amber": it opens the uncut King's Amber after one or two
      pages, and none of the cut ones are listed.
- [ ] Search "frost": one line per item; click one, then **< Back**.
- [ ] In an item, click a line and **Buy one**: one stack is bought and the
      line's auction count goes down.
- [ ] **Lists v** shows "<recipe> materials" for a tracked recipe; Crafts 3
      triples the need. Make a **New list...**, add an item with **+ To list**,
      right-click it off again.
- [ ] **Scan tracked** twice in a row: the second time it says the items are
      still fresh and skips them.
- [ ] Hover over cloth in your bags away from the Auction House: the tooltip
      shows the CraftProfit AH price and its age, and "x20: ..." on a stack.
      A recipe of yours also shows "Craft cost".
- [ ] Post cloth as 20 x 5, then put cloth in again: it starts at 20 x 5.
      **Set as default** with 5 x 3, then put in an item you never posted: it
      starts at 5 x 3.

## Development

Tests run outside the game with Lua 5.1 and a mock of the WoW API:

```sh
lua5.1 tests/run.lua           # unit tests
lua5.1 tests/check_globals.lua # typo/leaked-global check
tools/package.sh               # builds dist/CraftProfit.zip
```

Design notes: `docs/superpowers/specs/2026-10-15-craftprofit-design.md`.
