/* ==========================================================================================
   2603-389 Data Warehouse & Business Intelligence System | Project 2 | Group G6
   NikeUS_DW - Nike US Sales, Inventory & Channel Performance Data Warehouse
   Target  : Microsoft SQL Server 2022 (16.x), database compatibility level 160
   Content : database, 9 tables (6 dimensions, 2 facts, 1 audit), PK / UNIQUE / CHECK / FK constraints,
             foreign-key and lookup indexes, MS_Description extended properties (= data dictionary).
   Use     : 1) Run once in SSMS to build the DW.
             2) PowerDesigner: File > Reverse Engineer > Database... > DBMS "Microsoft SQL Server 2019/2022"
                > Using script files > this file. Arrange the diagram, then Database > Generate Database to
                produce the submission script 2603389_2569_P2_G6.sql.
   Re-run  : safe - drops and recreates every table (all data is lost; reload with the Prep flow).
   Note    : No IDENTITY / DEFAULT columns on purpose - Tableau Prep supplies every column, including
             surrogate keys (ROW_NUMBER) and ETL_Load_Date (NOW()).
   ========================================================================================== */
SET NOCOUNT ON;
GO
USE master;
GO
IF DB_ID(N'NikeUS_DW') IS NULL
    CREATE DATABASE NikeUS_DW;
GO
ALTER DATABASE NikeUS_DW SET RECOVERY SIMPLE;
GO
ALTER DATABASE NikeUS_DW SET COMPATIBILITY_LEVEL = 160;
GO
USE NikeUS_DW;
GO

/* ------------------------------------------------------------------------------------------
   0. Drop existing objects (children first)
   ------------------------------------------------------------------------------------------ */
IF OBJECT_ID(N'dbo.vw_Sales_Star', N'V') IS NOT NULL DROP VIEW dbo.vw_Sales_Star;
IF OBJECT_ID(N'dbo.vw_Inventory_Star', N'V') IS NOT NULL DROP VIEW dbo.vw_Inventory_Star;
IF OBJECT_ID(N'dbo.Audit_ETL_Reject', N'U') IS NOT NULL DROP TABLE dbo.Audit_ETL_Reject;
IF OBJECT_ID(N'dbo.Fact_Inventory_Snapshot', N'U') IS NOT NULL DROP TABLE dbo.Fact_Inventory_Snapshot;
IF OBJECT_ID(N'dbo.Fact_Sales', N'U') IS NOT NULL DROP TABLE dbo.Fact_Sales;
IF OBJECT_ID(N'dbo.Dim_Promotion', N'U') IS NOT NULL DROP TABLE dbo.Dim_Promotion;
IF OBJECT_ID(N'dbo.Dim_Channel', N'U') IS NOT NULL DROP TABLE dbo.Dim_Channel;
IF OBJECT_ID(N'dbo.Dim_Geography', N'U') IS NOT NULL DROP TABLE dbo.Dim_Geography;
IF OBJECT_ID(N'dbo.Dim_Retailer', N'U') IS NOT NULL DROP TABLE dbo.Dim_Retailer;
IF OBJECT_ID(N'dbo.Dim_Product', N'U') IS NOT NULL DROP TABLE dbo.Dim_Product;
IF OBJECT_ID(N'dbo.Dim_Date', N'U') IS NOT NULL DROP TABLE dbo.Dim_Date;
GO

/* ------------------------------------------------------------------------------------------
   1. Dim_Date  [Dimension (static)]
      Calendar and Nike fiscal calendar (FY ends 31 May), one row per day 2019-01-01..2025-12-31, with US federal holidays and retail events.
      Source: S10 calendar_bounds.csv -> New Rows; S8 us_holidays_retail_events.csv
   ------------------------------------------------------------------------------------------ */
CREATE TABLE dbo.Dim_Date
(
    Date_Key              INT            NOT NULL,
    Full_Date             DATE           NOT NULL,
    Day_Of_Week_No        TINYINT        NOT NULL,
    Day_Name              VARCHAR(9)     NOT NULL,
    Day_Name_Short        CHAR(3)        NOT NULL,
    Is_Weekend            BIT            NOT NULL,
    Day_Of_Month          TINYINT        NOT NULL,
    Day_Of_Year           SMALLINT       NOT NULL,
    ISO_Week_No           TINYINT        NOT NULL,
    Week_Start_Date       DATE           NOT NULL,
    Month_No              TINYINT        NOT NULL,
    Month_Name            VARCHAR(9)     NOT NULL,
    Month_Name_Short      CHAR(3)        NOT NULL,
    Year_Month            CHAR(7)        NOT NULL,
    Quarter_No            TINYINT        NOT NULL,
    Calendar_Year         SMALLINT       NOT NULL,
    Quarter_Label         CHAR(7)        NOT NULL,
    Is_Month_End          BIT            NOT NULL,
    Fiscal_Year           SMALLINT       NOT NULL,
    Fiscal_Year_Label     CHAR(6)        NOT NULL,
    Fiscal_Month_No       TINYINT        NOT NULL,
    Fiscal_Quarter_No     TINYINT        NOT NULL,
    Fiscal_Quarter_Label  VARCHAR(8)     NOT NULL,
    Season                VARCHAR(6)     NOT NULL,
    Is_Federal_Holiday    BIT            NOT NULL,
    Is_Retail_Event       BIT            NOT NULL,
    Holiday_Event_Name    VARCHAR(60)    NULL,
    CONSTRAINT PK_Dim_Date PRIMARY KEY CLUSTERED (Date_Key),
    CONSTRAINT UQ_Dim_Date_Full_Date UNIQUE (Full_Date),
    CONSTRAINT CK_Dim_Date_Date_Key CHECK (Date_Key = CONVERT(INT, CONVERT(CHAR(8), Full_Date, 112))),
    CONSTRAINT CK_Dim_Date_Day_Of_Week_No CHECK (Day_Of_Week_No BETWEEN 1 AND 7),
    CONSTRAINT CK_Dim_Date_Day_Of_Month CHECK (Day_Of_Month BETWEEN 1 AND 31),
    CONSTRAINT CK_Dim_Date_Day_Of_Year CHECK (Day_Of_Year BETWEEN 1 AND 366),
    CONSTRAINT CK_Dim_Date_ISO_Week_No CHECK (ISO_Week_No BETWEEN 1 AND 53),
    CONSTRAINT CK_Dim_Date_Month_No CHECK (Month_No BETWEEN 1 AND 12),
    CONSTRAINT CK_Dim_Date_Quarter_No CHECK (Quarter_No BETWEEN 1 AND 4),
    CONSTRAINT CK_Dim_Date_Calendar_Year CHECK (Calendar_Year BETWEEN 2019 AND 2025),
    CONSTRAINT CK_Dim_Date_Fiscal_Year CHECK (Fiscal_Year BETWEEN 2019 AND 2026),
    CONSTRAINT CK_Dim_Date_Fiscal_Month_No CHECK (Fiscal_Month_No BETWEEN 1 AND 12),
    CONSTRAINT CK_Dim_Date_Fiscal_Quarter_No CHECK (Fiscal_Quarter_No BETWEEN 1 AND 4),
    CONSTRAINT CK_Dim_Date_Season CHECK (Season IN ('Winter','Spring','Summer','Fall'))
);
GO

/* ------------------------------------------------------------------------------------------
   2. Dim_Product  [Dimension (SCD2)]
      Product (style-colour SKU) with derived hierarchy; SCD Type 2 on list price, price band and lifecycle status.
      Source: S5 product_price_history.csv (versions) inner-join S2 nike_2020_04_13_cleaned.csv; S11 Product_Unknown
   ------------------------------------------------------------------------------------------ */
CREATE TABLE dbo.Dim_Product
(
    Product_Key           INT            NOT NULL,
    Product_ID            VARCHAR(10)    NOT NULL,
    Style_Code            VARCHAR(6)     NOT NULL,
    Color_Code            CHAR(3)        NOT NULL,
    Product_Name          NVARCHAR(80)   NOT NULL,
    Brand_Line            VARCHAR(10)    NOT NULL,
    Category              VARCHAR(20)    NOT NULL,
    Franchise             VARCHAR(20)    NOT NULL,
    Product_Type          VARCHAR(12)    NOT NULL,
    Gender_Segment        VARCHAR(10)    NOT NULL,
    List_Price_USD        DECIMAL(10,2)  NULL,
    Price_Band            VARCHAR(20)    NOT NULL,
    Lifecycle_Status      VARCHAR(12)    NOT NULL,
    Web_Rating            DECIMAL(3,1)   NULL,
    Web_Review_Count      INT            NOT NULL,
    Rating_Status         VARCHAR(10)    NOT NULL,
    Web_Discount_Pct      DECIMAL(5,4)   NOT NULL,
    Image_Count           TINYINT        NOT NULL,
    Product_URL           VARCHAR(200)   NULL,
    Version_No            SMALLINT       NOT NULL,
    Effective_Start_Date  DATE           NOT NULL,
    Effective_End_Date    DATE           NOT NULL,
    Is_Current            BIT            NOT NULL,
    Row_Change_Reason     VARCHAR(60)    NOT NULL,
    CONSTRAINT PK_Dim_Product PRIMARY KEY CLUSTERED (Product_Key),
    CONSTRAINT UQ_Dim_Product_NK_Start UNIQUE (Product_ID, Effective_Start_Date),
    CONSTRAINT CK_Dim_Product_Brand_Line CHECK (Brand_Line IN ('Nike','Jordan','Unknown')),
    CONSTRAINT CK_Dim_Product_Gender_Segment CHECK (Gender_Segment IN ('Men''s','Women''s','Unisex','Unknown')),
    CONSTRAINT CK_Dim_Product_List_Price_USD CHECK (List_Price_USD > 0),
    CONSTRAINT CK_Dim_Product_Lifecycle_Status CHECK (Lifecycle_Status IN ('Active','Clearance','Discontinued','Unknown')),
    CONSTRAINT CK_Dim_Product_Web_Rating CHECK (Web_Rating BETWEEN 1 AND 5),
    CONSTRAINT CK_Dim_Product_Web_Review_Count CHECK (Web_Review_Count >= 0),
    CONSTRAINT CK_Dim_Product_Rating_Status CHECK (Rating_Status IN ('Rated','Not Rated')),
    CONSTRAINT CK_Dim_Product_Web_Discount_Pct CHECK (Web_Discount_Pct BETWEEN 0 AND 1),
    CONSTRAINT CK_Dim_Product_Version_No CHECK (Version_No >= 1),
    CONSTRAINT CK_Dim_Product_Effective_Range CHECK (Effective_End_Date >= Effective_Start_Date),
    CONSTRAINT CK_Dim_Product_Current_Flag CHECK ((Is_Current = 1 AND Effective_End_Date = '9999-12-31') OR (Is_Current = 0 AND Effective_End_Date < '9999-12-31'))
);
GO

/* ------------------------------------------------------------------------------------------
   3. Dim_Retailer  [Dimension (SCD2)]
      Retail account (wholesale partner or Nike Direct); SCD Type 2 on partner tier, key account manager and payment terms.
      Source: S4 retailer_master.xlsx [Retailer_Versions]; S11 Retailer_Unknown
   ------------------------------------------------------------------------------------------ */
CREATE TABLE dbo.Dim_Retailer
(
    Retailer_Key          INT            NOT NULL,
    Retailer_ID           VARCHAR(10)    NOT NULL,
    Retailer_Name         NVARCHAR(60)   NOT NULL,
    Retailer_Type         VARCHAR(40)    NOT NULL,
    Ownership_Type        VARCHAR(20)    NOT NULL,
    Partner_Tier          VARCHAR(15)    NOT NULL,
    Key_Account_Manager   NVARCHAR(60)   NOT NULL,
    Payment_Terms_Days    SMALLINT       NOT NULL,
    HQ_State              VARCHAR(30)    NOT NULL,
    Onboard_Date          DATE           NULL,
    Version_No            SMALLINT       NOT NULL,
    Effective_Start_Date  DATE           NOT NULL,
    Effective_End_Date    DATE           NOT NULL,
    Is_Current            BIT            NOT NULL,
    Row_Change_Reason     VARCHAR(60)    NOT NULL,
    CONSTRAINT PK_Dim_Retailer PRIMARY KEY CLUSTERED (Retailer_Key),
    CONSTRAINT UQ_Dim_Retailer_NK_Start UNIQUE (Retailer_ID, Effective_Start_Date),
    CONSTRAINT CK_Dim_Retailer_Ownership_Type CHECK (Ownership_Type IN ('Wholesale Partner','Nike-Owned','Unknown')),
    CONSTRAINT CK_Dim_Retailer_Partner_Tier CHECK (Partner_Tier IN ('Platinum','Gold','Silver','Bronze','Owned Channel','Unknown')),
    CONSTRAINT CK_Dim_Retailer_Payment_Terms_Days CHECK (Payment_Terms_Days BETWEEN 0 AND 120),
    CONSTRAINT CK_Dim_Retailer_Version_No CHECK (Version_No >= 1),
    CONSTRAINT CK_Dim_Retailer_Effective_Range CHECK (Effective_End_Date >= Effective_Start_Date),
    CONSTRAINT CK_Dim_Retailer_Current_Flag CHECK ((Is_Current = 1 AND Effective_End_Date = '9999-12-31') OR (Is_Current = 0 AND Effective_End_Date < '9999-12-31'))
);
GO

/* ------------------------------------------------------------------------------------------
   4. Dim_Geography  [Dimension (static)]
      US city of sale with state, company sales region and Census hierarchy; natural key = City + State.
      Source: S7 us_geography_reference.csv; S11 Geography_Unknown
   ------------------------------------------------------------------------------------------ */
CREATE TABLE dbo.Dim_Geography
(
    Geography_Key           INT            NOT NULL,
    Geo_Code                VARCHAR(20)    NOT NULL,
    City                    NVARCHAR(40)   NOT NULL,
    State_Name              VARCHAR(30)    NOT NULL,
    State_Code              CHAR(2)        NOT NULL,
    Sales_Region            VARCHAR(15)    NOT NULL,
    Census_Region           VARCHAR(15)    NOT NULL,
    Census_Division         VARCHAR(25)    NOT NULL,
    Time_Zone               VARCHAR(20)    NOT NULL,
    City_Tier               VARCHAR(25)    NOT NULL,
    Is_DTC_Flagship_Market  BIT            NOT NULL,
    City_State_Label        NVARCHAR(50)   NOT NULL,
    Country_Code            CHAR(2)        NOT NULL,
    CONSTRAINT PK_Dim_Geography PRIMARY KEY CLUSTERED (Geography_Key),
    CONSTRAINT UQ_Dim_Geography_Geo_Code UNIQUE (Geo_Code),
    CONSTRAINT UQ_Dim_Geography_City_State UNIQUE (City, State_Name)
);
GO

/* ------------------------------------------------------------------------------------------
   5. Dim_Channel  [Dimension (static)]
      Sales channel (P1 'Sales Method' / OMS 'sales_channel').
      Source: S11 dw_seed_special_members.xlsx [Channel]
   ------------------------------------------------------------------------------------------ */
CREATE TABLE dbo.Dim_Channel
(
    Channel_Key        INT            NOT NULL,
    Channel_Code       CHAR(2)        NOT NULL,
    Channel_Name       VARCHAR(15)    NOT NULL,
    Channel_Group      VARCHAR(10)    NOT NULL,
    Price_Positioning  VARCHAR(12)    NOT NULL,
    Sort_Order         TINYINT        NOT NULL,
    CONSTRAINT PK_Dim_Channel PRIMARY KEY CLUSTERED (Channel_Key),
    CONSTRAINT UQ_Dim_Channel_Channel_Code UNIQUE (Channel_Code),
    CONSTRAINT UQ_Dim_Channel_Channel_Name UNIQUE (Channel_Name),
    CONSTRAINT CK_Dim_Channel_Channel_Group CHECK (Channel_Group IN ('Physical','Digital','Unknown'))
);
GO

/* ------------------------------------------------------------------------------------------
   6. Dim_Promotion  [Dimension (static)]
      Promotion campaign 2022-2024 plus special members (0 none, -1 unknown code, -2 not captured in P1 legacy data).
      Source: S6 promotion_calendar.xlsx [Promotions]; S11 Promotion_Special
   ------------------------------------------------------------------------------------------ */
CREATE TABLE dbo.Dim_Promotion
(
    Promotion_Key        INT            NOT NULL,
    Promo_Code           VARCHAR(10)    NOT NULL,
    Promo_Name           NVARCHAR(60)   NOT NULL,
    Promo_Type           VARCHAR(20)    NOT NULL,
    Discount_Pct         DECIMAL(5,4)   NOT NULL,
    Start_Date           DATE           NULL,
    End_Date             DATE           NULL,
    Eligible_Channels    VARCHAR(30)    NOT NULL,
    Promo_Fiscal_Year    CHAR(6)        NULL,
    Funding_Type         VARCHAR(30)    NOT NULL,
    Promo_Duration_Days  SMALLINT       NOT NULL,
    CONSTRAINT PK_Dim_Promotion PRIMARY KEY CLUSTERED (Promotion_Key),
    CONSTRAINT UQ_Dim_Promotion_Promo_Code UNIQUE (Promo_Code),
    CONSTRAINT CK_Dim_Promotion_Discount_Pct CHECK (Discount_Pct BETWEEN 0 AND 1),
    CONSTRAINT CK_Dim_Promotion_Promo_Duration_Days CHECK (Promo_Duration_Days >= 0),
    CONSTRAINT CK_Dim_Promotion_Date_Range CHECK (End_Date IS NULL OR Start_Date IS NULL OR End_Date >= Start_Date)
);
GO

/* ------------------------------------------------------------------------------------------
   7. Fact_Sales  [Fact (transaction)]
      Transaction fact. Grain: one invoice line or credit-memo line (product x document x retailer x city x channel x day x promotion).
      Source: S1 P1 CSV (2020-2021) UNION S3 OMS extract (2022-2024)
   ------------------------------------------------------------------------------------------ */
CREATE TABLE dbo.Fact_Sales
(
    Sales_Line_Key           BIGINT         NOT NULL,
    Date_Key                 INT            NOT NULL,
    Product_Key              INT            NOT NULL,
    Retailer_Key             INT            NOT NULL,
    Geography_Key            INT            NOT NULL,
    Channel_Key              INT            NOT NULL,
    Promotion_Key            INT            NOT NULL,
    Invoice_No               VARCHAR(20)    NOT NULL,
    Invoice_Line_No          SMALLINT       NOT NULL,
    Line_Type                VARCHAR(6)     NOT NULL,
    Ref_Invoice_No           VARCHAR(20)    NULL,
    Source_System            VARCHAR(10)    NOT NULL,
    Units_Sold               INT            NOT NULL,
    Units_Returned           INT            NOT NULL,
    Unit_Price               DECIMAL(10,2)  NOT NULL,
    Gross_Sales_Amount       DECIMAL(14,2)  NOT NULL,
    Promo_Discount_Amount    DECIMAL(14,2)  NOT NULL,
    Return_Amount            DECIMAL(14,2)  NOT NULL,
    Net_Sales_Amount         DECIMAL(14,2)  NOT NULL,
    Operating_Profit         DECIMAL(14,2)  NOT NULL,
    Operating_Margin_Pct     DECIMAL(7,4)   NULL,
    Scale_Correction_Factor  TINYINT        NOT NULL,
    DQ_Issue_Codes           VARCHAR(100)   NULL,
    ETL_Load_Date            DATETIME2(0)   NOT NULL,
    CONSTRAINT PK_Fact_Sales PRIMARY KEY CLUSTERED (Sales_Line_Key),
    CONSTRAINT UQ_Fact_Sales_Invoice_Line UNIQUE (Invoice_No, Invoice_Line_No),
    CONSTRAINT CK_Fact_Sales_Invoice_Line_No CHECK (Invoice_Line_No >= 1),
    CONSTRAINT CK_Fact_Sales_Line_Type CHECK (Line_Type IN ('SALE','RETURN')),
    CONSTRAINT CK_Fact_Sales_Source_System CHECK (Source_System IN ('P1_CSV','OMS')),
    CONSTRAINT CK_Fact_Sales_Units_Sold CHECK (Units_Sold >= 0),
    CONSTRAINT CK_Fact_Sales_Units_Returned CHECK (Units_Returned >= 0),
    CONSTRAINT CK_Fact_Sales_Unit_Price CHECK (Unit_Price > 0),
    CONSTRAINT CK_Fact_Sales_Gross_Sales_Amount CHECK (Gross_Sales_Amount >= 0),
    CONSTRAINT CK_Fact_Sales_Promo_Discount_Amount CHECK (Promo_Discount_Amount >= 0),
    CONSTRAINT CK_Fact_Sales_Return_Amount CHECK (Return_Amount >= 0),
    CONSTRAINT CK_Fact_Sales_Operating_Margin_Pct CHECK (Operating_Margin_Pct BETWEEN -1 AND 1),
    CONSTRAINT CK_Fact_Sales_Scale_Correction_Factor CHECK (Scale_Correction_Factor IN (1, 10)),
    CONSTRAINT CK_Fact_Sales_LineType_Units CHECK ((Line_Type = 'SALE' AND Units_Sold > 0 AND Units_Returned = 0) OR (Line_Type = 'RETURN' AND Units_Sold = 0 AND Units_Returned > 0)),
    CONSTRAINT CK_Fact_Sales_Net_Arithmetic CHECK (ABS(Net_Sales_Amount - (Gross_Sales_Amount - Promo_Discount_Amount - Return_Amount)) <= 0.05)
);
GO

/* ------------------------------------------------------------------------------------------
   8. Fact_Inventory_Snapshot  [Fact (periodic snapshot)]
      Periodic snapshot fact. Grain: one row per product version x retailer account x calendar month-end.
      Source: S9 wms_inventory_snapshot.csv
   ------------------------------------------------------------------------------------------ */
CREATE TABLE dbo.Fact_Inventory_Snapshot
(
    Inventory_Snapshot_Key  BIGINT         NOT NULL,
    Date_Key                INT            NOT NULL,
    Product_Key             INT            NOT NULL,
    Retailer_Key            INT            NOT NULL,
    Units_On_Hand           INT            NOT NULL,
    Units_On_Order          INT            NOT NULL,
    Inventory_Value_Cost    DECIMAL(14,2)  NOT NULL,
    Units_Received          INT            NOT NULL,
    Units_Shipped           INT            NOT NULL,
    Stockout_Days           TINYINT        NOT NULL,
    Std_Unit_Cost           DECIMAL(10,2)  NOT NULL,
    Weeks_Of_Supply         DECIMAL(9,2)   NULL,
    DQ_Issue_Codes          VARCHAR(60)    NULL,
    ETL_Load_Date           DATETIME2(0)   NOT NULL,
    CONSTRAINT PK_Fact_Inventory_Snapshot PRIMARY KEY CLUSTERED (Inventory_Snapshot_Key),
    CONSTRAINT UQ_Fact_Inventory_Grain UNIQUE (Date_Key, Product_Key, Retailer_Key),
    CONSTRAINT CK_Fact_Inventory_Snapshot_Units_On_Hand CHECK (Units_On_Hand >= 0),
    CONSTRAINT CK_Fact_Inventory_Snapshot_Units_On_Order CHECK (Units_On_Order >= 0),
    CONSTRAINT CK_Fact_Inventory_Snapshot_Inventory_Value_Cost CHECK (Inventory_Value_Cost >= 0),
    CONSTRAINT CK_Fact_Inventory_Snapshot_Units_Received CHECK (Units_Received >= 0),
    CONSTRAINT CK_Fact_Inventory_Snapshot_Stockout_Days CHECK (Stockout_Days BETWEEN 0 AND 31),
    CONSTRAINT CK_Fact_Inventory_Snapshot_Std_Unit_Cost CHECK (Std_Unit_Cost > 0),
    CONSTRAINT CK_Fact_Inventory_Snapshot_Weeks_Of_Supply CHECK (Weeks_Of_Supply >= 0)
);
GO

/* ------------------------------------------------------------------------------------------
   9. Audit_ETL_Reject  [Audit (outside the star)]
      ETL audit: source records rejected or superseded by the Prep flow, with reason.
      Source: Reject branches of the Prep flow
   ------------------------------------------------------------------------------------------ */
CREATE TABLE dbo.Audit_ETL_Reject
(
    Reject_ID          BIGINT         NOT NULL,
    Source_System      VARCHAR(10)    NOT NULL,
    Source_File        VARCHAR(60)    NOT NULL,
    Source_Record_Ref  VARCHAR(120)   NOT NULL,
    Reject_Code        VARCHAR(30)    NOT NULL,
    Reject_Reason      NVARCHAR(200)  NOT NULL,
    ETL_Load_Date      DATETIME2(0)   NOT NULL,
    CONSTRAINT PK_Audit_ETL_Reject PRIMARY KEY CLUSTERED (Reject_ID),
    CONSTRAINT CK_Audit_ETL_Reject_Source_System CHECK (Source_System IN ('P1_CSV','OMS','WMS')),
    CONSTRAINT CK_Audit_ETL_Reject_Reject_Code CHECK (Reject_Code IN ('R01_ZERO_QUANTITY','R02_DUPLICATE_LINE','R03_DATE_OUT_OF_RANGE','R04_SUPERSEDED_SNAPSHOT'))
);
GO

/* ------------------------------------------------------------------------------------------
   10. Foreign keys (fact constellation: both facts share Dim_Date, Dim_Product, Dim_Retailer)
   ------------------------------------------------------------------------------------------ */
ALTER TABLE dbo.Fact_Sales WITH CHECK ADD CONSTRAINT FK_Fact_Sales_Dim_Date FOREIGN KEY (Date_Key) REFERENCES dbo.Dim_Date (Date_Key);
ALTER TABLE dbo.Fact_Sales WITH CHECK ADD CONSTRAINT FK_Fact_Sales_Dim_Product FOREIGN KEY (Product_Key) REFERENCES dbo.Dim_Product (Product_Key);
ALTER TABLE dbo.Fact_Sales WITH CHECK ADD CONSTRAINT FK_Fact_Sales_Dim_Retailer FOREIGN KEY (Retailer_Key) REFERENCES dbo.Dim_Retailer (Retailer_Key);
ALTER TABLE dbo.Fact_Sales WITH CHECK ADD CONSTRAINT FK_Fact_Sales_Dim_Geography FOREIGN KEY (Geography_Key) REFERENCES dbo.Dim_Geography (Geography_Key);
ALTER TABLE dbo.Fact_Sales WITH CHECK ADD CONSTRAINT FK_Fact_Sales_Dim_Channel FOREIGN KEY (Channel_Key) REFERENCES dbo.Dim_Channel (Channel_Key);
ALTER TABLE dbo.Fact_Sales WITH CHECK ADD CONSTRAINT FK_Fact_Sales_Dim_Promotion FOREIGN KEY (Promotion_Key) REFERENCES dbo.Dim_Promotion (Promotion_Key);
ALTER TABLE dbo.Fact_Inventory_Snapshot WITH CHECK ADD CONSTRAINT FK_Fact_Inventory_Snapshot_Dim_Date FOREIGN KEY (Date_Key) REFERENCES dbo.Dim_Date (Date_Key);
ALTER TABLE dbo.Fact_Inventory_Snapshot WITH CHECK ADD CONSTRAINT FK_Fact_Inventory_Snapshot_Dim_Product FOREIGN KEY (Product_Key) REFERENCES dbo.Dim_Product (Product_Key);
ALTER TABLE dbo.Fact_Inventory_Snapshot WITH CHECK ADD CONSTRAINT FK_Fact_Inventory_Snapshot_Dim_Retailer FOREIGN KEY (Retailer_Key) REFERENCES dbo.Dim_Retailer (Retailer_Key);
GO

/* ------------------------------------------------------------------------------------------
   11. Indexes: one per fact foreign key (star-join filtering) + SCD2 range-lookup indexes
   ------------------------------------------------------------------------------------------ */
CREATE NONCLUSTERED INDEX IX_Fact_Sales_Date_Key ON dbo.Fact_Sales (Date_Key);
CREATE NONCLUSTERED INDEX IX_Fact_Sales_Product_Key ON dbo.Fact_Sales (Product_Key);
CREATE NONCLUSTERED INDEX IX_Fact_Sales_Retailer_Key ON dbo.Fact_Sales (Retailer_Key);
CREATE NONCLUSTERED INDEX IX_Fact_Sales_Geography_Key ON dbo.Fact_Sales (Geography_Key);
CREATE NONCLUSTERED INDEX IX_Fact_Sales_Channel_Key ON dbo.Fact_Sales (Channel_Key);
CREATE NONCLUSTERED INDEX IX_Fact_Sales_Promotion_Key ON dbo.Fact_Sales (Promotion_Key);
CREATE NONCLUSTERED INDEX IX_Fact_Inventory_Snapshot_Date_Key ON dbo.Fact_Inventory_Snapshot (Date_Key);
CREATE NONCLUSTERED INDEX IX_Fact_Inventory_Snapshot_Product_Key ON dbo.Fact_Inventory_Snapshot (Product_Key);
CREATE NONCLUSTERED INDEX IX_Fact_Inventory_Snapshot_Retailer_Key ON dbo.Fact_Inventory_Snapshot (Retailer_Key);
CREATE NONCLUSTERED INDEX IX_Dim_Product_Lookup ON dbo.Dim_Product (Product_ID, Effective_Start_Date, Effective_End_Date) INCLUDE (Product_Key);
CREATE NONCLUSTERED INDEX IX_Dim_Retailer_Lookup ON dbo.Dim_Retailer (Retailer_ID, Effective_Start_Date, Effective_End_Date) INCLUDE (Retailer_Key);
CREATE NONCLUSTERED INDEX IX_Dim_Date_Fiscal ON dbo.Dim_Date (Fiscal_Year, Fiscal_Quarter_No, Fiscal_Month_No);
CREATE NONCLUSTERED INDEX IX_Fact_Sales_Source ON dbo.Fact_Sales (Source_System, Line_Type) INCLUDE (Net_Sales_Amount, Operating_Profit);
GO

/* ------------------------------------------------------------------------------------------
   12. Data dictionary as MS_Description extended properties (imported by PowerDesigner as Comments)
   ------------------------------------------------------------------------------------------ */
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Calendar and Nike fiscal calendar (FY ends 31 May), one row per day 2019-01-01..2025-12-31, with US federal holidays and retail events.', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Smart surrogate key yyyymmdd', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Date_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Calendar date', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Full_Date';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'ISO weekday 1 = Monday .. 7 = Sunday', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Day_Of_Week_No';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Weekday name (English)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Day_Name';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Weekday abbreviation', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Day_Name_Short';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'1 = Saturday or Sunday', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Is_Weekend';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Day number in month', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Day_Of_Month';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Day number in calendar year', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Day_Of_Year';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'ISO-8601 week number', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'ISO_Week_No';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Monday of the ISO week', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Week_Start_Date';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Calendar month number', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Month_No';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Month name (English)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Month_Name';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Month abbreviation', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Month_Name_Short';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Sortable year-month label yyyy-MM', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Year_Month';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Calendar quarter', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Quarter_No';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Calendar year', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Calendar_Year';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Calendar quarter label e.g. 2023 Q4', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Quarter_Label';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'1 = last day of month (inventory snapshot dates)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Is_Month_End';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Nike fiscal year (June-May); FY2023 = Jun 2022-May 2023', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Fiscal_Year';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Fiscal year label e.g. FY2023', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Fiscal_Year_Label';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Fiscal month (June = 1 .. May = 12)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Fiscal_Month_No';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Fiscal quarter (Q1 = Jun-Aug)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Fiscal_Quarter_No';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Fiscal quarter label e.g. FY23 Q1', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Fiscal_Quarter_Label';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Meteorological season (US)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Season';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'1 = US federal holiday (actual date)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Is_Federal_Holiday';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'1 = retail event (Black Friday, Cyber Monday, Easter, ...)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Is_Retail_Event';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Holiday / event name(s); collisions joined with '' / ''', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Date', @level2type = N'COLUMN', @level2name = N'Holiday_Event_Name';
GO
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Product (style-colour SKU) with derived hierarchy; SCD Type 2 on list price, price band and lifecycle status.', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Surrogate key; -1 = Unknown product', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Product_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Natural key: Nike style-colour code (e.g. CJ1646-600)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Product_ID';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Style part of the SKU', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Style_Code';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Colourway part of the SKU', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Color_Code';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Product name, (R) symbol and double spaces removed', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Product_Name';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Nike or Jordan Brand', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Brand_Line';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Sport category (Running, Football, Basketball, Lifestyle, ...)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Category';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Franchise / model family (Air Max, Air Force 1, Pegasus, ...)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Franchise';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Shoe, Boot, Slide, Flip-Flop, Sandal', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Product_Type';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Gender segment from the product description', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Gender_Segment';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Suggested retail price in USD valid for this version (SCD2)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'List_Price_USD';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Price band of List_Price_USD (SCD2)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Price_Band';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Lifecycle state valid for this version (SCD2)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Lifecycle_Status';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Average star rating on nike.com (2020-04-13); NULL = not yet rated', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Web_Rating';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Number of web reviews', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Web_Review_Count';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Rated / Not Rated flag', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Rating_Status';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Web markdown on 2020-04-13 as a fraction', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Web_Discount_Pct';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Number of product images on the web page', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Image_Count';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Product page URL (tooltip / URL action)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Product_URL';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'SCD2 version number per Product_ID', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Version_No';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'SCD2 row valid from (inclusive)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Effective_Start_Date';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'SCD2 row valid to (inclusive); 9999-12-31 = current', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Effective_End_Date';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'1 = current version', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Is_Current';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Why this version was created', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Product', @level2type = N'COLUMN', @level2name = N'Row_Change_Reason';
GO
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Retail account (wholesale partner or Nike Direct); SCD Type 2 on partner tier, key account manager and payment terms.', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Retailer';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Surrogate key; -1 = Unknown retailer', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Retailer', @level2type = N'COLUMN', @level2name = N'Retailer_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Natural key from source systems (P1 Retailer ID)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Retailer', @level2type = N'COLUMN', @level2name = N'Retailer_ID';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Account name (fictional for P1 IDs)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Retailer', @level2type = N'COLUMN', @level2name = N'Retailer_Name';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Specialty Athletic Chain, Mass Merchant, ...', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Retailer', @level2type = N'COLUMN', @level2name = N'Retailer_Type';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Wholesale partner vs Nike-owned DTC', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Retailer', @level2type = N'COLUMN', @level2name = N'Ownership_Type';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Commercial tier valid for this version (SCD2)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Retailer', @level2type = N'COLUMN', @level2name = N'Partner_Tier';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Nike account manager valid for this version (SCD2)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Retailer', @level2type = N'COLUMN', @level2name = N'Key_Account_Manager';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Payment terms in days (SCD2)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Retailer', @level2type = N'COLUMN', @level2name = N'Payment_Terms_Days';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Head-office state', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Retailer', @level2type = N'COLUMN', @level2name = N'HQ_State';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Date the account was opened', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Retailer', @level2type = N'COLUMN', @level2name = N'Onboard_Date';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'SCD2 version number per Retailer_ID', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Retailer', @level2type = N'COLUMN', @level2name = N'Version_No';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'SCD2 row valid from (inclusive)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Retailer', @level2type = N'COLUMN', @level2name = N'Effective_Start_Date';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'SCD2 row valid to (inclusive); 9999-12-31 = current', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Retailer', @level2type = N'COLUMN', @level2name = N'Effective_End_Date';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'1 = current version', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Retailer', @level2type = N'COLUMN', @level2name = N'Is_Current';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Why this version was created', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Retailer', @level2type = N'COLUMN', @level2name = N'Row_Change_Reason';
GO
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'US city of sale with state, company sales region and Census hierarchy; natural key = City + State.', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Geography';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Surrogate key; -1 = Unknown', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Geography', @level2type = N'COLUMN', @level2name = N'Geography_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Business code STATE-CITY (e.g. OR-PORTLAND)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Geography', @level2type = N'COLUMN', @level2name = N'Geo_Code';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'City name', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Geography', @level2type = N'COLUMN', @level2name = N'City';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'State full name', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Geography', @level2type = N'COLUMN', @level2name = N'State_Name';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'USPS state code (ZZ = unknown member)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Geography', @level2type = N'COLUMN', @level2name = N'State_Code';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Company sales territory from P1 (not Census)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Geography', @level2type = N'COLUMN', @level2name = N'Sales_Region';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'US Census region', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Geography', @level2type = N'COLUMN', @level2name = N'Census_Region';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'US Census division', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Geography', @level2type = N'COLUMN', @level2name = N'Census_Division';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Time zone of the city', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Geography', @level2type = N'COLUMN', @level2name = N'Time_Zone';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Tier 1 Major Metro / Tier 2 Mid / Tier 3 Small market', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Geography', @level2type = N'COLUMN', @level2name = N'City_Tier';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'1 = market with a Nike Direct flagship store', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Geography', @level2type = N'COLUMN', @level2name = N'Is_DTC_Flagship_Market';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Display label ''City, ST'' (disambiguates Portland / Charleston)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Geography', @level2type = N'COLUMN', @level2name = N'City_State_Label';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'ISO country code', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Geography', @level2type = N'COLUMN', @level2name = N'Country_Code';
GO
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Sales channel (P1 ''Sales Method'' / OMS ''sales_channel'').', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Channel';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Surrogate key; -1 = Unknown', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Channel', @level2type = N'COLUMN', @level2name = N'Channel_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Channel code used in OMS invoice numbers (IS/ON/OT; UN = unknown)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Channel', @level2type = N'COLUMN', @level2name = N'Channel_Code';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Channel name', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Channel', @level2type = N'COLUMN', @level2name = N'Channel_Name';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Physical vs Digital', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Channel', @level2type = N'COLUMN', @level2name = N'Channel_Group';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Full-Price vs Off-Price', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Channel', @level2type = N'COLUMN', @level2name = N'Price_Positioning';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Display order', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Channel', @level2type = N'COLUMN', @level2name = N'Sort_Order';
GO
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Promotion campaign 2022-2024 plus special members (0 none, -1 unknown code, -2 not captured in P1 legacy data).', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Promotion';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Surrogate key; 0 none, -1 unknown, -2 legacy', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Promotion', @level2type = N'COLUMN', @level2name = N'Promotion_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Business code (e.g. BFCM23)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Promotion', @level2type = N'COLUMN', @level2name = N'Promo_Code';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Campaign name', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Promotion', @level2type = N'COLUMN', @level2name = N'Promo_Name';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Clearance / Seasonal Event / Holiday Event / Loyalty-Member / special', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Promotion', @level2type = N'COLUMN', @level2name = N'Promo_Type';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Discount off the unit price as a fraction', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Promotion', @level2type = N'COLUMN', @level2name = N'Discount_Pct';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'First day of the campaign', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Promotion', @level2type = N'COLUMN', @level2name = N'Start_Date';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Last day of the campaign', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Promotion', @level2type = N'COLUMN', @level2name = N'End_Date';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Pipe-delimited channel list', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Promotion', @level2type = N'COLUMN', @level2name = N'Eligible_Channels';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Nike fiscal year of the start date', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Promotion', @level2type = N'COLUMN', @level2name = N'Promo_Fiscal_Year';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Nike-funded markdown vs co-funded with retailer', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Promotion', @level2type = N'COLUMN', @level2name = N'Funding_Type';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Campaign length in days', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Dim_Promotion', @level2type = N'COLUMN', @level2name = N'Promo_Duration_Days';
GO
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Transaction fact. Grain: one invoice line or credit-memo line (product x document x retailer x city x channel x day x promotion).', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Surrogate key of the line', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Sales_Line_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Invoice / credit-memo date', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Date_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Product version valid on the invoice date', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Product_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Retailer version valid on the invoice date', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Retailer_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'City of sale', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Geography_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Sales channel', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Channel_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Promotion applied to the line', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Promotion_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Degenerate dimension: invoice / credit-memo number', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Invoice_No';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Line number on the document', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Invoice_Line_No';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'SALE or RETURN (credit memo)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Line_Type';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Original invoice of a RETURN line', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Ref_Invoice_No';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Lineage: which source produced the line', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Source_System';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Units sold (additive)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Units_Sold';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Units returned (additive)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Units_Returned';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Selling price per unit before promotion (non-additive)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Unit_Price';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Units_Sold x Unit_Price (additive)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Gross_Sales_Amount';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Promotion discount given (additive)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Promo_Discount_Amount';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Value credited back on RETURN lines (additive)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Return_Amount';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Gross - Promo discount - Returns (additive; negative on RETURN lines)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Net_Sales_Amount';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Operating profit of the line (additive; negative on RETURN lines)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Operating_Profit';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Line margin as given / recomputed (non-additive: never SUM or AVG it)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Operating_Margin_Pct';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'10 = P1 line divided by 10 (scale defect F6); 1 otherwise', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'Scale_Correction_Factor';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Pipe-delimited data-quality fixes applied to this line', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'DQ_Issue_Codes';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Load timestamp of the Prep run', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Sales', @level2type = N'COLUMN', @level2name = N'ETL_Load_Date';
GO
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Periodic snapshot fact. Grain: one row per product version x retailer account x calendar month-end.', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Inventory_Snapshot';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Surrogate key', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Inventory_Snapshot', @level2type = N'COLUMN', @level2name = N'Inventory_Snapshot_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Month-end snapshot date', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Inventory_Snapshot', @level2type = N'COLUMN', @level2name = N'Date_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Product version valid on the snapshot date', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Inventory_Snapshot', @level2type = N'COLUMN', @level2name = N'Product_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Retailer version valid on the snapshot date', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Inventory_Snapshot', @level2type = N'COLUMN', @level2name = N'Retailer_Key';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Closing stock (semi-additive: not across time)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Inventory_Snapshot', @level2type = N'COLUMN', @level2name = N'Units_On_Hand';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Open purchase orders (semi-additive)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Inventory_Snapshot', @level2type = N'COLUMN', @level2name = N'Units_On_Order';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Units_On_Hand x Std_Unit_Cost (semi-additive)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Inventory_Snapshot', @level2type = N'COLUMN', @level2name = N'Inventory_Value_Cost';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Receipts in the month (additive)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Inventory_Snapshot', @level2type = N'COLUMN', @level2name = N'Units_Received';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Net shipments in the month; negative when returns exceed shipments (additive)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Inventory_Snapshot', @level2type = N'COLUMN', @level2name = N'Units_Shipped';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Days out of stock in the month (additive)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Inventory_Snapshot', @level2type = N'COLUMN', @level2name = N'Stockout_Days';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Standard cost per unit (non-additive)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Inventory_Snapshot', @level2type = N'COLUMN', @level2name = N'Std_Unit_Cost';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'On-hand / weekly shipments in the month (non-additive; NULL if no shipments)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Inventory_Snapshot', @level2type = N'COLUMN', @level2name = N'Weeks_Of_Supply';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Pipe-delimited DQ fixes (NEG_ON_HAND, SKU_CASE)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Inventory_Snapshot', @level2type = N'COLUMN', @level2name = N'DQ_Issue_Codes';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Load timestamp', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Fact_Inventory_Snapshot', @level2type = N'COLUMN', @level2name = N'ETL_Load_Date';
GO
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'ETL audit: source records rejected or superseded by the Prep flow, with reason.', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Audit_ETL_Reject';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Surrogate key', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Audit_ETL_Reject', @level2type = N'COLUMN', @level2name = N'Reject_ID';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Source that produced the record', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Audit_ETL_Reject', @level2type = N'COLUMN', @level2name = N'Source_System';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'File or file pattern', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Audit_ETL_Reject', @level2type = N'COLUMN', @level2name = N'Source_File';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Natural reference of the record (invoice|line, or date|sku|account)', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Audit_ETL_Reject', @level2type = N'COLUMN', @level2name = N'Source_Record_Ref';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Reason code', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Audit_ETL_Reject', @level2type = N'COLUMN', @level2name = N'Reject_Code';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Readable reason', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Audit_ETL_Reject', @level2type = N'COLUMN', @level2name = N'Reject_Reason';
EXEC sys.sp_addextendedproperty @name = N'MS_Description', @value = N'Load timestamp', @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'Audit_ETL_Reject', @level2type = N'COLUMN', @level2name = N'ETL_Load_Date';
GO

DECLARE @fk_count INT = (SELECT COUNT(*) FROM sys.foreign_keys);
PRINT N'NikeUS_DW schema created: 9 tables, ' + CAST(@fk_count AS NVARCHAR(10)) + N' foreign keys.';
GO
