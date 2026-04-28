# GFT 2.0 KOBE Retrofit — Design, Data & Verification Notes

**View:** `GBI_FINANCE_BAP_DB.FINANCE_PREP_BIZ.FREIGHT_IB_OB_GFT2`
**Replaces:** `GBI_FINANCE_BAP_DB.FINANCE_BIZ.FREIGHT_OB_COSTED`
**Source Model:** `GBI_OPS_SEMANTIC_DB.GFT.GFT_COSTED_EXTENDED` (GFT 2.0 / Pando)

---

## Background

FREIGHT_OB_COSTED (view1) was built on legacy GFT 1.0 tables — `DELIVERY_LINE_ITEM_ATTR`, `DELIVERY_LINE_ITEM_COST_CUR`, `FPP_FINAL_OB_COSTING`, `OB_WEIGHT_SOURCE_DETAILS_CUR` — which are being retired. The KOBE Retrofit replaces view1 with FREIGHT_IB_OB_GFT2 sourced entirely from `GFT_COSTED_EXTENDED`, the Pando-managed GFT 2.0 canonical view.

The challenge: the two models have **incompatible grain**.

| | View1 (legacy) | View2 (GFT 2.0) |
|---|---|---|
| Grain | delivery_line_item (pre-pivoted per-leg columns) | delivery_line_item × CHARGE_NAME (one row per charge per leg) |
| Per-leg columns | Pre-computed `Seg1_*`, `Line_Haul_*`, `Final_Leg_*` | Normalized rows keyed by `LEG_TYPE` |
| Source system | GFT 1.0 legacy tables | Pando / GFT_COSTED_EXTENDED |

The new view reconstructs per-leg columns from normalized rows using conditional aggregation (pivot), preserving the exact 43-column output schema of view1 for downstream compatibility.

---

## Key Business Rules

- **Scope filter**: `DATA_CLASS_CD = 'OB'` — OB only. Change to `IN ('OB','IB')` or remove for combined view.
- **Rolling quarter filter**: `ROLLING_QUARTER IN (-5,-4,-3,-2,-1,0)` — 6-quarter rolling window, same as view1.
- **Costed only**: `COSTED_FLAG = 'Y'` — matches view1 filter.
- **Delivery type exclusions**: `NOT IN ('NL', 'NLCC', 'LR')` — matches view1.
- **Product filter**: `Prdt_Custom_Grp_GFT <> 'OPH_Software_Other'` — applied in outer WHERE, same as view1.
- **LEG_TYPE values** (verified against live data):
  - `SEG1` — first/origin segment (short-haul pre-linehaul)
  - `LH1`, `LH2`, `LH3` — line haul legs (primary, secondary, tertiary)
  - `FL` — final leg (last-mile delivery)
- **CHARGE_NAME values** (verified): Only `'BASE FREIGHT'` exists in GFT_COSTED_EXTENDED. Fuel surcharge is **not** a separate charge row — it is embedded in the BASE FREIGHT leg cost in GFT 2.0.
- **SCAC / Carrier identity**: `SCAC_LH` and `CARRIER_TYPE_LH` use `LH1` only (primary line-haul leg) to identify the carrier, consistent with view1 behavior. Cost/weight measures roll up `LH1 + LH2 + LH3`.
- **DELIVERY_QTY**: Must use `MAX(DELIVERY_QTY)` — NOT `SUM(CASE WHEN REPORTING_FLAG='Y')`. `REPORTING_FLAG` can be `'N'` on ALL rows for a multi-leg shipment where the confirmed SCAC matches neither modeled leg (see Data Verification section).
- **ACCRUAL_WEIGHT_KG**: Delivery-level attribute repeated on every charge row per item — use `MAX()` not SUM.
- **OPH Product Custom Group**: `PRDT_CUSTOM_GRP_GFT` is not in GFT_COSTED_EXTENDED. It is still joined from `OPH_MDM_CUSTM_GRP_MPN_EXT_CUR` + `MDM_CUSTOM_GROUP_CUR` via `PROD_ID`, same as view1.
- **Fiscal calendar**: GFT_COSTED_EXTENDED joins `FISCAL_DAY_CUR` with `Region_Cd='AMR'`, which provides the Apple corporate fiscal calendar — globally applicable for all regions.

---

## Source Model Overview — GFT_COSTED_EXTENDED

| Property | Value |
|---|---|
| Full name | `GBI_OPS_SEMANTIC_DB.GFT.GFT_COSTED_EXTENDED` |
| Grain | `DELIVERY_ID` + `DELIVERY_ITEM_NR` + `CHARGE_NAME` (per leg) |
| Column count | ~664 columns |
| Managed by | Pando team |
| Delete filter | `Delete_Ind <> 'D'` (applied internally in view2) |
| Fiscal calendar | LEFT JOIN to `FISCAL_DAY_CUR` with `Region_Cd = 'AMR'` |

### Key Columns Used

| Column | Maps To | Notes |
|---|---|---|
| `DATA_CLASS_CD` | UNIVERSE | 'OB' or 'IB' |
| `COSTED_FLAG` | COSTED_FLAG | Filter: = 'Y' |
| `FISCAL_QTR_YEAR` | FISCAL_QTR_YEAR | Pre-computed in view2 |
| `FISCAL_YEAR` + `FISCAL_QUARTER` | FISCAL_QUARTER | Concatenated with TRIM() |
| `PO_TYPE_CD` | PO_TYPE_CD | Available in view2 (was NULL in view1) |
| `DELIVERY_TYPE_CD` | DELIVERY_TYPE | |
| `REGION_CD` | DEST_REGION_CD | TRIM() applied |
| `DESTINATION_COUNTRY_CODE` | DEST_COUNTRY_CD | |
| `ORIGIN_COUNTRY_CODE` | SOURCE_COUNTRY_CD | |
| `ORIGIN_CITY` | SOURCE_CITY | UPPER + TRIM + strip CHAR(160) |
| `SHIPPING_POINT_CD` | SHIPPING_PT_CD | |
| `SHIP_POINT_TYPE_CD` | SHIPPING_PT_TYPE (base) | Replaces EM_SHIP_POINT join |
| `OPS_CHANNEL_LEVEL_2_DESCRIPTION` | RTM_OPS_CHANNEL_L2 | UPPER() applied |
| `BOPIS_ITEM_CATEG_CD` | BOPIS_ITEM_CATEG_CD | |
| `CHARTER_DEAL_TYPE` | CHARTER_DEAL_TYPE | UPPER() applied |
| `CHARTER_FLIGHT_FLAG` | CHARTER_FLAG | UPPER() applied |
| `LEG_TYPE` | (pivot key) | SEG1 / LH1 / LH2 / LH3 / FL |
| `PARENT_SCAC_CD` | SCAC_SG / SCAC_LH / SCAC_FL | Pivoted by LEG_TYPE |
| `CARRIER_TYPE` | CARRIER_TYPE_SG / _LH / _FL | Pivoted by LEG_TYPE |
| `DELIVERY_QTY` | DELIVERY_UNIT | MAX() — see business rules |
| `FPP_CHRGBLE_WEIGHT_MSR_KG` | WGT_FPP_SG_KG, WGT_FPP_LH_KG | SUM per leg |
| `FPP_FL_CHRGBLE_WEIGHT_MSR_KG_SUM` | WGT_FPP_FL_KG | Pre-aggregated FL column |
| `ACCRUAL_WEIGHT_KG` | WGT_ACCRUAL_KG | MAX() — delivery-level attribute |
| `ACCRUAL_COST_USD` | COST_ACCRUAL_*_USD | SUM per leg; NULL until FPP processes |
| `CHARGE_VALUE_USD` | GFT_*_COST_CHARGEABLE_USD | Contracted/standard rate cost |
| `GFT_CHARGEABLE_WT_KG` | GFT_*_WGT_CHARGEABLE_KG | SUM per leg |
| `ROLLING_QUARTER` | (filter only) | IN (-5,-4,-3,-2,-1,0) |
| `PROD_ID` | (join key for OPH) | Used to join MDM product group tables |

---

## View Design

### Two-Step CTE Pattern

```
GFT_COSTED_EXTENDED          oph CTE
(charge-level rows)      (MDM product group)
       |                        |
    base CTE                    |
(pivot to delivery-item         |
 grain via conditional          |
 aggregation)                   |
       |________________________|
              |
         final SELECT
    (derived dims + GROUP BY ALL)
```

**Step 1 — `base` CTE**: Collapses the normalized charge-level rows to one row per `DELIVERY_ID + DELIVERY_ITEM_NR + PROD_ID`. Uses:
- `MAX(CASE WHEN LEG_TYPE = 'X' THEN col END)` for single-valued dimensional columns (SCAC, carrier type)
- `SUM(CASE WHEN LEG_TYPE IN (...) THEN col ELSE 0 END)` for additive measures (costs, weights)
- `MAX(col)` for delivery-level attributes repeated on every row (DELIVERY_QTY, ACCRUAL_WEIGHT_KG, all dimension fields)

**Step 2 — `oph` CTE**: Joins `OPH_MDM_CUSTM_GRP_MPN_EXT_CUR` to `MDM_CUSTOM_GROUP_CUR` on `GRP_CATEG_CD='gft_All'`, `HIER_CD='OPH'`, `LEFT(custom_grp_desc,3)='OPH'`. Returns one row per PROD_ID.

**Final SELECT**: Applies SHIPPING_PT_TYPE CASE, DEPLOYMENT CASE, SHIPMENT_MODE CASE (PAC/AMR/EURO logic), and RTM_1 mapping. Joins base to oph. Aggregates measures with `SUM()`. `GROUP BY ALL`.

### Derived Dimension Logic

**SHIPPING_PT_TYPE**:
```sql
CASE
    WHEN SHIP_POINT_TYPE_CD IS NULL
         AND REGEXP_INSTR(SHIPPING_POINT_CD, '^[R][0-9]{1,4}?$') > 0  THEN 'RETAIL STORE'
    WHEN UPPER(SHIP_POINT_TYPE_CD) = 'DIRECT'                          THEN 'OEM'
    ELSE UPPER(SHIP_POINT_TYPE_CD)
END
```
*Note: The `DIRECT+IDL/SFS → RETAIL STORE` override from view1 is dropped — requires `ESP.ORIGIN` from `EM_SHIP_POINT` which is not available in view2. Current logic relies on `SHIP_POINT_TYPE_CD` already reflecting the correct value.*

**DEPLOYMENT**:
```sql
CASE
    WHEN LEFT(SHIP_POINT_TYPE_CD, 3) = 'HUB'  THEN 'FD'
    WHEN LEFT(SHIP_POINT_TYPE_CD, 3) = 'OEM'  THEN 'DS'
    WHEN LEFT(SHIPPING_POINT_CD, 1)  = 'V'    THEN 'DS'
    WHEN UPPER(SHIP_POINT_TYPE_CD)   = 'DIRECT' THEN 'DS'
    ELSE 'FD'
END
```

**SHIPMENT_MODE** (PAC / AMR / EURO regions, same as view1):
- `FD` → `DC_Outbound`
- Same source/dest country → `LOCAL`
- PAC: HK + SHENZHEN origin → `LOCAL`
- AMR: US dest + BR source → `LOCAL`
- EURO: IE source → `LOCAL` (checked first, before FD)
- Default → `AIR`

**RTM_1**:
```
ONLINE:ONLINE               → ONLINE
RETAIL:RETAIL               → RETAIL
RETAIL RPLN:RETAIL REPLENISH → RETAIL
INTRCO:INTERCOMPANY         → RESELLER
RSLR:RESELLER               → RESELLER
EDU:EDUCATION               → EDUCATION
(other)                     → NULL
```

---

## Column Mapping: View1 → View2

| View1 Column | View1 Source | View2 Equivalent | Notes |
|---|---|---|---|
| UNIVERSE | `'OB'` (literal) | `DATA_CLASS_CD` | Now populated from data, not hardcoded |
| COSTED_FLAG | `DLIA.Costed_Flag` | `COSTED_FLAG` | |
| FISCAL_QTR_YEAR | `GFD.fiscal_qtr_year` | `FISCAL_QTR_YEAR` | |
| FISCAL_QUARTER | `TRIM(GFD.fiscal_year)\|\|TRIM(GFD.fiscal_quarter)` | Same via `FISCAL_YEAR\|\|FISCAL_QUARTER` | |
| PO_TYPE_CD | `NULL` (cast) | `PO_TYPE_CD` | Now populated in GFT 2.0 |
| DELIVERY_TYPE | `DLIA.Delivery_Type` | `DELIVERY_TYPE_CD` | |
| PRDT_CUSTOM_GRP_GFT | MDM join via `DLIA.Prod_Id` | MDM join via `PROD_ID` | Same join pattern |
| DEST_REGION_CD | `TRIM(DLIA.Region_Cd)` | `TRIM(REGION_CD)` | |
| DEST_COUNTRY_CD | `DLIA.Dest_Country_Cd` | `DESTINATION_COUNTRY_CODE` | |
| SOURCE_COUNTRY_CD | `DLIA.Source_Country_Cd` | `ORIGIN_COUNTRY_CODE` | |
| SOURCE_CITY | `UPPER(TRIM(...SOURCE_CITY_NAME...))` | `UPPER(TRIM(...ORIGIN_CITY...))` | Same CHAR(160) strip |
| SHIPPING_PT_CD | `DLIA.Shipping_Point_Cd` | `SHIPPING_POINT_CD` | |
| SHIPPING_PT_TYPE | CASE on `ESP.SHIP_POINT_TYPE` | CASE on `SHIP_POINT_TYPE_CD` | IDL/SFS override dropped |
| DEPLOYMENT | CASE on `ESP.SHIP_POINT_TYPE` | CASE on `SHIP_POINT_TYPE_CD` | |
| SHIPMENT_MODE | CASE on region/deployment/country | Same logic, same columns | |
| RTM_OPS_CHANNEL_L2 | `UPPER(CC.ops_channel_level_2_desc)` | `UPPER(OPS_CHANNEL_LEVEL_2_DESCRIPTION)` | No CHANNEL_CUR join needed |
| RTM_1 | CASE on RTM_Ops_Channel_L2 | Same CASE logic | |
| SCAC_SG | `DLIA.Seg1_SCAC_Cd` | `MAX(CASE WHEN LEG_TYPE='SEG1' THEN PARENT_SCAC_CD END)` | Pivot |
| SCAC_LH | `DLIA.Line_haul_scac_Cd` | `MAX(CASE WHEN LEG_TYPE='LH1' THEN PARENT_SCAC_CD END)` | LH1 only |
| SCAC_FL | `DLIA.final_leg_scac_Cd` | `MAX(CASE WHEN LEG_TYPE='FL' THEN PARENT_SCAC_CD END)` | Pivot |
| CARRIER_TYPE_SG | `UPPER(DLIA.Seg1_Carrier_Type_Cd)` | `MAX(CASE WHEN LEG_TYPE='SEG1' THEN UPPER(CARRIER_TYPE) END)` | Pivot |
| CARRIER_TYPE_LH | `UPPER(DLIA.line_haul_Carrier_Type_Cd)` | `MAX(CASE WHEN LEG_TYPE='LH1' THEN UPPER(CARRIER_TYPE) END)` | LH1 only |
| CARRIER_TYPE_FL | `UPPER(DLIA.Final_Carrier_Type_Cd)` | `MAX(CASE WHEN LEG_TYPE='FL' THEN UPPER(CARRIER_TYPE) END)` | Pivot; FL blank in some cases |
| BOPIS_ITEM_CATEG_CD | `DLIA.Bopis_Item_Categ_Cd` | `BOPIS_ITEM_CATEG_CD` | |
| CHARTER_DEAL_TYPE | `UPPER(DLIA.Charter_Deal_Type)` | `UPPER(CHARTER_DEAL_TYPE)` | |
| CHARTER_FLAG | `UPPER(DLIA.Charter_Flag)` | `UPPER(CHARTER_FLIGHT_FLAG)` | Column rename in GFT 2.0 |
| DELIVERY_UNIT | `SUM(DLICC.Delivery_Qty)` | `MAX(DELIVERY_QTY)` then SUM outer | MAX not REPORTING_FLAG='Y' |
| WGT_FPP_SG_KG | `SUM(FFOB.Fpp_Seg1_Chrgble_Wgt_Msr_Kg)` | `SUM(CASE WHEN LEG_TYPE='SEG1' THEN FPP_CHRGBLE_WEIGHT_MSR_KG END)` | |
| WGT_FPP_LH_KG | `SUM(FFOB.Fpp_Lh_Chrgble_Weight_Msr_Kg)` | `SUM(CASE WHEN LEG_TYPE IN ('LH1','LH2','LH3') THEN FPP_CHRGBLE_WEIGHT_MSR_KG END)` | Rolls up all LH legs |
| WGT_FPP_FL_KG | `SUM(FFOB.Fpp_Fl_Chrgble_Weight_Msr_Kg)` | `SUM(CASE WHEN LEG_TYPE='FL' THEN FPP_FL_CHRGBLE_WEIGHT_MSR_KG_SUM END)` | Pre-agg _SUM column |
| WGT_ACCRUAL_KG | `SUM(FFOB.Fpp_Accrual_Weight_Msr_Kg)` | `MAX(ACCRUAL_WEIGHT_KG)` then SUM outer | Delivery-level attr; MAX not SUM |
| COST_ACCRUAL_FL_USD | `SUM(FFOB.FL_Accrual_Cost_USD_Amt)` | `SUM(CASE WHEN LEG_TYPE='FL' THEN ACCRUAL_COST_USD END)` | |
| COST_ACCRUAL_LH_USD | `SUM(FFOB.LH_Accrual_Cost_USD_Amt)` | `SUM(CASE WHEN LEG_TYPE IN ('LH1','LH2','LH3') THEN ACCRUAL_COST_USD END)` | |
| COST_ACCRUAL_SG_USD | `SUM(FFOB.Seg1_Accrual_Cost_USD_Amt)` | `SUM(CASE WHEN LEG_TYPE='SEG1' THEN ACCRUAL_COST_USD END)` | |
| COST_ACCRUAL_TOTAL_USD | `SUM(FFOB.Fpp_Accrual_Fgt_Cost_USD_Amt)` | `SUM(ACCRUAL_COST_USD)` (all legs) | Fuel embedded; no separate row |
| GFT_SG_WGT_CHARGEABLE_KG | `SUM(OWSDC.Seg1_Chargeable_Wt_Kg_Msr)` | `SUM(CASE WHEN LEG_TYPE='SEG1' THEN GFT_CHARGEABLE_WT_KG END)` | |
| GFT_LH_WGT_CHARGEABLE_KG | `SUM(OWSDC.Lh_Chargeable_Wt_Kg_Msr)` | `SUM(CASE WHEN LEG_TYPE IN ('LH1','LH2','LH3') THEN GFT_CHARGEABLE_WT_KG END)` | |
| GFT_FL_WGT_CHARGEABLE_KG | `SUM(OWSDC.Fl_Chargeable_Wt_Kg_Msr)` | `SUM(CASE WHEN LEG_TYPE='FL' THEN GFT_CHARGEABLE_WT_KG END)` | |
| GFT_SG_COST_CHARGEABLE_USD | `SUM(DLICC.Seg1_Std_Cost_USD)` | `SUM(CASE WHEN LEG_TYPE='SEG1' THEN CHARGE_VALUE_USD END)` | Contracted rate cost |
| GFT_LH_COST_CHARGEABLE_USD | `SUM(DLICC.Line_Haul_std_cost_USD)` | `SUM(CASE WHEN LEG_TYPE IN ('LH1','LH2','LH3') THEN CHARGE_VALUE_USD END)` | |
| GFT_FL_COST_CHARGEABLE_USD | `SUM(DLICC.final_leg_std_cost_actual_USD)` | `SUM(CASE WHEN LEG_TYPE='FL' THEN CHARGE_VALUE_USD END)` | |
| FUEL_SURCHARGE_COST_USD | `SUM(DLICC.Fuel_Surcharge_Cost_USD)` | `CAST(0 AS NUMBER(38,6))` | No separate charge row in GFT 2.0 |

---

## Data Verification

### LEG_TYPE Distinct Values
Confirmed via `SELECT DISTINCT LEG_TYPE FROM GFT_COSTED_EXTENDED`:

```
FL, LH1, LH2, LH3, SEG1
```

*Initial design used 'SG', 'LH', 'FL' — corrected to 'SEG1', 'LH1'/'LH2'/'LH3', 'FL'.*

### CHARGE_NAME Distinct Values
Confirmed via `SELECT CHARGE_NAME, CHARGE_CATEGORY, COUNT(*)`:

```
CHARGE_NAME    CHARGE_CATEGORY    CNT
BASE FREIGHT   BASE FREIGHT       2,701,486
```

*Only one CHARGE_NAME exists. Fuel surcharge is NOT a separate row. Initial design had a FUEL SURCHARGE conditional — replaced with `CAST(0 AS NUMBER(38,6))`.*

### Spot-Check: Delivery QBM7987731, Item 10

```
DELIVERY_ID   ITEM  LEG_TYPE  LEGS  CHARGE_NAME    PARENT_SCAC  CARRIER_TYPE  DELIVERY_QTY  ACCRUAL_COST_USD  CHARGE_VALUE_USD  GFT_CHRGBLE_WT  FPP_CHRGBLE_WT  ACCRUAL_WT  FUEL_RATE  REPORTING_FLAG
QBM7987731    10    FL        2     BASE FREIGHT   DHLC         (blank)       1             (NULL)            0.0000            2.7800          2.7800          (NULL)       (NULL)     N
QBM7987731    10    SEG1      2     BASE FREIGHT   TCIF         BULK          1             (NULL)            0.4630            3.3560          3.3560          (NULL)       (NULL)     N
```

**Key findings from this delivery:**
- `REPORTING_FLAG = 'N'` on **both** rows — this occurs when the confirmed SCAC matches neither TCIF nor DHLC. Using `SUM(CASE WHEN REPORTING_FLAG='Y' THEN DELIVERY_QTY END)` returns 0. Fix: `MAX(DELIVERY_QTY)`.
- `ACCRUAL_COST_USD` is NULL (FPP has not processed this delivery). COALESCE to 0 handles this.
- `CARRIER_TYPE` is blank on the FL row — this is a data gap in view2, not actionable from the view side.
- `FUEL_RATE` and `FUEL_CHARGE_TYPE` are NULL — no fuel breakdown available for this delivery.

---

## Design Decisions

| Decision | Chosen Approach | Rationale |
|---|---|---|
| Grain pivot strategy | Conditional aggregation (`MAX`/`SUM` with CASE on LEG_TYPE) | Standard Snowflake pattern; no PIVOT keyword needed; readable |
| SCAC_LH carrier identity | LH1 only | Matches view1 `Line_haul_scac_Cd` which used the primary leg |
| LH cost/weight rollup | `IN ('LH1','LH2','LH3')` | Sum all line-haul legs for accurate total; individual legs may be partial |
| DELIVERY_QTY aggregation | `MAX(DELIVERY_QTY)` | REPORTING_FLAG can be 'N' on all rows; MAX is reliable |
| ACCRUAL_WEIGHT_KG aggregation | `MAX(ACCRUAL_WEIGHT_KG)` | Delivery-level attribute; summing would double-count |
| SHIPPING_PT_TYPE source | `SHIP_POINT_TYPE_CD` from view2 | Replaces `EM_SHIP_POINT` join; Pando enriches this column |
| DIRECT+IDL/SFS override | **Dropped** | Requires `ESP.ORIGIN` from `EM_SHIP_POINT` — not available in view2 |
| FUEL_SURCHARGE_COST_USD | `CAST(0 AS NUMBER(38,6))` | No separate fuel charge row in GFT 2.0; retained for schema compatibility |
| OPH product group | MDM join retained (not from view2) | `PRDT_CUSTOM_GRP_GFT` not available in GFT_COSTED_EXTENDED |
| Fiscal calendar | Use view2's built-in `FISCAL_QTR_YEAR` / `FISCAL_YEAR` / `FISCAL_QUARTER` | view2 already joins FISCAL_DAY_CUR with Region_Cd='AMR' |
| PO_TYPE_CD | Populated from `PO_TYPE_CD` column | Was `CAST(NULL AS VARCHAR(20))` in view1; now available in GFT 2.0 |

---

## Known Gaps & Open Items

| # | Gap | Impact | Status |
|---|---|---|---|
| 1 | `SHIP_POINT_TYPE_CD` not populated for ~908 delivery items (~0.8% of total) — causes `SHIPPING_PT_TYPE = NULL` | Affects shipment classification for those rows; see breakdown below | Open — raised with GFT team (Q4) |
| 2 | `FUEL_SURCHARGE_COST_USD` always 0 | Column not comparable to view1; fuel embedded in BASE FREIGHT total | Open — investigate FUEL_RATE / FUEL_CHARGE_TYPE columns |
| 3 | `ACCRUAL_COST_USD` NULL for some deliveries | COST_ACCRUAL_* columns zero until FPP processes; same behavior as view1 LEFT JOIN | Expected; not a defect |
| 4 | `CARRIER_TYPE_FL` blank for some FL rows | Data gap in view2 source; FL leg carrier type not always populated | Open — raise with Pando team |
| 5 | Is ACCRUAL_COST_USD inclusive of fuel? | Affects COST_ACCRUAL_TOTAL_USD comparability to view1 | Open — confirm with Pando team |
| 6 | Multi-LH deliveries (LH2, LH3) | LH cost/weight rolls up correctly; SCAC/carrier uses LH1 only | Accepted; matches view1 concept |

### Gap 1 Detail — NULL SHIPPING_PT_TYPE Breakdown (T5 finding, 108 distinct shipping points)

| Pattern | Examples | Likely Type | Note |
|---|---|---|---|
| V-prefix | V384, V235, V332, V304, V192 | DS (Direct Ship) | DEPLOYMENT correctly gets 'DS' via `LEFT(SHIPPING_POINT_CD,1)='V'` rule; only SHIPPING_PT_TYPE is NULL |
| European hub/DC codes | LO22, LU30, LU10, LU20, LU40, LU50, LU60, DE01, TR10 | HUB | Should likely be 'HUB' → DEPLOYMENT='FD'; SHIP_POINT_TYPE_CD not populated in source |
| SAP numeric plant codes | 8402, 8401, 8206, 6401 | Unknown | Likely OEM/factory origins; need GFT team confirmation |
| MIT / facility codes | MIT7, MIT5, MIT6, MIT3 | Unknown | Need GFT team confirmation |
| Other alphanumeric | 332A, 336A, 166A, C73A, C73B | Unknown | Need GFT team confirmation |

Root cause: the old view joined `EM_SHIP_POINT` to resolve ship point type; `GFT_COSTED_EXTENDED` does not populate `SHIP_POINT_TYPE_CD` for these plant codes. Options: (a) GFT/Pando team enriches `SHIP_POINT_TYPE_CD` in the source, or (b) reinstate a join to `EM_SHIP_POINT`.

---

## Questions for GFT Team

| # | Question | Context | Priority | Status |
|---|---|---|---|---|
| Q1 | ~~Is `CHARGE_NAME` always `'BASE FREIGHT'`, or could other charge types appear?~~ | Confirmed via T1: only BASE FREIGHT exists. No action needed. | ~~CRITICAL~~ | Closed |
| Q2 | ~~Do LH2/LH3 ever have a different `PARENT_SCAC_CD` than LH1?~~ | Confirmed via T2: no results — SCAC is consistent across all LH legs. | ~~HIGH~~ | Closed |
| Q3 | ~~Is `ACCRUAL_WEIGHT_KG` guaranteed to be identical across all charge rows for a given delivery item?~~ | Confirmed via T3: no results — weight is consistent. MAX() is safe. | ~~HIGH~~ | Closed |
| Q4 | `SHIP_POINT_TYPE_CD` is NULL for ~908 delivery items. Can the source view be enriched to populate this for plant codes (LO/LU/DE/TR, SAP numeric codes, MIT codes, V-prefix codes)? Alternatively, should we reinstate a join to `EM_SHIP_POINT`? | T5 found 908 NULL SHIPPING_PT_TYPE rows. European hub codes (LO/LU/DE/TR) are most likely to affect shipment classification. V-prefix codes get correct DEPLOYMENT via separate rule but still show NULL SHIPPING_PT_TYPE. | HIGH | Open |
| Q5 | Why does the FL chargeable weight use `FPP_FL_CHRGBLE_WEIGHT_MSR_KG_SUM` instead of `FPP_CHRGBLE_WEIGHT_MSR_KG` (used for SG and LH legs)? Is it already pre-aggregated? | Needed to confirm weight methodology is consistent across legs. | MEDIUM | Open |
| Q7 | 6 products in `GFT_COSTED_EXTENDED_GFT2` are not yet classified in the OPH HMS hierarchy: `KU193ZD/A` (iPhone 15 Plus Pink 256GB), `BCSE3LL/A`, `BCXL3LL/A`, `BCSB3LL/A`, `BCS83LL/A`, `BCTY3LL/A` (iPad A16 bundles). Can these be added to the OPH custom group in HMS? Currently handled via LEFT JOIN with `PRDT_CUSTOM_GRP_GFT = NULL` for these products. | These products' freight data is included in the view but unclassified by product group. | MEDIUM | Open |

---

## Source Files

| File | Description |
|---|---|
| `FREIGHT_IB_OB_GFT2.sql` | New view DDL (production-ready) |
| `FREIGHT_OB_COSTED.sql` | Old view DDL (reference / baseline) |
| `GFT_COSTED_EXTENDED.sql` | Source view DDL from Pando team (~664 columns) |
| `GFT 2.0 CDF column mappings.xlsx` | Column mapping spreadsheet (515 rows, GFT_PANDO team) |
| `GFT_COSTED_EXTENDED_ANALYSIS.xlsx` | Spot-check data, sample queries, reference values |

---

## Verification Queries

### Check LEG_TYPE values
```sql
SELECT DISTINCT LEG_TYPE
FROM GBI_OPS_SEMANTIC_DB.GFT.GFT_COSTED_EXTENDED
WHERE DATA_CLASS_CD = 'OB'
  AND ROLLING_QUARTER IN (-1, 0)
ORDER BY 1;
```

### Check CHARGE_NAME values
```sql
SELECT CHARGE_NAME, CHARGE_CATEGORY, COUNT(*) AS CNT
FROM GBI_OPS_SEMANTIC_DB.GFT.GFT_COSTED_EXTENDED
WHERE DATA_CLASS_CD = 'OB'
  AND ROLLING_QUARTER IN (-1, 0)
GROUP BY 1, 2
ORDER BY 3 DESC;
```

### Spot-check a specific delivery
```sql
SELECT
    DELIVERY_ID, DELIVERY_ITEM_NR, LEG_TYPE, LEGS, CHARGE_NAME,
    PARENT_SCAC_CD, CARRIER_TYPE,
    DELIVERY_QTY, ACCRUAL_COST_USD, CHARGE_VALUE_USD,
    GFT_CHARGEABLE_WT_KG, FPP_CHRGBLE_WEIGHT_MSR_KG,
    FPP_FL_CHRGBLE_WEIGHT_MSR_KG_SUM, ACCRUAL_WEIGHT_KG,
    FUEL_RATE, FUEL_CHARGE_TYPE, REPORTING_FLAG
FROM GBI_OPS_SEMANTIC_DB.GFT.GFT_COSTED_EXTENDED
WHERE DELIVERY_ID = '<DELIVERY_ID>'
  AND DELIVERY_ITEM_NR = <ITEM_NR>
ORDER BY LEG_TYPE;
```

### Row count comparison (view1 vs view2)
```sql
-- View1 baseline
SELECT COUNT(*) FROM GBI_FINANCE_BAP_DB.FINANCE_BIZ.FREIGHT_OB_COSTED;

-- View2 new
SELECT COUNT(*) FROM GBI_FINANCE_BAP_DB.FINANCE_PREP_BIZ.FREIGHT_IB_OB_GFT2;
```

### Aggregate comparison by fiscal quarter
```sql
SELECT
    v.FISCAL_QTR_YEAR,
    SUM(v.DELIVERY_UNIT)           AS DU_v1,
    SUM(n.DELIVERY_UNIT)           AS DU_v2,
    SUM(v.COST_ACCRUAL_TOTAL_USD)  AS ACCRUAL_v1,
    SUM(n.COST_ACCRUAL_TOTAL_USD)  AS ACCRUAL_v2
FROM GBI_FINANCE_BAP_DB.FINANCE_BIZ.FREIGHT_OB_COSTED   v
FULL OUTER JOIN GBI_FINANCE_BAP_DB.FINANCE_PREP_BIZ.FREIGHT_IB_OB_GFT2 n
    ON v.FISCAL_QTR_YEAR = n.FISCAL_QTR_YEAR
GROUP BY 1
ORDER BY 1;
```

---

## Logic Validation Queries

### T1 — Confirm only BASE FREIGHT exists
```sql
SELECT CHARGE_NAME, COUNT(*) cnt
FROM GBI_OPS_SEMANTIC_DB.GFT.GFT_COSTED_EXTENDED
WHERE COSTED_FLAG = 'Y'
  AND DELIVERY_TYPE_CD NOT IN ('NL', 'NLCC', 'LR')
  AND DATA_CLASS_CD = 'OB'
  AND ROLLING_QUARTER IN (-5,-4,-3,-2,-1,0)
GROUP BY 1
ORDER BY 2 DESC;
```

### T2 — Check if LH2/LH3 ever have different SCACs than LH1
```sql
SELECT DELIVERY_ID, DELIVERY_ITEM_NR,
       LISTAGG(DISTINCT LEG_TYPE || ':' || PARENT_SCAC_CD, '; ')
         WITHIN GROUP (ORDER BY LEG_TYPE) AS legs_scacs
FROM GBI_OPS_SEMANTIC_DB.GFT.GFT_COSTED_EXTENDED
WHERE LEG_TYPE IN ('LH1','LH2','LH3')
  AND COSTED_FLAG = 'Y'
  AND DATA_CLASS_CD = 'OB'
GROUP BY 1, 2
HAVING COUNT(DISTINCT PARENT_SCAC_CD) > 1
LIMIT 100;
```

### T3 — Confirm ACCRUAL_WEIGHT_KG is same across all rows per delivery item
```sql
SELECT DELIVERY_ID, DELIVERY_ITEM_NR,
       COUNT(DISTINCT ACCRUAL_WEIGHT_KG) AS weight_variants
FROM GBI_OPS_SEMANTIC_DB.GFT.GFT_COSTED_EXTENDED
WHERE COSTED_FLAG = 'Y'
  AND DATA_CLASS_CD = 'OB'
GROUP BY 1, 2
HAVING COUNT(DISTINCT ACCRUAL_WEIGHT_KG) > 1
LIMIT 100;
```

### T4 — Product match rate (quantifies INNER JOIN drop-off)
```sql
SELECT 'In GFT source' AS label, COUNT(DISTINCT PROD_ID) AS cnt
FROM GBI_OPS_SEMANTIC_DB.GFT.GFT_COSTED_EXTENDED
WHERE COSTED_FLAG = 'Y'
  AND DELIVERY_TYPE_CD NOT IN ('NL','NLCC','LR')
  AND DATA_CLASS_CD = 'OB'
UNION ALL
SELECT 'Matched to OPH', COUNT(DISTINCT bp.PROD_ID)
FROM (
    SELECT DISTINCT PROD_ID
    FROM GBI_OPS_SEMANTIC_DB.GFT.GFT_COSTED_EXTENDED
    WHERE COSTED_FLAG = 'Y'
      AND DELIVERY_TYPE_CD NOT IN ('NL','NLCC','LR')
      AND DATA_CLASS_CD = 'OB'
) bp
JOIN GBI_FINANCE_BAP_DB.FINANCE_BIZ.OPH_MDM_CUSTM_GRP_MPN_EXT_CUR omcgmec
  ON omcgmec.prod_node_id = bp.PROD_ID
WHERE omcgmec.HIER_CD = 'OPH';
```

### T5 — NULL audit on key dimensions
```sql
SELECT
    SUM(CASE WHEN Shipping_Pt_Type IS NULL THEN 1 ELSE 0 END) AS null_shipping_pt_type,
    SUM(CASE WHEN Shipment_Mode IS NULL THEN 1 ELSE 0 END) AS null_shipment_mode,
    SUM(CASE WHEN RTM_1 IS NULL THEN 1 ELSE 0 END) AS null_rtm_1,
    COUNT(*) AS total_rows
FROM GBI_FINANCE_BAP_DB.FINANCE_PREP_BIZ.FREIGHT_IB_OB_GFT2;
```

### T6 — Verify SG + LH + FL = Total cost
```sql
SELECT COUNT(*) AS mismatches
FROM GBI_FINANCE_BAP_DB.FINANCE_PREP_BIZ.FREIGHT_IB_OB_GFT2
WHERE ABS(
    (COST_ACCRUAL_SG_USD + COST_ACCRUAL_LH_USD + COST_ACCRUAL_FL_USD)
    - COST_ACCRUAL_TOTAL_USD
) > 0.01;
```

### T7 — Cardinality check (one row per delivery item)
```sql
SELECT DELIVERY_ID, DELIVERY_ITEM_NR, COUNT(*) AS row_count
FROM GBI_FINANCE_BAP_DB.FINANCE_PREP_BIZ.FREIGHT_IB_OB_GFT2
GROUP BY 1, 2
HAVING COUNT(*) > 1
LIMIT 100;
```
