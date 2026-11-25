/* ==========================================================================================
   2603-389 Project 2 | Group G6 | NikeUS_DW
   ETL control objects, post-deploy objects, validation / reconciliation queries and backup
   Target: Microsoft SQL Server 2022
   Run order:
     PART A once, right after 2603389_2569_P2_G6_DDL.sql (or after the PowerDesigner-generated script)
     PART B after every Tableau Prep run (validation + reconciliation against expected_load_reconciliation.csv)
     PART C when the load is final (creates the .bak for submission)
   ========================================================================================== */
USE NikeUS_DW;
GO

/* ==========================================================================================
   PART A - post-deploy objects
   ========================================================================================== */

/* A1. ETL run log (written by the control procedures, not by Prep) */
IF OBJECT_ID(N'dbo.ETL_Run_Log', N'U') IS NULL
CREATE TABLE dbo.ETL_Run_Log
(
    Run_Log_ID   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ETL_Run_Log PRIMARY KEY,
    Event_Name   VARCHAR(30)       NOT NULL,
    Event_Time   DATETIME2(0)      NOT NULL CONSTRAINT DF_ETL_Run_Log_Time DEFAULT (SYSDATETIME()),
    Detail       NVARCHAR(4000)    NULL
);
GO

/* A2. Optional staging table for the Dim_Date T-SQL fallback (load S8 with BULK INSERT, see A5) */
IF OBJECT_ID(N'dbo.Stg_Holiday_Event', N'U') IS NULL
CREATE TABLE dbo.Stg_Holiday_Event
(
    event_date          DATE          NOT NULL CONSTRAINT PK_Stg_Holiday_Event PRIMARY KEY,
    event_name          VARCHAR(60)   NOT NULL,
    is_federal_holiday  TINYINT       NOT NULL,
    is_retail_event     TINYINT       NOT NULL,
    event_type          VARCHAR(40)   NOT NULL
);
GO

/* A3. Filtered unique indexes: exactly one current SCD2 row per natural key */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Dim_Product_Current')
    CREATE UNIQUE NONCLUSTERED INDEX UX_Dim_Product_Current ON dbo.Dim_Product (Product_ID) WHERE Is_Current = 1;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UX_Dim_Retailer_Current')
    CREATE UNIQUE NONCLUSTERED INDEX UX_Dim_Retailer_Current ON dbo.Dim_Retailer (Retailer_ID) WHERE Is_Current = 1;
GO

/* A4. Nonclustered columnstore index for fast aggregation by Tableau (extract refresh / live queries) */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'NCCI_Fact_Sales')
    CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_Fact_Sales ON dbo.Fact_Sales
    (Date_Key, Product_Key, Retailer_Key, Geography_Key, Channel_Key, Promotion_Key, Line_Type, Source_System,
     Units_Sold, Units_Returned, Gross_Sales_Amount, Promo_Discount_Amount, Return_Amount, Net_Sales_Amount, Operating_Profit);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'NCCI_Fact_Inventory_Snapshot')
    CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_Fact_Inventory_Snapshot ON dbo.Fact_Inventory_Snapshot
    (Date_Key, Product_Key, Retailer_Key, Units_On_Hand, Units_On_Order, Inventory_Value_Cost, Units_Received, Units_Shipped, Stockout_Days);
GO

/* A5. Load-control procedures called from Tableau Prep Output steps (Custom SQL tab)
       Before-SQL on EVERY output :  EXEC dbo.usp_ETL_BeginLoad;
       After-SQL on the LAST output:  EXEC dbo.usp_ETL_EndLoad;
   BeginLoad drops the fact foreign keys so that "Replace data" can delete and reload dimensions in any order.
   EndLoad checks for orphans; only when there are none does it recreate the FKs WITH CHECK (trusted). */
CREATE OR ALTER PROCEDURE dbo.usp_ETL_BeginLoad
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql NVARCHAR(MAX) = N'';
    SELECT @sql += N'ALTER TABLE ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + N'.'
                 + QUOTENAME(OBJECT_NAME(fk.parent_object_id)) + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) + N'; '
    FROM sys.foreign_keys AS fk
    WHERE fk.parent_object_id IN (OBJECT_ID(N'dbo.Fact_Sales'), OBJECT_ID(N'dbo.Fact_Inventory_Snapshot'));
    IF @sql <> N''
    BEGIN
        EXEC sys.sp_executesql @sql;
        INSERT INTO dbo.ETL_Run_Log (Event_Name, Detail) VALUES ('BEGIN_LOAD', N'Fact foreign keys dropped');
    END
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ETL_EndLoad
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @o TABLE (FK_Column NVARCHAR(128) NOT NULL, Orphan_Rows BIGINT NOT NULL);
    INSERT INTO @o SELECT N'Fact_Sales.Date_Key', COUNT_BIG(*) FROM dbo.Fact_Sales AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Date AS d WHERE d.Date_Key = f.Date_Key);
    INSERT INTO @o SELECT N'Fact_Sales.Product_Key', COUNT_BIG(*) FROM dbo.Fact_Sales AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Product AS d WHERE d.Product_Key = f.Product_Key);
    INSERT INTO @o SELECT N'Fact_Sales.Retailer_Key', COUNT_BIG(*) FROM dbo.Fact_Sales AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Retailer AS d WHERE d.Retailer_Key = f.Retailer_Key);
    INSERT INTO @o SELECT N'Fact_Sales.Geography_Key', COUNT_BIG(*) FROM dbo.Fact_Sales AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Geography AS d WHERE d.Geography_Key = f.Geography_Key);
    INSERT INTO @o SELECT N'Fact_Sales.Channel_Key', COUNT_BIG(*) FROM dbo.Fact_Sales AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Channel AS d WHERE d.Channel_Key = f.Channel_Key);
    INSERT INTO @o SELECT N'Fact_Sales.Promotion_Key', COUNT_BIG(*) FROM dbo.Fact_Sales AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Promotion AS d WHERE d.Promotion_Key = f.Promotion_Key);
    INSERT INTO @o SELECT N'Fact_Inventory_Snapshot.Date_Key', COUNT_BIG(*) FROM dbo.Fact_Inventory_Snapshot AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Date AS d WHERE d.Date_Key = f.Date_Key);
    INSERT INTO @o SELECT N'Fact_Inventory_Snapshot.Product_Key', COUNT_BIG(*) FROM dbo.Fact_Inventory_Snapshot AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Product AS d WHERE d.Product_Key = f.Product_Key);
    INSERT INTO @o SELECT N'Fact_Inventory_Snapshot.Retailer_Key', COUNT_BIG(*) FROM dbo.Fact_Inventory_Snapshot AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Retailer AS d WHERE d.Retailer_Key = f.Retailer_Key);
    IF EXISTS (SELECT 1 FROM @o WHERE Orphan_Rows > 0)
    BEGIN
        SELECT FK_Column, Orphan_Rows FROM @o WHERE Orphan_Rows > 0;
        INSERT INTO dbo.ETL_Run_Log (Event_Name, Detail)
        SELECT 'END_LOAD_ABORTED', STRING_AGG(CONCAT(FK_Column, N'=', Orphan_Rows), N'; ') FROM @o WHERE Orphan_Rows > 0;
        RAISERROR(N'usp_ETL_EndLoad: orphan keys found - run the remaining dimension outputs, then EXEC dbo.usp_ETL_EndLoad again.', 16, 1);
        RETURN;
    END;
    IF NOT EXISTS (SELECT 1 FROM sys.foreign_key_columns AS k WHERE k.parent_object_id = OBJECT_ID(N'dbo.Fact_Sales') AND COL_NAME(k.parent_object_id, k.parent_column_id) = N'Date_Key')
        ALTER TABLE dbo.Fact_Sales WITH CHECK ADD CONSTRAINT FK_Fact_Sales_Dim_Date FOREIGN KEY (Date_Key) REFERENCES dbo.Dim_Date (Date_Key);
    IF NOT EXISTS (SELECT 1 FROM sys.foreign_key_columns AS k WHERE k.parent_object_id = OBJECT_ID(N'dbo.Fact_Sales') AND COL_NAME(k.parent_object_id, k.parent_column_id) = N'Product_Key')
        ALTER TABLE dbo.Fact_Sales WITH CHECK ADD CONSTRAINT FK_Fact_Sales_Dim_Product FOREIGN KEY (Product_Key) REFERENCES dbo.Dim_Product (Product_Key);
    IF NOT EXISTS (SELECT 1 FROM sys.foreign_key_columns AS k WHERE k.parent_object_id = OBJECT_ID(N'dbo.Fact_Sales') AND COL_NAME(k.parent_object_id, k.parent_column_id) = N'Retailer_Key')
        ALTER TABLE dbo.Fact_Sales WITH CHECK ADD CONSTRAINT FK_Fact_Sales_Dim_Retailer FOREIGN KEY (Retailer_Key) REFERENCES dbo.Dim_Retailer (Retailer_Key);
    IF NOT EXISTS (SELECT 1 FROM sys.foreign_key_columns AS k WHERE k.parent_object_id = OBJECT_ID(N'dbo.Fact_Sales') AND COL_NAME(k.parent_object_id, k.parent_column_id) = N'Geography_Key')
        ALTER TABLE dbo.Fact_Sales WITH CHECK ADD CONSTRAINT FK_Fact_Sales_Dim_Geography FOREIGN KEY (Geography_Key) REFERENCES dbo.Dim_Geography (Geography_Key);
    IF NOT EXISTS (SELECT 1 FROM sys.foreign_key_columns AS k WHERE k.parent_object_id = OBJECT_ID(N'dbo.Fact_Sales') AND COL_NAME(k.parent_object_id, k.parent_column_id) = N'Channel_Key')
        ALTER TABLE dbo.Fact_Sales WITH CHECK ADD CONSTRAINT FK_Fact_Sales_Dim_Channel FOREIGN KEY (Channel_Key) REFERENCES dbo.Dim_Channel (Channel_Key);
    IF NOT EXISTS (SELECT 1 FROM sys.foreign_key_columns AS k WHERE k.parent_object_id = OBJECT_ID(N'dbo.Fact_Sales') AND COL_NAME(k.parent_object_id, k.parent_column_id) = N'Promotion_Key')
        ALTER TABLE dbo.Fact_Sales WITH CHECK ADD CONSTRAINT FK_Fact_Sales_Dim_Promotion FOREIGN KEY (Promotion_Key) REFERENCES dbo.Dim_Promotion (Promotion_Key);
    IF NOT EXISTS (SELECT 1 FROM sys.foreign_key_columns AS k WHERE k.parent_object_id = OBJECT_ID(N'dbo.Fact_Inventory_Snapshot') AND COL_NAME(k.parent_object_id, k.parent_column_id) = N'Date_Key')
        ALTER TABLE dbo.Fact_Inventory_Snapshot WITH CHECK ADD CONSTRAINT FK_Fact_Inventory_Snapshot_Dim_Date FOREIGN KEY (Date_Key) REFERENCES dbo.Dim_Date (Date_Key);
    IF NOT EXISTS (SELECT 1 FROM sys.foreign_key_columns AS k WHERE k.parent_object_id = OBJECT_ID(N'dbo.Fact_Inventory_Snapshot') AND COL_NAME(k.parent_object_id, k.parent_column_id) = N'Product_Key')
        ALTER TABLE dbo.Fact_Inventory_Snapshot WITH CHECK ADD CONSTRAINT FK_Fact_Inventory_Snapshot_Dim_Product FOREIGN KEY (Product_Key) REFERENCES dbo.Dim_Product (Product_Key);
    IF NOT EXISTS (SELECT 1 FROM sys.foreign_key_columns AS k WHERE k.parent_object_id = OBJECT_ID(N'dbo.Fact_Inventory_Snapshot') AND COL_NAME(k.parent_object_id, k.parent_column_id) = N'Retailer_Key')
        ALTER TABLE dbo.Fact_Inventory_Snapshot WITH CHECK ADD CONSTRAINT FK_Fact_Inventory_Snapshot_Dim_Retailer FOREIGN KEY (Retailer_Key) REFERENCES dbo.Dim_Retailer (Retailer_Key);
    ALTER TABLE dbo.Fact_Sales WITH CHECK CHECK CONSTRAINT ALL;
    ALTER TABLE dbo.Fact_Inventory_Snapshot WITH CHECK CHECK CONSTRAINT ALL;
    UPDATE STATISTICS dbo.Fact_Sales;
    UPDATE STATISTICS dbo.Fact_Inventory_Snapshot;
    DECLARE @fs BIGINT = (SELECT COUNT_BIG(*) FROM dbo.Fact_Sales),
            @fi BIGINT = (SELECT COUNT_BIG(*) FROM dbo.Fact_Inventory_Snapshot);
    INSERT INTO dbo.ETL_Run_Log (Event_Name, Detail)
    VALUES ('END_LOAD', CONCAT(N'Fact_Sales=', @fs, N'; Fact_Inventory_Snapshot=', @fi, N'; foreign keys recreated WITH CHECK'));
END;
GO

/* A6. Dim_Date T-SQL fallback - use ONLY if the Prep "New Rows" date spine is unavailable (Prep < 2021.3).
       Optional holidays: BULK INSERT dbo.Stg_Holiday_Event FROM 'C:\...\us_holidays_retail_events.csv'
                          WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001');
       Then: EXEC dbo.usp_ETL_BeginLoad; EXEC dbo.usp_Load_Dim_Date; (reload facts) EXEC dbo.usp_ETL_EndLoad; */
CREATE OR ALTER PROCEDURE dbo.usp_Load_Dim_Date
    @StartDate DATE = '2019-01-01',
    @EndDate   DATE = '2025-12-31'
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.Dim_Date;
    WITH n AS (
        SELECT TOP (DATEDIFF(DAY, @StartDate, @EndDate) + 1)
               ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
        FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
    ), d AS (
        SELECT DATEADD(DAY, i, @StartDate) AS dt FROM n
    ), c AS (
        SELECT dt,
               (DATEDIFF(DAY, '20181231', dt) % 7) + 1                       AS dow,
               MONTH(dt)                                                    AS m,
               YEAR(dt)                                                     AS y,
               CASE WHEN MONTH(dt) >= 6 THEN YEAR(dt) + 1 ELSE YEAR(dt) END AS fy,
               CASE WHEN MONTH(dt) >= 6 THEN MONTH(dt) - 5 ELSE MONTH(dt) + 7 END AS fm
        FROM d
    )
    INSERT INTO dbo.Dim_Date
        (Date_Key, Full_Date, Day_Of_Week_No, Day_Name, Day_Name_Short, Is_Weekend, Day_Of_Month, Day_Of_Year,
         ISO_Week_No, Week_Start_Date, Month_No, Month_Name, Month_Name_Short, Year_Month, Quarter_No, Calendar_Year,
         Quarter_Label, Is_Month_End, Fiscal_Year, Fiscal_Year_Label, Fiscal_Month_No, Fiscal_Quarter_No,
         Fiscal_Quarter_Label, Season, Is_Federal_Holiday, Is_Retail_Event, Holiday_Event_Name)
    SELECT CONVERT(INT, CONVERT(CHAR(8), c.dt, 112)),
           c.dt,
           c.dow,
           CHOOSE(c.dow, 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'),
           CHOOSE(c.dow, 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'),
           CASE WHEN c.dow >= 6 THEN 1 ELSE 0 END,
           DAY(c.dt),
           DATEPART(DAYOFYEAR, c.dt),
           DATEPART(ISO_WEEK, c.dt),
           DATEADD(DAY, 1 - c.dow, c.dt),
           c.m,
           CHOOSE(c.m, 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'),
           CHOOSE(c.m, 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'),
           CONVERT(CHAR(7), c.dt, 126),
           DATEPART(QUARTER, c.dt),
           c.y,
           CONCAT(c.y, ' Q', DATEPART(QUARTER, c.dt)),
           CASE WHEN c.dt = EOMONTH(c.dt) THEN 1 ELSE 0 END,
           c.fy,
           CONCAT('FY', c.fy),
           c.fm,
           (c.fm + 2) / 3,
           CONCAT('FY', RIGHT(CAST(c.fy AS CHAR(4)), 2), ' Q', (c.fm + 2) / 3),
           CASE WHEN c.m IN (12, 1, 2) THEN 'Winter' WHEN c.m IN (3, 4, 5) THEN 'Spring'
                WHEN c.m IN (6, 7, 8) THEN 'Summer' ELSE 'Fall' END,
           ISNULL(h.is_federal_holiday, 0),
           ISNULL(h.is_retail_event, 0),
           h.event_name
    FROM c
    LEFT JOIN dbo.Stg_Holiday_Event AS h ON h.event_date = c.dt;
    INSERT INTO dbo.ETL_Run_Log (Event_Name, Detail) VALUES ('DIM_DATE_FALLBACK', CONCAT(N'Rows=', @@ROWCOUNT));
END;
GO

/* A7. Flattened analysis views (SSMS checks; Tableau should use the star with relationships instead) */
CREATE OR ALTER VIEW dbo.vw_Sales_Star
AS
SELECT f.Sales_Line_Key, f.Invoice_No, f.Invoice_Line_No, f.Line_Type, f.Source_System,
       d.Full_Date, d.Calendar_Year, d.Quarter_Label, d.Year_Month, d.Fiscal_Year_Label, d.Fiscal_Quarter_Label,
       p.Product_ID, p.Product_Name, p.Brand_Line, p.Category, p.Franchise, p.Price_Band, p.Lifecycle_Status, p.List_Price_USD,
       r.Retailer_ID, r.Retailer_Name, r.Ownership_Type, r.Partner_Tier,
       g.City_State_Label, g.State_Name, g.Sales_Region, g.Census_Region, g.City_Tier,
       c.Channel_Name, c.Channel_Group,
       pr.Promo_Code, pr.Promo_Type,
       f.Units_Sold, f.Units_Returned, f.Unit_Price, f.Gross_Sales_Amount, f.Promo_Discount_Amount, f.Return_Amount,
       f.Net_Sales_Amount, f.Operating_Profit, f.Scale_Correction_Factor, f.DQ_Issue_Codes
FROM dbo.Fact_Sales AS f
JOIN dbo.Dim_Date      AS d  ON d.Date_Key = f.Date_Key
JOIN dbo.Dim_Product   AS p  ON p.Product_Key = f.Product_Key
JOIN dbo.Dim_Retailer  AS r  ON r.Retailer_Key = f.Retailer_Key
JOIN dbo.Dim_Geography AS g  ON g.Geography_Key = f.Geography_Key
JOIN dbo.Dim_Channel   AS c  ON c.Channel_Key = f.Channel_Key
JOIN dbo.Dim_Promotion AS pr ON pr.Promotion_Key = f.Promotion_Key;
GO

CREATE OR ALTER VIEW dbo.vw_Inventory_Star
AS
SELECT i.Inventory_Snapshot_Key, d.Full_Date AS Snapshot_Date, d.Year_Month, d.Fiscal_Year_Label, d.Fiscal_Quarter_Label,
       p.Product_ID, p.Product_Name, p.Category, p.Franchise, p.Lifecycle_Status,
       r.Retailer_Name, r.Ownership_Type, r.Partner_Tier,
       i.Units_On_Hand, i.Units_On_Order, i.Inventory_Value_Cost, i.Units_Received, i.Units_Shipped,
       i.Stockout_Days, i.Std_Unit_Cost, i.Weeks_Of_Supply, i.DQ_Issue_Codes
FROM dbo.Fact_Inventory_Snapshot AS i
JOIN dbo.Dim_Date     AS d ON d.Date_Key = i.Date_Key
JOIN dbo.Dim_Product  AS p ON p.Product_Key = i.Product_Key
JOIN dbo.Dim_Retailer AS r ON r.Retailer_Key = i.Retailer_Key;
GO

/* ==========================================================================================
   PART B - validation and reconciliation (run after each Prep load; expected values are in
            99_Reference_Golden_Output/expected_load_reconciliation.csv)
   ========================================================================================== */

/* B0. Finish the load if the last Prep output did not already do it */
EXEC dbo.usp_ETL_EndLoad;
GO

/* B1. Row counts - expected: Dim_Date 2,557 | Dim_Product 1,242 | Dim_Retailer 11 | Dim_Geography 55 |
       Dim_Channel 4 | Dim_Promotion 27 | Fact_Sales 43,248 | Fact_Inventory_Snapshot 96,094 | Audit_ETL_Reject 528 */
SELECT 'Dim_Date' AS Table_Name, COUNT_BIG(*) AS Row_Count FROM dbo.Dim_Date
UNION ALL SELECT 'Dim_Product', COUNT_BIG(*) FROM dbo.Dim_Product
UNION ALL SELECT 'Dim_Retailer', COUNT_BIG(*) FROM dbo.Dim_Retailer
UNION ALL SELECT 'Dim_Geography', COUNT_BIG(*) FROM dbo.Dim_Geography
UNION ALL SELECT 'Dim_Channel', COUNT_BIG(*) FROM dbo.Dim_Channel
UNION ALL SELECT 'Dim_Promotion', COUNT_BIG(*) FROM dbo.Dim_Promotion
UNION ALL SELECT 'Fact_Sales', COUNT_BIG(*) FROM dbo.Fact_Sales
UNION ALL SELECT 'Fact_Inventory_Snapshot', COUNT_BIG(*) FROM dbo.Fact_Inventory_Snapshot
UNION ALL SELECT 'Audit_ETL_Reject', COUNT_BIG(*) FROM dbo.Audit_ETL_Reject;

/* B2. Fact_Sales totals by calendar year (compare with the SUM(...) rows of the expected file) */
SELECT d.Calendar_Year,
       COUNT_BIG(*)                 AS Lines,
       SUM(f.Units_Sold)            AS Units_Sold,
       SUM(f.Units_Returned)        AS Units_Returned,
       SUM(f.Gross_Sales_Amount)    AS Gross_Sales,
       SUM(f.Promo_Discount_Amount) AS Promo_Discount,
       SUM(f.Return_Amount)         AS Return_Amount,
       SUM(f.Net_Sales_Amount)      AS Net_Sales,
       SUM(f.Operating_Profit)      AS Operating_Profit,
       CAST(SUM(f.Operating_Profit) / NULLIF(SUM(f.Net_Sales_Amount), 0) AS DECIMAL(6,4)) AS Operating_Margin
FROM dbo.Fact_Sales AS f
JOIN dbo.Dim_Date AS d ON d.Date_Key = f.Date_Key
GROUP BY d.Calendar_Year
ORDER BY d.Calendar_Year;

/* B3. Referential integrity - every row must return 0 */
SELECT N'Fact_Sales.Date_Key' AS FK_Column, COUNT_BIG(*) AS Orphan_Rows FROM dbo.Fact_Sales AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Date AS d WHERE d.Date_Key = f.Date_Key)
UNION ALL SELECT N'Fact_Sales.Product_Key' AS FK_Column, COUNT_BIG(*) AS Orphan_Rows FROM dbo.Fact_Sales AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Product AS d WHERE d.Product_Key = f.Product_Key)
UNION ALL SELECT N'Fact_Sales.Retailer_Key' AS FK_Column, COUNT_BIG(*) AS Orphan_Rows FROM dbo.Fact_Sales AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Retailer AS d WHERE d.Retailer_Key = f.Retailer_Key)
UNION ALL SELECT N'Fact_Sales.Geography_Key' AS FK_Column, COUNT_BIG(*) AS Orphan_Rows FROM dbo.Fact_Sales AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Geography AS d WHERE d.Geography_Key = f.Geography_Key)
UNION ALL SELECT N'Fact_Sales.Channel_Key' AS FK_Column, COUNT_BIG(*) AS Orphan_Rows FROM dbo.Fact_Sales AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Channel AS d WHERE d.Channel_Key = f.Channel_Key)
UNION ALL SELECT N'Fact_Sales.Promotion_Key' AS FK_Column, COUNT_BIG(*) AS Orphan_Rows FROM dbo.Fact_Sales AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Promotion AS d WHERE d.Promotion_Key = f.Promotion_Key)
UNION ALL SELECT N'Fact_Inventory_Snapshot.Date_Key' AS FK_Column, COUNT_BIG(*) AS Orphan_Rows FROM dbo.Fact_Inventory_Snapshot AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Date AS d WHERE d.Date_Key = f.Date_Key)
UNION ALL SELECT N'Fact_Inventory_Snapshot.Product_Key' AS FK_Column, COUNT_BIG(*) AS Orphan_Rows FROM dbo.Fact_Inventory_Snapshot AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Product AS d WHERE d.Product_Key = f.Product_Key)
UNION ALL SELECT N'Fact_Inventory_Snapshot.Retailer_Key' AS FK_Column, COUNT_BIG(*) AS Orphan_Rows FROM dbo.Fact_Inventory_Snapshot AS f WHERE NOT EXISTS (SELECT 1 FROM dbo.Dim_Retailer AS d WHERE d.Retailer_Key = f.Retailer_Key);

/* B4. SCD2 integrity - each query must return no rows */
SELECT 'Product without exactly one current row' AS Issue, Product_ID FROM dbo.Dim_Product
GROUP BY Product_ID HAVING SUM(CAST(Is_Current AS INT)) <> 1
UNION ALL
SELECT 'Retailer without exactly one current row', Retailer_ID FROM dbo.Dim_Retailer
GROUP BY Retailer_ID HAVING SUM(CAST(Is_Current AS INT)) <> 1
UNION ALL
SELECT 'Overlapping product versions', a.Product_ID FROM dbo.Dim_Product AS a
JOIN dbo.Dim_Product AS b ON a.Product_ID = b.Product_ID AND a.Product_Key < b.Product_Key
 AND a.Effective_Start_Date <= b.Effective_End_Date AND b.Effective_Start_Date <= a.Effective_End_Date
UNION ALL
SELECT 'Overlapping retailer versions', a.Retailer_ID FROM dbo.Dim_Retailer AS a
JOIN dbo.Dim_Retailer AS b ON a.Retailer_ID = b.Retailer_ID AND a.Retailer_Key < b.Retailer_Key
 AND a.Effective_Start_Date <= b.Effective_End_Date AND b.Effective_Start_Date <= a.Effective_End_Date;

/* B5. Point-in-time correctness - fact rows pointing to a version not valid on the transaction date (expect 0) */
SELECT COUNT_BIG(*) AS Wrong_Product_Version
FROM dbo.Fact_Sales AS f
JOIN dbo.Dim_Date AS d ON d.Date_Key = f.Date_Key
JOIN dbo.Dim_Product AS p ON p.Product_Key = f.Product_Key
WHERE f.Product_Key > 0 AND d.Full_Date NOT BETWEEN p.Effective_Start_Date AND p.Effective_End_Date;
SELECT COUNT_BIG(*) AS Wrong_Retailer_Version
FROM dbo.Fact_Sales AS f
JOIN dbo.Dim_Date AS d ON d.Date_Key = f.Date_Key
JOIN dbo.Dim_Retailer AS r ON r.Retailer_Key = f.Retailer_Key
WHERE f.Retailer_Key > 0 AND d.Full_Date NOT BETWEEN r.Effective_Start_Date AND r.Effective_End_Date;

/* B6. Special-member usage - expected: Product -1 = 67, Retailer -1 = 33, Geography -1 = 9, Promotion -2 = 9,644 */
SELECT SUM(CASE WHEN Product_Key = -1 THEN 1 ELSE 0 END)   AS Unknown_Product,
       SUM(CASE WHEN Retailer_Key = -1 THEN 1 ELSE 0 END)  AS Unknown_Retailer,
       SUM(CASE WHEN Geography_Key = -1 THEN 1 ELSE 0 END) AS Unknown_Geography,
       SUM(CASE WHEN Channel_Key = -1 THEN 1 ELSE 0 END)   AS Unknown_Channel,
       SUM(CASE WHEN Promotion_Key = -1 THEN 1 ELSE 0 END) AS Unknown_Promotion,
       SUM(CASE WHEN Promotion_Key = -2 THEN 1 ELSE 0 END) AS Legacy_Not_Captured,
       SUM(CASE WHEN Scale_Correction_Factor = 10 THEN 1 ELSE 0 END) AS P1_Scale_Corrected
FROM dbo.Fact_Sales;

/* B7. Rejects by code - expected: R01 4 | R02 202 | R03 34 | R04 288 */
SELECT Reject_Code, COUNT_BIG(*) AS Rejected FROM dbo.Audit_ETL_Reject GROUP BY Reject_Code ORDER BY Reject_Code;

/* B8. Data-quality fixes applied (KPI K17) */
SELECT s.value AS DQ_Code, COUNT_BIG(*) AS Lines
FROM dbo.Fact_Sales AS f
CROSS APPLY STRING_SPLIT(f.DQ_Issue_Codes, '|') AS s
WHERE f.DQ_Issue_Codes IS NOT NULL
GROUP BY s.value
ORDER BY Lines DESC;

/* B9. Constraint health - is_not_trusted and is_disabled must all be 0 */
SELECT 'FK' AS Kind, name, is_not_trusted, is_disabled FROM sys.foreign_keys
UNION ALL
SELECT 'CHECK', name, is_not_trusted, is_disabled FROM sys.check_constraints
ORDER BY Kind, name;

/* B10. KPI smoke test by fiscal year (FY2020 and FY2025 are partial years) */
SELECT d.Fiscal_Year_Label,
       SUM(f.Net_Sales_Amount) AS Net_Sales,
       SUM(f.Operating_Profit) AS Operating_Profit,
       CAST(SUM(f.Operating_Profit) / NULLIF(SUM(f.Net_Sales_Amount), 0) AS DECIMAL(6,4)) AS Margin,
       CAST(SUM(CASE WHEN r.Ownership_Type = 'Nike-Owned' THEN f.Net_Sales_Amount ELSE 0 END)
            / NULLIF(SUM(f.Net_Sales_Amount), 0) AS DECIMAL(6,4)) AS DTC_Share,
       CAST(SUM(f.Units_Returned) * 1.0 / NULLIF(SUM(f.Units_Sold), 0) AS DECIMAL(6,4)) AS Unit_Return_Rate
FROM dbo.Fact_Sales AS f
JOIN dbo.Dim_Date AS d ON d.Date_Key = f.Date_Key
JOIN dbo.Dim_Retailer AS r ON r.Retailer_Key = f.Retailer_Key
GROUP BY d.Fiscal_Year_Label
ORDER BY d.Fiscal_Year_Label;

/* B11. Semi-additive demo: correct ending inventory per fiscal year (last month-end) vs the WRONG sum over months */
WITH fy_end AS (
    SELECT d.Fiscal_Year_Label, MAX(i.Date_Key) AS Last_Date_Key
    FROM dbo.Fact_Inventory_Snapshot AS i JOIN dbo.Dim_Date AS d ON d.Date_Key = i.Date_Key
    GROUP BY d.Fiscal_Year_Label
)
SELECT e.Fiscal_Year_Label,
       SUM(CASE WHEN i.Date_Key = e.Last_Date_Key THEN i.Units_On_Hand END)        AS Ending_On_Hand_Correct,
       SUM(CASE WHEN i.Date_Key = e.Last_Date_Key THEN i.Inventory_Value_Cost END) AS Ending_Value_Correct,
       SUM(i.Units_On_Hand)                                                         AS On_Hand_Summed_Over_Months_WRONG
FROM fy_end AS e
JOIN dbo.Dim_Date AS d ON d.Fiscal_Year_Label = e.Fiscal_Year_Label
JOIN dbo.Fact_Inventory_Snapshot AS i ON i.Date_Key = d.Date_Key
GROUP BY e.Fiscal_Year_Label
ORDER BY e.Fiscal_Year_Label;

/* B12. ETL run log */
SELECT TOP (20) * FROM dbo.ETL_Run_Log ORDER BY Run_Log_ID DESC;
GO

/* ==========================================================================================
   PART C - backup for submission (deliverable 7: 2603389_2569_P2_G6.bak)
   Writes to the instance default backup folder (SQL Server 2019+). Express edition: no COMPRESSION.
   ========================================================================================== */
DECLARE @dir  NVARCHAR(400) = CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS NVARCHAR(400));
DECLARE @file NVARCHAR(500) = @dir + N'\2603389_2569_P2_G6.bak';
BACKUP DATABASE NikeUS_DW TO DISK = @file
    WITH FORMAT, INIT, NAME = N'NikeUS_DW - 2603389_2569_P2_G6 full backup', CHECKSUM, STATS = 10;
RESTORE VERIFYONLY FROM DISK = @file WITH CHECKSUM;
PRINT N'Backup written to ' + @file;
GO
