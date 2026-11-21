#!/usr/bin/env python3
"""Build (and optionally send) purchasing-power App Store price schedules with the asc CLI.

For every territory it takes the price level from ppp.py and picks the nearest
App Store price point (preferring .x9 / 9 endings). Territories without PPP
data stay on automatic pricing, equalized from the US price; `keepFree`
territories get the free price point. It prices either the app itself or
tiers of in-app purchases (every product in a tier shares one US price).

The app itself (no `tiers`):
  1. Backs up the current schedule to <out-dir>/current_prices.json.
  2. Downloads each territory's price points through `asc pricing price-points`.
  3. Writes the request body to <out-dir>/schedule_body.json and prints the plan.
  4. With --send, posts it via `asc api POST /v1/appPriceSchedules`. Prices take
     effect immediately and replace the whole schedule.

In-app purchases (`tiers`, or --products):
  1. Lists the territories and their currencies.
  2. Downloads every territory's price points for the first product, 8000 a
     page through `asc api` (price points are the same grid for every product;
     their IDs only name the product, so they're retargeted for the others).
  3. Writes each product's price point IDs to <out-dir>/prices-<product>.txt
     and prints the plan.
  4. With --send, replaces each product's schedule through
     `asc iap pricing schedules create`. Prices take effect immediately.

To check an in-app purchase's schedule, read its manual prices with their
price points through `asc api GET /v1/inAppPurchasePriceSchedules/<iap
id>/manualPrices --query include=inAppPurchasePricePoint`: `asc iap pricing
schedules manual-prices --resolved` looks prices up by price point code alone
and shows another territory's price.

Settings come from the game's pricing.json (the PRICING environment variable,
or --settings): `appStore` (`app`, `price` or `tiers`, `keepFree`) and
`purchasingPower`. Every flag overrides its setting.

Usage (a game runs it through its own two-line shim):
  python3 Tools/Pricing/appstore.py            # the plan, from pricing.json
  python3 Tools/Pricing/appstore.py --send     # replace the schedules
  python3 Tools/Pricing/appstore.py --app <id> --price 2.99 --add-vat --keep-free CHN
"""

import argparse
import json
import os
import subprocess
import sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ppp import EXCLUDED, FX_API, WB_API, fetch_json, income_ratios, price_level_ratios  # noqa: E402
import lib  # noqa: E402

BASE_TERRITORY = "USA"
# The largest page the API serves for price points.
PAGE_SIZE = 8000

# ISO codes missing from the World Bank country list, or spelled differently by Apple.
EXTRA_ISO3 = {"TW": "TWN", "XK": "XKS"}


def asc_json(*args):
    result = subprocess.run(["asc", *args, "--output", "json"], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"asc {' '.join(args)} failed: {result.stderr.strip() or result.stdout.strip()}")
    return json.loads(result.stdout)


def app_price_points(app, territory):
    data = asc_json("pricing", "price-points", "--app", app, "--territory", territory, "--paginate")["data"]
    return [(float(p["attributes"]["customerPrice"]), p["id"]) for p in data]


def iap_price_points(iap):
    """Every territory's price points for a product, as {territory: [(price, id)]}."""
    data = asc_json("api", "GET", f"/v2/inAppPurchases/{iap}/pricePoints", "--paginate",
                    "--query", f"limit={PAGE_SIZE}", "--query", "fields[inAppPurchasePricePoints]=customerPrice")["data"]
    points = defaultdict(list)
    for p in data:
        points[lib.decode_point(p["id"])["t"]].append((float(p["attributes"]["customerPrice"]), p["id"]))
    return points


def levels(ppp):
    countries = fetch_json(f"{WB_API}/country?format=json&per_page=1000")[1]
    iso2_by_iso3 = {c["id"]: c["iso2Code"] for c in countries}
    iso2_by_iso3.update({iso3: iso2 for iso2, iso3 in EXTRA_ISO3.items()})
    ratios = price_level_ratios()
    incomes = income_ratios() if ppp["incomeWeight"] > 0 else {}
    rates = fetch_json(FX_API)["rates"]
    return iso2_by_iso3, ratios, incomes, rates


def ppp_ratio(iso2, currency, ratios, incomes, rates, ppp):
    """The fraction of the US price a territory pays, VAT included when asked; None for automatic pricing."""
    if iso2 not in ratios or iso2 in EXCLUDED or currency not in rates:
        return None
    ratio = lib.target_ratio(iso2, ratios, incomes, ppp)
    if ppp["addVat"]:
        ratio *= 1 + lib.vat(iso2, ppp)
    return ratio


def price_app(app, price, ppp, keep_free, out_dir, send):
    print("Fetching current prices, PPP data and exchange rates…", file=sys.stderr)
    current = asc_json("pricing", "schedule", "manual-prices", "--schedule", app, "--paginate", "--resolved")
    with open(os.path.join(out_dir, "current_prices.json"), "w") as f:
        json.dump(current, f, indent=1)
    current = {p["territory"]: p for p in current["prices"]}
    iso2_by_iso3, ratios, incomes, rates = levels(ppp)

    print(f"Downloading price points for {len(current)} territories…", file=sys.stderr)
    with ThreadPoolExecutor(8) as pool:
        points = dict(zip(current, pool.map(lambda t: app_price_points(app, t), current)))

    plan, old, automatic = [], {}, []
    for territory, cur in sorted(current.items()):
        currency = cur["currency"]
        old[territory] = cur["customerPrice"]
        if territory in keep_free:
            plan.append((territory, currency, next(p for p in points[territory] if p[0] == 0)))
            continue
        if territory == BASE_TERRITORY:
            ratio = 1.0
        else:
            ratio = ppp_ratio(iso2_by_iso3.get(territory), currency, ratios, incomes, rates, ppp)
            if ratio is None:
                automatic.append(territory)
                continue
        target = price * ratio * rates[currency]
        plan.append((territory, currency, lib.nearest_point(points[territory], target, currency)))

    body_path = os.path.join(out_dir, "schedule_body.json")
    with open(body_path, "w") as f:
        json.dump(lib.schedule_body(app, BASE_TERRITORY, [point[1] for *_, point in plan]), f)

    for line in lib.plan_lines(plan):
        print(line)
    changed = sum(float(old[t]) != p for t, _, (p, _) in plan)
    print(f"\n{len(plan)} manual prices ({changed} changed), automatic: {', '.join(automatic) or 'none'}", file=sys.stderr)
    print(f"Wrote {body_path}", file=sys.stderr)

    if send:
        subprocess.run(["asc", "api", "POST", "/v1/appPriceSchedules", "--confirm", "--body-file", body_path],
                       check=True, stdout=subprocess.DEVNULL)
        print("Sent new price schedule.", file=sys.stderr)
    else:
        print(f"Send with: asc api POST /v1/appPriceSchedules --confirm --body-file {body_path}", file=sys.stderr)


def price_iaps(app, tiers, ppp, keep_free, out_dir, send):
    products = [p for tier in tiers for p in tier["products"]]
    print("Fetching products, territories, PPP data and exchange rates…", file=sys.stderr)
    iaps = {i["attributes"]["productId"]: i["id"] for i in asc_json("iap", "list", "--app", app, "--paginate")["data"]}
    missing = [p for p in products if p not in iaps]
    if missing:
        raise SystemExit(f"Unknown products: {', '.join(missing)}")
    currencies = {t["id"]: t["attributes"]["currency"] for t in asc_json("pricing", "territories", "list", "--paginate")["data"]}
    iso2_by_iso3, ratios, incomes, rates = levels(ppp)

    print(f"Downloading price points for {len(currencies)} territories…", file=sys.stderr)
    points = iap_price_points(iaps[products[0]])

    for tier in tiers:
        price = tier["price"]
        if len(tiers) > 1:
            print(f"\n{price:g} USD: {', '.join(tier['products'])}")
        plan, automatic = [], []
        for territory, currency in sorted(currencies.items()):
            if territory in keep_free:
                plan.append((territory, currency, next(p for p in points[territory] if p[0] == 0)))
                continue
            if territory == BASE_TERRITORY:
                plan.append((territory, currency, next(p for p in points[territory] if round(p[0], 2) == round(price, 2))))
                continue
            ratio = ppp_ratio(iso2_by_iso3.get(territory), currency, ratios, incomes, rates, ppp)
            if ratio is None:
                automatic.append(territory)
                continue
            target = price * ratio * rates[currency]
            plan.append((territory, currency, lib.nearest_point(points[territory], target, currency)))

        for line in lib.plan_lines(plan):
            print(line)
        print(f"\n{len(plan)} manual prices, automatic: {', '.join(automatic) or 'none'}", file=sys.stderr)

        for product in tier["products"]:
            iap = iaps[product]
            prices = ",".join(lib.retarget(point_id, iap) for *_, (_, point_id) in plan)
            with open(os.path.join(out_dir, f"prices-{product}.txt"), "w") as f:
                f.write(prices)
            if send:
                asc_json("iap", "pricing", "schedules", "create", "--iap-id", iap,
                         "--base-territory", BASE_TERRITORY, "--prices", prices)
                print(f"Sent {product}.", file=sys.stderr)
    if not send:
        print(f"Wrote price lists to {out_dir}; send with --send.", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--settings", default=os.environ.get("PRICING"), help="the game's pricing.json")
    parser.add_argument("--app", help="App Store Connect app ID")
    parser.add_argument("--price", type=float, help="US price in USD, e.g. 2.99")
    parser.add_argument("--products", help="comma-separated product IDs sharing --price (else the app itself)")
    parser.add_argument("--strength", type=float, help="how strongly to apply PPP (default 1)")
    parser.add_argument("--income-weight", type=float, help="blend in relative income per head, 0-1 (default 0)")
    parser.add_argument("--min-ratio", type=float, help="lowest fraction of the US price (default 0.25)")
    parser.add_argument("--max-ratio", type=float, help="highest fraction of the US price")
    parser.add_argument("--add-vat", action=argparse.BooleanOptionalAction, default=None,
                        help="add local VAT/GST on top of the PPP price")
    parser.add_argument("--keep-free", help="comma-separated alpha-3 territories to keep free, e.g. CHN")
    parser.add_argument("--out-dir", default=".", help="where to write the backup, request body or price lists (default: .)")
    parser.add_argument("--send", action="store_true", help="replace the schedules in App Store Connect")
    args = parser.parse_args()

    settings = lib.load_settings(args.settings)
    store = settings.get("appStore") or {}
    ppp = lib.purchasing_power(settings, {"strength": args.strength, "incomeWeight": args.income_weight,
                                          "minRatio": args.min_ratio, "maxRatio": args.max_ratio, "addVat": args.add_vat})
    app = args.app or store.get("app")
    if args.keep_free is not None:
        keep_free = {t.strip().upper() for t in args.keep_free.split(",") if t.strip()}
    else:
        keep_free = {t.upper() for t in store.get("keepFree", [])}
    if args.products:
        if args.price is None:
            parser.error("--products needs --price")
        tiers = [{"price": args.price, "products": [p.strip() for p in args.products.split(",") if p.strip()]}]
    elif store.get("tiers"):
        if args.price is not None:
            # Never let a price meant for in-app purchases fall through to the app's own.
            parser.error("pricing.json prices in-app purchases by tier: pass --products with --price")
        tiers = store["tiers"]
    else:
        tiers = None
    price = args.price if args.price is not None else store.get("price")
    if not app:
        parser.error("no app: pass --app or set appStore.app in pricing.json")
    if tiers and any(t.get("price") is None or not t.get("products") for t in tiers):
        parser.error("every tier needs a price and products")
    if not tiers and price is None:
        parser.error("no price: pass --price or set appStore.price (the app) or appStore.tiers (in-app purchases)")

    os.makedirs(args.out_dir, exist_ok=True)
    if tiers:
        price_iaps(app, tiers, ppp, keep_free, args.out_dir, args.send)
    else:
        price_app(app, price, ppp, keep_free, args.out_dir, args.send)


if __name__ == "__main__":
    main()
