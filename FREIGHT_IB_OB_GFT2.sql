-- =============================================================================
-- FREIGHT_IB_OB_GFT2
-- Full replacement for GBI_FINANCE_BAP_DB.FINANCE_BIZ.FREIGHT_IB_OB
-- Built on GFT 2.0 model (GFT_COSTED_EXTENDED_GFT2)
--
-- Key design notes:
--   1. Source: GBI_FINANCE_DATA_ENG_DB.FIN_DATA_ENG.GFT_COSTED_EXTENDED_GFT2 (view2)
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
--      MAX() used instead of REPORTING_FLAG='Y' filter — REPORTING_FLAG can be
--      'N' on all rows for multi-leg shipments where confirmed SCAC matches
--      neither modelled leg.
--
--   4. SHIPPING_PT_TYPE: view2 provides SHIP_POINT_TYPE_CD directly (already
--      enriched by Pando); same CASE override logic retained for RETAIL STORE
--      regex pattern. NOTE: the DIRECT+IDL/SFS override from EM_SHIP_POINT.ORIGIN
--      cannot be replicated without an additional join — current logic relies on
--      SHIP_POINT_TYPE_CD already reflecting the correct value for those cases.
--
--   5. PRDT_CUSTOM_GRP_GFT: not in GFT_COSTED_EXTENDED; still joined from HMS
--      (GBI_FINANCE_SEMANTIC_DB.SALESFIN_ENT HMS views, replacing old MDM tables).
--
--   6. OB scope: DATA_CLASS_CD = 'OB'.  Remove/change filter for IB or combined view.
--
--   7. FISCAL calendar: view2 joins to FISCAL_DAY_CUR with Region_Cd='AMR' which
--      provides the Apple corporate fiscal calendar (globally applicable).
--
--   8. COST_ACCRUAL_TOTAL_USD: sum of ACCRUAL_COST_USD across all legs per delivery item
--      (SEG1 + LH1/LH2/LH3 + FL).  Fuel surcharge is embedded in BASE FREIGHT in
--      GFT 2.0 — no separate charge row exists.
--
--   9. GFT_*_COST_CHARGEABLE_USD: uses CHARGE_VALUE_USD (contracted rate cost)
--      per BASE FREIGHT row, consistent with old Std_Cost columns.
--
--  10. FUEL_SURCHARGE_COST_USD: GFT_COSTED_EXTENDED has only CHARGE_NAME='BASE FREIGHT';
--      fuel surcharge is not a separate row.  Column retained for schema
--      compatibility and currently returns 0.
--
--  11. RATE_TYPE: available directly as GFT_COSTED_EXTENDED_GFT2.RATE_TYPE;
--      pulled into base CTE via MAX() like other delivery-level dimensions.
--
--  12. STO_TYPE: derived — 'STO' when SHIPPING_PT_TYPE='HUB' AND UNIVERSE='IB';
--      'NON-STO' otherwise.  Matches GFT 1.0 derivation logic from column mapping.
--
--  13. ORIGINAL_DATASET: hardcoded as 'GFT2' for schema compatibility.
--      In GFT 1.0 this held values: FREIGHT_OB_UNCOSTED, FREIGHT_OB_COSTED,
--      FREIGHT_IB_UNCOSTED, FREIGHT_IB_COSTED.
--
--  14. CHANNEL: alias for the RTM_1 derivation (based on RTM_OPS_CHANNEL_L2).
--      In the old view architecture this was labelled RTM_1 in the inner data
--      layer and aliased CHANNEL in the FREIGHT_IB_OB wrapper.
--
--  15. SCAC_SG_FLAG, PROGRAM_CODE, COUNTRY_FCST, DC_FCST, ORIGIN:
--      derived via LEFT JOINs to Dataiku reference tables in FINANCE_BIZ_APP.
--
--  16. BULK_PARCEL, DEPLOYMENT_MIX, RETAIL_BOPIS_UNITS:
--      derived CASE expressions computed in the final SELECT.
--      DEPLOYMENT_MIX references ORIGIN, BULK_PARCEL, CHANNEL aliases from the
--      same SELECT — supported in Snowflake.
--
--  17. PROXY_IB_LISTING_FLAG / UNION ALL proxy expansion:
--      The main SELECT produces base rows (flag=0).  A UNION ALL second SELECT
--      re-runs the same logic but joins DKU_OFN_LF_PROXY_MAPPING and overrides
--      DEST_COUNTRY_CD with F.TO_COUNTRY_CODE and COUNTRY_FCST with
--      F.TO_LOGISTIC_REGION.  Filtered to DEPLOYMENT_MIX LIKE 'INTERNATIONAL_FD_BULK%'.
--      PROXY_IB_LISTING_FLAG=1 for proxy rows.
--      SHIPMENT_MODE is intentionally computed from the original DEST_COUNTRY_CD
--      in both branches, matching GFT 1.0 FREIGHT_IB_OB behaviour.
--      Comment from original view: addresses shipments shown as going through one
--      country that need to be accounted for in a different country.
-- =============================================================================

create or replace view GBI_FINANCE_BAP_DB.FINANCE_PREP_BIZ.FREIGHT_IB_OB_GFT2(
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
    RATE_TYPE,
    RTM_OPS_CHANNEL_L2,
    CHANNEL,
    SCAC_SG,
    SCAC_LH,
    SCAC_FL,
    CARRIER_TYPE_SG,
    CARRIER_TYPE_LH,
    CARRIER_TYPE_FL,
    CHARTER_DEAL_TYPE,
    CHARTER_FLAG,
    BOPIS_ITEM_CATEG_CD,
    STO_TYPE,
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
    FUEL_SURCHARGE_COST_USD,
    ORIGINAL_DATASET,
    SCAC_SG_FLAG,
    PROGRAM_CODE,
    COUNTRY_FCST,
    DC_FCST,
    ORIGIN,
    BULK_PARCEL,
    DEPLOYMENT_MIX,
    RETAIL_BOPIS_UNITS,
    PROXY_IB_LISTING_FLAG
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
        UPPER(MAX(g.OPS_CHANNEL_LEVEL_2_DESCRIPTION))                                  AS RTM_Ops_Channel_L2,
        MAX(g.BOPIS_ITEM_CATEG_CD)                                                      AS Bopis_Item_Categ_Cd,
        UPPER(MAX(g.CHARTER_DEAL_TYPE))                                                 AS Charter_Deal_Type,
        UPPER(MAX(g.CHARTER_FLIGHT_FLAG))                                               AS Charter_Flag,

        -- RATE_TYPE: delivery-level dimension, available directly in GFT 2.0 (see note 11)
        MAX(g.RATE_TYPE)                                                                AS Rate_Type,

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
        MAX(CASE WHEN g.LEG_TYPE = 'SEG1' THEN g.PARENT_SCAC_CD END)                 AS SCAC_SG,
        MAX(CASE WHEN g.LEG_TYPE = 'LH1'  THEN g.PARENT_SCAC_CD END)                 AS SCAC_LH,
        MAX(CASE WHEN g.LEG_TYPE = 'FL'   THEN g.PARENT_SCAC_CD END)                 AS SCAC_FL,

        -- Per-leg Carrier Type pivot (LH1 as primary line-haul)
        MAX(CASE WHEN g.LEG_TYPE = 'SEG1' THEN UPPER(g.CARRIER_TYPE) END)            AS Carrier_Type_SG,
        MAX(CASE WHEN g.LEG_TYPE = 'LH1'  THEN UPPER(g.CARRIER_TYPE) END)            AS Carrier_Type_LH,
        MAX(CASE WHEN g.LEG_TYPE = 'FL'   THEN UPPER(g.CARRIER_TYPE) END)            AS Carrier_Type_FL,

        -- Delivery Qty: use MAX — REPORTING_FLAG can be 'N' on all rows (see note 3)
        MAX(g.DELIVERY_QTY)                                                            AS Delivery_Unit,

        -- FPP Chargeable Weights per leg
        COALESCE(SUM(CASE WHEN g.LEG_TYPE = 'SEG1'
                          THEN g.FPP_CHRGBLE_WEIGHT_MSR_KG   ELSE 0 END), 0)         AS Wgt_FPP_SG_Kg,
        COALESCE(SUM(CASE WHEN g.LEG_TYPE IN ('LH1','LH2','LH3')
                          THEN g.FPP_CHRGBLE_WEIGHT_MSR_KG   ELSE 0 END), 0)         AS Wgt_FPP_LH_Kg,
        COALESCE(SUM(CASE WHEN g.LEG_TYPE = 'FL'
                          THEN g.FPP_FL_CHRGBLE_WEIGHT_MSR_KG_SUM ELSE 0 END), 0)   AS Wgt_FPP_FL_Kg,

        -- Accrual Weight: delivery-level attribute; MAX not SUM (see note 3)
        COALESCE(MAX(g.ACCRUAL_WEIGHT_KG), 0)                                         AS Wgt_Accrual_Kg,

        -- Accrual Costs per leg
        COALESCE(SUM(CASE WHEN g.LEG_TYPE = 'FL'
                          THEN g.ACCRUAL_COST_USD ELSE 0 END), 0)                    AS Cost_Accrual_FL_USD,
        COALESCE(SUM(CASE WHEN g.LEG_TYPE IN ('LH1','LH2','LH3')
                          THEN g.ACCRUAL_COST_USD ELSE 0 END), 0)                    AS Cost_Accrual_LH_USD,
        COALESCE(SUM(CASE WHEN g.LEG_TYPE = 'SEG1'
                          THEN g.ACCRUAL_COST_USD ELSE 0 END), 0)                    AS Cost_Accrual_SG_USD,
        COALESCE(SUM(g.ACCRUAL_COST_USD), 0)                                          AS Cost_Accrual_Total_USD,

        -- GFT Chargeable Weights per leg
        COALESCE(SUM(CASE WHEN g.LEG_TYPE = 'SEG1'
                          THEN g.GFT_CHARGEABLE_WT_KG ELSE 0 END), 0)               AS GFT_SG_Wgt_Chargeable_Kg,
        COALESCE(SUM(CASE WHEN g.LEG_TYPE IN ('LH1','LH2','LH3')
                          THEN g.GFT_CHARGEABLE_WT_KG ELSE 0 END), 0)               AS GFT_LH_Wgt_Chargeable_Kg,
        COALESCE(SUM(CASE WHEN g.LEG_TYPE = 'FL'
                          THEN g.GFT_CHARGEABLE_WT_KG ELSE 0 END), 0)               AS GFT_FL_Wgt_Chargeable_Kg,

        -- GFT Chargeable Costs per leg (CHARGE_VALUE_USD = contracted rate cost)
        COALESCE(SUM(CASE WHEN g.LEG_TYPE = 'SEG1'
                          THEN g.CHARGE_VALUE_USD ELSE 0 END), 0)                    AS GFT_SG_Cost_Chargeable_USD,
        COALESCE(SUM(CASE WHEN g.LEG_TYPE IN ('LH1','LH2','LH3')
                          THEN g.CHARGE_VALUE_USD ELSE 0 END), 0)                    AS GFT_LH_Cost_Chargeable_USD,
        COALESCE(SUM(CASE WHEN g.LEG_TYPE = 'FL'
                          THEN g.CHARGE_VALUE_USD ELSE 0 END), 0)                    AS GFT_FL_Cost_Chargeable_USD,

        -- Fuel Surcharge: no separate charge row in GFT 2.0; returns 0 for schema compat.
        CAST(0 AS NUMBER(38,6))                                                        AS Fuel_Surcharge_Cost_USD,

        MAX(g.ROLLING_QUARTER)                                                         AS Rolling_Quarter

    FROM GBI_FINANCE_DATA_ENG_DB.FIN_DATA_ENG.GFT_COSTED_EXTENDED_GFT2 g

    WHERE g.COSTED_FLAG       = 'Y'
      AND g.DELIVERY_TYPE_CD NOT IN ('NL', 'NLCC', 'LR')
      AND g.DATA_CLASS_CD     = 'OB'
      AND g.ROLLING_QUARTER  IN (-5, -4, -3, -2, -1, 0)

    GROUP BY g.DELIVERY_ID, g.DELIVERY_ITEM_NR, g.PROD_ID
),

-- ---------------------------------------------------------------------------
-- STEP 2: OPH Product Custom Group (HMS views)
-- ---------------------------------------------------------------------------
oph AS (
    SELECT
        pe.prod_node_id,
        UPPER(def.CG_NAME)                                                  AS Prdt_Custom_Grp_GFT
    FROM GBI_FINANCE_SEMANTIC_DB.SALESFIN_ENT.HMS_CG_PROD_EXPLOSION_CUR pe
    LEFT JOIN GBI_FINANCE_SEMANTIC_DB.SALESFIN_ENT.HMS_CUSTOM_GROUP_DTLS_CUR dtls
        ON  dtls.cg_code      = pe.cg_code
        AND dtls.cg_scope_id  = pe.cg_scope_id
    LEFT JOIN GBI_FINANCE_SEMANTIC_DB.SALESFIN_ENT.HMS_CUSTOM_GROUP_DEF_CUR def
        ON  def.cg_code       = pe.cg_code
    WHERE dtls.cg_scope_type          = 'OPH'
      AND def.CG_OWNER_FN_GROUP       = 'Ops Finance'
      AND LEFT(def.CG_NAME, 3)        = 'OPH'
)

-- ---------------------------------------------------------------------------
-- STEP 3: Main SELECT — base rows (PROXY_IB_LISTING_FLAG = 0).
--         Joins Dataiku reference tables for SCAC_SG_FLAG, PROGRAM_CODE,
--         COUNTRY_FCST, DC_FCST, ORIGIN.
--         BULK_PARCEL, DEPLOYMENT_MIX, RETAIL_BOPIS_UNITS are derived
--         expressions; DEPLOYMENT_MIX references ORIGIN/BULK_PARCEL/CHANNEL
--         aliases from earlier in the same SELECT (Snowflake alias fwd-ref).
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

    b.Rate_Type                                                         AS Rate_Type,

    b.RTM_Ops_Channel_L2                                                AS RTM_Ops_Channel_L2,

    -- CHANNEL: RTM_1 derivation; labelled CHANNEL to match FREIGHT_IB_OB schema (see note 14)
    (CASE
        WHEN b.RTM_Ops_Channel_L2 IN ('ONLINE:ONLINE')                                 THEN 'ONLINE'
        WHEN b.RTM_Ops_Channel_L2 IN ('RETAIL:RETAIL', 'RETAIL RPLN:RETAIL REPLENISH') THEN 'RETAIL'
        WHEN b.RTM_Ops_Channel_L2 IN ('INTRCO:INTERCOMPANY', 'RSLR:RESELLER')          THEN 'RESELLER'
        WHEN b.RTM_Ops_Channel_L2 IN ('EDU:EDUCATION')                                 THEN 'EDUCATION'
        ELSE NULL
    END)                                                                AS Channel,

    b.SCAC_SG,
    b.SCAC_LH,
    b.SCAC_FL,
    b.Carrier_Type_SG,
    b.Carrier_Type_LH,
    b.Carrier_Type_FL,
    b.Charter_Deal_Type,
    b.Charter_Flag,
    b.Bopis_Item_Categ_Cd,

    -- STO_TYPE: derived — 'STO' for IB HUB shipments (stock transfer orders) (see note 12)
    (CASE
        WHEN b.Shipping_Pt_Type = 'HUB' AND b.Universe = 'IB'                         THEN 'STO'
        ELSE 'NON-STO'
    END)                                                                AS Sto_Type,

    -- Measures aggregated across delivery items sharing the same dimension combination
    COALESCE(SUM(b.Delivery_Unit),               0)                     AS Delivery_Unit,
    COALESCE(SUM(b.Wgt_FPP_SG_Kg),              0)                     AS Wgt_FPP_SG_Kg,
    COALESCE(SUM(b.Wgt_FPP_LH_Kg),              0)                     AS Wgt_FPP_LH_Kg,
    COALESCE(SUM(b.Wgt_FPP_FL_Kg),              0)                     AS Wgt_FPP_FL_Kg,
    COALESCE(SUM(b.Wgt_Accrual_Kg),             0)                     AS Wgt_Accrual_Kg,
    COALESCE(SUM(b.Cost_Accrual_FL_USD),         0)                     AS Cost_Accrual_FL_USD,
    COALESCE(SUM(b.Cost_Accrual_LH_USD),         0)                     AS Cost_Accrual_LH_USD,
    COALESCE(SUM(b.Cost_Accrual_SG_USD),         0)                     AS Cost_Accrual_SG_USD,
    COALESCE(SUM(b.Cost_Accrual_Total_USD),      0)                     AS Cost_Accrual_Total_USD,
    COALESCE(SUM(b.GFT_SG_Wgt_Chargeable_Kg),   0)                     AS GFT_SG_Wgt_Chargeable_Kg,
    COALESCE(SUM(b.GFT_LH_Wgt_Chargeable_Kg),   0)                     AS GFT_LH_Wgt_Chargeable_Kg,
    COALESCE(SUM(b.GFT_FL_Wgt_Chargeable_Kg),   0)                     AS GFT_FL_Wgt_Chargeable_Kg,
    COALESCE(SUM(b.GFT_SG_Cost_Chargeable_USD),  0)                     AS GFT_SG_Cost_Chargeable_USD,
    COALESCE(SUM(b.GFT_LH_Cost_Chargeable_USD),  0)                     AS GFT_LH_Cost_Chargeable_USD,
    COALESCE(SUM(b.GFT_FL_Cost_Chargeable_USD),  0)                     AS GFT_FL_Cost_Chargeable_USD,
    COALESCE(SUM(b.Fuel_Surcharge_Cost_USD),     0)                     AS Fuel_Surcharge_Cost_USD,

    -- ORIGINAL_DATASET: hardcoded for GFT 2.0 source identification (see note 13)
    'GFT2'                                                              AS Original_Dataset,

    -- SCAC_SG_FLAG: 1 if first-leg SCAC is in the carrier reference list, else 0
    CASE WHEN cm.CARRIER IS NOT NULL THEN 1 ELSE 0 END                 AS SCAC_SG_Flag,

    pm.PROGRAM_CODE                                                     AS Program_Code,
    cdm.COUNTRY_FCST                                                    AS Country_Fcst,
    cdm.DC_FCST                                                         AS DC_Fcst,

    -- ORIGIN: from origin forecast mapping; falls back to DC_OUTBOUND for
    -- unmapped HUB / RETAIL STORE / HUB-RETURN shipping point types
    CASE
        WHEN om.ORIGIN_FCST IS NULL
             AND b.Shipping_Pt_Type IN ('RETAIL STORE', 'HUB', 'HUB-RETURN')          THEN 'DC_OUTBOUND'
        ELSE om.ORIGIN_FCST
    END                                                                 AS Origin,

    -- BULK_PARCEL: AMR uses FL carrier type; other regions use CHANNEL
    CASE b.Dest_Region_Cd
        WHEN 'AMR'
            THEN (CASE b.Carrier_Type_FL
                      WHEN 'PARCEL' THEN 'PARCEL'
                      WHEN 'POSTAL' THEN 'PARCEL'
                      ELSE 'BULK'
                  END)
        ELSE
            (CASE Channel
                  WHEN 'RESELLER' THEN 'BULK'
                  WHEN 'RETAIL'   THEN 'BULK'
                  WHEN 'ONLINE'   THEN 'PARCEL'
                  ELSE 'BULK'
             END)
    END                                                                 AS Bulk_Parcel,

    -- DEPLOYMENT_MIX: composite routing identifier used for planning/forecasting.
    -- References Origin, Bulk_Parcel, Channel, Shipment_Mode aliases from above.
    CAST(
        CASE b.Costed_Flag
            WHEN 'Y' THEN
                CASE
                    WHEN Origin = 'DC_OUTBOUND'
                        THEN 'OUTBOUND_' || Bulk_Parcel || '_' || Channel
                    WHEN Shipment_Mode = 'LOCAL'
                        THEN Shipment_Mode || '_' || b.Deployment || '_' || Bulk_Parcel || '_' || Channel
                    WHEN b.Source_Country_Cd <> b.Dest_Country_Cd
                        THEN 'INTERNATIONAL_' || b.Deployment || '_' || Bulk_Parcel || '_' || Channel
                    WHEN b.Source_Country_Cd = b.Dest_Country_Cd
                        THEN 'LOCAL_' || b.Deployment || '_' || Bulk_Parcel || '_' || Channel
                END
            ELSE CAST(NULL AS VARCHAR(20))
        END
    AS VARCHAR(255))                                                    AS Deployment_Mix,

    -- RETAIL_BOPIS_UNITS: BOPIS delivery units for retail store shipments only
    COALESCE(SUM(
        CASE
            WHEN b.Bopis_Item_Categ_Cd NOT IN ('$NA')
                 AND b.Shipping_Pt_Type = 'RETAIL STORE'                               THEN b.Delivery_Unit
            ELSE 0
        END
    ), 0)                                                               AS Retail_Bopis_Units,

    0                                                                   AS Proxy_Ib_Listing_Flag

FROM base b

LEFT JOIN oph
    ON  oph.prod_node_id = b.Prod_Id

-- Carrier reference list: determines SCAC_SG_FLAG
LEFT JOIN GBI_FINANCE_BAP_DB.FINANCE_BIZ_APP.DKU_OFN_LF_CARRIER_MAPPING cm
    ON  cm.CARRIER = b.SCAC_SG

-- Product-to-program mapping (Dataiku reference table)
LEFT JOIN GBI_FINANCE_BAP_DB.FINANCE_BIZ_APP.DKU_OFN_LF_PRODUCTS_MAPPING pm
    ON  pm.PRODUCT_CUSTOM_GROUP = oph.Prdt_Custom_Grp_GFT

-- Country-to-forecast-region mapping
LEFT JOIN GBI_FINANCE_BAP_DB.FINANCE_BIZ_APP.DKU_OFN_LF_COUNTRY_DC_FCST_MAPPING cdm
    ON  cdm.ISO_CD = b.Dest_Country_Cd

-- Origin forecast mapping: SOURCE_CITY + SHIPPING_PT_TYPE -> ORIGIN_FCST
LEFT JOIN GBI_FINANCE_BAP_DB.FINANCE_BIZ_APP.DKU_OFN_LF_ORIGIN_FCST_MAPPING om
    ON  om.SOURCE_CITY = b.Source_City
    AND COALESCE(b.Shipping_Pt_Type, 'NULL') = COALESCE(om.SHIPPING_PT_TYPE, 'NULL')

WHERE COALESCE(oph.Prdt_Custom_Grp_GFT, '') <> 'OPH_Software_Other'

GROUP BY ALL

-- ---------------------------------------------------------------------------
-- STEP 4: Proxy expansion — duplicates INTERNATIONAL_FD_BULK rows with
--         DEST_COUNTRY_CD remapped to a proxy logistic region.
--         Use case: shipments shown as going through one country that need
--         to be accounted for in a different country (e.g. re-export flows).
--
--         Changes vs main SELECT:
--           - DEST_COUNTRY_CD  overridden with F.TO_COUNTRY_CODE
--           - COUNTRY_FCST     overridden with F.TO_LOGISTIC_REGION
--           - PROXY_IB_LISTING_FLAG = 1
--           - Additional INNER JOIN to DKU_OFN_LF_PROXY_MAPPING
--           - WHERE filter: DEPLOYMENT_MIX LIKE 'INTERNATIONAL_FD_BULK%'
--
--         SHIPMENT_MODE is computed from the original DEST_COUNTRY_CD in both
--         branches — intentional, matches GFT 1.0 FREIGHT_IB_OB behaviour.
-- ---------------------------------------------------------------------------
UNION ALL

SELECT
    b.Universe                                                          AS Universe,
    b.Costed_Flag                                                       AS Costed_Flag,
    b.Fiscal_Qtr_Year                                                   AS Fiscal_Qtr_Year,
    b.Fiscal_Quarter                                                    AS Fiscal_Quarter,
    b.PO_Type_Cd                                                        AS PO_Type_Cd,
    b.Delivery_Type                                                     AS Delivery_Type,
    oph.Prdt_Custom_Grp_GFT                                             AS Prdt_Custom_Grp_GFT,
    b.Dest_Region_Cd                                                    AS Dest_Region_Cd,
    F.TO_COUNTRY_CODE                                                   AS Dest_Country_Cd,
    b.Source_Country_Cd                                                 AS Source_Country_Cd,
    b.Source_City                                                       AS Source_City,
    b.Shipping_Pt_Cd                                                    AS Shipping_Pt_Cd,
    b.Shipping_Pt_Type                                                  AS Shipping_Pt_Type,
    b.Deployment                                                        AS Deployment,

    -- SHIPMENT_MODE: uses original b.Dest_Country_Cd (not proxy) — see note 17
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

    b.Rate_Type                                                         AS Rate_Type,

    b.RTM_Ops_Channel_L2                                                AS RTM_Ops_Channel_L2,

    (CASE
        WHEN b.RTM_Ops_Channel_L2 IN ('ONLINE:ONLINE')                                 THEN 'ONLINE'
        WHEN b.RTM_Ops_Channel_L2 IN ('RETAIL:RETAIL', 'RETAIL RPLN:RETAIL REPLENISH') THEN 'RETAIL'
        WHEN b.RTM_Ops_Channel_L2 IN ('INTRCO:INTERCOMPANY', 'RSLR:RESELLER')          THEN 'RESELLER'
        WHEN b.RTM_Ops_Channel_L2 IN ('EDU:EDUCATION')                                 THEN 'EDUCATION'
        ELSE NULL
    END)                                                                AS Channel,

    b.SCAC_SG,
    b.SCAC_LH,
    b.SCAC_FL,
    b.Carrier_Type_SG,
    b.Carrier_Type_LH,
    b.Carrier_Type_FL,
    b.Charter_Deal_Type,
    b.Charter_Flag,
    b.Bopis_Item_Categ_Cd,

    (CASE
        WHEN b.Shipping_Pt_Type = 'HUB' AND b.Universe = 'IB'                         THEN 'STO'
        ELSE 'NON-STO'
    END)                                                                AS Sto_Type,

    COALESCE(SUM(b.Delivery_Unit),               0)                     AS Delivery_Unit,
    COALESCE(SUM(b.Wgt_FPP_SG_Kg),              0)                     AS Wgt_FPP_SG_Kg,
    COALESCE(SUM(b.Wgt_FPP_LH_Kg),              0)                     AS Wgt_FPP_LH_Kg,
    COALESCE(SUM(b.Wgt_FPP_FL_Kg),              0)                     AS Wgt_FPP_FL_Kg,
    COALESCE(SUM(b.Wgt_Accrual_Kg),             0)                     AS Wgt_Accrual_Kg,
    COALESCE(SUM(b.Cost_Accrual_FL_USD),         0)                     AS Cost_Accrual_FL_USD,
    COALESCE(SUM(b.Cost_Accrual_LH_USD),         0)                     AS Cost_Accrual_LH_USD,
    COALESCE(SUM(b.Cost_Accrual_SG_USD),         0)                     AS Cost_Accrual_SG_USD,
    COALESCE(SUM(b.Cost_Accrual_Total_USD),      0)                     AS Cost_Accrual_Total_USD,
    COALESCE(SUM(b.GFT_SG_Wgt_Chargeable_Kg),   0)                     AS GFT_SG_Wgt_Chargeable_Kg,
    COALESCE(SUM(b.GFT_LH_Wgt_Chargeable_Kg),   0)                     AS GFT_LH_Wgt_Chargeable_Kg,
    COALESCE(SUM(b.GFT_FL_Wgt_Chargeable_Kg),   0)                     AS GFT_FL_Wgt_Chargeable_Kg,
    COALESCE(SUM(b.GFT_SG_Cost_Chargeable_USD),  0)                     AS GFT_SG_Cost_Chargeable_USD,
    COALESCE(SUM(b.GFT_LH_Cost_Chargeable_USD),  0)                     AS GFT_LH_Cost_Chargeable_USD,
    COALESCE(SUM(b.GFT_FL_Cost_Chargeable_USD),  0)                     AS GFT_FL_Cost_Chargeable_USD,
    COALESCE(SUM(b.Fuel_Surcharge_Cost_USD),     0)                     AS Fuel_Surcharge_Cost_USD,

    'GFT2'                                                              AS Original_Dataset,

    CASE WHEN cm.CARRIER IS NOT NULL THEN 1 ELSE 0 END                 AS SCAC_SG_Flag,

    pm.PROGRAM_CODE                                                     AS Program_Code,

    -- COUNTRY_FCST overridden with proxy logistic region (not from cdm table)
    F.TO_LOGISTIC_REGION                                                AS Country_Fcst,
    cdm.DC_FCST                                                         AS DC_Fcst,

    CASE
        WHEN om.ORIGIN_FCST IS NULL
             AND b.Shipping_Pt_Type IN ('RETAIL STORE', 'HUB', 'HUB-RETURN')          THEN 'DC_OUTBOUND'
        ELSE om.ORIGIN_FCST
    END                                                                 AS Origin,

    CASE b.Dest_Region_Cd
        WHEN 'AMR'
            THEN (CASE b.Carrier_Type_FL
                      WHEN 'PARCEL' THEN 'PARCEL'
                      WHEN 'POSTAL' THEN 'PARCEL'
                      ELSE 'BULK'
                  END)
        ELSE
            (CASE Channel
                  WHEN 'RESELLER' THEN 'BULK'
                  WHEN 'RETAIL'   THEN 'BULK'
                  WHEN 'ONLINE'   THEN 'PARCEL'
                  ELSE 'BULK'
             END)
    END                                                                 AS Bulk_Parcel,

    -- DEPLOYMENT_MIX uses original b.Dest_Country_Cd for country equality check — see note 17
    CAST(
        CASE b.Costed_Flag
            WHEN 'Y' THEN
                CASE
                    WHEN Origin = 'DC_OUTBOUND'
                        THEN 'OUTBOUND_' || Bulk_Parcel || '_' || Channel
                    WHEN Shipment_Mode = 'LOCAL'
                        THEN Shipment_Mode || '_' || b.Deployment || '_' || Bulk_Parcel || '_' || Channel
                    WHEN b.Source_Country_Cd <> b.Dest_Country_Cd
                        THEN 'INTERNATIONAL_' || b.Deployment || '_' || Bulk_Parcel || '_' || Channel
                    WHEN b.Source_Country_Cd = b.Dest_Country_Cd
                        THEN 'LOCAL_' || b.Deployment || '_' || Bulk_Parcel || '_' || Channel
                END
            ELSE CAST(NULL AS VARCHAR(20))
        END
    AS VARCHAR(255))                                                    AS Deployment_Mix,

    COALESCE(SUM(
        CASE
            WHEN b.Bopis_Item_Categ_Cd NOT IN ('$NA')
                 AND b.Shipping_Pt_Type = 'RETAIL STORE'                               THEN b.Delivery_Unit
            ELSE 0
        END
    ), 0)                                                               AS Retail_Bopis_Units,

    1                                                                   AS Proxy_Ib_Listing_Flag

FROM base b

LEFT JOIN oph
    ON  oph.prod_node_id = b.Prod_Id

LEFT JOIN GBI_FINANCE_BAP_DB.FINANCE_BIZ_APP.DKU_OFN_LF_CARRIER_MAPPING cm
    ON  cm.CARRIER = b.SCAC_SG

LEFT JOIN GBI_FINANCE_BAP_DB.FINANCE_BIZ_APP.DKU_OFN_LF_PRODUCTS_MAPPING pm
    ON  pm.PRODUCT_CUSTOM_GROUP = oph.Prdt_Custom_Grp_GFT

LEFT JOIN GBI_FINANCE_BAP_DB.FINANCE_BIZ_APP.DKU_OFN_LF_COUNTRY_DC_FCST_MAPPING cdm
    ON  cdm.ISO_CD = b.Dest_Country_Cd

LEFT JOIN GBI_FINANCE_BAP_DB.FINANCE_BIZ_APP.DKU_OFN_LF_ORIGIN_FCST_MAPPING om
    ON  om.SOURCE_CITY = b.Source_City
    AND COALESCE(b.Shipping_Pt_Type, 'NULL') = COALESCE(om.SHIPPING_PT_TYPE, 'NULL')

-- INNER JOIN: only rows that have a proxy country mapping are included
JOIN GBI_FINANCE_BAP_DB.FINANCE_BIZ_APP.DKU_OFN_LF_PROXY_MAPPING F
    ON  b.Dest_Country_Cd = F.FROM_COUNTRY_CODE

WHERE COALESCE(oph.Prdt_Custom_Grp_GFT, '') <> 'OPH_Software_Other'
  AND DEPLOYMENT_MIX LIKE 'INTERNATIONAL_FD_BULK%'

GROUP BY ALL;
