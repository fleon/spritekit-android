"""Offline tests for the pricing tools: python3 -m unittest discover -s Tools/Pricing"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import lib  # noqa: E402
import play  # noqa: E402
import ppp  # noqa: E402

NO_PPP = dict(lib.PPP_DEFAULTS)


def write_json(path, body):
    with open(path, "w") as f:
        json.dump(body, f)


def point(territory, price, s="1"):
    payload = json.dumps({"s": s, "t": territory, "p": str(price)}, separators=(",", ":")).encode()
    return base64.b64encode(payload).decode().rstrip("=")


class RoundingTest(unittest.TestCase):
    def test_cent_currencies_end_in_99(self):
        self.assertEqual(ppp.round_price(4.2, "USD"), 3.99)
        self.assertEqual(ppp.round_price(4.6, "EUR"), 4.99)
        self.assertEqual(ppp.round_price(0.42, "USD"), 0.39)

    def test_whole_currencies_keep_two_figures_and_nines(self):
        self.assertEqual(ppp.round_price(1234, "JPY"), 1200)
        self.assertEqual(ppp.round_price(34, "INR"), 39)
        self.assertEqual(ppp.round_price(1234, "INR"), 1199)

    def test_ratio_is_softened_and_clamped(self):
        self.assertAlmostEqual(ppp.applied_ratio(0.25, 0.5), 0.5)
        self.assertEqual(ppp.applied_ratio(0.01, 1.0, 0.25), 0.25)
        self.assertEqual(ppp.applied_ratio(1.4, 1.0, 0.25, 1.0), 1.0)
        self.assertEqual(ppp.blended_level(0.5, None, 0.5), 0.5)
        self.assertAlmostEqual(ppp.blended_level(0.25, 1.0, 0.5), 0.5)


class SettingsTest(unittest.TestCase):
    def test_flags_override_settings_over_defaults(self):
        settings = {"purchasingPower": {"strength": 0.65, "addVat": True}}
        got = lib.purchasing_power(settings, {"strength": 0.5, "incomeWeight": None})
        self.assertEqual(got, {"strength": 0.5, "incomeWeight": 0.0, "minRatio": 0.25, "maxRatio": None, "addVat": True})

    def test_repo_root_finds_a_worktree_git_file(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "a", "b"))
            write_json(os.path.join(root, ".git"), "gitdir: elsewhere")
            self.assertEqual(lib.repo_root(os.path.join(root, "a", "b")), os.path.abspath(root))
            self.assertEqual(lib.shown_command(os.path.join(root, "a", "b", "x.py"), root), os.path.join("a", "b", "x.py"))


class AppStoreTest(unittest.TestCase):
    def test_price_point_ids_decode_and_retarget(self):
        pid = point("USA", 10001, s="111")
        self.assertEqual(lib.decode_point(pid), {"s": "111", "t": "USA", "p": "10001"})
        self.assertEqual(lib.decode_point(lib.retarget(pid, "222"))["s"], "222")
        urlsafe = base64.urlsafe_b64encode(b'{"s":"1","t":"JPN","p":"???>>>"}').decode().rstrip("=")
        self.assertEqual(lib.decode_point(urlsafe)["p"], "???>>>")

    def test_nearest_point_prefers_nine_endings(self):
        points = [(0, "free"), (4.49, "a"), (4.99, "b"), (5.49, "c")]
        self.assertEqual(lib.nearest_point(points, 4.8, "USD"), (4.99, "b"))
        self.assertEqual(lib.nearest_point([(0, "f"), (600, "a"), (650, "b")], 640, "JPY"), (650, "b"))
        self.assertEqual(lib.nearest_point([(5.0, "a"), (5.5, "b")], 5.2, "CHF"), (5.0, "a"))

    def test_schedule_body_names_every_price_point(self):
        body = lib.schedule_body("9", "USA", ["x", "y"])
        self.assertEqual(body["data"]["relationships"]["manualPrices"]["data"],
                         [{"type": "appPrices", "id": "${p0}"}, {"type": "appPrices", "id": "${p1}"}])
        self.assertEqual([i["relationships"]["appPricePoint"]["data"]["id"] for i in body["included"]], ["x", "y"])

    def test_plan_lines_put_usd_first_dearest_first(self):
        plan = [("DEU", "EUR", (4.99, "")), ("USA", "USD", (6.99, "")), ("AFG", "USD", (1.99, "")),
                ("ALB", "USD", (1.99, ""))]
        self.assertEqual(lib.plan_lines(plan), ["      6.99 USD  USA", "      1.99 USD  AFG, ALB", "      4.99 EUR  DEU"])


class PlayTest(unittest.TestCase):
    APPLE = [
        {"territory": "USA", "region": "US", "currency": "USD", "price": 4.99},
        {"territory": "DEU", "region": "DE", "currency": "EUR", "price": 4.99},
        {"territory": "ARG", "region": "AR", "currency": "USD", "price": 2.99},
        {"territory": "CHE", "region": "CH", "currency": "CHF", "price": 5.0},
        {"territory": "JPN", "region": "JP", "currency": "JPY", "price": 800.5},
        {"territory": "CHN", "region": "CN", "currency": "CNY", "price": 0},
        {"territory": "FJI", "region": "FJ", "currency": "USD", "price": 1.99},
    ]
    REGIONS = {
        "US": {"currency": "USD", "min": 0.05, "max": 400},
        "DE": {"currency": "EUR", "min": 0.05, "max": 350},
        "AR": {"currency": "ARS", "min": 20, "max": 900000},
        "CH": {"currency": "CHF", "min": 0.5, "max": 400},
        "JP": {"currency": "JPY", "min": 30, "max": 60000},
        "LI": {"currency": "CHF", "min": 0.5, "max": 400},
        "ZZ": {"currency": "USD", "min": 0.05, "max": 400},
        "YY": {"currency": "USD", "min": 0.05, "max": 400},
    }
    RATES = {"USD": 1.0, "EUR": 0.9, "ARS": 1000.0, "CHF": 0.8, "JPY": 150.0, "RUB": 90.0}

    def table(self, **kw):
        return lib.play_prices(self.APPLE, self.REGIONS, self.RATES, {"ZZ": (0.3, 2024)}, {}, 4.99, NO_PPP, **kw)

    def test_each_region_is_priced_by_its_rule(self):
        table = self.table()
        self.assertEqual(table["US"], {"currency": "USD", "price": 4.99, "basis": "App Store"})
        self.assertEqual(table["DE"]["price"], 4.99)
        # Play bills ARS: Apple's USD converted, rounded as a price.
        self.assertEqual(table["AR"]["price"], 3000)
        self.assertEqual(table["AR"]["why"], "Play bills in ARS")
        # JPY takes no decimals on Play.
        self.assertEqual(table["JP"]["price"], 800)
        self.assertEqual(table["JP"]["why"], "outside Play's range or decimals")
        self.assertEqual(table["LI"]["price"], 5.0)
        self.assertEqual(table["LI"]["basis"], "as CH on the App Store")
        # Purchasing power: 4.99 x 0.3 = 1.50, to the nearest .99.
        self.assertEqual(table["ZZ"]["price"], 1.99)
        self.assertEqual(table["YY"]["basis"], "no PPP data: US price converted")
        self.assertNotIn("CN", table)

    def test_console_only_places_are_priced_too(self):
        table = self.table(console_only={"RU": "RUB"})
        self.assertEqual(table["RU"]["currency"], "RUB")
        self.assertEqual(table["RU"]["price"], 450)

    def test_snap_keeps_to_decimals_and_range(self):
        self.assertEqual(lib.snap(0.844, "JOD", 0.05, 710), 0.84)
        self.assertEqual(lib.snap(0.72, "USD", 0.05, 400), 0.69)
        self.assertEqual(lib.snap(10, "USD", 0.05, 5), 5)
        self.assertEqual(lib.snap(0.01, "USD", 0.05, 400), 0.29)
        self.assertEqual(lib.snap(0.72, "USD", 0.05, 400, charm_under_one=False), 0.72)
        self.assertEqual(lib.snap(1.42, "USD", 0.05, 400, charm_under_one=False), 0.99)

    def test_money_splits_units_and_nanos(self):
        self.assertEqual(lib.money(6.99, "USD"), {"currencyCode": "USD", "units": "6", "nanos": 990000000})
        self.assertEqual(lib.money(1200, "JPY"), {"currencyCode": "JPY", "units": "1200", "nanos": 0})

    def test_product_file_keeps_its_copy(self):
        product = lib.product_file({"listings": [{"languageCode": "en-US", "title": "t", "description": "d"}]},
                                   "com.example", "com.example.full", {"de-DE": {"title": "x", "description": "y"}},
                                   {"US": {"currency": "USD", "price": 4.99}}, 4.99)
        self.assertEqual(product["listings"][0]["languageCode"], "en-US")
        option = product["purchaseOptions"][0]
        self.assertEqual(option["regionalPricingAndAvailabilityConfigs"][0]["regionCode"], "US")
        self.assertEqual(option["newRegionsConfig"]["eurPrice"]["units"], "4")

    def test_report_sorts_regions_and_shows_the_console(self):
        table = self.table()
        console = {"DE": {"currency": "EUR", "price": 4.9}}
        text, summary = lib.report("Prices", "Tools/x.py", {"source": "ASC, 2 Nov 2026", "prices": self.APPLE},
                                   {"source": "Play, version 2026/01"}, table, console, 4.99, NO_PPP, None)
        self.assertIn("App Store Connect, 2 Nov 2026", text)
        self.assertIn("version 2026/01", text)
        self.assertIn("| US | 4.99 USD | 4.99 USD |", text)
        self.assertIn("| DE | 4.99 EUR | 4.90 EUR | Play Console charms it |", text)
        self.assertIn("| AR | 2.99 USD | 3,000.00 ARS | Play bills in ARS |", text)
        self.assertIn("| CN | free |", text)
        self.assertIn("| FJ | 1.99 USD |", text)
        self.assertTrue(summary.startswith("8 Play regions: 2 the App Store's exact price, 3 not, 3 Play only; 2 "))


class PlayToolTest(unittest.TestCase):
    """play.py end to end, on a fixture game, with the network stubbed."""

    def run_tool(self, settings, extra=None):
        root = tempfile.mkdtemp()
        os.mkdir(os.path.join(root, ".git"))
        folder = os.path.join(root, "Play", "Pricing")
        os.makedirs(folder)
        write_json(os.path.join(folder, "apple-prices.json"), {"source": "ASC, 3 Nov 2026", "prices": PlayTest.APPLE})
        write_json(os.path.join(folder, "play-regions.json"), {"source": "Play, version 2026/01", "regions": PlayTest.REGIONS})
        for name, body in (extra or {}).items():
            write_json(os.path.join(root, "Play", name), body)
        settings_path = os.path.join(root, "Play", "pricing.json")
        write_json(settings_path, settings)
        argv = [os.path.join(root, "Play", "prices.py"), "--settings", settings_path]
        with mock.patch.object(sys, "argv", argv), \
                mock.patch.object(play, "fetch_json", return_value={"rates": PlayTest.RATES}), \
                mock.patch.object(play, "price_level_ratios", return_value={"ZZ": (0.3, 2024)}), \
                mock.patch.object(play, "income_ratios", return_value={}), \
                mock.patch("sys.stderr"):
            play.main()
        return folder

    def test_table(self):
        folder = self.run_tool({"play": {"dir": "Pricing", "price": 4.99, "table": "app-prices.json", "newRegions": True}})
        with open(os.path.join(folder, "app-prices.json")) as f:
            table = json.load(f)
        self.assertEqual(table["source"].split("`")[1], "python3 Play/prices.py")
        self.assertEqual(table["prices"]["ZZ"], {"currency": "USD", "price": 1.99, "basis": "price level 0.30"})
        self.assertEqual(table["newRegions"], {"USD": 4.99, "EUR": 4.99})
        with open(os.path.join(folder, "prices.md")) as f:
            self.assertIn("## Countries Play adds later", f.read())

    def test_product(self):
        listing = {"package": "com.example", "product": {"productId": "com.example.full",
                                                         "listings": {"en-US": {"title": "Full", "description": "All"}}}}
        folder = self.run_tool({"appStore": {"tiers": [{"price": 4.99, "products": ["com.example.full"]}]},
                                "play": {"dir": "Pricing", "product": True}}, {"listing.json": listing})
        with open(os.path.join(folder, "iap", "com.example.full.json")) as f:
            product = json.load(f)
        self.assertEqual(product["packageName"], "com.example")
        self.assertEqual(len(product["purchaseOptions"][0]["regionalPricingAndAvailabilityConfigs"]), 8)


class ShimTest(unittest.TestCase):
    def test_a_game_shim_runs_the_tool_on_its_settings(self):
        with tempfile.TemporaryDirectory() as root:
            shim = os.path.join(root, "appstore.py")
            with open(shim, "w") as f:
                f.write("import os, runpy; os.environ.setdefault('PRICING', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pricing.json'))\n")
                f.write(f"runpy.run_path({os.path.join(HERE, 'appstore.py')!r}, init_globals={{'SHIM': __file__}}, run_name='__main__')\n")
            write_json(os.path.join(root, "pricing.json"), {"appStore": {"app": "1", "tiers": [{"price": 1.99, "products": ["a"]}]}})
            run = subprocess.run([sys.executable, shim, "--price", "2.99"], capture_output=True, text=True)
            self.assertEqual(run.returncode, 2)
            self.assertIn("pass --products with --price", run.stderr)


if __name__ == "__main__":
    unittest.main()
