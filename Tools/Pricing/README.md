# Prices

Purchasing-power prices for every game on this runtime, on the App Store and
Google Play, from one copy of the tools. A game keeps its settings in a
`pricing.json` and runs each tool through a two-line shim at its own path.

| Tool | What it does |
|---|---|
| `ppp.py <price>` | Prints the purchasing-power price for every storefront: World Bank price levels (and, with `--income-weight`, incomes) and live exchange rates, rounded as prices. Takes only flags. |
| `appstore.py` | Plans the App Store price schedule from those levels, at each territory's nearest price point (.x9 / 9 endings first), for the app itself or for tiers of in-app purchases. `--send` replaces the schedules. |
| `play.py` | Prices every Google Play region as the App Store prices it (snapshots of both), and writes gplay's one-time product file or, for a paid app, the table Play Console takes by hand, with `prices.md` comparing the two stores. Talks to neither store, but `--refresh` re-reads an app's App Store prices first (read only). |
| `product.js` | Creates or updates the one-time product on Play from the product file, through the Publisher API (`gplay iap apply` can't create a first product). The plan reads Play only; `--send` writes. `--reward` does the same for a pre-registration reward. |

`--help` on each lists its flags. Every flag overrides its setting.

## A game's settings

`pricing.json`, usually in the game's Play directory:

```json
{
  "name": "Example",
  "appStore": {
    "app": "1234567890",
    "tiers": [{ "price": 4.99, "products": ["com.example.full"] }],
    "keepFree": ["CHN"]
  },
  "purchasingPower": { "strength": 0.65, "incomeWeight": 0.5, "minRatio": 0.25, "addVat": true },
  "play": { "dir": "Monetization", "product": true, "title": "Example's prices" }
}
```

| Key | What it says |
|---|---|
| `name` | The game, in a refreshed snapshot's `source`. |
| `appStore.app` | The App Store Connect app ID. |
| `appStore.price` | The app's own US price, for a paid app. |
| `appStore.tiers` | In-app purchases instead: each tier's US price and the products that share it. |
| `appStore.keepFree` | Alpha-3 territories kept at the free price point. |
| `purchasingPower` | `strength` (1 = full purchasing power, 0 = the US price everywhere; default 1), `incomeWeight` (0–1, default 0), `minRatio` (default 0.25) and `maxRatio` (default none) of the US price, and `addVat` (VAT/GST on top, default false). |
| `play.dir` | The directory holding the snapshots and outputs, relative to `pricing.json`. |
| `play.price` | The US price Play's purchasing-power prices start from (default: the App Store's). |
| `play.product` | `true`: write `iap/<productId>.json` for `listing.json`'s `product` (beside `pricing.json`). |
| `play.table` | Or a file name: write the region → price table for a paid app. |
| `play.consoleOnly` | Places Play Console prices though Play's table gives them no purchases, `{ "<region>": "<currency>" }`. |
| `play.newRegions` | `true`: the table also prices regions Play adds later (the product always does). |
| `play.charmUnderOne` | `false`: an amount under 1 keeps its converted value rather than ending in .x9 (default true). For prices already set that way. |
| `play.title` | The heading of `prices.md`. |

`play.dir` holds:

| File | What it holds |
|---|---|
| `apple-prices.json` | The App Store's customer price in every storefront (`territory`, `region`, `currency`, `price`), with a dated `source`. Free storefronts count as not sold. |
| `play-regions.json` | Play's supported locations: each region's currency and price range, with the version in `source`. |
| `console-prices.json` | Optional: what Play Console holds once it has charmed each price. `prices.md` then shows the Console's prices. |
| `iap/<productId>.json`, the table, `prices.md` | What `play.py` writes. |

## The shims

Each sets the settings and runs the tool, so callers keep their old command:

```python
#!/usr/bin/env python3
# Google Play prices for this game: the runtime's Tools/Pricing/play.py on this game's pricing.json.
import os, runpy; here = os.path.dirname(os.path.abspath(__file__)); os.environ["PRICING"] = os.path.join(here, "pricing.json")
runpy.run_path(os.path.join(here, "../../Android/spritekit-android/Tools/Pricing/play.py"), init_globals={"SHIM": __file__}, run_name="__main__")
```

`SHIM` lets the tool name the game's own command in what it writes.
`ppp.py` needs no settings, so its shim only runs it. `product.js` takes the
Play directory as `play.js` does:

```js
#!/usr/bin/env node
// The one-time product on Google Play: the runtime's Tools/Pricing/product.js on this directory.
process.env.PLAY_DIR = __dirname;
require('../../Android/spritekit-android/Tools/Pricing/product.js');
```

## Rules it keeps

- Nothing reaches a store without `--send`, and only `appstore.py` and
  `product.js` take it. Without it, `appstore.py` only reads App Store
  Connect and writes its plan to `--out-dir`.
- A price set in a store isn't redone by running `play.py` again: it reads
  today's exchange rates, so commit its output only when the store takes it.
- `appstore.py` refuses `--price` without `--products` when the settings
  price in-app purchases, so a tier's price never lands on the app's own.
- `product.js` reads gplay's service account (`GPLAY_SERVICE_ACCOUNT`, else
  the login keychain) into memory to sign one token, and never writes or
  prints it.

## Tests

```bash
python3 -m unittest discover -s Tools/Pricing
node --test Tools/Pricing/product.test.js
```

The tests run offline: fixtures, a stubbed network and a stubbed Play.
