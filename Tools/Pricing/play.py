#!/usr/bin/env python3
"""Writes a game's Google Play prices, as the App Store prices it, region by region.

Two sources, both snapshots kept in the game's pricing directory (`play.dir`):

  apple-prices.json   App Store Connect's customer price in every storefront
                      (`--refresh` rewrites it from asc, for an app's own price).
  play-regions.json   Google Play's supported locations: where users can buy,
                      the currency Play bills there and its price range.

Every Play region gets a fixed price; none is left to Play's automatic
conversion, so nothing drifts with exchange rates.

  1. Sold on both, in the same currency: the App Store's price exactly.
  2. Sold on both, but Play bills another currency, or can't take Apple's
     amount (outside the currency's range, or more decimals than it allows):
     the closest valid Play price, Apple's converted at today's rate and
     rounded as a price, within Play's range. Each is listed.
  3. Sold on Play only (or free on the App Store): a neighbour's App Store
     price where it shares the currency (Liechtenstein as Switzerland, Monaco
     as France…), else the purchasing-power price from the US price (ppp.py,
     with pricing.json's `purchasingPower`).

App Store storefronts with no Play purchases are listed at the end.

It writes one of:

  iap/<productId>.json  (`play.product`) gplay's declarative one-time product
                        for listing.json's `product`, keeping its copy; Play's
                        new regions take the US price in USD and EUR. The
                        runtime's Tools/Play/play.js `product` step (or
                        product.js, for a first product) sends it.
  <play.table>          a region → price table for a paid app, whose price
                        can't be set through the Play API: Play Console's
                        Monetize → App pricing takes it by hand. With
                        `play.consoleOnly`, places the Console lists without
                        purchases are priced too; with `play.newRegions`, the
                        price for regions Play adds later.

and prices.md, the country-by-country comparison. When console-prices.json
(what Play Console holds after it charms each price) is there, the comparison
shows the Console's prices. Nothing here talks to Play.

Usage (a game runs it through its own two-line shim):
  python3 Tools/Pricing/play.py             # from the snapshots
  python3 Tools/Pricing/play.py --refresh   # first re-read the app's App Store prices
"""

import argparse
import base64
import datetime
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ppp import FX_API, fetch_json, income_ratios, price_level_ratios  # noqa: E402
import lib  # noqa: E402


def asc(*args):
    run = subprocess.run(["asc", *args, "--output", "json"], capture_output=True, text=True, timeout=120)
    if run.returncode:
        raise RuntimeError(f"asc {' '.join(args)}: {run.stderr.strip()[:300]}")
    return json.loads(run.stdout)


def refresh(path, app, name, command):
    """Every storefront's customer price, from the app's price schedule: each
    price's ID names its territory and price point. Reads only."""
    # Apple's territories are alpha-3; the snapshot keeps each one's alpha-2.
    regions = {p["territory"]: p["region"] for p in json.load(open(path))["prices"]}
    points = []
    for kind in ("manual-prices", "automatic-prices"):
        for item in asc("pricing", "schedule", kind, "--schedule", app, "--paginate")["data"]:
            key = lib.decode_point(item["id"])
            if key.get("sd") or key.get("ed"):
                raise RuntimeError(f"a dated price ({key}): this reads only a price that holds today")
            points.append((key["t"], key["p"]))
    currencies = {t["id"]: t["attributes"]["currency"] for t in asc("pricing", "territories", "list", "--paginate")["data"]}

    def price(point):
        territory, number = point
        token = base64.urlsafe_b64encode(json.dumps(
            {"s": app, "t": territory, "p": number}, separators=(",", ":")).encode()).decode().rstrip("=")
        attributes = asc("pricing", "price-points", "view", "--price-point", token)["data"][0]["attributes"]
        return {"territory": territory, "region": regions[territory], "currency": currencies[territory],
                "price": float(attributes["customerPrice"])}

    with ThreadPoolExecutor(6) as pool:
        prices = sorted(pool.map(price, points), key=lambda p: p["region"])
    with open(path, "w") as f:
        json.dump({
            "source": f"App Store Connect customer prices for {name} (app {app}), {datetime.date.today():%-d %b %Y} "
                      f"(`python3 {command} --refresh`)",
            "prices": prices,
        }, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(f"{len(prices)} App Store storefronts read.", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--settings", default=os.environ.get("PRICING"), help="the game's pricing.json")
    parser.add_argument("--refresh", action="store_true", help="re-read the app's App Store prices with asc first")
    parser.add_argument("--price", type=float, help="the US price (default: play.price, else the App Store's)")
    parser.add_argument("--strength", type=float, help="how strongly to apply PPP")
    parser.add_argument("--income-weight", type=float, help="blend in relative income per head, 0-1")
    parser.add_argument("--min-ratio", type=float, help="lowest fraction of the US price")
    parser.add_argument("--max-ratio", type=float, help="highest fraction of the US price")
    parser.add_argument("--add-vat", action=argparse.BooleanOptionalAction, default=None,
                        help="add local VAT/GST on top of the purchasing-power price")
    args = parser.parse_args()
    if not args.settings:
        parser.error("no settings: set PRICING or pass --settings <pricing.json>")

    settings = lib.load_settings(args.settings)
    play = settings.get("play") or {}
    store = settings.get("appStore") or {}
    ppp = lib.purchasing_power(settings, {"strength": args.strength, "incomeWeight": args.income_weight,
                                          "minRatio": args.min_ratio, "maxRatio": args.max_ratio, "addVat": args.add_vat})
    us_price = args.price or play.get("price") or store.get("price") or (store.get("tiers") or [{}])[0].get("price")
    if not us_price:
        parser.error("no US price: set play.price in pricing.json or pass --price")
    if bool(play.get("product")) == bool(play.get("table")):
        parser.error("pricing.json's play needs one of `product` (true) or `table` (a file name)")
    folder = os.path.join(settings["dir"], play.get("dir", "."))
    apple_path = os.path.join(folder, "apple-prices.json")
    # A game's shim names itself (runpy gives this file argv[0]).
    command = lib.shown_command(globals().get("SHIM") or sys.argv[0], lib.repo_root(settings["dir"]))

    if args.refresh:
        if not store.get("app") or store.get("tiers"):
            parser.error("--refresh reads an app's own price: it needs appStore.app and no tiers")
        refresh(apple_path, store["app"], settings.get("name", "the app"), command)

    apple = json.load(open(apple_path))
    regions = json.load(open(os.path.join(folder, "play-regions.json")))
    console_path = os.path.join(folder, "console-prices.json")
    console = json.load(open(console_path))["prices"] if os.path.exists(console_path) else {}

    print("Fetching exchange rates and World Bank PPP data…", file=sys.stderr)
    rates = fetch_json(FX_API)["rates"]
    ratios = price_level_ratios()
    incomes = income_ratios() if ppp["incomeWeight"] > 0 else {}
    table = lib.play_prices(apple["prices"], regions["regions"], rates, ratios, incomes, us_price, ppp,
                            play.get("consoleOnly"), play.get("charmUnderOne", True))

    new_regions = {"USD": us_price, "EUR": us_price} if play.get("product") or play.get("newRegions") else None
    if play.get("product"):
        listing = json.load(open(os.path.join(settings["dir"], "listing.json")))
        product_id = listing["product"]["productId"]
        path = os.path.join(folder, "iap", f"{product_id}.json")
        product = json.load(open(path)) if os.path.exists(path) else {}
        product = lib.product_file(product, listing["package"], product_id, listing["product"].get("listings", {}),
                                   table, us_price)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump(product, f, indent=2, ensure_ascii=False)
            f.write("\n")
    else:
        body = {
            "source": f"`python3 {command}`: the Play price in each region (what the buyer pays), for Play Console's "
                      "App pricing",
            "usPrice": us_price,
            "prices": {r: {"currency": e["currency"], "price": e["price"], "basis": e["basis"]} for r, e in table.items()},
        }
        if new_regions:
            body["newRegions"] = new_regions
        with open(os.path.join(folder, play["table"]), "w") as f:
            json.dump(body, f, indent=1, ensure_ascii=False)
            f.write("\n")

    text, summary = lib.report(play.get("title", "Prices"), command, apple, regions, table, console, us_price, ppp,
                               new_regions)
    with open(os.path.join(folder, "prices.md"), "w") as f:
        f.write(text)
    print(summary, file=sys.stderr)


if __name__ == "__main__":
    main()
