# Nike US Sales: Data Warehouse & BI System

A two-phase group project for *Data Warehouse and Business Intelligence Systems* at Chulalongkorn University (2026). Phase 1 is a Tableau analysis of US Nike sales. Phase 2 turns it into a full data warehouse in SQL Server, loaded through a Tableau Prep ETL flow and reported in Tableau.

**Skills shown:** dimensional modelling, ETL design, data-quality checks, SQL Server, Tableau Prep, Tableau (LOD expressions, parameters, what-if analysis) and Python (pandas).

## Phase 1: Tableau analysis

- 7 dashboards and 3 stories on sales, profit, margin, regions and products.
- Fixed and nested LOD expressions for benchmarks, a price what-if simulator (simulated profit and profit gap by channel), and a product portfolio matrix that sorts 393 products into scale, fix or cut groups.

File: `phase1_tableau/Nike_US_Sales_Phase1.twb`

## Phase 2: Data warehouse

- **Star schema (fact constellation)** in SQL Server 2022, database `NikeUS_DW`:
  - 2 facts: `Fact_Sales`, `Fact_Inventory_Snapshot`
  - 6 dimensions: `Dim_Date`, `Dim_Product`, `Dim_Retailer`, `Dim_Geography`, `Dim_Channel`, `Dim_Promotion`
  - an `Audit_ETL_Reject` table
  - primary key, unique, check and foreign key constraints, plus indexes
- **ETL in Tableau Prep:** 11 source files (2 from Phase 1 and 9 new sources for 2022–2024) loaded through a single flow, giving 43,248 sales lines and 96,094 inventory rows.
- **Data-quality fix:** 3,876 of the 9,648 Phase 1 lines (40%) had a 10× scaling defect that had overstated profit about 7×. The ETL corrects it and records a `Scale_Correction_Factor`, so every change is traceable. Rejected rows go to `Audit_ETL_Reject`.
- **Load control and validation:** `usp_ETL_BeginLoad` / `usp_ETL_EndLoad`, plus reconciliation queries for row counts, totals and orphan keys (zero orphan keys after loading).
- **Reporting layer:** 5 Tableau dashboards and 1 story answering 14 business questions with 17 KPIs.
- **Python:**
  - `generate_p2_sources.py` rebuilds the 2022–2024 sources (deterministic, seed 2569).
  - `reference_etl_check.py` is a rule-for-rule pandas copy of the Prep flow, used to check the load.

## Repository structure

```
nike-us-sales-data-warehouse/
├── phase1_tableau/
│   └── Nike_US_Sales_Phase1.twb             # Phase 1 workbook (structure only)
├── phase2_data_warehouse/
│   ├── sql/
│   │   ├── 01_create_dw_schema.sql          # DDL: 9 tables, keys, constraints, indexes
│   │   └── 02_etl_control_and_validation.sql# load-control procedures + validation queries
│   ├── model/NikeUS_DW.pdm                  # PowerDesigner physical data model
│   ├── etl/NikeUS_DW_ETL.tfl                # Tableau Prep flow
│   ├── python/                              # source generator + reference ETL check
│   ├── tableau/
│   │   ├── NikeUS_DW_Dashboards.twb         # Phase 2 dashboards (structure only)
│   │   └── Calculated_Fields.txt            # every calculated field used in the dashboards
│   └── docs/Data_Dictionary_STTM.xlsx       # data dictionary and source-to-target mapping
└── data/                                    # source data S1–S11 (13 files), generation log, README
```

## How to run

1. Run `sql/01_create_dw_schema.sql` in SQL Server Management Studio.
2. Run **PART A** of `sql/02_etl_control_and_validation.sql` (post-deploy objects and load-control procedures).
3. Open `etl/NikeUS_DW_ETL.tfl` in Tableau Prep. Point the inputs to the `data/` folder and the outputs to your SQL Server. Each output runs `EXEC dbo.usp_ETL_BeginLoad;` as Before-SQL.
4. Run **PART B** of the same script; it starts with `EXEC dbo.usp_ETL_EndLoad;` and checks the load.
5. Open `tableau/NikeUS_DW_Dashboards.twb` and connect it to `NikeUS_DW` (Data → Replace Data Source).

The workbooks are published without their Tableau extracts, so Tableau asks for the data location when you open them.

## Data

All source files (S1–S11) are in [`data/`](data/README.md). The Phase 1 files come from an open Nike US sales dataset; the 2022–2024 data, the retailer names and the price, promotion and inventory histories are synthetic.

## Team

A group of students in the course built this project.
