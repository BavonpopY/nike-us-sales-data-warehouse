# Data

This folder holds the source data for the ETL flow (S1–S11, 13 files) plus the generation log and manifest.

| Source | Files | What it is |
|---|---|---|
| S1–S2 | `Nike US Sales Datasets.csv`, `nike_2020_04_13_cleaned.csv` | Phase 1 Nike US sales data (2020–2021), an open dataset the team chose from a public open-data site |
| S3 | `oms_sales_2022.csv`, `oms_sales_2023.csv`, `oms_sales_2024.csv` | Synthetic order-management extracts for 2022–2024, with deliberately injected data-quality problems |
| S4 | `retailer_master.xlsx` | Synthetic retailer master with change history (SCD Type 2) |
| S5 | `product_price_history.csv` | Synthetic list-price history (SCD Type 2) |
| S6 | `promotion_calendar.xlsx` | Synthetic promotion campaigns, 2022–2024 |
| S7 | `us_geography_reference.csv` | City, state and region reference |
| S8 | `us_holidays_retail_events.csv` | Holidays and retail events, one row per date |
| S9 | `wms_inventory_snapshot.csv` | Synthetic month-end stock by product and retailer |
| S10 | `calendar_bounds.csv` | Start and end dates for the date dimension |
| S11 | `dw_seed_special_members.xlsx` | "Unknown" and special dimension members, static channel rows |
| — | `anomaly_injection_log.csv`, `generation_manifest.json` | Which rows were deliberately corrupted and how; row counts and seed |

S3–S11 were generated from S1–S2 by `phase2_data_warehouse/python/generate_p2_sources.py` (deterministic, seed 2569). To rebuild them, or to rebuild the expected warehouse tables for checking a load, run from `phase2_data_warehouse/python/`:

```bash
pip install pandas numpy openpyxl faker
python generate_p2_sources.py --p1-sales "../../data/Nike US Sales Datasets.csv" \
       --p1-catalog "../../data/nike_2020_04_13_cleaned.csv" --out ../../data
python reference_etl_check.py --src ../../data --p1-sales "../../data/Nike US Sales Datasets.csv" \
       --p1-catalog "../../data/nike_2020_04_13_cleaned.csv" --out ../../data/reference_output
```
