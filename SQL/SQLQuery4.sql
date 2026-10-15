;WITH ActualSalesByQuarter AS (
    SELECT
        h.SalesPersonID,
        YEAR(h.OrderDate) AS SalesYear,
        DATEPART(QUARTER, h.OrderDate) AS SalesQuarter,
        SUM(d.LineTotal) AS ActualSales,
        COUNT(DISTINCT h.SalesOrderID) AS OrderCount
    FROM Sales.SalesOrderHeader AS h
    INNER JOIN Sales.SalesOrderDetail AS d
        ON h.SalesOrderID = d.SalesOrderID
    WHERE h.SalesPersonID IS NOT NULL
      AND h.OnlineOrderFlag = 0
      AND h.Status = 5
    GROUP BY
        h.SalesPersonID,
        YEAR(h.OrderDate),
        DATEPART(QUARTER, h.OrderDate)
),
QuotaByQuarter AS (
    SELECT
        BusinessEntityID AS SalesPersonID,
        YEAR(QuotaDate) AS QuotaYear,
        DATEPART(QUARTER, QuotaDate) AS QuotaQuarter,
        SalesQuota
    FROM Sales.SalesPersonQuotaHistory
),
Performance AS (
    SELECT
        COALESCE(a.SalesPersonID, q.SalesPersonID)
            AS SalesPersonID,
        COALESCE(a.SalesYear, q.QuotaYear) AS SalesYear,
        COALESCE(a.SalesQuarter, q.QuotaQuarter)
            AS SalesQuarter,
        a.ActualSales,
        a.OrderCount,
        q.SalesQuota
    FROM ActualSalesByQuarter AS a
    FULL OUTER JOIN QuotaByQuarter AS q
        ON a.SalesPersonID = q.SalesPersonID
       AND a.SalesYear = q.QuotaYear
       AND a.SalesQuarter = q.QuotaQuarter
)
SELECT
    COUNT(*) AS PerformanceRows,

    SUM(CASE
        WHEN SalesQuota IS NOT NULL THEN 1
        ELSE 0
    END) AS RowsWithQuota,

    SUM(CASE
        WHEN SalesQuota IS NULL THEN 1
        ELSE 0
    END) AS RowsWithoutQuota,

    SUM(COALESCE(ActualSales, 0)) AS TotalActualSales,

    SUM(CASE
        WHEN SalesQuota IS NOT NULL
         AND ActualSales IS NULL THEN 1
        ELSE 0
    END) AS QuotaPeriodsWithoutSales

FROM Performance;






/*
=========================================================
QUOTA VALIDATION: IDENTIFY UNUSUAL QUOTA CHANGES
=========================================================
Purpose:
Compare each salesperson's current quota with their
previous quota to flag unusually large increases or decreases.

Method:
Use the LAG() window function to retrieve the previous
quota for each salesperson.

Business Reason:
Investigate extreme quota changes before interpreting
salesperson performance and quota attainment.

Note:
Flagged changes require investigation; they are not
automatically considered data errors.
=========================================================
*/

WITH QuotaChanges AS (
    SELECT
        BusinessEntityID,
        QuotaDate,
        SalesQuota,

        LAG(SalesQuota) OVER (
            PARTITION BY BusinessEntityID
            ORDER BY QuotaDate
        ) AS PreviousQuota

    FROM Sales.SalesPersonQuotaHistory
)
SELECT
    BusinessEntityID,
    QuotaDate,
    PreviousQuota,
    SalesQuota,

    CAST(
        100.0 * (SalesQuota - PreviousQuota)
        / NULLIF(PreviousQuota, 0)
        AS DECIMAL(10, 2)
    ) AS QuotaChangePct

FROM QuotaChanges
WHERE PreviousQuota IS NOT NULL
  AND (
      SalesQuota < PreviousQuota * 0.2
      OR SalesQuota > PreviousQuota * 5
  )
ORDER BY
    BusinessEntityID,
    QuotaDate;


    /*
=========================================================
QUOTA INVESTIGATION: COMPARE QUOTA HISTORY WITH ACTUALS
=========================================================
Purpose:
Investigate unusually large changes in quarterly quotas.

Method:
Compare each salesperson's quota history with actual
sales and attainment in the corresponding calendar quarter.

Important:
Large changes are investigation flags, not confirmed errors.
=========================================================
*/

WITH ActualSalesByQuarter AS (
    SELECT
        h.SalesPersonID,
        YEAR(h.OrderDate) AS SalesYear,
        DATEPART(QUARTER, h.OrderDate) AS SalesQuarter,
        SUM(d.LineTotal) AS ActualSales,
        COUNT(DISTINCT h.SalesOrderID) AS OrderCount
    FROM Sales.SalesOrderHeader AS h
    INNER JOIN Sales.SalesOrderDetail AS d
        ON h.SalesOrderID = d.SalesOrderID
    WHERE h.SalesPersonID IS NOT NULL
      AND h.OnlineOrderFlag = 0
      AND h.Status = 5
    GROUP BY
        h.SalesPersonID,
        YEAR(h.OrderDate),
        DATEPART(QUARTER, h.OrderDate)
),
QuotaWithPrevious AS (
    SELECT
        BusinessEntityID,
        QuotaDate,
        SalesQuota,

        YEAR(QuotaDate) AS QuotaYear,
        DATEPART(QUARTER, QuotaDate) AS QuotaQuarter,

        LAG(SalesQuota) OVER (
            PARTITION BY BusinessEntityID
            ORDER BY QuotaDate
        ) AS PreviousQuota

    FROM Sales.SalesPersonQuotaHistory
),
QuotaHistory AS (
    SELECT
        *,
        CAST(
            100.0 * (SalesQuota - PreviousQuota)
            / NULLIF(PreviousQuota, 0)
            AS DECIMAL(10, 2)
        ) AS QuotaChangePct
    FROM QuotaWithPrevious
)
SELECT
    q.BusinessEntityID,
    CONCAT(p.FirstName, ' ', p.LastName) AS SalespersonName,
    q.QuotaDate,
    q.QuotaYear,
    q.QuotaQuarter,
    q.PreviousQuota,
    q.SalesQuota,
    q.QuotaChangePct,

    COALESCE(a.ActualSales, 0) AS ActualSales,

    CAST(
        100.0 * COALESCE(a.ActualSales, 0)
        / NULLIF(q.SalesQuota, 0)
        AS DECIMAL(10, 2)
    ) AS AttainmentPct,

    COALESCE(a.OrderCount, 0) AS OrderCount,

    CASE
        WHEN a.SalesPersonID IS NULL
            THEN 'No attributed sales'
        ELSE 'Sales recorded'
    END AS SalesStatus

FROM QuotaHistory AS q

LEFT JOIN ActualSalesByQuarter AS a
    ON q.BusinessEntityID = a.SalesPersonID
   AND q.QuotaYear = a.SalesYear
   AND q.QuotaQuarter = a.SalesQuarter

LEFT JOIN Person.Person AS p
    ON q.BusinessEntityID = p.BusinessEntityID

WHERE q.BusinessEntityID IN (274, 285, 287)

ORDER BY
    q.BusinessEntityID,
    q.QuotaDate;




/*
=========================================================
CATEGORY ANALYSIS: SALES MIX BY QUOTA PERFORMANCE
=========================================================
Purpose:
Identify product categories associated with
below-quota salesperson-quarter results.

Method:
Compare category revenue and category sales mix
between below-quota and quota-met quarters.

Scope:
- Shipped, salesperson-attributed orders
- Calendar-quarter quota matching
- Assigned salesperson territory
- Exclude incomplete Q2 2011 and periods without quota

Limitation:
Category-specific quotas are unavailable.
This measures sales mix, not category-level quota variance.
=========================================================
*/

WITH ActualSalesByQuarter AS (
    SELECT
        h.SalesPersonID,
        YEAR(h.OrderDate) AS SalesYear,
        DATEPART(QUARTER, h.OrderDate) AS SalesQuarter,
        SUM(d.LineTotal) AS ActualSales
    FROM Sales.SalesOrderHeader AS h
    INNER JOIN Sales.SalesOrderDetail AS d
        ON h.SalesOrderID = d.SalesOrderID
    WHERE h.SalesPersonID IS NOT NULL
      AND h.OnlineOrderFlag = 0
      AND h.Status = 5
    GROUP BY
        h.SalesPersonID,
        YEAR(h.OrderDate),
        DATEPART(QUARTER, h.OrderDate)
),
QuotaByQuarter AS (
    SELECT
        BusinessEntityID AS SalesPersonID,
        YEAR(QuotaDate) AS QuotaYear,
        DATEPART(QUARTER, QuotaDate) AS QuotaQuarter,
        SalesQuota
    FROM Sales.SalesPersonQuotaHistory
),
Performance AS (
    SELECT
        COALESCE(a.SalesPersonID, q.SalesPersonID)
            AS SalesPersonID,
        COALESCE(a.SalesYear, q.QuotaYear) AS SalesYear,
        COALESCE(a.SalesQuarter, q.QuotaQuarter)
            AS SalesQuarter,
        a.ActualSales,
        q.SalesQuota
    FROM ActualSalesByQuarter AS a
    FULL OUTER JOIN QuotaByQuarter AS q
        ON a.SalesPersonID = q.SalesPersonID
       AND a.SalesYear = q.QuotaYear
       AND a.SalesQuarter = q.QuotaQuarter
),
CategorySalesByQuarter AS (
    SELECT
        h.SalesPersonID,
        YEAR(h.OrderDate) AS SalesYear,
        DATEPART(QUARTER, h.OrderDate) AS SalesQuarter,

        COALESCE(
            pc.Name,
            N'Uncategorized'
        ) AS ProductCategory,

        SUM(d.LineTotal) AS CategorySales

    FROM Sales.SalesOrderHeader AS h

    INNER JOIN Sales.SalesOrderDetail AS d
        ON h.SalesOrderID = d.SalesOrderID

    LEFT JOIN Production.Product AS pr
        ON d.ProductID = pr.ProductID

    LEFT JOIN Production.ProductSubcategory AS psc
        ON pr.ProductSubcategoryID = psc.ProductSubcategoryID

    LEFT JOIN Production.ProductCategory AS pc
        ON psc.ProductCategoryID = pc.ProductCategoryID

    WHERE h.SalesPersonID IS NOT NULL
      AND h.OnlineOrderFlag = 0
      AND h.Status = 5

    GROUP BY
        h.SalesPersonID,
        YEAR(h.OrderDate),
        DATEPART(QUARTER, h.OrderDate),
        COALESCE(pc.Name, N'Uncategorized')
),
CategoryPerformance AS (
    SELECT
        c.SalesPersonID,
        c.SalesYear,
        c.SalesQuarter,

        CASE
            WHEN sp.TerritoryID IS NULL
                THEN N'Unassigned'
            WHEN st.TerritoryID IS NULL
                THEN N'Unknown territory'
            ELSE st.Name
        END AS AssignedTerritory,

        c.ProductCategory,
        c.CategorySales,

        p.ActualSales,
        p.SalesQuota,

        CASE
            WHEN p.ActualSales < p.SalesQuota
                THEN N'Below quota'
            ELSE N'Met or exceeded quota'
        END AS PerformanceBucket

    FROM CategorySalesByQuarter AS c

    INNER JOIN Performance AS p
        ON c.SalesPersonID = p.SalesPersonID
       AND c.SalesYear = p.SalesYear
       AND c.SalesQuarter = p.SalesQuarter

    LEFT JOIN Sales.SalesPerson AS sp
        ON c.SalesPersonID = sp.BusinessEntityID

    LEFT JOIN Sales.SalesTerritory AS st
        ON sp.TerritoryID = st.TerritoryID

    WHERE p.SalesQuota IS NOT NULL
      AND p.ActualSales IS NOT NULL
      AND NOT (
          p.SalesYear = 2011
          AND p.SalesQuarter = 2
      )
),
CategorySummary AS (
    SELECT
        AssignedTerritory,
        ProductCategory,

        SUM(
            CASE
                WHEN PerformanceBucket = N'Below quota'
                    THEN CategorySales
                ELSE 0
            END
        ) AS SalesDuringBelowQuotaPeriods,

        SUM(
            CASE
                WHEN PerformanceBucket = N'Met or exceeded quota'
                    THEN CategorySales
                ELSE 0
            END
        ) AS SalesDuringMetQuotaPeriods,

        COUNT(DISTINCT
            CASE
                WHEN PerformanceBucket = N'Below quota'
                    THEN CONCAT(
                        SalesPersonID, '-',
                        SalesYear, '-',
                        SalesQuarter
                    )
            END
        ) AS BelowQuotaRepQuarters

    FROM CategoryPerformance

    GROUP BY
        AssignedTerritory,
        ProductCategory
),
TerritoryTotals AS (
    SELECT
        AssignedTerritory,
        SUM(SalesDuringBelowQuotaPeriods)
            AS TotalBelowQuotaSales,
        SUM(SalesDuringMetQuotaPeriods)
            AS TotalMetQuotaSales
    FROM CategorySummary
    GROUP BY AssignedTerritory
)
SELECT
    c.AssignedTerritory,
    c.ProductCategory,

    c.SalesDuringBelowQuotaPeriods,

    CAST(
        100.0 * c.SalesDuringBelowQuotaPeriods
        / NULLIF(t.TotalBelowQuotaSales, 0)
        AS DECIMAL(6, 2)
    ) AS BelowQuotaSalesMixPct,

    c.SalesDuringMetQuotaPeriods,

    CAST(
        100.0 * c.SalesDuringMetQuotaPeriods
        / NULLIF(t.TotalMetQuotaSales, 0)
        AS DECIMAL(6, 2)
    ) AS MetQuotaSalesMixPct,

    CAST(
        100.0 * c.SalesDuringBelowQuotaPeriods
        / NULLIF(t.TotalBelowQuotaSales, 0)
        -
        100.0 * c.SalesDuringMetQuotaPeriods
        / NULLIF(t.TotalMetQuotaSales, 0)
        AS DECIMAL(6, 2)
    ) AS SalesMixDifferencePP,

    c.BelowQuotaRepQuarters

FROM CategorySummary AS c

INNER JOIN TerritoryTotals AS t
    ON c.AssignedTerritory = t.AssignedTerritory

ORDER BY
    c.AssignedTerritory,
    c.SalesDuringBelowQuotaPeriods DESC;




/*
=========================================================
TERRITORY PERFORMANCE: ACTUAL SALES VS QUOTA
=========================================================
Purpose:
Identify territories with the largest quota shortfalls.

Metrics:
- Number of salesperson-quarter observations
- Below-quota and quota-met observations
- Total actual sales and quota
- Net variance and weighted attainment

Scope:
Exclude incomplete Q2 2011 and periods without quota.
=========================================================
*/

;WITH ActualSalesByQuarter AS (
    SELECT
        h.SalesPersonID,
        YEAR(h.OrderDate) AS SalesYear,
        DATEPART(QUARTER, h.OrderDate) AS SalesQuarter,
        SUM(d.LineTotal) AS ActualSales
    FROM Sales.SalesOrderHeader AS h
    INNER JOIN Sales.SalesOrderDetail AS d
        ON h.SalesOrderID = d.SalesOrderID
    WHERE h.SalesPersonID IS NOT NULL
      AND h.OnlineOrderFlag = 0
      AND h.Status = 5
    GROUP BY
        h.SalesPersonID,
        YEAR(h.OrderDate),
        DATEPART(QUARTER, h.OrderDate)
),
QuotaByQuarter AS (
    SELECT
        BusinessEntityID AS SalesPersonID,
        YEAR(QuotaDate) AS QuotaYear,
        DATEPART(QUARTER, QuotaDate) AS QuotaQuarter,
        SalesQuota
    FROM Sales.SalesPersonQuotaHistory
),
Performance AS (
    SELECT
        COALESCE(a.SalesPersonID, q.SalesPersonID)
            AS SalesPersonID,
        COALESCE(a.SalesYear, q.QuotaYear) AS SalesYear,
        COALESCE(a.SalesQuarter, q.QuotaQuarter)
            AS SalesQuarter,
        a.ActualSales,
        q.SalesQuota
    FROM ActualSalesByQuarter AS a
    FULL OUTER JOIN QuotaByQuarter AS q
        ON a.SalesPersonID = q.SalesPersonID
       AND a.SalesYear = q.QuotaYear
       AND a.SalesQuarter = q.QuotaQuarter
)
SELECT
    CASE
        WHEN sp.BusinessEntityID IS NULL
            THEN 'Unknown salesperson'
        WHEN sp.TerritoryID IS NULL
            THEN 'Unassigned'
        WHEN st.TerritoryID IS NULL
            THEN 'Unknown territory'
        ELSE st.Name
    END AS AssignedTerritory,

    COUNT(*) AS ComparableRepQuarters,

    COUNT(DISTINCT pf.SalesPersonID)
        AS Salespeople,

    SUM(CASE
        WHEN COALESCE(pf.ActualSales, 0) < pf.SalesQuota
            THEN 1 ELSE 0
    END) AS BelowQuotaRepQuarters,

    SUM(CASE
        WHEN COALESCE(pf.ActualSales, 0) >= pf.SalesQuota
            THEN 1 ELSE 0
    END) AS MetOrExceededRepQuarters,

    SUM(COALESCE(pf.ActualSales, 0)) AS TotalActualSales,

    SUM(pf.SalesQuota) AS TotalQuota,

    SUM(COALESCE(pf.ActualSales, 0))
        - SUM(pf.SalesQuota) AS NetVariance,

    CAST(
        100.0 * SUM(COALESCE(pf.ActualSales, 0))
        / NULLIF(SUM(pf.SalesQuota), 0)
        AS DECIMAL(10, 2)
    ) AS WeightedAttainmentPct

FROM Performance AS pf

LEFT JOIN Sales.SalesPerson AS sp
    ON pf.SalesPersonID = sp.BusinessEntityID

LEFT JOIN Sales.SalesTerritory AS st
    ON sp.TerritoryID = st.TerritoryID

WHERE pf.SalesQuota IS NOT NULL
  AND NOT (
      pf.SalesYear = 2011
      AND pf.SalesQuarter = 2
  )

GROUP BY
    CASE
        WHEN sp.BusinessEntityID IS NULL
            THEN 'Unknown salesperson'
        WHEN sp.TerritoryID IS NULL
            THEN 'Unassigned'
        WHEN st.TerritoryID IS NULL
            THEN 'Unknown territory'
        ELSE st.Name
    END

ORDER BY NetVariance ASC;






/*
=========================================================
SALESPERSON PERFORMANCE: QUOTA ATTAINMENT SUMMARY
=========================================================
Purpose:
Identify salespeople with persistent quota shortfalls.

Metrics:
- Comparable quarters
- Quarters below quota
- Quarters at or above quota
- Total actual sales and quota
- Net variance and weighted attainment

Scope:
Exclude incomplete Q2 2011 and periods without quota.

Caveat:
Extreme quota changes are retained but require review.
=========================================================
*/

;WITH ActualSalesByQuarter AS (
    SELECT
        h.SalesPersonID,
        YEAR(h.OrderDate) AS SalesYear,
        DATEPART(QUARTER, h.OrderDate) AS SalesQuarter,
        SUM(d.LineTotal) AS ActualSales
    FROM Sales.SalesOrderHeader AS h
    INNER JOIN Sales.SalesOrderDetail AS d
        ON h.SalesOrderID = d.SalesOrderID
    WHERE h.SalesPersonID IS NOT NULL
      AND h.OnlineOrderFlag = 0
      AND h.Status = 5
    GROUP BY
        h.SalesPersonID,
        YEAR(h.OrderDate),
        DATEPART(QUARTER, h.OrderDate)
),
QuotaByQuarter AS (
    SELECT
        BusinessEntityID AS SalesPersonID,
        YEAR(QuotaDate) AS QuotaYear,
        DATEPART(QUARTER, QuotaDate) AS QuotaQuarter,
        SalesQuota
    FROM Sales.SalesPersonQuotaHistory
),
Performance AS (
    SELECT
        q.SalesPersonID,
        q.QuotaYear AS SalesYear,
        q.QuotaQuarter AS SalesQuarter,
        q.SalesQuota,
        a.ActualSales
    FROM QuotaByQuarter AS q
    LEFT JOIN ActualSalesByQuarter AS a
        ON q.SalesPersonID = a.SalesPersonID
       AND q.QuotaYear = a.SalesYear
       AND q.QuotaQuarter = a.SalesQuarter
    WHERE NOT (
        q.QuotaYear = 2011
        AND q.QuotaQuarter = 2
    )
)
SELECT
    pf.SalesPersonID,
    CONCAT(p.FirstName, ' ', p.LastName)
        AS SalespersonName,

    CASE
        WHEN sp.TerritoryID IS NULL
            THEN 'Unassigned'
        ELSE st.Name
    END AS AssignedTerritory,

    COUNT(*) AS ComparableQuarters,

    SUM(CASE
        WHEN COALESCE(pf.ActualSales, 0) < pf.SalesQuota
            THEN 1 ELSE 0
    END) AS BelowQuotaQuarters,

    SUM(CASE
        WHEN COALESCE(pf.ActualSales, 0) >= pf.SalesQuota
            THEN 1 ELSE 0
    END) AS MetOrExceededQuarters,

    CAST(
        100.0 * SUM(CASE
            WHEN COALESCE(pf.ActualSales, 0) < pf.SalesQuota
                THEN 1 ELSE 0
        END) / COUNT(*)
        AS DECIMAL(6, 2)
    ) AS BelowQuotaRatePct,

    SUM(COALESCE(pf.ActualSales, 0))
        AS TotalActualSales,

    SUM(pf.SalesQuota)
        AS TotalQuota,

    SUM(COALESCE(pf.ActualSales, 0))
        - SUM(pf.SalesQuota)
        AS NetVariance,

    CAST(
        100.0 * SUM(COALESCE(pf.ActualSales, 0))
        / NULLIF(SUM(pf.SalesQuota), 0)
        AS DECIMAL(10, 2)
    ) AS WeightedAttainmentPct

FROM Performance AS pf

LEFT JOIN Sales.SalesPerson AS sp
    ON pf.SalesPersonID = sp.BusinessEntityID

LEFT JOIN Person.Person AS p
    ON pf.SalesPersonID = p.BusinessEntityID

LEFT JOIN Sales.SalesTerritory AS st
    ON sp.TerritoryID = st.TerritoryID

GROUP BY
    pf.SalesPersonID,
    p.FirstName,
    p.LastName,
    sp.TerritoryID,
    st.Name

ORDER BY
    NetVariance ASC;






-- final_salesperson_performance

WITH QuotaLag AS (
    SELECT
        q.BusinessEntityID AS SalesPersonID,
        q.QuotaDate,
        YEAR(q.QuotaDate) AS SalesYear,
        DATEPART(QUARTER, q.QuotaDate) AS SalesQuarter,
        q.SalesQuota,
        LAG(q.SalesQuota) OVER (
            PARTITION BY q.BusinessEntityID
            ORDER BY q.QuotaDate
        ) AS PreviousQuota
    FROM Sales.SalesPersonQuotaHistory AS q
),
QuotaByQuarter AS (
    SELECT
        *,
        CASE
            WHEN PreviousQuota IS NULL
                THEN 'No prior quota'
            WHEN SalesQuota < PreviousQuota * 0.20
                THEN 'Review: quota fell by >80%'
            WHEN SalesQuota > PreviousQuota * 5.00
                THEN 'Review: quota increased >5x'
            ELSE 'No major change flagged'
        END AS QuotaQualityFlag
    FROM QuotaLag
),
ActualSalesByQuarter AS (
    SELECT
        h.SalesPersonID,
        YEAR(h.OrderDate) AS SalesYear,
        DATEPART(QUARTER, h.OrderDate) AS SalesQuarter,
        COUNT(DISTINCT h.SalesOrderID) AS OrderCount,
        SUM(d.LineTotal) AS ActualSales
    FROM Sales.SalesOrderHeader AS h
    INNER JOIN Sales.SalesOrderDetail AS d
        ON d.SalesOrderID = h.SalesOrderID
    WHERE h.SalesPersonID IS NOT NULL
      AND h.OnlineOrderFlag = 0
      AND h.Status = 5
    GROUP BY
        h.SalesPersonID,
        YEAR(h.OrderDate),
        DATEPART(QUARTER, h.OrderDate)
)
SELECT
    COALESCE(q.SalesPersonID, a.SalesPersonID) AS SalesPersonID,
    CONCAT(p.FirstName, ' ', p.LastName) AS SalespersonName,
    COALESCE(st.Name, 'Unassigned') AS AssignedTerritory,
    COALESCE(q.SalesYear, a.SalesYear) AS SalesYear,
    COALESCE(q.SalesQuarter, a.SalesQuarter) AS SalesQuarter,
    q.QuotaDate,
    COALESCE(a.ActualSales, 0) AS ActualSales,
    q.SalesQuota,
    q.PreviousQuota,
    CASE
        WHEN q.SalesQuota IS NULL
          OR (q.SalesYear = 2011 AND q.SalesQuarter = 2)
            THEN NULL
        ELSE COALESCE(a.ActualSales, 0) - q.SalesQuota
    END AS QuotaVariance,
    CASE
        WHEN q.SalesQuota IS NULL
          OR (q.SalesYear = 2011 AND q.SalesQuarter = 2)
            THEN NULL
        ELSE 100.0 * COALESCE(a.ActualSales, 0)
             / NULLIF(q.SalesQuota, 0)
    END AS AttainmentPct,
    COALESCE(a.OrderCount, 0) AS OrderCount,
    CASE
        WHEN q.SalesQuota IS NULL
            THEN 'No quota record'
        WHEN q.SalesYear = 2011 AND q.SalesQuarter = 2
            THEN 'Partial sales history'
        WHEN a.ActualSales IS NULL
            THEN 'No attributed sales'
        ELSE 'Comparable period'
    END AS PeriodStatus,
    CASE
        WHEN q.SalesQuota IS NOT NULL
         AND NOT (q.SalesYear = 2011 AND q.SalesQuarter = 2)
            THEN 1
        ELSE 0
    END AS IsComparablePeriod,
    q.QuotaQualityFlag
FROM QuotaByQuarter AS q
FULL OUTER JOIN ActualSalesByQuarter AS a
    ON a.SalesPersonID = q.SalesPersonID
   AND a.SalesYear = q.SalesYear
   AND a.SalesQuarter = q.SalesQuarter
LEFT JOIN Sales.SalesPerson AS sp
    ON sp.BusinessEntityID = COALESCE(q.SalesPersonID, a.SalesPersonID)
LEFT JOIN Person.Person AS p
    ON p.BusinessEntityID = COALESCE(q.SalesPersonID, a.SalesPersonID)
LEFT JOIN Sales.SalesTerritory AS st
    ON st.TerritoryID = sp.TerritoryID
ORDER BY
    SalesYear,
    SalesQuarter,
    SalespersonName;







-- final_category_sales
WITH ActualSalesByQuarter AS (
    SELECT
        h.SalesPersonID,
        YEAR(h.OrderDate) AS SalesYear,
        DATEPART(QUARTER, h.OrderDate) AS SalesQuarter,
        SUM(d.LineTotal) AS QuarterActualSales
    FROM Sales.SalesOrderHeader AS h
    INNER JOIN Sales.SalesOrderDetail AS d
        ON d.SalesOrderID = h.SalesOrderID
    WHERE h.SalesPersonID IS NOT NULL
      AND h.OnlineOrderFlag = 0
      AND h.Status = 5
    GROUP BY
        h.SalesPersonID,
        YEAR(h.OrderDate),
        DATEPART(QUARTER, h.OrderDate)
),
QuotaByQuarter AS (
    SELECT
        q.BusinessEntityID AS SalesPersonID,
        YEAR(q.QuotaDate) AS SalesYear,
        DATEPART(QUARTER, q.QuotaDate) AS SalesQuarter,
        q.SalesQuota
    FROM Sales.SalesPersonQuotaHistory AS q
),
CategorySalesByQuarter AS (
    SELECT
        h.SalesPersonID,
        YEAR(h.OrderDate) AS SalesYear,
        DATEPART(QUARTER, h.OrderDate) AS SalesQuarter,
        pc.ProductCategoryID,
        COALESCE(pc.Name, 'Uncategorized') AS CategoryName,
        COALESCE(st.Name, 'Unassigned') AS AssignedTerritory,
        CONCAT(person.FirstName, ' ', person.LastName) AS SalespersonName,
        COUNT(DISTINCT h.SalesOrderID) AS OrdersContainingCategory,
        SUM(d.OrderQty) AS UnitsSold,
        SUM(d.LineTotal) AS CategorySales
    FROM Sales.SalesOrderHeader AS h
    INNER JOIN Sales.SalesOrderDetail AS d
        ON d.SalesOrderID = h.SalesOrderID
    INNER JOIN Production.Product AS pr
        ON pr.ProductID = d.ProductID
    LEFT JOIN Production.ProductSubcategory AS psc
        ON psc.ProductSubcategoryID = pr.ProductSubcategoryID
    LEFT JOIN Production.ProductCategory AS pc
        ON pc.ProductCategoryID = psc.ProductCategoryID
    INNER JOIN Sales.SalesPerson AS sp
        ON sp.BusinessEntityID = h.SalesPersonID
    INNER JOIN Person.Person AS person
        ON person.BusinessEntityID = h.SalesPersonID
    LEFT JOIN Sales.SalesTerritory AS st
        ON st.TerritoryID = sp.TerritoryID
    WHERE h.SalesPersonID IS NOT NULL
      AND h.OnlineOrderFlag = 0
      AND h.Status = 5
    GROUP BY
        h.SalesPersonID,
        YEAR(h.OrderDate),
        DATEPART(QUARTER, h.OrderDate),
        pc.ProductCategoryID,
        pc.Name,
        st.Name,
        person.FirstName,
        person.LastName
)
SELECT
    cs.SalesPersonID,
    cs.SalespersonName,
    cs.AssignedTerritory,
    cs.SalesYear,
    cs.SalesQuarter,
    cs.ProductCategoryID,
    cs.CategoryName,
    cs.OrdersContainingCategory,
    cs.UnitsSold,
    cs.CategorySales,
    CASE
        WHEN q.SalesQuota IS NULL
            THEN 'No quota record'
        WHEN cs.SalesYear = 2011 AND cs.SalesQuarter = 2
            THEN 'Partial sales history'
        WHEN COALESCE(a.QuarterActualSales, 0) < q.SalesQuota
            THEN 'Below quota'
        ELSE 'Met or exceeded quota'
    END AS PerformanceBucket
FROM CategorySalesByQuarter AS cs
LEFT JOIN ActualSalesByQuarter AS a
    ON a.SalesPersonID = cs.SalesPersonID
   AND a.SalesYear = cs.SalesYear
   AND a.SalesQuarter = cs.SalesQuarter
LEFT JOIN QuotaByQuarter AS q
    ON q.SalesPersonID = cs.SalesPersonID
   AND q.SalesYear = cs.SalesYear
   AND q.SalesQuarter = cs.SalesQuarter
ORDER BY
    cs.SalesYear,
    cs.SalesQuarter,
    cs.SalespersonName,
    cs.CategoryName;