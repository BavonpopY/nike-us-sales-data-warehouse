#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
2603-389 Project 2 (G6) - Reference ETL ("golden" implementation of the Tableau Prep flow)
==========================================================================================
This script re-implements, rule for rule, the Source-to-Target Mapping (STTM) that the
Tableau Prep flow `2603389_2569_P2_G6.tflx` executes.  It exists for two reasons:

 1. Reconciliation  - after the Prep flow loads SQL Server, compare row counts and
    totals with expected_load_reconciliation.csv (Section 7 of the spec).
 2. Parallel work   - the dashboard sub-team can build Tableau worksheets on the golden
    CSVs while the ETL sub-team is still building the Prep flow.

It is NOT the submitted ETL.  The course deliverable is the Prep packaged flow.

Usage:  python reference_etl_check.py --src ./01_Data_Sources --p1-sales "Nike US Sales Datasets.csv" \
                                      --p1-catalog nike_2020_04_13_cleaned.csv --out ./99_Reference_Golden_Output
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

import numpy as np
import pandas as pd

from generate_p2_sources import CATEGORY_RULES, FRANCHISE_RULES, classify, product_type

HIGH_DATE = pd.Timestamp("2262-04-11")      # pandas max; written out as 9999-12-31
LOAD_TS = pd.Timestamp("2026-11-16 08:00:00")


def num(s):
    return pd.to_numeric(s.astype(str).str.replace(r"[\$,%\s]", "", regex=True), errors="coerce")


def price_band(p):
    return np.select([p.isna(), p < 75, p < 125, p < 175], ["Unknown", "Entry (<$75)", "Core ($75-$124)", "Premium ($125-$174)"],
                     "Elite ($175+)")


def scd2_close(df, nk, start):
    """Self-join technique used in Prep: End = next version's start - 1 day; current = 9999-12-31."""
    df = df.sort_values([nk, start]).copy()
    df["Version_No"] = df.groupby(nk).cumcount() + 1
    nxt = df[[nk, "Version_No", start]].copy()
    nxt["Version_No"] -= 1
    df = df.merge(nxt.rename(columns={start: "_next_start"}), on=[nk, "Version_No"], how="left")
    df["Effective_End_Date"] = (df._next_start - pd.Timedelta(days=1)).fillna(HIGH_DATE)
    df["Is_Current"] = (df.Effective_End_Date == HIGH_DATE).astype(int)
    return df.drop(columns="_next_start")


def range_lookup(fact, dim, fact_nk, dim_nk, fact_date, key):
    """Prep join: fact_nk = dim_nk AND fact_date >= Effective_Start_Date AND fact_date <= Effective_End_Date (left join)."""
    m = fact[[fact_nk, fact_date]].reset_index().merge(
        dim[[dim_nk, "Effective_Start_Date", "Effective_End_Date", key]], left_on=fact_nk, right_on=dim_nk, how="left")
    m = m[(m[fact_date] >= m.Effective_Start_Date) & (m[fact_date] <= m.Effective_End_Date)]
    assert not m["index"].duplicated().any(), f"SCD2 overlap in {key}"
    return fact.index.map(m.set_index("index")[key]).fillna(-1).astype(int)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--p1-sales", required=True)
    ap.add_argument("--p1-catalog", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    src, out = Path(a.src), Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    seed = pd.read_excel(src / "dw_seed_special_members.xlsx", sheet_name=None)
    rejects = []

    # ===================== DIM_DATE  (S10 + New Rows + S8) ============================
    d = pd.DataFrame({"Full_Date": pd.date_range("2019-01-01", "2025-12-31", freq="D")})
    hol = pd.read_csv(src / "us_holidays_retail_events.csv", parse_dates=["event_date"])
    d["Date_Key"] = d.Full_Date.dt.strftime("%Y%m%d").astype(int)
    d["Day_Of_Week_No"] = d.Full_Date.dt.dayofweek + 1                    # ISO 1=Mon..7=Sun
    d["Day_Name"] = d.Full_Date.dt.day_name()
    d["Day_Name_Short"] = d.Day_Name.str[:3]
    d["Is_Weekend"] = (d.Day_Of_Week_No >= 6).astype(int)
    d["Day_Of_Month"] = d.Full_Date.dt.day
    d["Day_Of_Year"] = d.Full_Date.dt.dayofyear
    d["ISO_Week_No"] = d.Full_Date.dt.isocalendar().week.astype(int)
    d["Week_Start_Date"] = d.Full_Date - pd.to_timedelta(d.Day_Of_Week_No - 1, unit="D")
    d["Month_No"] = d.Full_Date.dt.month
    d["Month_Name"] = d.Full_Date.dt.month_name()
    d["Month_Name_Short"] = d.Month_Name.str[:3]
    d["Year_Month"] = d.Full_Date.dt.strftime("%Y-%m")
    d["Quarter_No"] = d.Full_Date.dt.quarter
    d["Calendar_Year"] = d.Full_Date.dt.year
    d["Quarter_Label"] = d.Calendar_Year.astype(str) + " Q" + d.Quarter_No.astype(str)
    d["Is_Month_End"] = d.Full_Date.dt.is_month_end.astype(int)
    d["Fiscal_Year"] = d.Calendar_Year + (d.Month_No >= 6).astype(int)
    d["Fiscal_Year_Label"] = "FY" + d.Fiscal_Year.astype(str)
    d["Fiscal_Month_No"] = (d.Month_No + 6) % 12 + 1
    d["Fiscal_Quarter_No"] = (d.Fiscal_Month_No - 1) // 3 + 1
    d["Fiscal_Quarter_Label"] = "FY" + d.Fiscal_Year.astype(str).str[2:] + " Q" + d.Fiscal_Quarter_No.astype(str)
    d["Season"] = d.Month_No.map({12: "Winter", 1: "Winter", 2: "Winter", 3: "Spring", 4: "Spring", 5: "Spring",
                                  6: "Summer", 7: "Summer", 8: "Summer", 9: "Fall", 10: "Fall", 11: "Fall"})
    d = d.merge(hol, left_on="Full_Date", right_on="event_date", how="left")
    d["Is_Federal_Holiday"] = d.is_federal_holiday.fillna(0).astype(int)
    d["Is_Retail_Event"] = d.is_retail_event.fillna(0).astype(int)
    d["Holiday_Event_Name"] = d.event_name
    dim_date = d.drop(columns=["event_date", "event_name", "is_federal_holiday", "is_retail_event", "event_type"])

    # ===================== DIM_GEOGRAPHY  (S7) =========================================
    g = pd.read_csv(src / "us_geography_reference.csv").sort_values(["state_name", "city"]).reset_index(drop=True)
    dim_geo = pd.DataFrame({
        "Geography_Key": np.arange(1, len(g) + 1), "Geo_Code": g.geo_code, "City": g.city, "State_Name": g.state_name,
        "State_Code": g.state_code, "Sales_Region": g.sales_region, "Census_Region": g.census_region,
        "Census_Division": g.census_division, "Time_Zone": g.time_zone, "City_Tier": g.city_tier,
        "Is_DTC_Flagship_Market": (g.is_dtc_flagship_market == "Y").astype(int),
        "City_State_Label": g.city + ", " + g.state_code, "Country_Code": "US"})
    dim_geo = pd.concat([seed["Geography_Unknown"], dim_geo], ignore_index=True)

    # ===================== DIM_CHANNEL (S11 sheet Channel) ============================
    dim_channel = seed["Channel"]

    # ===================== DIM_PROMOTION  (S6 + S11) ==================================
    pr = pd.read_excel(src / "promotion_calendar.xlsx").sort_values(["start_date", "promo_code"]).reset_index(drop=True)
    dim_promo = pd.DataFrame({
        "Promotion_Key": np.arange(1, len(pr) + 1), "Promo_Code": pr.promo_code, "Promo_Name": pr.promo_name,
        "Promo_Type": pr.promo_type, "Discount_Pct": pr.discount_pct, "Start_Date": pr.start_date, "End_Date": pr.end_date,
        "Eligible_Channels": pr.eligible_channels, "Promo_Fiscal_Year": pr.fiscal_year, "Funding_Type": pr.funding_type,
        "Promo_Duration_Days": (pr.end_date - pr.start_date).dt.days + 1})
    dim_promo = pd.concat([seed["Promotion_Special"], dim_promo], ignore_index=True)

    # ===================== DIM_RETAILER  (S4, SCD-2) ===================================
    r = pd.read_excel(src / "retailer_master.xlsx", dtype={"retailer_id": str})
    r = r.rename(columns={"retailer_id": "Retailer_ID", "effective_from": "Effective_Start_Date"})
    r = scd2_close(r, "Retailer_ID", "Effective_Start_Date")
    r = r.sort_values(["Retailer_ID", "Version_No"]).reset_index(drop=True)
    dim_ret = pd.DataFrame({
        "Retailer_Key": np.arange(1, len(r) + 1), "Retailer_ID": r.Retailer_ID, "Retailer_Name": r.retailer_name.str.strip(),
        "Retailer_Type": r.retailer_type, "Ownership_Type": r.ownership_type, "Partner_Tier": r.partner_tier,
        "Key_Account_Manager": r.key_account_manager, "Payment_Terms_Days": r.payment_terms_days, "HQ_State": r.hq_state,
        "Onboard_Date": r.onboard_date, "Version_No": r.Version_No, "Effective_Start_Date": r.Effective_Start_Date,
        "Effective_End_Date": r.Effective_End_Date, "Is_Current": r.Is_Current, "Row_Change_Reason": r.change_reason})
    dim_ret = pd.concat([seed["Retailer_Unknown"], dim_ret], ignore_index=True)
    for c in ["Effective_Start_Date", "Effective_End_Date", "Onboard_Date"]:
        dim_ret[c] = pd.to_datetime(dim_ret[c].replace("9999-12-31", HIGH_DATE))

    # ===================== DIM_PRODUCT  (S2 + S5, SCD-2) ===============================
    c = pd.read_csv(src.parent / a.p1_catalog if not Path(a.p1_catalog).exists() else a.p1_catalog, dtype=str)
    c["Product ID"] = c["Product ID"].str.strip().str.upper()
    h = pd.read_csv(src / "product_price_history.csv", parse_dates=["effective_from"])
    h = h.rename(columns={"product_id": "Product_ID", "effective_from": "Effective_Start_Date"})
    h = scd2_close(h, "Product_ID", "Effective_Start_Date")
    p = h.merge(c, left_on="Product_ID", right_on="Product ID", how="inner")
    name = p["Product Name"].str.replace("®", "", regex=False).str.replace(r"\s+", " ", regex=True).str.strip()
    desc = p["Description"].str.lower().fillna("")
    rating = pd.to_numeric(p["Rating"], errors="coerce")
    p = p.sort_values(["Product_ID", "Version_No"]).reset_index(drop=True)
    dim_prod = pd.DataFrame({
        "Product_Key": np.arange(1, len(p) + 1), "Product_ID": p.Product_ID,
        "Style_Code": p.Product_ID.str.extract(r"^([A-Z0-9]{6})-")[0], "Color_Code": p.Product_ID.str[-3:],
        "Product_Name": name.values,
        "Brand_Line": np.where(name.str.contains(r"^(?:Air )?Jordan", regex=True).values, "Jordan", "Nike"),
        "Category": name.map(lambda n: classify(n, CATEGORY_RULES, "Lifestyle")).values,
        "Franchise": name.map(lambda n: classify(n, FRANCHISE_RULES, "Other")).values,
        "Product_Type": [product_type(u, n) for u, n in zip(p.URL, name)],
        "Gender_Segment": np.select([desc.str.contains("women", regex=False), desc.str.contains(r"\bmen's", regex=True)],
                                    ["Women's", "Men's"], "Unisex"),
        "List_Price_USD": p.list_price_usd.values, "Price_Band": price_band(p.list_price_usd),
        "Lifecycle_Status": p.lifecycle_status.values, "Web_Rating": rating.values,
        "Web_Review_Count": pd.to_numeric(p.Reviews).fillna(0).astype(int).values,
        "Rating_Status": np.where(rating.isna(), "Not Rated", "Rated"),
        "Web_Discount_Pct": pd.to_numeric(p["Discount %"]).values / 100, "Image_Count": pd.to_numeric(p["Image Count"]).astype(int).values,
        "Product_URL": p.URL.values, "Version_No": p.Version_No.values,
        "Effective_Start_Date": p.Effective_Start_Date.values, "Effective_End_Date": p.Effective_End_Date.values,
        "Is_Current": p.Is_Current.values, "Row_Change_Reason": p.change_reason.values})
    dim_prod = pd.concat([seed["Product_Unknown"], dim_prod], ignore_index=True)
    for col in ["Effective_Start_Date", "Effective_End_Date"]:
        dim_prod[col] = pd.to_datetime(dim_prod[col].replace({"9999-12-31": HIGH_DATE, "1900-01-01": pd.Timestamp("1900-01-01")}))

    # ===================== FACT_SALES - branch A: P1 legacy CSV (S1) ==================
    s = pd.read_csv(a.p1_sales, dtype=str, encoding="cp1252")
    s = s[s["Invoice Date"].notna()].copy()                                     # drop 640 blank rows
    s["Invoice_Date"] = pd.to_datetime(s["Invoice Date"], format="%d/%m/%Y")
    s["Units"] = num(s["Units Sold"]).astype(int)
    s["OP_Raw"] = num(s["Operating Profit"])
    s["OM"] = num(s["Operating Margin"]) / 100
    s["Gross_Raw"] = s.OP_Raw / s.OM
    s["Implied_ASP"] = np.where(s.Units > 0, s.Gross_Raw / s.Units.replace(0, np.nan), np.nan)
    s["Scale_Correction_Factor"] = np.where(s.Implied_ASP > 120, 10, 1)
    zero = s[s.Units == 0]
    for _, z in zero.iterrows():
        rejects.append(("P1_CSV", "Nike US Sales Datasets.csv", f"{z['Invoice Date']}|{z['Retailer ID']}|{z['City']}|{z['Product ID']}",
                        "R01_ZERO_QUANTITY", "Units Sold = 0 and Operating Profit = 0 (empty invoice line)"))
    s = s[s.Units > 0].copy()
    s = s.sort_values(["Invoice_Date", "Retailer ID", "State", "City", "Sales Method", "Product ID", "Units", "OP_Raw"]).reset_index(drop=True)
    s["Row_No"] = np.arange(1, len(s) + 1)
    gross = (s.Gross_Raw / s.Scale_Correction_Factor).round(2)
    fa = pd.DataFrame({
        "Invoice_No": "P1-" + s.Row_No.map("{:07d}".format), "Invoice_Line_No": 1, "Line_Type": "SALE", "Ref_Invoice_No": None,
        "Source_System": "P1_CSV", "Invoice_Date": s.Invoice_Date, "Retailer_ID": s["Retailer ID"].str.strip(),
        "Channel_Name": s["Sales Method"].str.strip(), "City": s.City.str.strip(), "State_Name": s.State.str.strip(),
        "Product_ID": s["Product ID"].str.strip().str.upper(), "Promo_Code": "#LEGACY",
        "Units_Sold": s.Units, "Units_Returned": 0, "Unit_Price": (gross / s.Units).round(2),
        "Gross_Sales_Amount": gross, "Promo_Discount_Amount": 0.0, "Return_Amount": 0.0, "Net_Sales_Amount": gross,
        "Operating_Profit": (s.OP_Raw / s.Scale_Correction_Factor).round(2), "Operating_Margin_Pct": s.OM.round(4),
        "Scale_Correction_Factor": s.Scale_Correction_Factor,
        "DQ_Issue_Codes": np.where(s.Scale_Correction_Factor == 10, "P1_SCALE_X10", None)})

    # ===================== FACT_SALES - branch B: OMS 2022-2024 (S3 wildcard union) ===
    o = pd.concat([pd.read_csv(f, dtype=str, keep_default_na=False) for f in sorted(src.glob("oms_sales_20*.csv"))], ignore_index=True)
    o["_rn"] = o.groupby(["invoice_no", "invoice_line_no"]).cumcount() + 1     # {PARTITION inv,line : ROW_NUMBER()}
    for _, z in o[o._rn > 1].iterrows():
        rejects.append(("OMS", "oms_sales_*.csv", f"{z.invoice_no}|{z.invoice_line_no}", "R02_DUPLICATE_LINE", "Exact duplicate of an already-loaded line"))
    o = o[o._rn == 1].copy()
    dq = pd.Series([[] for _ in range(len(o))], index=o.index)

    def flag(mask, code):
        for i in o.index[mask]:
            dq[i].append(code)

    dt = pd.to_datetime(o.invoice_date, format="%Y-%m-%d", errors="coerce")
    dt2 = pd.to_datetime(o.invoice_date, format="%m/%d/%Y", errors="coerce")
    flag(dt.isna() & dt2.notna(), "DATE_FMT")
    o["Invoice_Date"] = dt.fillna(dt2)
    bad = o.Invoice_Date.isna() | (o.Invoice_Date < "2020-01-01") | (o.Invoice_Date > "2024-12-31")
    for _, z in o[bad].iterrows():
        rejects.append(("OMS", "oms_sales_*.csv", f"{z.invoice_no}|{z.invoice_line_no}", "R03_DATE_OUT_OF_RANGE",
                        f"invoice_date '{z.invoice_date}' outside load window 2020-01-01..2024-12-31"))
    o = o[~bad].copy(); dq = dq[o.index]

    ch_raw = o.sales_channel.str.lower().str.strip()
    ch_code = o.invoice_no.str.extract(r"^(?:NK|CM)-(IS|ON|OT)-")[0].map({"IS": "In-store", "ON": "Online", "OT": "Outlet"})
    std = np.select([ch_raw.str.contains(r"on-?line"), ch_raw.str.contains(r"in[- ]?store"), ch_raw.str.contains("outlet")],
                    ["Online", "In-store", "Outlet"], "")
    flag(pd.Series(std == "", index=o.index), "CHANNEL_FROM_INVOICE")
    flag(pd.Series((std != "") & (o.sales_channel.values != std), index=o.index), "CHANNEL_FMT")
    o["Channel_Name"] = np.where(std == "", ch_code, std)

    pid = o.product_id.str.upper().str.replace(r"[^A-Z0-9]", "", regex=True)
    o["Product_ID"] = pid.str[:-3] + "-" + pid.str[-3:]
    flag(o.Product_ID != o.product_id, "PRODUCT_ID_FMT")

    # state standardisation (code -> name), city conformance & imputation via geography reference
    gref = pd.read_csv(src / "us_geography_reference.csv")
    code2name = gref.drop_duplicates("state_code").set_index("state_code").state_name
    st = o.state.str.strip()
    o["State_Name"] = np.where(st.str.upper().isin(code2name.index), st.str.upper().map(code2name), st)
    flag(st.str.len() == 2, "STATE_CODE")
    single = gref.groupby("state_name").city.agg(["count", "first"])
    single_city = single[single["count"] == 1]["first"]
    city = o.city.str.strip()
    flag(city == "", "CITY_IMPUTED")
    city = np.where(city == "", o.State_Name.map(single_city).fillna(""), city)
    up2proper = dict(zip(gref.city.str.upper(), gref.city))
    o["City"] = pd.Series(city, index=o.index).str.upper().map(up2proper).fillna(pd.Series(city, index=o.index))
    flag(pd.Series(o.city.values != o.City.values, index=o.index) & (o.city.str.strip() != ""), "CITY_FMT")

    qty = o.quantity.astype(int)
    up = o.unit_price.astype(float)
    disc = o.discount_pct.astype(float)
    net = o.net_amount.astype(float)
    ratio = (qty * up * (1 - disc)) / net
    cents = ratio.between(95, 105)
    flag(cents, "PRICE_CENTS")
    up = np.where(cents, up / 100, up)
    op = o.operating_profit.astype(float)
    om = pd.to_numeric(o.operating_margin, errors="coerce")
    flag(om.isna(), "MARGIN_RECALC")
    om = om.fillna((op / net).round(4))
    is_sale = o.line_type == "SALE"
    gross = np.where(is_sale, np.round(qty * up, 2), 0.0)
    pdisc = np.where(is_sale, np.round(gross * disc, 2), 0.0)
    ret_amt = np.where(~is_sale, np.abs(net), 0.0)
    fb = pd.DataFrame({
        "Invoice_No": o.invoice_no, "Invoice_Line_No": o.invoice_line_no.astype(int), "Line_Type": o.line_type,
        "Ref_Invoice_No": o.ref_invoice_no.replace("", None), "Source_System": "OMS", "Invoice_Date": o.Invoice_Date,
        "Retailer_ID": o.retailer_id.str.strip(), "Channel_Name": o.Channel_Name, "City": o.City, "State_Name": o.State_Name,
        "Product_ID": o.Product_ID, "Promo_Code": o.promo_code.str.strip().replace("", "NONE"),
        "Units_Sold": np.where(is_sale, qty, 0), "Units_Returned": np.where(~is_sale, -qty, 0),
        "Unit_Price": np.round(up, 2), "Gross_Sales_Amount": gross, "Promo_Discount_Amount": pdisc, "Return_Amount": ret_amt,
        "Net_Sales_Amount": np.round(gross - pdisc - ret_amt, 2), "Operating_Profit": op, "Operating_Margin_Pct": om,
        "Scale_Correction_Factor": 1,
        "DQ_Issue_Codes": [("|".join(v) if v else None) for v in dq]})

    # ===================== UNION + KEY LOOKUPS ========================================
    f = pd.concat([fa, fb], ignore_index=True)
    f["Date_Key"] = f.Invoice_Date.dt.strftime("%Y%m%d").astype(int)
    f["Product_Key"] = range_lookup(f, dim_prod[dim_prod.Product_Key > 0], "Product_ID", "Product_ID", "Invoice_Date", "Product_Key")
    f["Retailer_Key"] = range_lookup(f, dim_ret[dim_ret.Retailer_Key > 0], "Retailer_ID", "Retailer_ID", "Invoice_Date", "Retailer_Key")
    geo_map = dim_geo.set_index(["City", "State_Name"]).Geography_Key
    f["Geography_Key"] = pd.MultiIndex.from_arrays([f.City, f.State_Name]).map(geo_map).fillna(-1).astype(int)
    f["Channel_Key"] = f.Channel_Name.map(dim_channel.set_index("Channel_Name").Channel_Key).fillna(-1).astype(int)
    f["Promotion_Key"] = f.Promo_Code.map(dim_promo.set_index("Promo_Code").Promotion_Key).fillna(-1).astype(int)
    for col, code in [("Product_Key", "UNKNOWN_PRODUCT"), ("Retailer_Key", "UNKNOWN_RETAILER"), ("Geography_Key", "UNKNOWN_GEO")]:
        m = f[col] == -1
        f.loc[m, "DQ_Issue_Codes"] = f.loc[m, "DQ_Issue_Codes"].fillna("").map(lambda x: (x + "|" if x else "") + code)
    f = f.sort_values(["Date_Key", "Invoice_No", "Invoice_Line_No"]).reset_index(drop=True)
    f["Sales_Line_Key"] = np.arange(1, len(f) + 1)
    f["ETL_Load_Date"] = LOAD_TS
    fact_sales = f[["Sales_Line_Key", "Date_Key", "Product_Key", "Retailer_Key", "Geography_Key", "Channel_Key", "Promotion_Key",
                    "Invoice_No", "Invoice_Line_No", "Line_Type", "Ref_Invoice_No", "Source_System", "Units_Sold", "Units_Returned",
                    "Unit_Price", "Gross_Sales_Amount", "Promo_Discount_Amount", "Return_Amount", "Net_Sales_Amount",
                    "Operating_Profit", "Operating_Margin_Pct", "Scale_Correction_Factor", "DQ_Issue_Codes", "ETL_Load_Date"]]

    # ===================== FACT_INVENTORY_SNAPSHOT  (S9) ==============================
    w = pd.read_csv(src / "wms_inventory_snapshot.csv", dtype={"account_id": str})
    w["SKU"] = w.sku.str.strip().str.upper()
    w["_rn"] = w.sort_values("extract_ts", ascending=False).groupby(["snapshot_date", "SKU", "account_id"]).cumcount() + 1
    for _, z in w[w._rn > 1].iterrows():
        rejects.append(("WMS", "wms_inventory_snapshot.csv", f"{z.snapshot_date}|{z.SKU}|{z.account_id}|{z.extract_ts}",
                        "R04_SUPERSEDED_SNAPSHOT", "Older extract of the same SKU x account x month (latest kept)"))
    w = w[w._rn == 1].copy()
    w["Snapshot_Date"] = pd.to_datetime(w.snapshot_date)
    w["DQ"] = np.select([w.on_hand_qty < 0, w.sku != w.SKU], ["NEG_ON_HAND", "SKU_CASE"], None)
    w.loc[(w.on_hand_qty < 0) & (w.sku != w.SKU), "DQ"] = "NEG_ON_HAND|SKU_CASE"
    w["On_Hand"] = w.on_hand_qty.clip(lower=0)
    w["Product_ID"] = w.SKU
    w["Retailer_ID"] = w.account_id
    w["Product_Key"] = range_lookup(w, dim_prod[dim_prod.Product_Key > 0], "Product_ID", "Product_ID", "Snapshot_Date", "Product_Key")
    w["Retailer_Key"] = range_lookup(w, dim_ret[dim_ret.Retailer_Key > 0], "Retailer_ID", "Retailer_ID", "Snapshot_Date", "Retailer_Key")
    w["Date_Key"] = w.Snapshot_Date.dt.strftime("%Y%m%d").astype(int)
    w = w.sort_values(["Date_Key", "Retailer_Key", "Product_Key"]).reset_index(drop=True)
    fact_inv = pd.DataFrame({
        "Inventory_Snapshot_Key": np.arange(1, len(w) + 1), "Date_Key": w.Date_Key, "Product_Key": w.Product_Key,
        "Retailer_Key": w.Retailer_Key, "Units_On_Hand": w.On_Hand, "Units_On_Order": w.on_order_qty,
        "Inventory_Value_Cost": (w.On_Hand * w.std_unit_cost_usd).round(2), "Units_Received": w.received_qty,
        "Units_Shipped": w.shipped_qty, "Stockout_Days": w.stockout_days, "Std_Unit_Cost": w.std_unit_cost_usd,
        "Weeks_Of_Supply": np.where(w.shipped_qty > 0, (w.On_Hand / (w.shipped_qty / 4.345)).round(2), np.nan),
        "DQ_Issue_Codes": w.DQ, "ETL_Load_Date": LOAD_TS})
    fact_inv["Weeks_Of_Supply"] = fact_inv.Weeks_Of_Supply.clip(upper=9999.99)

    rej = pd.DataFrame(rejects, columns=["Source_System", "Source_File", "Source_Record_Ref", "Reject_Code", "Reject_Reason"])
    rej.insert(0, "Reject_ID", np.arange(1, len(rej) + 1))
    rej["ETL_Load_Date"] = LOAD_TS

    # ===================== WRITE + RECONCILIATION =====================================
    tables = {"Dim_Date": dim_date, "Dim_Product": dim_prod, "Dim_Retailer": dim_ret, "Dim_Geography": dim_geo,
              "Dim_Channel": dim_channel, "Dim_Promotion": dim_promo, "Fact_Sales": fact_sales,
              "Fact_Inventory_Snapshot": fact_inv, "Audit_ETL_Reject": rej}
    for name, df in tables.items():
        df2 = df.copy()
        for col in df2.columns:
            if pd.api.types.is_datetime64_any_dtype(df2[col]):
                s_ = df2[col].dt.strftime("%Y-%m-%d %H:%M:%S" if col == "ETL_Load_Date" else "%Y-%m-%d")
                df2[col] = s_.replace({"2262-04-11": "9999-12-31"})
        df2.to_csv(out / f"{name}.csv", index=False)

    fs = fact_sales.merge(dim_date[["Date_Key", "Calendar_Year"]], on="Date_Key")
    rec = [("ALL", t, "row_count", len(df)) for t, df in tables.items()]
    for y, gy in fs.groupby("Calendar_Year"):
        for m in ["Units_Sold", "Units_Returned", "Gross_Sales_Amount", "Promo_Discount_Amount", "Return_Amount",
                  "Net_Sales_Amount", "Operating_Profit"]:
            rec.append((str(y), "Fact_Sales", f"SUM({m})", round(gy[m].sum(), 2)))
        rec.append((str(y), "Fact_Sales", "row_count", len(gy)))
    for k in ["Product_Key", "Retailer_Key", "Geography_Key", "Channel_Key", "Promotion_Key"]:
        rec.append(("ALL", "Fact_Sales", f"rows with {k} = -1", int((fact_sales[k] == -1).sum())))
    rec.append(("ALL", "Fact_Sales", "rows with Promotion_Key = -2 (legacy)", int((fact_sales.Promotion_Key == -2).sum())))
    rec.append(("ALL", "Fact_Sales", "rows with Scale_Correction_Factor = 10", int((fact_sales.Scale_Correction_Factor == 10).sum())))
    rec.append(("ALL", "Fact_Inventory_Snapshot", "SUM(Units_On_Hand) at 2024-12-31",
                int(fact_inv[fact_inv.Date_Key == 20241231].Units_On_Hand.sum())))
    for code, n in rej.Reject_Code.value_counts().sort_index().items():
        rec.append(("ALL", "Audit_ETL_Reject", code, int(n)))
    pd.DataFrame(rec, columns=["Scope", "Table", "Check", "Expected_Value"]).to_csv(out / "expected_load_reconciliation.csv", index=False)
    print(pd.DataFrame(rec, columns=["Scope", "Table", "Check", "Expected_Value"]).to_string())


if __name__ == "__main__":
    main()
