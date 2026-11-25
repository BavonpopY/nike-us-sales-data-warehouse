#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
2603-389 Data Warehouse & BI System - Project 2 (Group G6)
Nike US Sales & Product Performance DW  --  Source-data enrichment generator
=============================================================================

Purpose
-------
Project 1 data covers Jan-2020 .. Dec-2021 only (9,648 usable sales lines, 554 SKUs,
4 retailer IDs).  Project 2 needs >= 3 years of history, richer dimensions and
realistic data-quality problems for the Tableau Prep ETL to solve.  This script
KEEPS the two Project 1 files untouched (they remain ETL sources as-is) and
generates the additional operational sources listed below, calibrated on the
Project 1 baseline so the 2022-2024 history continues the 2020-2021 trends.

Generated sources (all written to --out):
  S3  oms_sales_2022.csv / oms_sales_2023.csv / oms_sales_2024.csv
        New Order-Management-System extract (snake_case, ISO dates, numeric
        money, invoice numbers, promo codes, RETURN lines) + injected anomalies.
  S4  retailer_master.xlsx            (sheet Retailer_Versions, SCD-2 history)
  S5  product_price_history.csv       (list-price / lifecycle versions, SCD-2)
  S6  promotion_calendar.xlsx         (sheet Promotions, 2022-2024 campaigns)
  S7  us_geography_reference.csv      (54 city-state members + Census hierarchy)
  S8  us_holidays_retail_events.csv   (one row per date, 2019-2025)
  S9  wms_inventory_snapshot.csv      (month-end stock by SKU x account)
  S10 calendar_bounds.csv             (2 rows; seed for the Prep "New Rows" date spine)
  S11 dw_seed_special_members.xlsx    (Unknown / special members + static Dim_Channel rows)
  --  anomaly_injection_log.csv       (which rows were deliberately corrupted, and how)
  --  generation_manifest.json        (row counts, seed, parameters)

Usage
-----
  pip install pandas numpy openpyxl faker
  python generate_p2_sources.py --p1-sales "Nike US Sales Datasets.csv" \
         --p1-catalog "nike_2020_04_13_cleaned.csv" --out ./01_Data_Sources

The run is fully deterministic (seed 2569): every team member gets identical files.
"""
from __future__ import annotations

import argparse
import json
import re
from datetime import date, timedelta
from pathlib import Path

import numpy as np
import pandas as pd
from dateutil.easter import easter

SEED = 2569
FX_INR_PER_USD = 76.0          # fixed conversion for the 2020-04-13 nike.com/in catalog snapshot
SCALE_ASP_THRESHOLD = 120.0    # implied price/unit above this => 10x scaling defect in P1 rows
LOAD_START, LOAD_END = pd.Timestamp("2020-01-01"), pd.Timestamp("2024-12-31")
DTC_ID, DTC_LAUNCH = "1000001", pd.Timestamp("2022-06-01")

# ----------------------------------------------------------------------------------
# Shared business rules (identical logic is implemented in Tableau Prep - see spec)
# ----------------------------------------------------------------------------------
CATEGORY_RULES = [  # evaluated top-down, first match wins
    ("Football",      r"Mercurial|Phantom (Venom|Vision)|PhantomVNM|Tiempo"),
    ("Skateboarding", r"^Nike SB "),
    ("Tennis",        r"^NikeCourt"),
    ("Outdoor",       r"ACG"),
    ("Basketball",    r"LeBron|Kyrie|KD|^PG |Zoom Freak|AlphaDunk|Precision|Why Not|Jumpman|Proto-React|Air Jordan XXX"),
    ("Jordan Lifestyle", r"^(Air )?Jordan"),
    ("Running",       r"Pegasus|Vomero|Structure|Winflo|Zoom Fly|Vaporfly|ZoomX Vista|React Infinity|Odyssey React|"
                      r"Epic React|Epic Phantom|Free RN|Flex (RN|2020 RN|Contact)|Joyride (Run|Dual Run)|Terra Kiger|"
                      r"Wildhorse|Revolution|Renew Run|Legend React|Zoom Rival|React Phantom Run|Zoom Rise|Air Zoom Rise"),
    ("Training",      r"Metcon|SuperRep|Free TR|Flex TR|In-Season TR|Air Max Alpha|Air Max Bella|Bella Kai|Zoom Gravity|Renew Fusion"),
]
FRANCHISE_RULES = [
    ("Air Jordan",    r"^Air Jordan"),
    ("Jordan",        r"^Jordan"),
    ("Air Force 1",   r"Air Force 1|AF-1|Air Force Max"),
    ("Air Max",       r"Air Max|VaporMax|Air Max2"),
    ("Pegasus",       r"Pegasus"),
    ("Mercurial",     r"Mercurial"),
    ("Phantom",       r"Phantom (Venom|Vision)|PhantomVNM"),
    ("Tiempo",        r"Tiempo"),
    ("LeBron",        r"LeBron"),
    ("Kyrie",         r"Kyrie"),
    ("KD",            r"KD"),
    ("Metcon",        r"Metcon"),
    ("Joyride",       r"Joyride"),
    ("React",         r"React"),
    ("Blazer",        r"Blazer"),
    ("Cortez",        r"Cortez"),
    ("Huarache",      r"Huarache"),
    ("Free",          r"Free "),
    ("Zoom",          r"Zoom"),
]
SLIDE_NAME = r"Benassi|Kawa Shower|Jordan Hydro|Jordan Break|Jordan Modero|Solarsoft|Canyon|Offcourt|SFB|Victori"


def classify(name: str, rules, default: str) -> str:
    for label, pattern in rules:
        if re.search(pattern, name):
            return label
    return default


def product_type(url: str, name: str) -> str:
    m = re.search(r"/t/.*-(shoes?|boot|slide|flip-flop|flop|sandal)-[A-Za-z0-9]+/", str(url))
    if m:
        return {"shoe": "Shoe", "shoes": "Shoe", "boot": "Boot", "slide": "Slide",
                "flip-flop": "Flip-Flop", "flop": "Flip-Flop", "sandal": "Sandal"}[m.group(1)]
    return "Slide" if re.search(SLIDE_NAME, name) else "Shoe"


def money(x: pd.Series) -> pd.Series:
    return pd.to_numeric(x.astype(str).str.replace(r"[\$,%\s]", "", regex=True), errors="coerce")


# ----------------------------------------------------------------------------------
# Reference data
# ----------------------------------------------------------------------------------
STATE_REF = {  # state: (USPS code, Census region, Census division, time zone of listed city)
    "Alabama": ("AL", "South", "East South Central", "Central"), "Alaska": ("AK", "West", "Pacific", "Alaska"),
    "Arizona": ("AZ", "West", "Mountain", "Mountain (no DST)"), "Arkansas": ("AR", "South", "West South Central", "Central"),
    "California": ("CA", "West", "Pacific", "Pacific"), "Colorado": ("CO", "West", "Mountain", "Mountain"),
    "Connecticut": ("CT", "Northeast", "New England", "Eastern"), "Delaware": ("DE", "South", "South Atlantic", "Eastern"),
    "Florida": ("FL", "South", "South Atlantic", "Eastern"), "Georgia": ("GA", "South", "South Atlantic", "Eastern"),
    "Hawaii": ("HI", "West", "Pacific", "Hawaii"), "Idaho": ("ID", "West", "Mountain", "Mountain"),
    "Illinois": ("IL", "Midwest", "East North Central", "Central"), "Indiana": ("IN", "Midwest", "East North Central", "Eastern"),
    "Iowa": ("IA", "Midwest", "West North Central", "Central"), "Kansas": ("KS", "Midwest", "West North Central", "Central"),
    "Kentucky": ("KY", "South", "East South Central", "Eastern"), "Louisiana": ("LA", "South", "West South Central", "Central"),
    "Maine": ("ME", "Northeast", "New England", "Eastern"), "Maryland": ("MD", "South", "South Atlantic", "Eastern"),
    "Massachusetts": ("MA", "Northeast", "New England", "Eastern"), "Michigan": ("MI", "Midwest", "East North Central", "Eastern"),
    "Minnesota": ("MN", "Midwest", "West North Central", "Central"), "Mississippi": ("MS", "South", "East South Central", "Central"),
    "Missouri": ("MO", "Midwest", "West North Central", "Central"), "Montana": ("MT", "West", "Mountain", "Mountain"),
    "Nebraska": ("NE", "Midwest", "West North Central", "Central"), "Nevada": ("NV", "West", "Mountain", "Pacific"),
    "New Hampshire": ("NH", "Northeast", "New England", "Eastern"), "New Jersey": ("NJ", "Northeast", "Middle Atlantic", "Eastern"),
    "New Mexico": ("NM", "West", "Mountain", "Mountain"), "New York": ("NY", "Northeast", "Middle Atlantic", "Eastern"),
    "North Carolina": ("NC", "South", "South Atlantic", "Eastern"), "North Dakota": ("ND", "Midwest", "West North Central", "Central"),
    "Ohio": ("OH", "Midwest", "East North Central", "Eastern"), "Oklahoma": ("OK", "South", "West South Central", "Central"),
    "Oregon": ("OR", "West", "Pacific", "Pacific"), "Pennsylvania": ("PA", "Northeast", "Middle Atlantic", "Eastern"),
    "Rhode Island": ("RI", "Northeast", "New England", "Eastern"), "South Carolina": ("SC", "South", "South Atlantic", "Eastern"),
    "South Dakota": ("SD", "Midwest", "West North Central", "Central"), "Tennessee": ("TN", "South", "East South Central", "Eastern"),
    "Texas": ("TX", "South", "West South Central", "Central"), "Utah": ("UT", "West", "Mountain", "Mountain"),
    "Vermont": ("VT", "Northeast", "New England", "Eastern"), "Virginia": ("VA", "South", "South Atlantic", "Eastern"),
    "Washington": ("WA", "West", "Pacific", "Pacific"), "West Virginia": ("WV", "South", "South Atlantic", "Eastern"),
    "Wisconsin": ("WI", "Midwest", "East North Central", "Central"), "Wyoming": ("WY", "West", "Mountain", "Mountain"),
}
TIER1 = {"New York", "Los Angeles", "Chicago", "Houston", "Dallas", "Philadelphia", "Phoenix", "San Francisco",
         "Miami", "Atlanta", "Boston", "Seattle"}
TIER3 = {"Albany", "Anchorage", "Billings", "Boise", "Burlington", "Charleston", "Cheyenne", "Des Moines", "Fargo",
         "Jackson", "Little Rock", "Manchester", "Sioux Falls", "Wichita", "Wilmington"}
DTC_FLAGSHIP_CITIES = {"New York", "Los Angeles", "Chicago", "Houston", "Miami", "San Francisco", "Seattle",
                       "Boston", "Atlanta", "Dallas", "Las Vegas", "Denver"}


def build_geography(p1: pd.DataFrame) -> pd.DataFrame:
    g = p1[["City", "State", "Region"]].drop_duplicates().sort_values(["State", "City"]).reset_index(drop=True)
    g["state_code"] = g.State.map(lambda s: STATE_REF[s][0])
    g["census_region"] = g.State.map(lambda s: STATE_REF[s][1])
    g["census_division"] = g.State.map(lambda s: STATE_REF[s][2])
    g["time_zone"] = g.State.map(lambda s: STATE_REF[s][3])
    g["city_tier"] = np.where(g.City.isin(TIER1), "Tier 1 - Major Metro",
                     np.where(g.City.isin(TIER3), "Tier 3 - Small Market", "Tier 2 - Mid Market"))
    g["is_dtc_flagship_market"] = np.where(g.City.isin(DTC_FLAGSHIP_CITIES) & ~((g.City == "Portland")), "Y", "N")
    g = g.rename(columns={"City": "city", "State": "state_name", "Region": "sales_region"})
    g.insert(0, "geo_code", g.state_code + "-" + g.city.str.upper().str.replace(r"[^A-Z]", "", regex=True))
    return g[["geo_code", "city", "state_name", "state_code", "sales_region", "census_region",
              "census_division", "time_zone", "city_tier", "is_dtc_flagship_market"]]


def build_holidays() -> pd.DataFrame:
    def nth(y, m, wd, n):
        d = date(y, m, 1)
        return d + timedelta(days=(wd - d.weekday()) % 7 + 7 * (n - 1))

    def last(y, m, wd):
        d = (date(y, m + 1, 1) if m < 12 else date(y + 1, 1, 1)) - timedelta(days=1)
        return d - timedelta(days=(d.weekday() - wd) % 7)

    rows = []
    for y in range(2019, 2026):
        fed = [(date(y, 1, 1), "New Year's Day"), (nth(y, 1, 0, 3), "Martin Luther King Jr. Day"),
               (nth(y, 2, 0, 3), "Presidents' Day"), (last(y, 5, 0), "Memorial Day"),
               (date(y, 7, 4), "Independence Day"), (nth(y, 9, 0, 1), "Labor Day"),
               (nth(y, 10, 0, 2), "Columbus Day"), (date(y, 11, 11), "Veterans Day"),
               (nth(y, 11, 3, 4), "Thanksgiving Day"), (date(y, 12, 25), "Christmas Day")]
        if y >= 2021:
            fed.append((date(y, 6, 19), "Juneteenth"))
        tg = nth(y, 11, 3, 4)
        retail = [(date(y, 2, 14), "Valentine's Day"), (easter(y), "Easter Sunday"), (nth(y, 5, 6, 2), "Mother's Day"),
                  (nth(y, 6, 6, 3), "Father's Day"), (date(y, 10, 31), "Halloween"),
                  (tg + timedelta(days=1), "Black Friday"), (tg + timedelta(days=4), "Cyber Monday"),
                  (date(y, 12, 24), "Christmas Eve"), (date(y, 12, 31), "New Year's Eve")]
        rows += [(d, n, 1, 0) for d, n in fed] + [(d, n, 0, 1) for d, n in retail]
    h = pd.DataFrame(rows, columns=["event_date", "event_name", "is_federal_holiday", "is_retail_event"])
    h = (h.groupby("event_date", as_index=False)
          .agg(event_name=("event_name", " / ".join), is_federal_holiday=("is_federal_holiday", "max"),
               is_retail_event=("is_retail_event", "max")))
    h["event_type"] = np.select([(h.is_federal_holiday == 1) & (h.is_retail_event == 1), h.is_federal_holiday == 1],
                                ["Federal Holiday + Retail Event", "Federal Holiday"], "Retail Event")
    h["event_date"] = pd.to_datetime(h.event_date).dt.strftime("%Y-%m-%d")
    return h.sort_values("event_date").reset_index(drop=True)


def build_promotions() -> pd.DataFrame:
    rows = []
    for y in (2022, 2023, 2024):
        yy = str(y)[2:]
        # Thanksgiving = 4th Thursday of November
        first = date(y, 11, 1)
        tg = pd.Timestamp(first + timedelta(days=(3 - first.weekday()) % 7 + 21))
        mem = pd.Timestamp(date(y, 5, 31)) - pd.Timedelta(days=(date(y, 5, 31).weekday() - 0) % 7)
        clr_w = 0.40 if y == 2023 else 0.35
        clr_s = 0.45 if y == 2023 else 0.35
        rows += [
            (f"CLRW{yy}", f"Winter Clearance {y}", "Clearance", clr_w, f"{y}-01-02", f"{y}-02-15", "Outlet"),
            (f"SPR{yy}", f"Spring Sale {y}", "Seasonal Event", 0.15, f"{y}-03-15", f"{y}-04-10", "Online|In-store"),
            (f"MEM{yy}", f"Memorial Day Weekend {y}", "Holiday Event", 0.20, (mem - pd.Timedelta(days=3)).date(), mem.date(), "Online|In-store|Outlet"),
            (f"CLRS{yy}", f"Summer Clearance {y}", "Clearance", clr_s, f"{y}-06-15", f"{y}-07-15", "Outlet"),
            (f"BTS{yy}", f"Back to School {y}", "Seasonal Event", 0.15, f"{y}-07-20", f"{y}-08-31", "Online|In-store|Outlet"),
            (f"MBR{yy}", f"Member Week {y}", "Loyalty / Member", 0.20, f"{y}-09-10", f"{y}-09-16", "Online"),
            (f"BFCM{yy}", f"Black Friday - Cyber Monday {y}", "Holiday Event", 0.30, (tg - pd.Timedelta(days=2)).date(), (tg + pd.Timedelta(days=4)).date(), "Online|In-store|Outlet"),
            (f"HOL{yy}", f"Holiday Gifting {y}", "Holiday Event", 0.10, f"{y}-12-05", f"{y}-12-24", "Online|In-store"),
        ]
    p = pd.DataFrame(rows, columns=["promo_code", "promo_name", "promo_type", "discount_pct", "start_date", "end_date", "eligible_channels"])
    p["start_date"] = pd.to_datetime(p.start_date)
    p["end_date"] = pd.to_datetime(p.end_date)
    p["fiscal_year"] = "FY" + (p.start_date.dt.year + (p.start_date.dt.month >= 6).astype(int)).astype(str)
    p["funding_type"] = np.where(p.promo_type == "Clearance", "Nike-funded markdown", "Co-funded with retailer")
    return p


def build_retailers(fake) -> pd.DataFrame:
    am = [fake.name() for _ in range(8)]
    R = [
        # retailer_id, version_no, effective_from, name, type, ownership, tier, account manager, terms, hq_state, onboard_date
        ("1185732", 1, "2020-01-01", "Stride Athletic Group", "Specialty Athletic Chain", "Wholesale Partner", "Platinum", am[0], 45, "New York", "2009-03-01"),
        ("1185732", 2, "2023-03-01", "Stride Athletic Group", "Specialty Athletic Chain", "Wholesale Partner", "Platinum", am[1], 45, "New York", "2009-03-01"),
        ("1128299", 1, "2020-01-01", "PeakSport Outfitters", "Sporting Goods Retailer", "Wholesale Partner", "Gold", am[2], 60, "Texas", "2013-08-15"),
        ("1128299", 2, "2023-06-01", "PeakSport Outfitters", "Sporting Goods Retailer", "Wholesale Partner", "Platinum", am[2], 45, "Texas", "2013-08-15"),
        ("1197831", 1, "2020-01-01", "ValueMart Superstores", "Mass Merchant", "Wholesale Partner", "Gold", am[3], 60, "Ohio", "2015-02-01"),
        ("1197831", 2, "2022-06-01", "ValueMart Superstores", "Mass Merchant", "Wholesale Partner", "Silver", am[3], 60, "Ohio", "2015-02-01"),
        ("1197831", 3, "2024-06-01", "ValueMart Superstores", "Mass Merchant", "Wholesale Partner", "Bronze", am[4], 30, "Ohio", "2015-02-01"),
        ("1189833", 1, "2020-01-01", "Coastline Kicks", "Sneaker Boutique", "Wholesale Partner", "Silver", am[5], 30, "California", "2018-05-20"),
        ("1189833", 2, "2023-01-01", "Coastline Kicks", "Sneaker Boutique", "Wholesale Partner", "Gold", am[5], 45, "California", "2018-05-20"),
        (DTC_ID, 1, "2022-06-01", "Nike Direct (DTC)", "Nike-Owned Direct-to-Consumer", "Nike-Owned", "Owned Channel", "DTC Operations Team", 0, "Oregon", "2022-06-01"),
    ]
    r = pd.DataFrame(R, columns=["retailer_id", "version_no", "effective_from", "retailer_name", "retailer_type",
                                 "ownership_type", "partner_tier", "key_account_manager", "payment_terms_days",
                                 "hq_state", "onboard_date"])
    r["effective_from"] = pd.to_datetime(r.effective_from)
    r["onboard_date"] = pd.to_datetime(r.onboard_date)
    r["change_reason"] = ["Initial load", "Account manager reassigned", "Initial load", "Tier upgrade (FY24 review)",
                          "Initial load", "Tier downgrade (marketplace rationalisation)", "Tier downgrade + terms cut",
                          "Initial load", "Tier upgrade (sell-through)", "DTC channel launch (FY23)"]
    return r


def build_seed_members() -> dict:
    """Special / unknown members that every DW dimension must contain (loaded through Prep, not by SQL)."""
    hi, lo = "9999-12-31", "1900-01-01"
    return {
        "Channel": pd.DataFrame([
            (-1, "UN", "Unknown", "Unknown", "Unknown", 9),
            (1, "IS", "In-store", "Physical", "Full-Price", 1),
            (2, "ON", "Online", "Digital", "Full-Price", 2),
            (3, "OT", "Outlet", "Physical", "Off-Price", 3)],
            columns=["Channel_Key", "Channel_Code", "Channel_Name", "Channel_Group", "Price_Positioning", "Sort_Order"]),
        "Product_Unknown": pd.DataFrame([dict(
            Product_Key=-1, Product_ID="UNKNOWN", Style_Code="UNKNWN", Color_Code="000", Product_Name="Unknown Product",
            Brand_Line="Unknown", Category="Unknown", Franchise="Unknown", Product_Type="Unknown", Gender_Segment="Unknown",
            List_Price_USD=None, Price_Band="Unknown", Lifecycle_Status="Unknown", Web_Rating=None, Web_Review_Count=0,
            Rating_Status="Not Rated", Web_Discount_Pct=0, Image_Count=0, Product_URL=None, Version_No=1,
            Effective_Start_Date=lo, Effective_End_Date=hi, Is_Current=1, Row_Change_Reason="Unknown member")]),
        "Retailer_Unknown": pd.DataFrame([dict(
            Retailer_Key=-1, Retailer_ID="UNKNOWN", Retailer_Name="Unknown Retailer", Retailer_Type="Unknown",
            Ownership_Type="Unknown", Partner_Tier="Unknown", Key_Account_Manager="Unknown", Payment_Terms_Days=0,
            HQ_State="Unknown", Onboard_Date=None, Version_No=1, Effective_Start_Date=lo, Effective_End_Date=hi,
            Is_Current=1, Row_Change_Reason="Unknown member")]),
        "Geography_Unknown": pd.DataFrame([dict(
            Geography_Key=-1, Geo_Code="UNKNOWN", City="Unknown", State_Name="Unknown", State_Code="ZZ",
            Sales_Region="Unknown", Census_Region="Unknown", Census_Division="Unknown", Time_Zone="Unknown",
            City_Tier="Unknown", Is_DTC_Flagship_Market=0, City_State_Label="Unknown", Country_Code="US")]),
        "Promotion_Special": pd.DataFrame([
            (0, "NONE", "No Promotion", "No Promotion", 0.0, None, None, "All", None, "Not Applicable", 0),
            (-1, "UNKNOWN", "Unknown Promotion Code", "Unknown", 0.0, None, None, "Unknown", None, "Unknown", 0),
            (-2, "#LEGACY", "Not Captured (P1 legacy source 2020-2021)", "Not Captured", 0.0, None, None, "All", None, "Not Applicable", 0)],
            columns=["Promotion_Key", "Promo_Code", "Promo_Name", "Promo_Type", "Discount_Pct", "Start_Date", "End_Date",
                     "Eligible_Channels", "Promo_Fiscal_Year", "Funding_Type", "Promo_Duration_Days"]),
    }


# ----------------------------------------------------------------------------------
# Project 1 baseline (read-only; used for calibration)
# ----------------------------------------------------------------------------------
def load_p1(sales_path: Path, catalog_path: Path):
    s = pd.read_csv(sales_path, dtype=str, encoding="cp1252").dropna(how="all").reset_index(drop=True)
    s["units"] = money(s["Units Sold"])
    s["op_raw"] = money(s["Operating Profit"])
    s["om"] = money(s["Operating Margin"]) / 100
    s["date"] = pd.to_datetime(s["Invoice Date"], format="%d/%m/%Y")
    s["sales_raw"] = s.op_raw / s.om
    s["asp_raw"] = np.where(s.units > 0, s.sales_raw / s.units.replace(0, np.nan), np.nan)
    s["scale"] = np.where(s.asp_raw > SCALE_ASP_THRESHOLD, 10, 1)
    s["sales"] = s.sales_raw / s.scale
    s["op"] = s.op_raw / s.scale
    s["asp"] = s.sales / s.units.replace(0, np.nan)
    c = pd.read_csv(catalog_path, dtype=str)
    c["list_price_inr"] = money(c["Original Price"])
    c["category"] = c["Product Name"].map(lambda n: classify(n, CATEGORY_RULES, "Lifestyle"))
    c["franchise"] = c["Product Name"].map(lambda n: classify(n, FRANCHISE_RULES, "Other"))
    return s, c


# ----------------------------------------------------------------------------------
# SCD-2 product price / lifecycle history
# ----------------------------------------------------------------------------------
def build_price_history(cat: pd.DataFrame, rng) -> pd.DataFrame:
    base = (np.maximum(np.round(cat.list_price_inr / FX_INR_PER_USD / 5) * 5, 15) - 0.01).round(2)
    rows = []
    n = len(cat)
    inc22 = rng.random(n) < 0.60
    inc23 = rng.random(n) < 0.40
    # ~8% of SKUs are phased out: Clearance from 2023-09-01, Discontinued from 2024-03-01
    phase_out = rng.random(n) < 0.08
    pct22 = rng.choice([0.04, 0.05, 0.06, 0.08], n)
    pct23 = rng.choice([0.03, 0.04, 0.05], n)
    for i, pid in enumerate(cat["Product ID"]):
        p = base.iloc[i]
        rows.append((pid, 1, "2020-01-01", p, "Active", "Catalog snapshot 2020-04-13 (INR->USD)"))
        v = 1
        if inc22[i]:
            v += 1; p = round(np.round(p * (1 + pct22[i]) / 5) * 5 - 0.01, 2) if p > 20 else round(p * (1 + pct22[i]), 2)
            rows.append((pid, v, "2022-06-01", p, "Active", f"FY23 list-price increase {pct22[i]:.0%}"))
        if inc23[i]:
            v += 1; p = round(np.round(p * (1 + pct23[i]) / 5) * 5 - 0.01, 2) if p > 20 else round(p * (1 + pct23[i]), 2)
            rows.append((pid, v, "2023-06-01", p, "Active", f"FY24 list-price increase {pct23[i]:.0%}"))
        if phase_out[i]:
            v += 1; rows.append((pid, v, "2023-09-01", p, "Clearance", "End-of-life: moved to clearance"))
            v += 1; rows.append((pid, v, "2024-03-01", p, "Discontinued", "End-of-life: discontinued"))
    h = pd.DataFrame(rows, columns=["product_id", "version_no", "effective_from", "list_price_usd", "lifecycle_status", "change_reason"])
    h["effective_from"] = pd.to_datetime(h.effective_from)
    return h


def price_index_lookup(hist: pd.DataFrame):
    """Return f(pid array, date array) -> (list_price, lifecycle) as-of date."""
    h = hist.sort_values(["product_id", "effective_from"])
    base = h[h.version_no == 1].set_index("product_id").list_price_usd

    def asof(df: pd.DataFrame) -> pd.DataFrame:
        left = df[["product_id", "date"]].reset_index().sort_values("date")
        right = h[["product_id", "effective_from", "list_price_usd", "lifecycle_status"]].sort_values("effective_from")
        m = pd.merge_asof(left, right, left_on="date", right_on="effective_from", by="product_id", direction="backward")
        m = m.set_index("index").reindex(df.index)
        m["price_index"] = m.list_price_usd / m.product_id.map(base)
        return m[["list_price_usd", "lifecycle_status", "price_index"]]
    return asof


# ----------------------------------------------------------------------------------
# OMS sales 2022-2024
# ----------------------------------------------------------------------------------
CAT_TREND = {  # units multiplier by year
    "Running": {2022: 1.05, 2023: 1.15, 2024: 1.27}, "Jordan Lifestyle": {2022: 1.08, 2023: 1.14, 2024: 1.18},
    "Basketball": {2022: 1.00, 2023: 0.95, 2024: 0.91}, "Football": {2022: 1.10, 2023: 1.00, 2024: 1.05},
    "Training": {2022: 1.02, 2023: 1.04, 2024: 1.06}, "Tennis": {2022: 1.03, 2023: 1.06, 2024: 1.09},
    "Skateboarding": {2022: 1.00, 2023: 1.01, 2024: 1.00}, "Outdoor": {2022: 1.04, 2023: 1.08, 2024: 1.10},
    "Lifestyle": {2022: 1.01, 2023: 1.02, 2024: 0.98},
}
AIRMAX_TREND = {2022: 1.00, 2023: 0.94, 2024: 0.85}
REGION_GROWTH = {"Southeast": 1.04, "West": 1.02, "South": 1.03, "Northeast": 1.00, "Midwest": 0.98}
SEASON = {1: .90, 2: .90, 3: 1.0, 4: 1.0, 5: 1.0, 6: 1.0, 7: 1.10, 8: 1.15, 9: 1.0, 10: 1.0, 11: 1.20, 12: 1.25}
CH_ROW_GROWTH = {"Online": 1.05, "In-store": 1.01, "Outlet": 0.97}
RET_ROW_GROWTH = {"1185732": 1.00, "1128299": 1.02, "1197831": 0.90, "1189833": 1.05}
MARGIN_DRIFT = {"Online": {2022: .010, 2023: .015, 2024: .020}, "In-store": {2022: 0, 2023: -.005, 2024: -.010},
                "Outlet": {2022: -.010, 2023: -.040, 2024: -.025}}
RETURN_RATE = {"Online": {2022: .10, 2023: .12, 2024: .14}, "In-store": {2022: .04, 2023: .04, 2024: .045},
               "Outlet": {2022: .02, 2023: .02, 2024: .02}}
DTC_ROWS = {2022: {"Online": 350, "In-store": 150}, 2023: {"Online": 900, "In-store": 350}, 2024: {"Online": 1300, "In-store": 450}}
CH_CODE = {"In-store": "IS", "Online": "ON", "Outlet": "OT"}


def build_oms(p1: pd.DataFrame, cat: pd.DataFrame, hist: pd.DataFrame, promos: pd.DataFrame, rng) -> pd.DataFrame:
    base = p1[(p1.date.dt.year == 2021) & (p1.units > 0)].copy()
    base = base.merge(cat[["Product ID", "category", "franchise"]], on="Product ID", how="left")
    asof = price_index_lookup(hist)
    frames = []
    for y in (2022, 2023, 2024):
        k = y - 2021
        parts = []
        for (rid, ch), grp in base.groupby(["Retailer ID", "Sales Method"]):
            factor = CH_ROW_GROWTH[ch] ** k * RET_ROW_GROWTH[rid] ** k
            if rid == "1185732" and ch == "Online" and y >= 2023:   # DTC cannibalisation of the largest partner
                factor *= 0.95 if y == 2023 else 0.90
            n = int(round(len(grp) * factor))
            idx = rng.choice(grp.index.values, size=n, replace=n > len(grp))
            parts.append(base.loc[idx].assign(retailer_id=rid))
        # Nike Direct (DTC) rows: Online everywhere, In-store only in flagship markets
        for ch, n in DTC_ROWS[y].items():
            pool = base[base["Sales Method"] == ch]
            if ch == "In-store":
                pool = pool[pool.City.isin(DTC_FLAGSHIP_CITIES)]
            if y == 2022:
                pool = pool[pool.date.dt.month >= 6]
            idx = rng.choice(pool.index.values, size=n, replace=True)
            parts.append(base.loc[idx].assign(retailer_id=DTC_ID))
        d = pd.concat(parts, ignore_index=True)
        # move to target year with +-3 day jitter inside the month
        jitter = rng.integers(-3, 4, len(d))
        day = np.clip(d.date.dt.day.values + jitter, 1, 28 + 0 * jitter)
        day = np.where(d.date.dt.day.values > 28, d.date.dt.day.values, day)   # keep 29-31 as-is (valid in target year)
        d["date"] = pd.to_datetime(dict(year=y, month=d.date.dt.month, day=day), errors="coerce")
        d = d.dropna(subset=["date"])
        frames.append(d)
    d = pd.concat(frames, ignore_index=True).rename(columns={"Product ID": "product_id", "Sales Method": "channel"})
    d["year"] = d.date.dt.year
    d["is_dtc"] = d.retailer_id == DTC_ID

    # price list version as of invoice date (SCD-2) ; discontinued SKUs stop selling
    pi = asof(d.rename(columns={"product_id": "product_id"})[["product_id", "date"]])
    d = pd.concat([d, pi], axis=1)
    d = d[d.lifecycle_status != "Discontinued"].copy()

    # promotions
    d["promo_code"] = ""
    d["discount_pct"] = 0.0
    for _, p in promos.iterrows():
        m = d.date.between(p.start_date, p.end_date) & d.channel.isin(p.eligible_channels.split("|"))
        m &= rng.random(len(d)) < 0.65
        d.loc[m, "promo_code"] = p.promo_code
        d.loc[m, "discount_pct"] = p.discount_pct

    # units
    cat_mult = np.array([CAT_TREND[c][y] for c, y in zip(d.category, d.year)])
    cat_mult *= np.where(d.franchise.eq("Air Max"), d.year.map(AIRMAX_TREND), 1.0)
    wc = (d.category == "Football") & (d.year == 2022) & d.date.dt.month.isin([11, 12])        # FIFA World Cup 2022
    reg = np.array([REGION_GROWTH[r] ** (y - 2021) for r, y in zip(d.Region, d.year)])
    season = d.date.dt.month.map(SEASON).values
    uplift = 1 + 1.5 * d.discount_pct.values
    dtc = np.where(d.is_dtc, 0.55, 1.0)
    units = d.units.values * cat_mult * np.where(wc, 1.6, 1.0) * reg * season * uplift * dtc * rng.lognormal(0, 0.18, len(d))
    d["qty"] = np.maximum(1, np.round(units)).astype(int)

    # price (wholesale/realised, before promo); DTC sells at retail (~1.8x wholesale)
    ch_adj = np.where((d.channel == "Outlet") & (d.year == 2023), 0.97, 1.0)
    ch_adj = ch_adj * np.where(d.lifecycle_status.eq("Clearance") & d.channel.eq("Outlet"), 0.80, 1.0)
    ch_adj = ch_adj * np.where(d.is_dtc, 1.80, 1.0)
    d["unit_price"] = np.round(d.asp.values * d.price_index.values * ch_adj * rng.normal(1, 0.03, len(d)), 2)
    d["unit_price"] = d.unit_price.clip(lower=4.99)

    # margin
    drift = np.array([MARGIN_DRIFT[c][y] for c, y in zip(d.channel, d.year)])
    om = d.om.values + drift + np.where(d.is_dtc, 0.10, 0) - 0.6 * d.discount_pct.values + rng.normal(0, 0.015, len(d))
    d["om_new"] = np.clip(om, 0.05, 0.75)

    d["net_amount"] = np.round(d.qty * d.unit_price * (1 - d.discount_pct), 2)
    d["operating_profit"] = np.round(d.net_amount * d.om_new, 2)
    d["operating_margin"] = np.round(d.operating_profit / d.net_amount, 4)
    d["line_type"] = "SALE"
    d = d.sort_values(["date", "retailer_id", "State", "City", "channel", "product_id"]).reset_index(drop=True)

    # invoice numbering: one invoice per retailer x day x city x channel
    d["inv_grp"] = d.groupby(["date", "retailer_id", "State", "City", "channel"], sort=False).ngroup()
    d["invoice_line_no"] = d.groupby("inv_grp").cumcount() + 1
    inv = d.drop_duplicates("inv_grp")[["inv_grp", "year", "channel"]].copy()
    inv["seq"] = inv.groupby(["year", "channel"]).cumcount() + 1
    inv["invoice_no"] = "NK-" + inv.channel.map(CH_CODE) + "-" + inv.year.astype(str) + "-" + inv.seq.map("{:07d}".format)
    d = d.merge(inv[["inv_grp", "invoice_no"]], on="inv_grp")
    d["ref_invoice_no"] = ""

    # RETURN lines (credit memos)
    rate = np.array([RETURN_RATE[c][y] for c, y in zip(d.channel, d.year)])
    rate = np.where(d.is_dtc & d.channel.eq("Online"), 0.15, rate)
    has_ret = rng.random(len(d)) < rate / 0.4
    r = d[has_ret].copy()
    r["qty"] = -np.maximum(1, np.round(r.qty * rng.uniform(0.2, 0.6, len(r)))).astype(int)
    r["date"] = r.date + pd.to_timedelta(rng.integers(3, 31, len(r)), unit="D")
    r = r[r.date <= LOAD_END].copy()
    r["year"] = r.date.dt.year
    r["ref_invoice_no"] = r.invoice_no
    r["line_type"] = "RETURN"
    r["net_amount"] = np.round(r.qty * r.unit_price * (1 - r.discount_pct), 2)
    r["operating_profit"] = np.round(r.net_amount * r.om_new, 2)
    r = r.sort_values(["date", "ref_invoice_no"]).reset_index(drop=True)
    r["seq"] = r.groupby(["year", "channel"]).cumcount() + 1
    r["invoice_no"] = "CM-" + r.channel.map(CH_CODE) + "-" + r.year.astype(str) + "-" + r.seq.map("{:07d}".format)
    r["invoice_line_no"] = 1
    out = pd.concat([d, r], ignore_index=True).sort_values(["date", "invoice_no", "invoice_line_no"]).reset_index(drop=True)

    out = pd.DataFrame({
        "invoice_no": out.invoice_no, "invoice_line_no": out.invoice_line_no, "line_type": out.line_type,
        "ref_invoice_no": out.ref_invoice_no, "invoice_date": out.date.dt.strftime("%Y-%m-%d"),
        "retailer_id": out.retailer_id, "sales_channel": out.channel, "city": out.City, "state": out.State,
        "product_id": out.product_id, "promo_code": out.promo_code, "quantity": out.qty,
        "unit_price": out.unit_price.map("{:.2f}".format), "discount_pct": out.discount_pct.map("{:.2f}".format),
        "net_amount": out.net_amount.map("{:.2f}".format), "operating_profit": out.operating_profit.map("{:.2f}".format),
        "operating_margin": out.operating_margin.map("{:.4f}".format), "currency": "USD", "source_system": "OMS",
    })
    return out


# ----------------------------------------------------------------------------------
# Anomaly injection (documented in anomaly_injection_log.csv)
# ----------------------------------------------------------------------------------
def inject_oms_anomalies(o: pd.DataFrame, cat_ids: list, rng):
    o = o.copy()
    log = []
    n = len(o)

    def pick(frac, mask=None, exclude=None):
        pool = np.arange(n) if mask is None else np.flatnonzero(mask)
        if exclude is not None:
            pool = np.setdiff1d(pool, exclude)
        k = max(1, int(round(frac * n)))
        return rng.choice(pool, size=min(k, len(pool)), replace=False)

    def note(idx, code, desc):
        for i in idx:
            log.append((o.at[i, "invoice_no"], int(o.at[i, "invoice_line_no"]), code, desc))

    used = np.array([], dtype=int)
    # A2 inconsistent channel spelling/casing/whitespace
    i = pick(0.03); used = np.union1d(used, i)
    variants = {"Online": ["online", "ONLINE ", " Online", "On-line"], "In-store": ["in-store", "In Store", "IN-STORE", " in store "],
                "Outlet": ["OUTLET", "outlet ", "Outlet Store", " Outlet"]}
    o.loc[i, "sales_channel"] = [rng.choice(variants[c]) for c in o.loc[i, "sales_channel"]]
    note(i, "A02_CHANNEL_FORMAT", "sales_channel with casing/whitespace/spelling variants")
    # A3 missing channel
    i = pick(0.01, exclude=used); used = np.union1d(used, i)
    o.loc[i, "sales_channel"] = ""
    note(i, "A03_CHANNEL_NULL", "sales_channel blank - recover from invoice_no channel code")
    # A4 state as USPS code
    i = pick(0.04); o.loc[i, "state"] = o.loc[i, "state"].map(lambda s: STATE_REF[s][0])
    note(i, "A04_STATE_CODE", "state given as USPS code instead of full name")
    # A5 city casing / whitespace
    i = pick(0.03); o.loc[i, "city"] = [rng.choice([c.upper(), c.lower(), f"  {c}", f"{c}  "]) for c in o.loc[i, "city"]]
    note(i, "A05_CITY_FORMAT", "city with casing/leading-trailing whitespace")
    # A13 missing city
    i = pick(0.003); o.loc[i, "city"] = ""
    note(i, "A13_CITY_NULL", "city blank - impute when state has exactly one city in geography reference")
    # A6 malformed product id
    i = pick(0.02); used6 = i
    o.loc[i, "product_id"] = [rng.choice([p.lower(), p.replace("-", ""), f" {p} ", p.lower().replace("-", " ")]) for p in o.loc[i, "product_id"]]
    note(i, "A06_PRODUCT_ID_FORMAT", "product_id lower-case / missing hyphen / padded")
    # A7 unknown product id (late-arriving / not in catalog)
    i = pick(0.002, exclude=used6)
    o.loc[i, "product_id"] = [f"DX{rng.integers(1000, 9999)}-{rng.integers(1, 999):03d}" for _ in i]
    note(i, "A07_PRODUCT_UNKNOWN", "product_id not in catalog -> Unknown member (-1)")
    # A12 unknown retailer
    i = pick(0.001); o.loc[i, "retailer_id"] = "1199999"
    note(i, "A12_RETAILER_UNKNOWN", "retailer_id not in retailer master -> Unknown member (-1)")
    # A8 missing operating margin
    i = pick(0.01); o.loc[i, "operating_margin"] = ""
    note(i, "A08_MARGIN_NULL", "operating_margin blank - recompute = operating_profit / net_amount")
    # A9 unit price keyed in cents
    i = pick(0.003, mask=o.line_type.eq("SALE").values)
    o.loc[i, "unit_price"] = (pd.to_numeric(o.loc[i, "unit_price"]) * 100).map("{:.2f}".format)
    note(i, "A09_PRICE_IN_CENTS", "unit_price keyed in cents (x100) - divide by 100 when > 1000")
    # A14 legacy date format
    i = pick(0.02)
    o.loc[i, "invoice_date"] = pd.to_datetime(o.loc[i, "invoice_date"]).dt.strftime("%m/%d/%Y")
    note(i, "A14_DATE_FORMAT", "invoice_date in MM/DD/YYYY instead of ISO yyyy-MM-dd")
    # A10 out-of-window (typo) dates
    i = pick(0.001, mask=o.invoice_date.str.match(r"^\d{4}-").values)
    typo = {"2022": "2202", "2023": "2032", "2024": "2042"}
    o.loc[i, "invoice_date"] = [typo[v[:4]] + v[4:] for v in o.loc[i, "invoice_date"]]
    note(i, "A10_DATE_OUT_OF_RANGE", "invoice_date year digits transposed (e.g. 2024->2042) - reject to audit")
    # A1 exact duplicates (appended at the end of the year file, as a re-sent extract batch would be)
    i = pick(0.006)
    dups = o.loc[i].copy()
    note(i, "A01_DUPLICATE_LINE", "exact duplicate line re-sent by OMS - remove")
    o = pd.concat([o, dups], ignore_index=True)
    return o, pd.DataFrame(log, columns=["invoice_no", "invoice_line_no", "anomaly_code", "description"])


# ----------------------------------------------------------------------------------
# WMS month-end inventory snapshot (periodic snapshot -> semi-additive measures)
# ----------------------------------------------------------------------------------
def build_inventory(p1: pd.DataFrame, oms_clean: pd.DataFrame, hist: pd.DataFrame, rng):
    a = p1[p1.units > 0][["Product ID", "Retailer ID", "date", "units", "sales", "op"]].rename(
        columns={"Product ID": "product_id", "Retailer ID": "retailer_id"})
    b = oms_clean.assign(date=pd.to_datetime(oms_clean.invoice_date), units=oms_clean.quantity,
                         sales=pd.to_numeric(oms_clean.net_amount), op=pd.to_numeric(oms_clean.operating_profit))
    b = b[["product_id", "retailer_id", "date", "units", "sales", "op"]]
    t = pd.concat([a, b], ignore_index=True)
    t["month"] = t.date.dt.to_period("M")
    cost = t.groupby("product_id").apply(lambda g: max((g.sales - g.op).sum() / max(g.units.sum(), 1), 3.0), include_groups=False)
    dem = t.groupby(["product_id", "retailer_id", "month"]).units.sum()
    disc = hist[hist.lifecycle_status == "Discontinued"].set_index("product_id").effective_from.dt.to_period("M")
    months = pd.period_range("2020-01", "2024-12", freq="M")
    rows = []
    for (pid, rid), g in dem.groupby(level=[0, 1]):
        g = g.droplevel([0, 1])
        start = g.index.min()
        stop = min(disc.get(pid, months[-1]) + 2, months[-1])
        rng_m = [m for m in months if start <= m <= stop]
        yearly = g.groupby(g.index.year).sum() / 12.0
        on_hand = None
        for m in rng_m:
            plan = max(yearly.get(m.year, yearly.mean()), 1.0)
            cover = 3.2 if pd.Period("2022-06", "M") <= m <= pd.Period("2023-08", "M") else \
                    2.4 if pd.Period("2023-09", "M") <= m <= pd.Period("2023-12", "M") else \
                    1.8 if m.year == 2024 else 2.0
            if on_hand is None:
                on_hand = int(round(plan * cover))
            shipped = int(g.get(m, 0))
            if pid in disc and m >= disc[pid]:
                receipts = 0
            else:
                receipts = int(max(0, round((plan * cover + plan - on_hand) * rng.normal(1, 0.12))))
            end = on_hand + receipts - shipped
            stockout = 0
            if end < 0:
                stockout = int(min(30, round(30 * (-end) / max(shipped, 1)) + 1))
                end = 0
            on_order = 0 if (pid in disc and m >= disc[pid] - 1) else int(round(plan * rng.uniform(0.5, 1.2)))
            unit_cost = round(cost[pid] * (1.03 ** (m.year - 2020)), 2)
            rows.append((m.to_timestamp(how="end").strftime("%Y-%m-%d"), pid, rid, end, on_order, receipts, shipped, stockout, unit_cost))
            on_hand = end
    inv = pd.DataFrame(rows, columns=["snapshot_date", "sku", "account_id", "on_hand_qty", "on_order_qty",
                                      "received_qty", "shipped_qty", "stockout_days", "std_unit_cost_usd"])
    inv["extract_ts"] = pd.to_datetime(inv.snapshot_date) + pd.Timedelta(hours=23, minutes=15)
    log = []
    # W1 negative on-hand from cycle-count adjustments
    i = rng.choice(len(inv), size=int(0.002 * len(inv)), replace=False)
    inv.loc[i, "on_hand_qty"] = -rng.integers(1, 20, len(i))
    log += [("WMS", f"{inv.at[k,'snapshot_date']}|{inv.at[k,'sku']}|{inv.at[k,'account_id']}", "W01_NEGATIVE_ON_HAND",
             "on_hand_qty < 0 (cycle-count adjustment) - floor at 0") for k in i]
    # W2 lower-case SKU
    i = rng.choice(len(inv), size=int(0.01 * len(inv)), replace=False)
    inv.loc[i, "sku"] = inv.loc[i, "sku"].str.lower()
    log += [("WMS", f"{inv.at[k,'snapshot_date']}|{inv.at[k,'sku']}|{inv.at[k,'account_id']}", "W02_SKU_CASE",
             "sku lower-case - UPPER()") for k in i]
    # W3 re-extracted snapshot rows (keep latest extract_ts)
    i = rng.choice(len(inv), size=int(0.003 * len(inv)), replace=False)
    re_ex = inv.loc[i].copy()
    inv.loc[i, "on_hand_qty"] = inv.loc[i, "on_hand_qty"] + rng.integers(5, 40, len(i))   # stale (earlier) version is wrong
    inv.loc[i, "extract_ts"] = inv.loc[i, "extract_ts"] - pd.Timedelta(hours=20)
    log += [("WMS", f"{inv.at[k,'snapshot_date']}|{inv.at[k,'sku']}|{inv.at[k,'account_id']}", "W03_DUPLICATE_SNAPSHOT",
             "two extracts for same SKU x account x month - keep latest extract_ts") for k in i]
    inv = pd.concat([inv, re_ex], ignore_index=True)
    inv["extract_ts"] = inv.extract_ts.dt.strftime("%Y-%m-%d %H:%M:%S")
    inv = inv.sort_values(["snapshot_date", "account_id", "sku", "extract_ts"]).reset_index(drop=True)
    return inv, pd.DataFrame(log, columns=["invoice_no", "invoice_line_no", "anomaly_code", "description"])


# ----------------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--p1-sales", required=True)
    ap.add_argument("--p1-catalog", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(SEED)
    try:
        from faker import Faker
        fake = Faker("en_US"); Faker.seed(SEED)
    except ImportError:          # Faker is optional; fall back to fixed fictional names
        class _F:
            _n = iter(["Avery Collins", "Jordan Pratt", "Morgan Ellis", "Riley Hayes", "Casey Monroe",
                       "Taylor Brooks", "Quinn Foster", "Drew Sullivan"])
            def name(self): return next(self._n)
        fake = _F()

    p1, cat = load_p1(Path(a.p1_sales), Path(a.p1_catalog))

    geo = build_geography(p1); geo.to_csv(out / "us_geography_reference.csv", index=False)
    hol = build_holidays(); hol.to_csv(out / "us_holidays_retail_events.csv", index=False)
    pd.DataFrame({"calendar_date": ["2019-01-01", "2025-12-31"]}).to_csv(out / "calendar_bounds.csv", index=False)
    promos = build_promotions()
    ret = build_retailers(fake)
    hist = build_price_history(cat, rng)
    h_out = hist.assign(effective_from=hist.effective_from.dt.strftime("%Y-%m-%d"))
    h_out.to_csv(out / "product_price_history.csv", index=False)

    with pd.ExcelWriter(out / "retailer_master.xlsx", engine="openpyxl") as xw:
        ret.to_excel(xw, sheet_name="Retailer_Versions", index=False)
    with pd.ExcelWriter(out / "promotion_calendar.xlsx", engine="openpyxl") as xw:
        promos.to_excel(xw, sheet_name="Promotions", index=False)
    with pd.ExcelWriter(out / "dw_seed_special_members.xlsx", engine="openpyxl") as xw:
        for sheet, df in build_seed_members().items():
            df.to_excel(xw, sheet_name=sheet, index=False)

    oms = build_oms(p1, cat, hist, promos, rng)
    inv, inv_log = build_inventory(p1, oms, hist, rng)
    oms_dirty, oms_log = inject_oms_anomalies(oms, cat["Product ID"].tolist(), rng)

    # split by the year embedded in the invoice number (stable even when the date is corrupted)
    oms_dirty["_y"] = oms_dirty.invoice_no.str.extract(r"-(\d{4})-")[0]
    files = {}
    for y, g in oms_dirty.groupby("_y"):
        f = out / f"oms_sales_{y}.csv"
        g.drop(columns="_y").to_csv(f, index=False)
        files[f.name] = len(g)
    inv.to_csv(out / "wms_inventory_snapshot.csv", index=False)
    log = pd.concat([oms_log.assign(source="OMS"), inv_log.assign(source="WMS")], ignore_index=True)
    log.to_csv(out / "anomaly_injection_log.csv", index=False)

    manifest = {
        "seed": SEED, "fx_inr_per_usd": FX_INR_PER_USD, "scale_asp_threshold_usd": SCALE_ASP_THRESHOLD,
        "p1_rows_nonblank": int(len(p1)), "p1_rows_scale_defect": int((p1.scale == 10).sum()),
        "oms_files": files, "oms_clean_lines": int(len(oms)),
        "oms_sale_lines": int((oms.line_type == "SALE").sum()), "oms_return_lines": int((oms.line_type == "RETURN").sum()),
        "inventory_rows": int(len(inv)), "geography_members": int(len(geo)), "holiday_dates": int(len(hol)),
        "promotions": int(len(promos)), "retailer_versions": int(len(ret)), "product_versions": int(len(hist)),
        "anomalies": log.anomaly_code.value_counts().sort_index().to_dict(),
    }
    (out / "generation_manifest.json").write_text(json.dumps(manifest, indent=2))
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
