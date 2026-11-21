#!/usr/bin/env python3
"""Localize a US price for every storefront using purchasing power parity.

How it works:
  1. Fetches the World Bank PPP conversion factor for household consumption
     (PA.NUS.PRVT.PP, falling back to GDP PPP) and the official exchange rate
     (PA.NUS.FCRF) for each country, and divides them to get a price-level ratio
     (US = 1.0). A ratio of 0.3 means goods cost ~30% of what they cost in the US.
  2. Multiplies the reference US price by that ratio (optionally softened and clamped).
  3. Converts the result into the storefront's currency using live exchange rates
     and rounds it to a price-point-like value (e.g. 4.99, 1,200, 199).

App Store Connect snaps to its nearest available price point, so treat the output
as a target. Uses only the standard library. appstore.py and play.py price from the
same levels; this prints them for one price.

Usage (a game runs it through its own two-line shim):
  python3 Tools/Pricing/ppp.py 4.99
  python3 Tools/Pricing/ppp.py 9.99 --min-ratio 0.3 --max-ratio 1.0 --csv prices.csv
  python3 Tools/Pricing/ppp.py 2.99 --strength 0.7 --countries IN,BR,DE,JP
  python3 Tools/Pricing/ppp.py 2.99 --add-vat
  python3 Tools/Pricing/ppp.py 2.99 --income-weight 0.5 --strength 0.65
"""

import argparse
import csv
import json
import math
import sys
import urllib.request

WB_API = "https://api.worldbank.org/v2"
FX_API = "https://open.er-api.com/v6/latest/USD"
PPP_INDICATORS = ("PA.NUS.PRVT.PP", "PA.NUS.PPP")
FX_INDICATOR = "PA.NUS.FCRF"
INCOME_INDICATOR = "NY.GNP.PCAP.PP.CD"
YEARS = "2015:2030"

EURO_STOREFRONTS = {
    "AT", "BE", "BG", "CY", "DE", "EE", "ES", "FI", "FR", "GR", "HR", "IE",
    "IT", "LT", "LU", "LV", "MT", "NL", "PT", "SI", "SK",
}

# Storefronts that don't bill in USD or EUR. Every other storefront bills in USD.
STOREFRONT_CURRENCIES = {
    "AE": "AED", "AU": "AUD", "BR": "BRL", "CA": "CAD", "CH": "CHF", "CL": "CLP",
    "CN": "CNY", "CO": "COP", "CZ": "CZK", "DK": "DKK", "EG": "EGP", "GB": "GBP",
    "HK": "HKD", "HU": "HUF", "ID": "IDR", "IL": "ILS", "IN": "INR", "JP": "JPY",
    "KR": "KRW", "KZ": "KZT", "LI": "CHF", "MX": "MXN", "MY": "MYR", "NG": "NGN",
    "NO": "NOK", "NZ": "NZD", "PE": "PEN", "PH": "PHP", "PK": "PKR", "PL": "PLN",
    "QA": "QAR", "RO": "RON", "SA": "SAR", "SE": "SEK", "SG": "SGD", "TH": "THB",
    "TR": "TRY", "TW": "TWD", "TZ": "TZS", "VN": "VND", "ZA": "ZAR",
}

# World Bank aggregate holding the euro exchange rate. Used for euro storefronts so that
# countries that recently adopted the euro (e.g. Bulgaria) don't mix currency units.
EURO_AREA = "XC"

# Countries missing from World Bank data: {iso2: (name, price level vs US)}. IMF estimates.
MANUAL_PRICE_LEVELS = {
    "TW": ("Taiwan", 0.50),
}

# No App Store, or paid sales unavailable.
EXCLUDED = {"CU", "IR", "KP", "RU", "SY"}

# Approximate standard VAT/GST rates on digital goods, used by --add-vat. Countries not
# listed (and the US and Canada, whose App Store prices exclude sales tax) are treated as 0.
# Rates change; verify the ones that matter before relying on them.
VAT_RATES = {
    # European Union
    "AT": 0.20, "BE": 0.21, "BG": 0.20, "CY": 0.19, "CZ": 0.21, "DE": 0.19, "DK": 0.25,
    "EE": 0.24, "ES": 0.21, "FI": 0.255, "FR": 0.20, "GR": 0.24, "HR": 0.25, "HU": 0.27,
    "IE": 0.23, "IT": 0.22, "LT": 0.21, "LU": 0.17, "LV": 0.21, "MT": 0.18, "NL": 0.21,
    "PL": 0.23, "PT": 0.23, "RO": 0.21, "SE": 0.25, "SI": 0.22, "SK": 0.23,
    # Rest of Europe and Central Asia
    "AL": 0.20, "AM": 0.20, "AZ": 0.18, "BA": 0.17, "BY": 0.20, "CH": 0.081, "GB": 0.20,
    "GE": 0.18, "IS": 0.24, "KG": 0.12, "KZ": 0.16, "LI": 0.081, "MD": 0.20, "ME": 0.21,
    "MK": 0.18, "NO": 0.25, "RS": 0.20, "TJ": 0.14, "TR": 0.20, "UA": 0.20, "UZ": 0.12,
    "XK": 0.18,
    # Middle East and Africa
    "AE": 0.05, "AO": 0.14, "BH": 0.10, "BF": 0.18, "BJ": 0.18, "BW": 0.14, "CI": 0.18,
    "CM": 0.1925, "DZ": 0.19, "EG": 0.14, "GH": 0.15, "IL": 0.18, "KE": 0.16, "MA": 0.20,
    "ML": 0.18, "MU": 0.15, "MW": 0.165, "MZ": 0.16, "NA": 0.15, "NE": 0.19, "NG": 0.075,
    "OM": 0.05, "RW": 0.18, "SA": 0.15, "SC": 0.15, "SN": 0.18, "TN": 0.19, "TZ": 0.18,
    "UG": 0.18, "ZA": 0.15, "ZM": 0.16, "ZW": 0.15,
    # Asia Pacific
    "AU": 0.10, "BD": 0.15, "CN": 0.06, "FJ": 0.15, "ID": 0.11, "IN": 0.18, "JP": 0.10,
    "KH": 0.10, "KR": 0.10, "LA": 0.10, "LK": 0.18, "MN": 0.10, "MV": 0.08, "MY": 0.08,
    "NP": 0.13, "NZ": 0.15, "PG": 0.10, "PH": 0.12, "PK": 0.18, "SG": 0.09, "TH": 0.07,
    "TO": 0.15, "TW": 0.05, "VN": 0.10, "VU": 0.15, "WS": 0.15,
    # Latin America and the Caribbean
    "AG": 0.15, "AR": 0.21, "BB": 0.175, "BO": 0.13, "BS": 0.10, "BZ": 0.125, "CL": 0.19,
    "CO": 0.19, "CR": 0.13, "DM": 0.15, "DO": 0.18, "EC": 0.15, "GD": 0.15, "GT": 0.12,
    "GY": 0.14, "HN": 0.15, "JM": 0.15, "KN": 0.17, "LC": 0.125, "MX": 0.16, "NI": 0.15,
    "PA": 0.07, "PE": 0.18, "PY": 0.10, "SR": 0.10, "SV": 0.13, "TT": 0.125, "UY": 0.22,
    "VC": 0.16,
}

# Currencies whose price points end in .99; others use whole numbers.
CENT_CURRENCIES = {
    "USD", "EUR", "GBP", "AUD", "CAD", "CHF", "NZD", "SGD", "AED", "SAR", "QAR",
    "BRL", "PEN", "PLN", "RON", "ILS", "MYR", "ZAR", "TRY",
}

# Whole-number currencies that conventionally end in 9 (e.g. 199 kr, ₹99).
NINE_ENDING_CURRENCIES = {
    "CNY", "CZK", "DKK", "EGP", "HKD", "INR", "MXN", "NOK", "PHP", "SEK", "THB", "TWD",
}


def fetch_json(url):
    request = urllib.request.Request(url, headers={"User-Agent": "localize-prices"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def fetch_countries():
    data = fetch_json(f"{WB_API}/country?format=json&per_page=1000")
    countries = {
        c["iso2Code"]: c["name"]
        for c in data[1]
        if c["region"]["id"] != "NA" and c["iso2Code"] not in EXCLUDED
    }
    for iso2, (name, _) in MANUAL_PRICE_LEVELS.items():
        countries.setdefault(iso2, name)
    return countries


def fetch_indicator(indicator):
    """Returns {iso2: {year: value}}."""
    data = fetch_json(
        f"{WB_API}/country/all/indicator/{indicator}?format=json&per_page=30000&date={YEARS}"
    )
    values = {}
    for row in data[1] or []:
        if row["value"] is not None:
            values.setdefault(row["country"]["id"], {})[int(row["date"])] = row["value"]
    return values


def price_level_ratios():
    """Returns {iso2: (ratio, year)} where ratio is local price level relative to the US."""
    fx = fetch_indicator(FX_INDICATOR)
    ppp_sources = [fetch_indicator(i) for i in PPP_INDICATORS]
    ratios = {}
    for iso2 in set(fx) | set().union(*ppp_sources):
        country_fx = fx.get(EURO_AREA if iso2 in EURO_STOREFRONTS else iso2, {})
        for ppp in ppp_sources:
            years = sorted(set(ppp.get(iso2, {})) & set(country_fx), reverse=True)
            if years:
                year = years[0]
                ratios[iso2] = (ppp[iso2][year] / country_fx[year], year)
                break
    for iso2, (_, level) in MANUAL_PRICE_LEVELS.items():
        ratios.setdefault(iso2, (level, "manual"))
    return ratios


def income_ratios():
    """Returns {iso2: GNI per capita (PPP) relative to the US, same year}."""
    income = fetch_indicator(INCOME_INDICATOR)
    us = income.get("US", {})
    ratios = {}
    for iso2, by_year in income.items():
        years = sorted(set(by_year) & set(us), reverse=True)
        if years:
            ratios[iso2] = by_year[years[0]] / us[years[0]]
    return ratios


def blended_level(price_level, income_ratio, income_weight):
    """Geometric blend of price level and relative income; falls back to price level alone."""
    if income_ratio is None or income_weight <= 0:
        return price_level
    return price_level ** (1 - income_weight) * income_ratio ** income_weight


def applied_ratio(raw_ratio, strength=1.0, min_ratio=0.0, max_ratio=None):
    ratio = max(raw_ratio ** strength, min_ratio)
    return ratio if max_ratio is None else min(ratio, max_ratio)


def storefront_currency(iso2):
    if iso2 in EURO_STOREFRONTS:
        return "EUR"
    return STOREFRONT_CURRENCIES.get(iso2, "USD")


def round_half_up(value):
    return math.floor(value + 0.5)


def round_price(value, currency):
    if currency in CENT_CURRENCIES:
        # Nearest x.99 (or 0.x9 below 1).
        if value < 1:
            return max(0.29, round_half_up(value * 10 + 0.1) / 10 - 0.01)
        return max(0.99, round_half_up(value + 0.01) - 0.01)

    if value <= 0:
        return 0
    # Two significant figures, e.g. 1234 -> 1200, 47 -> 47.
    magnitude = 10 ** max(0, int(math.floor(math.log10(value))) - 1)
    rounded = max(magnitude, round_half_up(value / magnitude) * magnitude)
    if currency in NINE_ENDING_CURRENCIES and rounded >= 10:
        # Nearest 9-ending value, e.g. 34 -> 39, 52 -> 49, 1234 -> 1199.
        step = 10 if rounded < 1000 else magnitude
        rounded = max(step, round_half_up((value + 1) / step) * step) - 1
    return int(rounded)


def format_price(value, currency):
    if currency in CENT_CURRENCIES:
        return f"{value:,.2f} {currency}"
    return f"{int(value):,} {currency}"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("price", type=float, help="reference US price in USD, e.g. 4.99")
    parser.add_argument("--strength", type=float, default=1.0,
                        help="how strongly to apply PPP: 1 = full, 0.5 = halfway, 0 = same USD price everywhere (default 1)")
    parser.add_argument("--income-weight", type=float, default=0.0,
                        help="blend in relative income per head: 0 = price level only, 0.5 = equal blend (default 0)")
    parser.add_argument("--min-ratio", type=float, default=0.25,
                        help="lowest allowed fraction of the US price (default 0.25)")
    parser.add_argument("--max-ratio", type=float, default=None,
                        help="highest allowed fraction of the US price, e.g. 1.0 to never exceed the US price")
    parser.add_argument("--add-vat", action="store_true",
                        help="treat the PPP-adjusted price as pre-tax and add local VAT/GST on top")
    parser.add_argument("--countries", help="comma-separated ISO country codes to include, e.g. IN,BR,DE")
    parser.add_argument("--csv", help="also write results to this CSV file")
    args = parser.parse_args()

    print("Fetching World Bank PPP data and exchange rates…", file=sys.stderr)
    countries = fetch_countries()
    ratios = price_level_ratios()
    incomes = income_ratios() if args.income_weight > 0 else {}
    rates = fetch_json(FX_API)["rates"]

    wanted = {c.strip().upper() for c in args.countries.split(",")} if args.countries else None
    rows = []
    for iso2, name in countries.items():
        if wanted and iso2 not in wanted:
            continue
        if iso2 not in ratios:
            continue
        raw_ratio, year = ratios[iso2]
        level = blended_level(raw_ratio, incomes.get(iso2), args.income_weight)
        ratio = applied_ratio(level, args.strength, args.min_ratio, args.max_ratio)

        currency = storefront_currency(iso2)
        rate = rates.get(currency)
        if rate is None:
            continue
        vat = VAT_RATES.get(iso2, 0) if args.add_vat else 0
        local = round_price(args.price * ratio * (1 + vat) * rate, currency)
        rows.append({
            "country": iso2,
            "name": name,
            "currency": currency,
            "ppp_year": year,
            "price_level": round(raw_ratio, 3),
            "income": round(incomes[iso2], 3) if iso2 in incomes else "",
            "applied_ratio": round(ratio, 3),
            "vat": vat,
            "local_price": local,
            "usd_equivalent": round(local / rate, 2),
        })

    rows.sort(key=lambda r: r["name"])
    missing = sorted(set(wanted) - {r["country"] for r in rows}) if wanted else []

    header = f"{'CC':<3} {'Country':<32} {'Level':>6} {'Applied':>7} {'Local price':>20} {'≈ USD':>9}"
    print(header)
    print("-" * len(header))
    for r in rows:
        print(f"{r['country']:<3} {r['name'][:32]:<32} {r['price_level']:>6.2f} {r['applied_ratio']:>7.2f} "
              f"{format_price(r['local_price'], r['currency']):>20} {r['usd_equivalent']:>9.2f}")
    print(f"\n{len(rows)} storefronts · reference price {args.price:.2f} USD", file=sys.stderr)
    if missing:
        print(f"No data for: {', '.join(missing)}", file=sys.stderr)

    if args.csv:
        with open(args.csv, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else [])
            writer.writeheader()
            writer.writerows(rows)
        print(f"Wrote {args.csv}", file=sys.stderr)


if __name__ == "__main__":
    main()
