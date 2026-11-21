"""The pure parts of the pricing tools: settings, App Store price points, Play
prices and the report. Nothing here reads the network or runs a command, so
test_pricing.py covers it offline.
"""

import base64
import json
import math
import os
import re

from ppp import CENT_CURRENCIES, NINE_ENDING_CURRENCIES, VAT_RATES, applied_ratio, blended_level, round_price

# --- settings ---------------------------------------------------------------

# Purchasing-power settings and their defaults (ppp.py's).
PPP_DEFAULTS = {"strength": 1.0, "incomeWeight": 0.0, "minRatio": 0.25, "maxRatio": None, "addVat": False}


def load_settings(path):
    """A game's pricing.json, with `dir` (its directory) added. No path: none."""
    if not path:
        return {"dir": os.getcwd()}
    with open(path) as f:
        settings = json.load(f)
    settings["dir"] = os.path.dirname(os.path.abspath(path))
    return settings


def purchasing_power(settings, overrides=None):
    """The purchasing-power settings, defaults filled in, then any the command line gave."""
    ppp = dict(PPP_DEFAULTS)
    ppp.update(settings.get("purchasingPower") or {})
    ppp.update({k: v for k, v in (overrides or {}).items() if v is not None})
    return ppp


def repo_root(start):
    """The repository holding `start` (a worktree's `.git` is a file), else `start`."""
    here = os.path.abspath(start)
    while True:
        if os.path.exists(os.path.join(here, ".git")):
            return here
        parent = os.path.dirname(here)
        if parent == here:
            return os.path.abspath(start)
        here = parent


def shown_command(script, root):
    """How a game's own script is run from its repository root, for messages."""
    return os.path.relpath(os.path.abspath(script), root)


def target_ratio(iso2, ratios, incomes, ppp):
    """The fraction of the US price a country pays, VAT included when asked; None without a price level."""
    if iso2 not in ratios:
        return None
    level = blended_level(ratios[iso2][0], incomes.get(iso2), ppp["incomeWeight"])
    return applied_ratio(level, ppp["strength"], ppp["minRatio"], ppp["maxRatio"])


def vat(iso2, ppp):
    return VAT_RATES.get(iso2, 0) if ppp["addVat"] else 0


# --- App Store ----------------------------------------------------------------

def decode_point(point_id):
    """A price point's ID is base64 JSON naming its product or app (s), territory (t) and price (p)."""
    standard = point_id.replace("-", "+").replace("_", "/")
    return json.loads(base64.b64decode(standard + "=" * (-len(standard) % 4)))


def retarget(point_id, iap):
    """The same price point for another product."""
    payload = decode_point(point_id)
    payload["s"] = iap
    return base64.b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode().rstrip("=")


def is_nice(price, currency):
    if currency in CENT_CURRENCIES and currency != "CHF":
        return round(price * 100) % 10 == 9
    if currency in NINE_ENDING_CURRENCIES:
        return price == int(price) and int(price) % 10 == 9
    return True


def nearest_point(points, target, currency):
    """The paid price point nearest the target, preferring .x9 / 9 endings."""
    paid = [p for p in points if p[0] > 0]
    candidates = [p for p in paid if is_nice(p[0], currency)] or paid
    return min(candidates, key=lambda p: (abs(p[0] - target), p[0]))


def schedule_body(app, base_territory, price_point_ids):
    """The request that replaces an app's whole price schedule."""
    refs = [f"${{p{i}}}" for i in range(len(price_point_ids))]
    return {
        "data": {
            "type": "appPriceSchedules",
            "relationships": {
                "app": {"data": {"type": "apps", "id": app}},
                "baseTerritory": {"data": {"type": "territories", "id": base_territory}},
                "manualPrices": {"data": [{"type": "appPrices", "id": ref} for ref in refs]},
            },
        },
        "included": [
            {
                "type": "appPrices",
                "id": ref,
                "attributes": {"startDate": None},
                "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": pid}}},
            }
            for ref, pid in zip(refs, price_point_ids)
        ],
    }


def plan_lines(plan):
    """The plan grouped by price: USD first, then by currency, dearest first."""
    groups = {}
    for territory, currency, (price, _) in plan:
        groups.setdefault((currency, price), []).append(territory)
    return [f"{price:>10g} {currency}  {', '.join(territories)}"
            for (currency, price), territories in sorted(groups.items(), key=lambda g: (g[0][0] != "USD", g[0][0], -g[0][1]))]


# --- Google Play ---------------------------------------------------------------

# Currencies Play prices in whole units (its price table shows them without
# decimals). Every other one takes two: Play shows JOD to three but keeps it
# to two (0.844 is saved as 0.840).
WHOLE = {"CLP", "COP", "PYG", "XAF", "XOF", "HUF", "IQD", "RSD", "IDR", "JPY", "MMK", "KRW", "VND"}

# Play-only places that shop as a neighbour does and share its currency: they
# take that neighbour's App Store price rather than a conversion.
NEIGHBOURS = {"LI": "CH", "MC": "FR", "SM": "IT", "VA": "IT", "GI": "GB"}


def decimals(currency):
    return 0 if currency in WHOLE else 2


def representable(value, currency):
    places = decimals(currency)
    return abs(round(value, places) - value) < 1e-9


def snap(value, currency, low, high, charm_under_one=True):
    """A price-like value Play takes: rounded as ppp.py rounds, then to the
    currency's decimals, inside its range. Below 1, only cent currencies round
    as prices (0.x9, as the App Store's do), and only with `charm_under_one`."""
    charm = value >= 1 or (charm_under_one and currency in CENT_CURRENCIES)
    price = round_price(value, currency) if charm else value
    places = decimals(currency)
    price = round(price, places)
    step = 10 ** -places
    if price < low:
        price = math.ceil(low / step) * step
    if price > high:
        price = math.floor(high / step) * step
    return round(price, places)


def money(value, currency):
    units = int(math.floor(value + 1e-9))
    nanos = int(round((value - units) * 1_000_000_000))
    return {"currencyCode": currency, "units": str(units), "nanos": nanos}


def fmt(value, currency):
    return f"{value:,.{decimals(currency)}f} {currency}"


def play_prices(apple_rows, regions, rates, ratios, incomes, us_price, ppp, console_only=None, charm_under_one=True):
    """Every Play region's fixed price, as {region: {currency, price, basis}}.

    `apple_rows` is the App Store snapshot (free storefronts count as not on
    sale), `regions` Play's table and `console_only` places Play Console
    prices though the table gives them no purchases ({region: currency}).

      1. On both, same currency, an amount Play takes: the App Store's price.
      2. On both otherwise: the App Store's converted at today's rate, snapped.
      3. Play only: a neighbour's App Store price in the same currency, else
         the purchasing-power price from the US price.

    Without `charm_under_one`, an amount below 1 is kept as converted, to the
    currency's decimals, rather than ending in .x9.
    """
    apple = {row["region"]: row for row in apple_rows if row["price"] > 0}
    ranges = {info["currency"]: (info["min"], info["max"]) for info in regions.values()}
    places = dict(regions)
    for region, currency in (console_only or {}).items():
        # A currency Play bills nowhere has no range to keep to.
        low, high = ranges.get(currency, (0, math.inf))
        places.setdefault(region, {"currency": currency, "min": low, "max": high})

    table = {}
    for region in sorted(places):
        info = places[region]
        currency, low, high = info["currency"], info["min"], info["max"]
        entry = {"currency": currency}
        if region in apple:
            a = apple[region]
            if a["currency"] == currency and low <= a["price"] <= high and representable(a["price"], currency):
                entry.update(price=a["price"], basis="App Store")
            else:
                converted = a["price"] / rates[a["currency"]] * rates[currency]
                why = "Play bills in " + currency if a["currency"] != currency else "outside Play's range or decimals"
                entry.update(price=snap(converted, currency, low, high, charm_under_one), basis="converted: " + why, why=why)
        elif NEIGHBOURS.get(region) in apple and apple[NEIGHBOURS[region]]["currency"] == currency:
            entry.update(price=apple[NEIGHBOURS[region]]["price"], basis="as " + NEIGHBOURS[region] + " on the App Store",
                         playOnly=True)
        else:
            ratio = target_ratio(region, ratios, incomes, ppp)
            target = us_price * (1.0 if ratio is None else ratio) * (1 + vat(region, ppp)) * rates[currency]
            entry.update(price=snap(target, currency, low, high, charm_under_one), playOnly=True,
                         basis="price level %.2f" % ratio if ratio is not None else "no PPP data: US price converted")
        table[region] = entry
    return table


def product_file(product, package, product_id, listings, table, us_price):
    """gplay's declarative one-time product: the given file's fields, the
    listings (kept if it has them) and one purchase option at fixed prices."""
    product = dict(product)
    product.update({
        "packageName": package,
        "productId": product_id,
        "listings": product.get("listings") or [
            {"languageCode": code, "title": text["title"], "description": text["description"]}
            for code, text in listings.items()
        ],
        "purchaseOptions": [{
            "purchaseOptionId": "buy",
            # The option Play Billing reads (getOneTimePurchaseOfferDetails).
            "buyOption": {"legacyCompatible": True, "multiQuantityEnabled": False},
            "state": "ACTIVE",
            "regionalPricingAndAvailabilityConfigs": [
                {"regionCode": region, "price": money(e["price"], e["currency"]), "availability": "AVAILABLE"}
                for region, e in table.items()
            ],
            # Locations Play opens later: a fixed price, not a conversion.
            "newRegionsConfig": {
                "usdPrice": money(us_price, "USD"),
                "eurPrice": money(us_price, "EUR"),
                "availability": "AVAILABLE",
            },
        }],
    })
    return product


def snapshot_date(source):
    """The date in a snapshot's `source` line ("19 Nov 2026"), else the line."""
    match = re.search(r"\b\d{1,2} [A-Z][a-z]{2} \d{4}\b", source or "")
    return match.group(0) if match else (source or "undated")


def regions_version(source):
    match = re.search(r"version (\d{4}/\d{2})", source or "")
    return match.group(1) if match else "unknown"


def report(title, command, apple_snapshot, regions_snapshot, table, console, us_price, ppp, new_regions):
    """prices.md: the App Store's price and Play's, region by region.

    `console` is what Play Console holds once it has charmed each price
    ({region: {currency, price}}, empty when there's no snapshot)."""
    apple = {row["region"]: row for row in apple_snapshot["prices"] if row["price"] > 0}
    free = sorted(row["region"] for row in apple_snapshot["prices"] if row["price"] == 0)

    def final(region):
        return console.get(region) or table[region]

    def charm(region):
        if final(region)["price"] == table[region]["price"]:
            return ""
        return f" (the Console charms {fmt(table[region]['price'], table[region]['currency'])} to this)"

    same, differ, play_only = [], [], []
    for region in sorted(table):
        held = final(region)
        if table[region].get("playOnly"):
            play_only.append(region)
        elif held["currency"] == apple[region]["currency"] and held["price"] == apple[region]["price"]:
            same.append(region)
        else:
            differ.append(region)
    apple_only = sorted(set(apple) - set(table))

    sources = [f"`apple-prices.json` (App Store Connect, {snapshot_date(apple_snapshot.get('source'))})",
               f"`play-regions.json` (Play's supported locations, version {regions_version(regions_snapshot.get('source'))})"]
    if console:
        sources.append("`console-prices.json` (what Play Console holds once it has charmed each price)")
    terms = f"strength {ppp['strength']}, income weight {ppp['incomeWeight']}"
    if ppp["minRatio"]:
        terms += f", at least {ppp['minRatio']:g} of it"
    if ppp["maxRatio"] is not None:
        terms += f", at most {ppp['maxRatio']:g} of it"
    if ppp["addVat"]:
        terms += ", VAT on top"

    lines = [
        f"# {title}, App Store and Google Play",
        "",
        f"Written by `python3 {command}` from {', '.join(sources[:-1])} and {sources[-1]}. Prices are what the buyer",
        "pays. Every Play price is fixed: none is left to Play's automatic conversion.",
        "",
        f"## The same price on both ({len(same)})",
        "",
        "| Region | App Store | Google Play |",
        "|---|---:|---:|",
    ]
    lines += [f"| {r} | {fmt(apple[r]['price'], apple[r]['currency'])} | {fmt(final(r)['price'], final(r)['currency'])} |"
              for r in same]
    lines += [
        "",
        f"## Not the same ({len(differ)})",
        "",
        "Where Play bills another currency or can't take the App Store's amount, the App Store's price converted",
        "at today's rate and rounded as a price inside Play's range for the currency."
        + (" Elsewhere Play Console charms the amount to its own ending for the currency." if console else ""),
        "",
        "| Region | App Store | Google Play | Why |",
        "|---|---:|---:|---|",
    ]
    lines += [f"| {r} | {fmt(apple[r]['price'], apple[r]['currency'])} | {fmt(final(r)['price'], final(r)['currency'])} | "
              f"{table[r]['why'] + charm(r) if 'why' in table[r] else 'Play Console charms it'} |" for r in differ]
    lines += [
        "",
        f"## Google Play only ({len(play_only)})",
        "",
        "A neighbour's App Store price in the same currency, else the purchasing-power price from the",
        f"US ${us_price:.2f} ({terms}).",
        "",
        "| Region | Google Play | Basis |",
        "|---|---:|---|",
    ]
    lines += [f"| {r} | {fmt(final(r)['price'], final(r)['currency'])} | {table[r]['basis']}{charm(r)} |" for r in play_only]
    if new_regions:
        lines += [
            "",
            "## Countries Play adds later",
            "",
            " and ".join(fmt(v, c) for c, v in new_regions.items()) + ": the US price.",
        ]
    lines += [
        "",
        f"## App Store only: no Google Play purchases there ({len(apple_only) + len(free)})",
        "",
        "| Region | App Store |",
        "|---|---:|",
    ]
    lines += [f"| {r} | {fmt(apple[r]['price'], apple[r]['currency'])} |" for r in apple_only]
    lines += [f"| {r} | free |" for r in free]
    summary = (f"{len(table)} Play regions: {len(same)} the App Store's exact price, {len(differ)} not, "
               f"{len(play_only)} Play only; {len(apple_only) + len(free)} App Store storefronts have no Play purchases.")
    return "\n".join(lines) + "\n", summary
