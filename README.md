# CraftProfit

A World of Warcraft **3.3.5a** (Warmane) addon that tells you whether your
crafts make money. It reads your recipes from the profession window, scans
the Auction House for the materials and the finished item, and shows the
profit for each craft you track in a panel beside the Auction House.

## Install

1. Download `CraftProfit.zip`.
2. Unzip it into `World of Warcraft\Interface\AddOns\`, so that this file
   exists: `World of Warcraft\Interface\AddOns\CraftProfit\CraftProfit.toc`.
   The folder must be called exactly `CraftProfit`.
3. Restart the game (or log out to the character screen), click **AddOns**
   and make sure **CraftProfit** is ticked.

## Use

1. **Pick what to track.** Open Tailoring, click a recipe, and tick
   **Track** at the top right of the recipe details. The recipe you click
   is learned right away. The rest of your recipes are learned quietly in
   the background over the next 10–20 seconds, one per frame, which is how
   the addon knows you can weave your own bolts. This happens once per
   session, and again only after you learn a new recipe.
2. **Open the Auction House.** The CraftProfit panel appears on the right.
3. Press **Scan tracked**. The addon searches the AH for every tracked
   item and all of its materials, one search at a time (about 10–30 s).
   Press **Stop** to cancel.
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
   where the price came from. **Right-click a row** to stop tracking it.

### Scan All

**Scan All** downloads the entire Auction House in one go and saves the
lowest price of every item. Then a recipe you start tracking later already
has prices. The server allows it once every 15 minutes, and the button
shows the countdown. On busy realms it can freeze the game for a while or
disconnect you, so the first time you press it you'll be asked to confirm.

## How prices are chosen

For each **material**, the addon uses:

1. Your own price, if you set one with `/cp price`.
2. Otherwise, the cheapest of:
   - the **AH** (lowest buyout per unit)
   - the **vendor** price (remembered automatically whenever you open a
     vendor that sells it, e.g. Eternium Thread)
   - **crafting it yourself**, if it's one of your own recipes. For
     example, Bolts of Frostweave are priced at the cheaper of buying bolts
     or buying cloth and weaving them. The tooltip tells you how much
     crafting saves.
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
| `/cp list` | Print the profit of every tracked craft to chat |
| `/cp reset prices` | Forget scanned AH prices for this realm and faction |
| `/cp diag` | Diagnostic mode for the profession window: runs each setup step one frame apart and prints a chat line before each, so a freeze leaves the culprit on screen |

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
- [ ] Hover shows the breakdown, and right-click removes the row.
- [ ] Visit a thread vendor, then check the thread's source in the tooltip
      says "vendor".
- [ ] `/cp price [some item] 1` changes that row. `/cp price [some item] clear` undoes it.
- [ ] Optional: press **Scan All** once on a quiet moment and confirm it
      finishes ("Scan All done: … items").
- [ ] If a material has no AH listings but Auctionator knows a price, the
      tooltip says "Atr". If it says "no price" instead, Auctionator's
      interface wasn't found, which is harmless.

## Development

Tests run outside the game with Lua 5.1 and a mock of the WoW API:

```sh
lua5.1 tests/run.lua           # unit tests
lua5.1 tests/check_globals.lua # typo/leaked-global check
tools/package.sh               # builds dist/CraftProfit.zip
```

Design notes: `docs/superpowers/specs/2026-10-15-craftprofit-design.md`.
