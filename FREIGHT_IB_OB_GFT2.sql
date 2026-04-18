-- =============================================================================
-- FREIGHT_IB_OB_GFT2
-- Replaces FREIGHT_OB_COSTED, built on GFT 2.0 model (GFT_COSTED_EXTENDED)
--
-- Key design notes:
--   1. Source: GBI_OPS_SEMANTIC_DB.GFT_PANDO.GFT_COSTED_EXTENDED (view2)
--      - grain is delivery_line_item + CHARGE_NAME (one row per charge per leg)
--      - OLD model grain was delivery_line_item with per-leg columns pre-pivoted
--
--   2. Pivot strategy: conditional aggregation by LEG_TYPE to reconstruct
--      per-leg SG/LH/FL columns from normalised rows.
--      Verified LEG_TYPE values: 'SEG1' (first segment), 'LH1'/'LH2'/'LH3' (line haul legs),
--      'FL' (final leg).
--      SCAC/carrier type uses LH1 as the primary line-haul leg.
--      Cost/weight measures roll up all LH legs (LH1+LH2+LH3).
--
--   3. DELIVERY_QTY: repeated on every charge row for the same delivery item;
--      summed only on REPORTING_FLAG='Y' rows to avoid double-count.
--
--   4. SHIPPING_PT_TYPE: view2 provides SHIP_POINT_TYPE_CD directly (already
--      enriched by Pando); same CASE override logic retained for RETAIL STORE
--      regex pattern. NOTE: the DIRECT+IDL/SFS override from EM_SHIP_POINT.ORIGIN
--      cannot be replicated without an additional join -- current logic relies on
--      SHIP_POINT_TYPE_CD already reflecting the correct value for those cases.
--
--   5. PRDT_CUSTOM_GRP_GFT: not in GFT_COSTED_EXTENDED; still joined from MDM.
--
--   6. OB scope: DATA_CLASS_CD = 'OB'.  Remove/change filter for IB or combined view.
--
--   7. FISCAL calendar: view2 joins to FISCAL_DAY_CUR with Region_Cd='AMR' which
--      provides the Apple corporate fiscal calendar (globally applicable).
--
--   8. COST_ACCRUAL_TOTAL_USD: sum of ACCRUAL_COST_USD across all legs per delivery item
--      (SEG1 + LH1/LH2/LH3 + FL).  In the old model this also included a separate
--      Fuel_Surcharge row; since GFT_COSTED_EXTENDED has only CHARGE_NAME='BASE FREIGHT',
--      fuel is embedded in the leg costs — total here reflects that.
--
--   9. GFT_*_COST_CHARGEABLE_USD: uses CHARGE_VALUE_USD (contracted rate cost)
--      per BASE FREIGHT row, consistent with old Std_Cost columns.
--
--  10. FUEL_SURCHARGE_COST_USD: GFT_COSTED_EXTENDED has only CHARGE_NAME='BASE FREIGHT';
--      fuel surcharge is not a separate row.  The column is retained for schema
--      compatibility and currently returns 0.  Investigate FUEL_RATE / FUEL_CHARGE_TYPE
--      columns in the source if a separate fuel cost is required.
-- =============================================================================

create or replace view GBI_FINANCE_BAP_DB.FINANCE_BIZ.FREIGHT_IB_OB_GFT2(
    UNIVERSE,
    COSTED_FLAG,
    FISCAL_QTR_YEAR,
    FISCAL_QUARTER,
    PO_TYPE_CD,
    DELIVERY_TYPE,
    PRDT_CUSTOM_GRP_GFT,
    DEST_REGION_CD,
    DEST_COUNTRY_CD,
    SOURCE_COUNTRY_CD,
    SOURCE_CITY,
    SHIPPING_PT_CD,
    SHIPPING_PT_TYPE,
    DEPLOYMENT,
    SHIPMENT_MODE,
    RTM_OPS_CHANNEL_L2,
    RTM_1,
    SCAC_SG,
    SCAC_LH,
    SCAC_FL,
    CARRIER_TYPE_SG,
    CARRIER_TYPE_LH,
    CARRIER_TYPE_FL,
    BOPIS_ITEM_CATEG_CD,
    CHARTER_DEAL_TYPE,
    CHARTER_FLAG,
    DELIVERY_UNIT,
    WGT_FPP_SG_KG,
    WGT_FPP_LH_KG,
    WGT_FPP_FL_KG,
    WGT_ACCRUAL_KG,
    COST_ACCRUAL_FL_USD,
    COST_ACCRUAL_LH_USD,
    COST_ACCRUAL_SG_USD,
    COST_ACCRUAL_TOTAL_USD,
    GFT_SG_WGT_CHARGEABLE_KG,
    GFT_LH_WGT_CHARGEABLE_KG,
    GFT_FL_WGT_CHARGEABLE_KG,
    GFT_SG_COST_CHARGEABLE_USD,
    GFT_LH_COST_CHARGEABLE_USD,
    GFT_FL_COST_CHARGEABLE_USD,
    FUEL_SURCHARGE_COST_USD
) AS

WITH

-- ---------------------------------------------------------------------------
-- STEP 1: Pivot GFT_COSTED_EXTENDED from charge-level to delivery-item-level.
--         One output row per DELIVERY_ID + DELIVERY_ITEM_NR.
-- ---------------------------------------------------------------------------
base AS (
    SELECT
        g.DELIVERY_ID,
        g.DELIVERY_ITEM_NR,
        g.PROD_ID,

        -- Core delivery-level dimensions (repeated on every charge row; MAX picks one value)
        MAX(g.DATA_CLASS_CD)                                                            AS Universe,
        MAX(g.COSTED_FLAG)                                                              AS Costed_Flag,
        MAX(g.FISCAL_QTR_YEAR)                                                          AS Fiscal_Qtr_Year,
        MAX(TRIM(g.FISCAL_YEAR) || TRIM(g.FISCAL_QUARTER))                             AS Fiscal_Quarter,
        MAX(g.PO_TYPE_CD)                                                               AS PO_Type_Cd,
        MAX(g.DELIVERY_TYPE_CD)                                                         AS Delivery_Type,
        TRIM(MAX(g.REGION_CD))                                                          AS Dest_Region_Cd,
        MAX(g.DESTINATION_COUNTRY_CODE)                                                 AS Dest_Country_Cd,
        MAX(g.ORIGIN_COUNTRY_CODE)                                                      AS Source_Country_Cd,
        UPPER(TRIM(TRIM(MAX(g.ORIGIN_CITY), CHAR(160))))                               AS Source_City,
        MAX(g.SHIPPING_POINT_CD)                                                        AS Shipping_Pt_Cd,
        -- SHIP_POINT_TYPE_CD from view2 replaces the EM_SHIP_POINT join
        MAX(g.SHIP_POINT_TYPE_CD)                                                       AS Shipping_Pt_Type_Raw,
        UPPER(MAX(g.OPS_CHANNEL_LEVEL_2_DESCRIPTION))                                  AS RTM_Ops_Channel_L2,
        MAX(g.BOPIS_ITEM_CATEG_CD)                                                      AS Bopis_Item_Categ_Cd,
        UPPER(MAX(g.CHARTER_DEAL_TYPE))                                                 AS Charter_Deal_Type,
        UPPER(MAX(g.CHARTER_FLIGHT_FLAG))                                               AS Charter_Flag,

        -- Derived: SHIPPING_PT_TYPE (same CASE logic as old view; see note 4 in header)
        (CASE
            WHEN MAX(g.SHIP_POINT_TYPE_CD) IS NULL
                 AND REGEXP_INSTR(MAX(g.SHIPPING_POINT_CD), '^[R][0-9]{1,4}?$') > 0   THEN 'RETAIL STORE'
            WHEN UPPER(MAX(g.SHIP_POINT_TYPE_CD)) = 'DIRECT'                           THEN 'OEM'
            ELSE UPPER(MAX(g.SHIP_POINT_TYPE_CD))
        END)                                                                            AS Shipping_Pt_Type,

        -- Derived: DEPLOYMENT
        (CASE
            WHEN LEFT(MAX(g.SHIP_POINT_TYPE_CD), 3) = 'HUB'                           THEN 'FD'
            WHEN LEFT(MAX(g.SHIP_POINT_TYPE_CD), 3) = 'OEM'                           THEN 'DS'
            WHEN LEFT(MAX(g.SHIPPING_POINT_CD), 1)  = 'V'                             THEN 'DS'
            WHEN UPPER(MAX(g.SHIP_POINT_TYPE_CD))   = 'DIRECT'                        THEN 'DS'
            ELSE 'FD'
        END)                                                                            AS Deployment,

        -- Per-leg SCAC pivot  (verified LEG_TYPE values: SEG1, LH1, LH2, LH3, FL)
        -- SCAC_LH uses LH1 (primary/first line-haul leg)
        MAX(CASE WHEN g.LEG_TYPE = 'SEG1' THEN g.PARENT_SCAC_CD END)                 AS SCAC_SG,
        MAX(CASE WHEN g.LEG_TYPE = 'LH1'  THEN g.PARENT_SCAC_CD END)                 AS SCAC_LH,
        MAX(CASE WHEN g.LEG_TYPE = 'FL'   THEN g.PARENT_SCAC_CD END)                 AS SCAC_FL,

        -- Per-leg Carrier Type pivot (LH1 as primary line-haul)
        MAX(CASE WHEN g.LEG_TYPE = 'SEG1' THEN UPPER(g.CARRIER_TYPE) END)            AS Carrier_Type_SG,
        MAX(CASE WHEN g.LEG_TYPE = 'LH1'  THEN UPPER(g.CARRIER_TYPE) END)            AS Carrier_Type_LH,
        MAX(CASE WHEN g.LEG_TYPE = 'FL'   THEN UPPER(g.CARRIER_TYPE) END)            AS Carrier_Type_FL,

        -- Delivery Qty: DELIVERY_QTY is the same on every charge row for a given delivery item.
        -- Use MAX (not REPORTING_FLAG='Y') because REPORTING_FLAG can be 'N' on all rows
        -- for multi-leg shipments where the confirmed SCAC matches neither leg.
        MAX(g.DELIVERY_QTY)                                                            AS Delivery_Unit,

        -- FPP Chargeable Weights per leg
        -- (CHARGE_NAME='BASE FREIGHT' is the only value in view2; filters kept for safety)
        COALESCE(SUM(CASE WHEN g.LEG_TYPE = 'SEG1'
                          THEN g.FPP_CHRGBLE_WEIGHT_MSR_KG   ELSE 0 END), 0)         AS Wgt_FPP_SG_Kg,
        -- LH rolls up all line-haul legs (LH1 + LH2 + LH3)
        COALESCE(SUM(CASE WHEN g.LEG_TYPE IN ('LH1','LH2','LH3')
                          THEN g.FPP_CHRGBLE_WEIGHT_MSR_KG   ELSE 0 END), 0)         AS Wgt_FPP_LH_Kg,
        -- FL uses the pre-aggregated _SUM column (matches FPP_FINAL_OB_COSTING.Fpp_Fl_Chrgble_Weight_Msr_Kg)
        COALESCE(SUM(CASE WHEN g.LEG_TYPE = 'FL'
                          THEN g.FPP_FL_CHRGBLE_WEIGHT_MSR_KG_SUM ELSE 0 END), 0)   AS Wgt_FPP_FL_Kg,

        -- Accrual Weight: delivery-level attribute, same value on all rows per item.
        -- Use MAX (not REPORTING_FLAG='Y') for same reason as DELIVERY_QTY above.
        COALESCE(MAX(g.ACCRUAL_WEIGHT_KG), 0)                                         AS Wgt_Accrual_Kg,

        -- Accrual Costs per leg
        COALESCE(SUM(CASE WHEN g.LEG_TYPE = 'FL'
                          THEN g.ACCRUAL_COST_USD ELSE 0 END), 0)                    AS Cost_Accrual_FL_USD,
        -- LH rolls up all line-haul legs (LH1 + LH2 + LH3)
        COALESCE(SUM(CASE WHEN g.LEG_TYPE IN ('LH1','LH2','LH3')
                          THEN g.ACCRUAL_COST_USD ELSE 0 END), 0)                    AS Cost_Accrual_LH_USD,
        COALESCE(SUM(CASE WHEN g.LEG_TYPE = 'SEG1'
                          THEN g.ACCRUAL_COST_USD ELSE 0 END), 0)                    AS Cost_Accrual_SG_USD,

        -- Total Accrual: sum across all legs (SEG1 + LH* + FL)
        -- Note: fuel surcharge is embedded in BASE FREIGHT in GFT 2.0; no separate row exists
        COALESCE(SUM(g.ACCRUAL_COST_USD), 0)                                          AS Cost_Accrual_Total_USD,

        -- GFT Chargeable Weights per leg
        COALESCE(SUM(CASE WHEN g.LEG_TYPE = 'SEG1'
                          THEN g.GFT_CHARGEABLE_WT_KG ELSE 0 END), 0)               AS GFT_SG_Wgt_Chargeable_Kg,
        -- LH rolls up all line-haul legs (LH1 + LH2 + LH3)
        COALESCE(SUM(CASE WHEN g.LEG_TYPE IN ('LH1','LH2','LH3')
                          THEN g.GFT_CHARGEABLE_WT_KG ELSE 0 END), 0)               AS GFT_LH_Wgt_Chargeable_Kg,
        COALESCE(SUM(CASE WHEN g.LEG_TYPE = 'FL'
                          THEN g.GFT_CHARGEABLE_WT_KG ELSE 0 END), 0)               AS GFT_FL_Wgt_Chargeable_Kg,

        -- GFT Chargeable Costs per leg (CHARGE_VALUE_USD = contracted/standard rate cost,
        --   equivalent to Seg1_Std_Cost_USD / Line_Haul_std_cost_USD / final_leg_std_cost_actual_USD)
        COALESCE(SUM(CASE WHEN g.LEG_TYPE = 'SEG1'
                          THEN g.CHARGE_VALUE_USD ELSE 0 END), 0)                    AS GFT_SG_Cost_Chargeable_USD,
        -- LH rolls up all line-haul legs (LH1 + LH2 + LH3)
        COALESCE(SUM(CASE WHEN g.LEG_TYPE IN ('LH1','LH2','LH3')
                          THEN g.CHARGE_VALUE_USD ELSE 0 END), 0)                    AS GFT_LH_Cost_Chargeable_USD,
        COALESCE(SUM(CASE WHEN g.LEG_TYPE = 'FL'
                          THEN g.CHARGE_VALUE_USD ELSE 0 END), 0)                    AS GFT_FL_Cost_Chargeable_USD,

        -- Fuel Surcharge: no separate CHARGE_NAME row in GFT 2.0; returns 0 for schema compat.
        -- Investigate FUEL_RATE / FUEL_CHARGE_TYPE columns if a breakdown is needed.
        CAST(0 AS NUMBER(38,6))                                                        AS Fuel_Surcharge_Cost_USD,

        -- Retain ROLLING_QUARTER for WHERE filter pushdown (used in outer WHERE)
        MAX(g.ROLLING_QUARTER)                                                         AS Rolling_Quarter

    FROM GBI_OPS_SEMANTIC_DB.GFT_PANDO.GFT_COSTED_EXTENDED g

    WHERE g.COSTED_FLAG       = 'Y'
      AND g.DELIVERY_TYPE_CD NOT IN ('NL', 'NLCC', 'LR')
      AND g.DATA_CLASS_CD     = 'OB'             -- OB scope; adjust for IB_OB
      AND g.ROLLING_QUARTER  IN (-5, -4, -3, -2, -1, 0)

    GROUP BY g.DELIVERY_ID, g.DELIVERY_ITEM_NR, g.PROD_ID
),

-- ---------------------------------------------------------------------------
-- STEP 2: OPH Product Custom Group (same MDM join as old view, using PROD_ID)
-- ---------------------------------------------------------------------------
oph AS (
    SELECT
        omcgmec.prod_node_id,
        UPPER(mcgc.custom_grp_desc) AS Prdt_Custom_Grp_GFT
    FROM GBI_FINANCE_BAP_DB.FINANCE_BIZ.OPH_MDM_CUSTM_GRP_MPN_EXT_CUR omcgmec
    JOIN GBI_FINANCE_BAP_DB.FINANCE_BIZ.MDM_CUSTOM_GROUP_CUR mcgc
        ON  mcgc.GRP_CATEG_CD    = 'gft_All'
        AND mcgc.custom_grp_cd   = omcgmec.custom_grp_cd
        AND mcgc.hier_cd         = omcgmec.HIER_CD
        AND LEFT(mcgc.custom_grp_desc, 3) = 'OPH'
    WHERE omcgmec.HIER_CD = 'OPH'
)

-- ---------------------------------------------------------------------------
-- STEP 3: Final SELECT — apply derived dimension logic and aggregate measures.
-- ---------------------------------------------------------------------------
SELECT
    b.Universe                                                          AS Universe,
    b.Costed_Flag                                                       AS Costed_Flag,
    b.Fiscal_Qtr_Year                                                   AS Fiscal_Qtr_Year,
    b.Fiscal_Quarter                                                    AS Fiscal_Quarter,
    b.PO_Type_Cd                                                        AS PO_Type_Cd,
    b.Delivery_Type                                                     AS Delivery_Type,
    oph.Prdt_Custom_Grp_GFT                                             AS Prdt_Custom_Grp_GFT,
    b.Dest_Region_Cd                                                    AS Dest_Region_Cd,
    b.Dest_Country_Cd                                                   AS Dest_Country_Cd,
    b.Source_Country_Cd                                                 AS Source_Country_Cd,
    b.Source_City                                                       AS Source_City,
    b.Shipping_Pt_Cd                                                    AS Shipping_Pt_Cd,
    b.Shipping_Pt_Type                                                  AS Shipping_Pt_Type,
    b.Deployment                                                        AS Deployment,

    -- SHIPMENT_MODE: same region/deployment/country logic as old view
    CASE TRIM(b.Dest_Region_Cd)
        WHEN 'PAC'
            THEN (CASE
                      WHEN b.Deployment = 'FD'                                          THEN 'DC_Outbound'
                      WHEN b.Source_Country_Cd = b.Dest_Country_Cd                     THEN 'LOCAL'
                      WHEN b.Dest_Country_Cd = 'HK' AND b.Source_City = 'SHENZHEN'     THEN 'LOCAL'
                      ELSE 'AIR'
                  END)
        WHEN 'AMR'
            THEN (CASE
                      WHEN b.Deployment = 'FD'                                          THEN 'DC_Outbound'
                      WHEN b.Source_Country_Cd = b.Dest_Country_Cd                     THEN 'LOCAL'
                      WHEN b.Dest_Country_Cd = 'US' AND b.Source_Country_Cd = 'BR'     THEN 'LOCAL'
                      ELSE 'AIR'
                  END)
        WHEN 'EURO'
            THEN (CASE
                      WHEN b.Source_Country_Cd = 'IE'                                  THEN 'LOCAL'
                      WHEN b.Deployment = 'FD'                                          THEN 'DC_Outbound'
                      WHEN b.Source_Country_Cd = b.Dest_Country_Cd                     THEN 'LOCAL'
                      ELSE 'AIR'
                  END)
    END                                                                 AS Shipment_Mode,

    b.RTM_Ops_Channel_L2                                                AS RTM_Ops_Channel_L2,

    -- RTM_1: same channel-to-RTM mapping as old view
    (CASE
        WHEN b.RTM_Ops_Channel_L2 IN ('ONLINE:ONLINE')                                 THEN 'ONLINE'
        WHEN b.RTM_Ops_Channel_L2 IN ('RETAIL:RETAIL', 'RETAIL RPLN:RETAIL REPLENISH') THEN 'RETAIL'
        WHEN b.RTM_Ops_Channel_L2 IN ('INTRCO:INTERCOMPANY', 'RSLR:RESELLER')          THEN 'RESELLER'
        WHEN b.RTM_Ops_Channel_L2 IN ('EDU:EDUCATION')                                 THEN 'EDUCATION'
        ELSE NULL
    END)                                                                AS RTM_1,

    b.SCAC_SG,
    b.SCAC_LH,
    b.SCAC_FL,
    b.Carrier_Type_SG,
    b.Carrier_Type_LH,
    b.Carrier_Type_FL,
    b.Bopis_Item_Categ_Cd,
    b.Charter_Deal_Type,
    b.Charter_Flag,

    -- Aggregated measures (sum across delivery items sharing the same dimension combination)
    COALESCE(SUM(b.Delivery_Unit),              0)                      AS Delivery_Unit,
    COALESCE(SUM(b.Wgt_FPP_SG_Kg),             0)                      AS Wgt_FPP_SG_Kg,
    COALESCE(SUM(b.Wgt_FPP_LH_Kg),             0)                      AS Wgt_FPP_LH_Kg,
    COALESCE(SUM(b.Wgt_FPP_FL_Kg),             0)                      AS Wgt_FPP_FL_Kg,
    COALESCE(SUM(b.Wgt_Accrual_Kg),            0)                      AS Wgt_Accrual_Kg,
    COALESCE(SUM(b.Cost_Accrual_FL_USD),        0)                      AS Cost_Accrual_FL_USD,
    COALESCE(SUM(b.Cost_Accrual_LH_USD),        0)                      AS Cost_Accrual_LH_USD,
    COALESCE(SUM(b.Cost_Accrual_SG_USD),        0)                      AS Cost_Accrual_SG_USD,
    COALESCE(SUM(b.Cost_Accrual_Total_USD),     0)                      AS Cost_Accrual_Total_USD,
    COALESCE(SUM(b.GFT_SG_Wgt_Chargeable_Kg),  0)                      AS GFT_SG_Wgt_Chargeable_Kg,
    COALESCE(SUM(b.GFT_LH_Wgt_Chargeable_Kg),  0)                      AS GFT_LH_Wgt_Chargeable_Kg,
    COALESCE(SUM(b.GFT_FL_Wgt_Chargeable_Kg),  0)                      AS GFT_FL_Wgt_Chargeable_Kg,
    COALESCE(SUM(b.GFT_SG_Cost_Chargeable_USD), 0)                     AS GFT_SG_Cost_Chargeable_USD,
    COALESCE(SUM(b.GFT_LH_Cost_Chargeable_USD), 0)                     AS GFT_LH_Cost_Chargeable_USD,
    COALESCE(SUM(b.GFT_FL_Cost_Chargeable_USD), 0)                     AS GFT_FL_Cost_Chargeable_USD,
    COALESCE(SUM(b.Fuel_Surcharge_Cost_USD),    0)                      AS Fuel_Surcharge_Cost_USD

FROM base b

JOIN oph ON oph.prod_node_id = b.Prod_Id

WHERE oph.Prdt_Custom_Grp_GFT <> 'OPH_Software_Other'

GROUP BY ALL;
