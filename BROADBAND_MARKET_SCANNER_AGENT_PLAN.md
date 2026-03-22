# Broadband Market Scanner — Agent Coding Plan

## Project Overview

Build an end-to-end platform that marries FCC Broadband Data Collection (BDC) provider-level fiber availability at the **census block (CB)** level with ACS demographic data to produce **hyperlocal, real-time fiber deployment forecasts**. Users query any geographic area and instantly receive an interactive map showing current fiber coverage, demographics, provider analytics, and ML-driven forecasts of future fiber builds.

### What We Already Have (From NetConnect-AI)

- **FCC BDC data** already downloaded and processed at the CB level for **5 states**. This includes provider-level records with technology codes, download/upload speeds, and block GEOIDs.
- **Demographics data** already downloaded — housing units and population at the CB level, and median household income (MHI) at the CBG level from ACS.
- **Household projections** available at the CBG level — these provide **Housing Unit** counts (total units, not just occupied/households), which are larger than household counts.

### What We Still Need to Build

- Shapefile processing pipeline to compute CB areas and densities
- MHI rolldown from CBG to CB
- Household and population projection allocation from CBG to CB (with unit-type conversion)
- Full feature engineering matrix
- XGBoost forecasting model
- FastAPI + PostGIS backend with Redis caching
- React + Mapbox frontend with analytics dashboard

### Key Data Relationships

```
Census Hierarchy (FIPS codes):
State (2) → County (5) → Tract (11) → Block Group/CBG (12) → Block/CB (15)

Join Logic:  CB_FIPS[:12] == CBG_FIPS  (LEFT 12 characters = parent block group)
```

### Core Data Sources

| Dataset | Source | Granularity | Key Fields | Status |
|---------|--------|-------------|------------|--------|
| BDC Fixed Broadband | FCC BDC | Census Block (15-digit) | provider_id, technology_code (50=fiber), block_geoid, speeds | **Done** (5 states) |
| Median Household Income | ACS 5-Year B19013 | CBG (12-digit) | MHI estimate, margin of error | **Downloaded** |
| Housing Units | Decennial / ACS B25001 | Census Block | Total HU, Occupied HU (households) | **Downloaded** |
| Population | Decennial / ACS B01003 | Census Block | Total population | **Downloaded** |
| Household Projections | Third-party (ESRI or similar) | CBG | Projected Housing Unit count (future years) | **Available** |
| TIGER/Line Shapefiles | Census Bureau | Census Block | Polygon geometries | **To download** (5 states) |

### Critical Data Mismatch — CB Sums ≠ CBG Totals

The CB-level counts come from the **2020 Decennial Census** (a full enumeration), while the CBG-level estimates come from the **ACS** (a sample-based survey). These two data products were never designed to be arithmetically consistent. In practice, the sum of CB-level housing counts within a CBG does **not** equal the CBG-level ACS estimate, and the same is true for population.

**The solution:** When computing each CB's share within its parent CBG, always use the **rolled-up sum of CB values** as the denominator — not the CBG-reported ACS total. This guarantees that shares within every CBG sum to exactly 1.0.

Additionally, the projection data provides **Housing Unit** counts (total units including vacant), not **Household** counts (occupied units only). Since MHI and the forecasting model operate on households, we must apply an **occupancy rate** conversion when rolling down housing projections.

### FCC BDC Filing Timeline & Over-Reporting

The FCC BDC data is available from **June 2022 onward**, with new filings published every **6 months** (June and December). The available filing periods are:

```
June 2022 → Dec 2022 → June 2023 → Dec 2023 → June 2024 → Dec 2024 → ...
```

**Over-reporting problem:** Providers are known to over-report their fiber coverage in BDC filings — claiming service availability in census blocks where fiber has not actually been deployed. This creates a specific data quality issue: a CB may show `has_fiber = 1` in one filing but `has_fiber = 0` in a subsequent filing. Since fiber infrastructure, once physically installed, does not get removed, any such disappearance is a clear signal of over-reporting, not service withdrawal.

**Forward-persistence correction:** To clean the data, we apply a backward-looking rule from the latest filing: a CB's fiber flag should only be `1` at time `t` if it remains `1` in **all subsequent filings** through the most recent data. If fiber "appears" in an earlier filing but vanishes later, that earlier entry was over-reported and must be corrected to `0`. This is implemented in Phase 3 before computing any features.

**12-month comparison windows:** For training label construction, 6-month windows are too noisy — fiber construction cycles typically run 12–18 months from permitting to lit service, and mid-cycle reporting artifacts create false positives. Instead, we compare filings **12 months apart** (June-to-June, December-to-December) when constructing the `gained_fiber` training labels. All 6-month snapshots are still retained as feature inputs — they provide valuable temporal resolution for features like `neighbor_fiber_pct` — but the labels are computed across year-over-year pairs only.

---

## Phase 1: Shapefile Processing & Area Computation

**Goal:** Download TIGER/Line shapefiles for the 5 states, extract CB polygon geometries, compute land areas, and prepare the spatial foundation for density calculations.

**Deliverable:** Jupyter Notebook `01_shapefile_processing.ipynb`

### Notebook Instructions

1. **Download TIGER/Line shapefiles** for each of the 5 states. The files are named `tl_2020_{STATE_FIPS}_tabblock20.zip` and are available from the Census Bureau TIGER/Line FTP. Download the tabblock20 (2020 census block) shapefile for each state FIPS code.

2. **Load each state's shapefile** into a GeoDataFrame using `geopandas.read_file()`. Each shapefile contains polygon geometries for every census block in that state, along with the GEOID20 column (the 15-digit CB FIPS code).

3. **Concatenate all 5 states** into a single GeoDataFrame. This becomes the master geometry table.

4. **Verify the CRS.** TIGER shapefiles come in EPSG:4326 (WGS84, lat/lon). Confirm this with `gdf.crs`. This CRS is what we need for web-map compatibility later.

5. **Reproject to an equal-area CRS for area computation.** Create a new geometry column by reprojecting to EPSG:5070 (Albers Equal Area Conic, standard for US mainland). You cannot compute meaningful areas in EPSG:4326 because those are degrees, not meters.

6. **Compute the area of each CB in square kilometers.** Using the reprojected geometry, compute the area. The result from `.area` will be in square meters (since EPSG:5070 uses meters). Divide by 1,000,000 to convert to square kilometers. Store this as a new column `area_sq_km`.

7. **Handle edge cases:**
   - Some census blocks have zero area (water-only blocks or point geometries). Flag these but don't drop them — they may appear in the FCC data.
   - Some blocks have extremely small areas (< 0.001 sq km). These will produce very large density values. Cap densities later in the feature engineering phase, not here.

8. **Build the CB adjacency table.** For each census block, identify all neighboring blocks (those sharing a boundary). Use the spatial predicate `touches` (or `intersects` with a tiny buffer). Store the result as a DataFrame with columns `cb_fips` and `neighbor_fips`. This will be used later for the spatial contagion features (neighbor fiber percentage). **Note:** This is computationally expensive. Process state by state and concatenate. Consider using a spatial index (the default R-tree in geopandas) and working county by county within each state to keep memory manageable.

9. **Export the results:**
   - Save the geometry GeoDataFrame (with `area_sq_km`) as a GeoParquet file or shapefile for later use.
   - Save the adjacency table as a Parquet file.
   - Save a lightweight CSV with just `cb_fips` and `area_sq_km` (no geometry) for easy joins in subsequent notebooks.

### Key Libraries

- `geopandas` for shapefile I/O and spatial operations
- `pyproj` (comes with geopandas) for CRS transformations
- `shapely` for geometry operations
- `pyarrow` or `fastparquet` for Parquet I/O

---

## Phase 2: MHI Rolldown & Demographics Assembly

**Goal:** Assign CBG-level median household income to each CB, compute household shares using rolled-up denominators, allocate projection counts with the occupancy-rate conversion, and build the complete CB-level demographics table.

**Deliverable:** Jupyter Notebook `02_demographics_assembly.ipynb`

### The MHI Disaggregation Problem (Key Context for the Agent)

Median household income (MHI) is reported by the ACS at the **Census Block Group (CBG)** level — 12-digit FIPS codes. Our analysis unit is the **Census Block (CB)** — 15-digit FIPS codes, which are more granular. A single CBG contains multiple CBs. We need to assign income data to each CB.

**Critical rule: MHI is a median, not a mean.** You cannot split or weight-average a median across sub-groups. The correct approach is **uniform assignment** — every CB within a CBG inherits the same MHI value from its parent CBG. This is the standard dasymetric assumption and is mathematically defensible because the Census Bureau designs CBGs to be internally homogeneous.

### The CB ≠ CBG Count Mismatch (Key Context for the Agent)

The CB-level counts (housing, population) come from the 2020 Decennial Census, while the CBG-level estimates come from the ACS. These are different data products with different methodologies, so the sum of CB-level values within a CBG will **not** match the CBG-reported ACS total.

**Rule: Always compute the denominator by rolling up the CB values yourself.** When calculating each CB's share of its parent CBG, sum the CB-level counts within each CBG to create the denominator. Do **not** use the CBG-level ACS estimate as the denominator. This ensures shares within every CBG sum to exactly 1.0.

### Housing Unit vs. Household Distinction (Key Context for the Agent)

The projection data provides **Housing Unit** counts — this includes all housing units, both occupied and vacant. The model and MHI work with **Households** — which are only occupied housing units. Housing Unit counts are always greater than or equal to Household counts.

To convert projected Housing Units into projected Households, multiply by the **occupancy rate**: the ratio of households to housing units at the CBG level from the 2020 census data.

### Notebook Instructions

1. **Load the existing CB-level demographics data** (housing units, population) that was downloaded in the previous project. This should have columns like `cb_fips` (15-digit), `total_housing_units`, `occupied_housing_units` (households), and `total_population`.

2. **Load the ACS MHI data** at the CBG level. This should have `cbg_fips` (12-digit) and `mhi` (median household income estimate). Also load the margin of error (`mhi_moe`) if available — it's useful for flagging low-confidence estimates.

3. **Derive the CBG key on each CB record.** Create a new column `cbg_fips` on the CB table by taking the first 12 characters of `cb_fips`. This is the join key: `cb_df["cbg_fips"] = cb_df["cb_fips"].str[:12]`.

4. **Join MHI to each CB.** Left-join the CB table to the ACS MHI table on `cbg_fips`. After this join, every CB has the MHI of its parent block group. This is the uniform assignment — no splitting, no weighting. Just a direct join.

5. **Compute rolled-up CBG totals from the CB data.** Group the CB-level data by `cbg_fips` and sum both `occupied_housing_units` and `total_population`. These rolled-up sums become the denominators for share computation. **Do not use the CBG-level ACS estimates as denominators** — they won't match the CB sums and shares won't add to 1.0. Store these as `cbg_rolled_hh` and `cbg_rolled_pop`.

6. **Compute the household share for each CB within its CBG.** Divide each CB's household count by the rolled-up CBG total: `hh_share = occupied_housing_cb / cbg_rolled_hh`. Handle division by zero (CBGs where all CBs report zero households) by setting the share to 0. Verify that shares within each CBG sum to exactly 1.0.

7. **Compute the population share for each CB within its CBG.** Same logic: `pop_share = total_population_cb / cbg_rolled_pop`. This will be used for population projection rolldown.

8. **Compute the CBG-level occupancy rate.** For each CBG, compute the occupancy rate from the 2020 Decennial Census data: `occupancy_rate = CBG_2020_HH_Count / CBG_2020_HH_Unit_Count`. This is the ratio of occupied housing units (households) to total housing units. This rate will be used to convert projected Housing Units into projected Households. If you have the CBG-level 2020 counts directly, use those. If not, use the rolled-up CB-level sums: `occupancy_rate = cbg_rolled_hh / cbg_rolled_total_hu`.

9. **Allocate projected housing to each CB.** The projection data provides Housing Unit estimates at the CBG level. To get projected **households** at the CB level, apply the three-step formula:

   ```
   Projected_HH_cb = CBG_HH_Unit_Projection × hh_share × occupancy_rate
   ```

   Expanding this:
   ```
   Projected_HH_cb = CBG_HH_Unit_2024_Estimate
                     × (CB_HH_Count / CBG_Rolled_HH_Count)
                     × (CBG_2020_HH_Count / CBG_2020_HH_Unit_Count)
   ```

   - **First term:** The CBG-level Housing Unit projection (from the projection dataset).
   - **Second term:** The CB's share of households within the CBG (using the rolled-up denominator).
   - **Third term:** The occupancy rate, converting Housing Units to Households.

   Also compute the household growth rate: `hh_growth_rate = (projected_hh_cb - current_hh_cb) / current_hh_cb`. Handle division by zero for CBs with zero current households.

10. **Allocate projected population to each CB.** The projection data may also include population estimates at the CBG level. Use the population share with the rolled-up denominator:

    ```
    Projected_Pop_cb = CBG_Pop_Estimate × (CB_Pop_Count / CBG_Rolled_Pop_Count)
    ```

    This is straightforward because population counts are in the same unit at both levels — no unit conversion needed, only the denominator correction.

11. **Join the area data** from Phase 1 (the `cb_fips` + `area_sq_km` CSV). Merge on `cb_fips`.

12. **Compute density features:**
    - `housing_density = occupied_housing_units / area_sq_km`
    - `pop_density = total_population / area_sq_km`
    - Handle zero-area blocks: set density to NaN or 0 rather than infinity.

13. **Quality checks:**
    - Verify that every CB has been matched to a CBG (no null `cbg_fips`).
    - Verify that household shares within each CBG sum to ~1.0 (should be exactly 1.0 with rolled-up denominators).
    - Verify that population shares within each CBG sum to ~1.0.
    - Check the occupancy rate distribution: typical values are 0.85–0.95. Flag any CBGs with extreme values (< 0.5 or > 1.0, which would indicate data issues).
    - Check for unreasonable MHI values (negative, extremely high).
    - Print summary statistics: count of CBs, count of CBGs, MHI distribution, density distribution, occupancy rate distribution.

14. **Export** the complete CB-level demographics table as a Parquet file: `cb_demographics.parquet`. This table should have columns: `cb_fips`, `cbg_fips`, `total_housing_units`, `occupied_housing_units`, `total_population`, `mhi`, `mhi_moe`, `hh_share_in_cbg`, `pop_share_in_cbg`, `occupancy_rate`, `projected_hh`, `hh_growth_rate`, `projected_pop`, `area_sq_km`, `housing_density`, `pop_density`.

---

## Phase 3: Provider & Fiber Feature Engineering

**Goal:** Clean the FCC BDC fiber data for over-reporting artifacts, then extract fiber presence, provider counts, major provider flags, and spatial neighbor features for each CB and filing period.

**Deliverable:** Jupyter Notebook `03_provider_features.ipynb`

### Notebook Instructions

1. **Load the processed FCC BDC data** from the previous project. This should contain columns like `filing_period`, `provider_id`, `provider_name`, `technology_code`, `block_geoid` (15-digit CB FIPS), `max_download`, and `max_upload`. If multiple filing periods are available, ensure they are all loaded with a `filing_period` column distinguishing them. The available periods should span from June 2022 onward at 6-month intervals.

2. **Compute the raw `has_fiber` flag per CB per period.** Before any correction, compute the raw fiber presence: for each `(filing_period, block_geoid)`, set `has_fiber_raw = 1` if any record has `technology_code == 50`, else `0`.

3. **Apply the forward-persistence correction for over-reported fiber.** Providers are known to over-report fiber coverage. Since physical fiber infrastructure, once installed, does not get removed, a CB that shows fiber in an earlier filing but not in a later filing was almost certainly over-reported. Correct the data as follows:

   - For each CB, construct the full timeline of `has_fiber_raw` values across all filing periods, sorted chronologically (e.g., `[0, 1, 0, 1, 1, 1]` for June '22 through Dec '24).
   - **Walk backward from the most recent filing.** Find the earliest period from which `has_fiber_raw = 1` persists **unbroken** through to the latest filing. This is the "true arrival" point.
   - Set `has_fiber = 1` for that period and all subsequent periods. Set `has_fiber = 0` for all earlier periods, regardless of what the raw data says.
   - **Example:** If a CB's raw timeline is `[0, 1, 0, 1, 1, 1]`:
     - The raw `1` at period 2 (Dec '22) does NOT persist — it drops to `0` at period 3 (June '23). This was over-reported.
     - The `1` at period 4 (Dec '23) persists through periods 5 and 6. The true arrival is period 4.
     - Corrected timeline: `[0, 0, 0, 1, 1, 1]`.
   - **Edge case:** If a CB shows fiber in the very latest filing only (e.g., `[0, 0, 0, 0, 0, 1]`), keep it as-is — there is no subsequent filing to confirm persistence. Accept this as provisionally correct but note that it will be validated when the next filing arrives.
   - Print a summary of corrections: how many CB-period entries were flipped from `1` to `0`, what percentage of all fiber entries were corrected, and the distribution across filing periods.

4. **Compute fiber and provider features per CB per filing period** using the **corrected** `has_fiber` flag. Group by `filing_period` and `block_geoid` and compute:
   - `has_fiber`: the corrected binary flag (from step 3 above).
   - `fiber_provider_count`: count of distinct `provider_id` where `technology_code == 50`. **Note:** After the persistence correction, if `has_fiber` was flipped to `0`, set `fiber_provider_count` to `0` as well for consistency, even if raw provider records exist for that period.
   - `total_provider_count`: count of distinct `provider_id` across all technologies (this is unaffected by the fiber correction — providers may still offer non-fiber services).
   - `max_fiber_down`: maximum download speed among fiber records (set to `NaN` or `0` if `has_fiber` was corrected to `0`).
   - `max_fiber_up`: maximum upload speed among fiber records (same treatment).

5. **Define a major providers list.** Create a reference list of major ISPs (AT&T, Verizon, Lumen/CenturyLink, Comcast/Xfinity, Charter/Spectrum, Frontier, Cox, Google Fiber, Windstream, T-Mobile, etc.) with their FCC provider IDs. Verify these IDs against the actual data — provider IDs can vary between filings.

6. **Generate one-hot flags for major providers.** For each CB and filing period, create binary columns:
   - `{provider}_present`: 1 if that provider serves this CB with any technology, else 0.
   - `{provider}_fiber`: 1 if that provider serves this CB specifically with fiber (tech code 50), else 0. **Apply the same persistence correction logic per provider**: if the provider's fiber flag does not persist through to the latest filing, set it to `0` for the earlier periods.
   - This produces columns like `att_present`, `att_fiber`, `verizon_present`, `verizon_fiber`, etc.

7. **Compute spatial neighbor features.** Load the adjacency table from Phase 1. For each CB and filing period, look up all its neighbors and compute:
   - `neighbor_fiber_pct`: the fraction of neighboring CBs that have fiber (`has_fiber == 1`, using the **corrected** flag).
   - `neighbor_count`: the number of adjacent CBs (useful as a control variable).
   - This is the "spatial contagion" signal — fiber tends to expand from existing footprints.

   **Implementation note:** This is a many-to-many join (each CB has multiple neighbors, each neighbor has a fiber status). The efficient approach is to merge the adjacency table with the fiber presence table, then group by `(filing_period, cb_fips)` and take the mean of neighbors' `has_fiber`.

8. **Assemble the provider feature matrix.** Merge the fiber/provider features, major provider flags, and spatial features into a single DataFrame keyed on `(filing_period, cb_fips)`.

9. **Export** as `cb_provider_features.parquet`.

---

## Phase 4: Full Feature Matrix & Training Labels

**Goal:** Merge demographics and provider features into one unified matrix, construct the binary training labels using **12-month comparison windows** from the corrected fiber data, and prepare the data for model training.

**Deliverable:** Jupyter Notebook `04_feature_matrix_and_labels.ipynb`

### Notebook Instructions

1. **Load the demographics table** (`cb_demographics.parquet` from Phase 2) and the **provider features table** (`cb_provider_features.parquet` from Phase 3, which contains the forward-persistence-corrected fiber flags).

2. **Merge into the full feature matrix.** Join on `cb_fips` (demographics is period-independent; provider features are per-period). The result should have one row per CB per filing period, with all demographic and provider columns.

3. **Construct training labels using 12-month comparison windows.** The prediction target is binary: **did this CB gain fiber over a 12-month period?** Using 6-month windows is too noisy — fiber construction cycles run 12–18 months, and half-year snapshots capture mid-cycle reporting artifacts rather than genuine completions. Instead, compare filings that are **12 months apart**:

   - Pair June filings with June filings: June '22 → June '23, June '23 → June '24, etc.
   - Pair December filings with December filings: Dec '22 → Dec '23, Dec '23 → Dec '24, etc.
   - **Do not** pair June with December (6-month gaps) for label construction.

   For each 12-month pair (time `t` and time `t+12mo`):
   - Filter to CBs that did **not** have fiber at time t (`has_fiber == 0`, using the corrected flag).
   - Check whether those same CBs have fiber at time t+12mo.
   - Label `gained_fiber = 1` if they went from no-fiber to fiber over the 12-month window, `0` if they remained without fiber.
   - Exclude CBs that already had fiber at time t — they are not prediction targets.

   **Important:** The features for each training row come from time t. The label comes from comparing t to t+12mo. All 6-month filing snapshots are still retained in the feature matrix — they provide valuable temporal resolution for computing features like `neighbor_fiber_pct`. Only the **label pairs** use 12-month gaps.

   **Example comparison pairs** (assuming data from June '22 through Dec '24):
   ```
   Features from June '22  →  Label: gained fiber by June '23?
   Features from Dec '22   →  Label: gained fiber by Dec '23?
   Features from June '23  →  Label: gained fiber by June '24?
   Features from Dec '23   →  Label: gained fiber by Dec '24?
   ```

4. **Concatenate all 12-month-pair training sets** into a single DataFrame. Add columns for `train_period` (time t) and `label_period` (time t+12mo) so the model training script can implement temporal cross-validation.

5. **Print class distribution.** Report the number and percentage of positive examples (`gained_fiber == 1`) vs. negatives. 12-month windows should produce a higher and more meaningful positive rate than 6-month windows. Document the imbalance ratio — it determines the `scale_pos_weight` parameter for XGBoost.

6. **Handle missing values.** Identify columns with NaN values and decide on a strategy:
   - For density features: NaN where area is zero — fill with 0 or leave as NaN (XGBoost handles NaN natively).
   - For MHI: NaN where ACS data is missing — note the count and decide whether to drop or impute.
   - For neighbor features: NaN where a CB has no neighbors in the adjacency table — fill with 0.

7. **Define the feature column list.** Explicitly list which columns are features (inputs) and which are metadata/identifiers/targets. Store this list — it will be used identically in training and scoring.

8. **Export:**
   - `feature_matrix_full.parquet`: the complete merged matrix (all periods, all CBs).
   - `training_data.parquet`: the labeled training set (only no-fiber CBs with a gain/no-gain label, using 12-month pairs).
   - `feature_columns.json`: a JSON list of the feature column names.

---

## Phase 5: Model Training & Batch Scoring

**Goal:** Train an XGBoost binary classifier to predict fiber deployment, evaluate with temporal cross-validation, interpret with SHAP, and batch-score all currently unserved CBs.

**Deliverable:** Jupyter Notebook `05_model_training.ipynb`

### Notebook Instructions

1. **Load the training data** (`training_data.parquet`) and the feature column list (`feature_columns.json`).

2. **Implement temporal cross-validation.** Sort the unique `train_period` values chronologically. For each fold, train on all period-pairs up to period i, and validate on the period-pair at period i+1. This prevents data leakage — you never train on future data.

3. **Train XGBoost** with the following configuration:
   - `objective`: `binary:logistic`
   - `eval_metric`: `aucpr` (area under precision-recall curve — better than AUC-ROC for imbalanced data)
   - `scale_pos_weight`: set to the negative/positive ratio from the training set (e.g., if 2% positive, set to ~49)
   - `n_estimators`: 500 with `early_stopping_rounds`: 50
   - `max_depth`: 6, `learning_rate`: 0.05, `subsample`: 0.8, `colsample_bytree`: 0.8
   - Use `tree_method="hist"` for speed on large datasets.

4. **Evaluate each fold.** Compute and log AUC-ROC, AUC-PR (the primary metric for imbalanced problems), and F1 score at the optimal threshold (sweep thresholds from 0.1 to 0.9).

5. **Train the final model** on all available training data using the same hyperparameters. Save the model using `joblib.dump()`.

6. **SHAP analysis.** Use `shap.TreeExplainer` on the final model to compute SHAP values for a sample of the training data. Generate a summary beeswarm plot showing global feature importance, the ranked feature importance list, and save the SHAP explainer for use in batch scoring.

7. **Batch-score all currently unserved CBs.** Load the feature matrix for the most recent filing period, filter to CBs where `has_fiber == 0`, run `model.predict_proba()` to get fiber probability for each CB, and compute per-CB SHAP values to identify the top 3 contributing features for each prediction.

8. **Assign forecast labels.** Based on the probability, assign a categorical label: **High** (> 0.6), **Medium** (0.3–0.6), **Low** (< 0.3). Adjust thresholds based on validation performance.

9. **Export:**
   - `fiber_forecast_model.joblib`: the trained model.
   - `cb_predictions.parquet`: columns `cb_fips`, `fiber_probability`, `fiber_forecast_label`, `top_contributing_features`.
   - `model_evaluation_results.json`: AUC-ROC, AUC-PR, F1, and threshold per fold.
   - SHAP summary plot saved as an image.

---

## Phase 6: Backend API & Serving Layer

**Goal:** Build a FastAPI backend that serves CB-level data, spatial queries, provider breakdowns, and forecast results. Use PostGIS for spatial queries and Redis for caching.

**Deliverable:** Backend application codebase in `backend/`

### Project Structure

```
backend/
├── app/
│   ├── __init__.py
│   ├── main.py                # FastAPI app entry point
│   ├── config.py              # Settings (DB URL, Redis URL, etc.)
│   ├── database.py            # Async database connection (asyncpg + SQLAlchemy)
│   ├── routers/
│   │   ├── area.py            # /api/v1/area — CB-level data within bounding box
│   │   ├── summary.py         # /api/v1/area/summary — aggregated stats
│   │   ├── providers.py       # /api/v1/providers — provider breakdown
│   │   ├── forecast.py        # /api/v1/forecast — prediction distribution
│   │   └── tiles.py           # /api/v1/tiles/{z}/{x}/{y}.mvt — vector tiles
│   ├── services/
│   │   ├── spatial.py         # PostGIS query builders
│   │   ├── aggregation.py     # Summary stat computations
│   │   └── cache.py           # Redis get/set/invalidate helpers
│   └── utils/
│       └── geo.py             # GeoJSON helpers, bbox parsing
├── requirements.txt
├── Dockerfile
└── docker-compose.yml
```

### What the Agent Needs to Build

1. **Database setup.** Write a setup script or migration that creates a PostGIS-enabled PostgreSQL database and loads the Parquet outputs from Phases 1–5 into proper tables. The geometry GeoParquet from Phase 1 goes into a `geo.census_blocks` table with a GIST spatial index on the geometry column. The demographics, provider features, and predictions all go into tables indexed on `cb_fips`. A materialized view should join everything into a single denormalized serving table so that spatial queries hit one table rather than multiple joins.

2. **Spatial query endpoints.** The core endpoint accepts a bounding box (west, south, east, north coordinates) and returns all census blocks whose geometry intersects that box. The query should use PostGIS's `ST_MakeEnvelope` and the `&&` operator for index-accelerated bounding box filtering. For each CB, return its properties (demographics, fiber status, provider counts, forecast probability/label) and its geometry as GeoJSON. The response format should be a GeoJSON FeatureCollection.

3. **Summary endpoint.** For a given bounding box, compute aggregated statistics across all CBs in the area: total census blocks, fiber coverage percentage (by CB count and by household count), household-weighted average MHI, total population, average housing density, and the forecast distribution (count of High/Medium/Low predictions among unserved blocks).

4. **Provider breakdown endpoint.** For a given bounding box, return a table of all providers operating in the area. For each provider, show: the count of CBs they serve (any technology), the count of CBs they serve with fiber, their total coverage percentage, and their fiber-specific coverage percentage. Sort by total coverage descending.

5. **Vector tile endpoint.** Serve Mapbox Vector Tiles (MVT) directly from PostGIS using `ST_AsMVT` and `ST_AsMVTGeom`. The endpoint pattern is `/{z}/{x}/{y}.mvt`. Each tile should include CB polygons with key properties (has_fiber, mhi, fiber_probability, fiber_forecast_label) embedded in the tile so the frontend can style them without additional API calls. Alternatively, set up pg_tileserv as a standalone tile server that reads directly from PostGIS.

6. **Redis caching layer.** Implement a cache-aside pattern: before running any PostGIS query, check Redis for a cached result keyed on the query parameters (a hash of the bounding box). If found, return the cached result. If not, run the query, return the result, and store it in Redis with a TTL of 1–6 hours. On data refresh (new FCC filing loaded), flush the entire cache. Use `redis.asyncio` for non-blocking cache operations.

7. **Docker Compose.** Produce a `docker-compose.yml` that runs PostGIS, Redis, the FastAPI app, and optionally pg_tileserv, all wired together.

### API Endpoints Summary

| Endpoint | Method | Parameters | Returns |
|----------|--------|------------|---------|
| `/api/v1/area` | GET | `west`, `south`, `east`, `north` | GeoJSON FeatureCollection of CBs with all properties |
| `/api/v1/area/summary` | GET | `west`, `south`, `east`, `north` | Aggregated stats JSON (coverage %, demographics, forecast) |
| `/api/v1/area/polygon` | POST | GeoJSON polygon in body | Same as `/area` but for arbitrary polygon |
| `/api/v1/providers` | GET | `west`, `south`, `east`, `north` | Provider breakdown table |
| `/api/v1/forecast` | GET | `west`, `south`, `east`, `north` | Forecast distribution and per-CB probabilities |
| `/api/v1/tiles/{z}/{x}/{y}.mvt` | GET | Tile coordinates | Mapbox Vector Tile binary |

---

## Phase 7: Frontend — Interactive Map & Analytics Dashboard

**Goal:** Build a React application with Mapbox GL JS for map rendering, multiple choropleth layers, an area search bar, and an analytics side panel displaying all coverage, demographic, and forecast data.

**Deliverable:** Frontend application codebase in `frontend/`

### Project Structure

```
frontend/
├── src/
│   ├── App.jsx
│   ├── index.jsx
│   ├── components/
│   │   ├── Map/
│   │   │   ├── MapContainer.jsx       # Mapbox GL map with vector tile source
│   │   │   ├── LayerControls.jsx      # Toggle between choropleth layers
│   │   │   └── MapLegend.jsx          # Dynamic legend per active layer
│   │   ├── Analytics/
│   │   │   ├── AnalyticsPanel.jsx     # Side panel container
│   │   │   ├── CoverageSummary.jsx    # Fiber % by CB count and HH count
│   │   │   ├── ProviderTable.jsx      # Provider breakdown (sortable)
│   │   │   ├── DemographicSummary.jsx # MHI, population, density cards
│   │   │   ├── ForecastSummary.jsx    # High/Med/Low donut chart
│   │   │   └── TrendChart.jsx         # Historical fiber % line chart
│   │   ├── Search/
│   │   │   └── AreaSearch.jsx         # Geocoding search bar (Mapbox Geocoding API)
│   │   └── common/
│   │       ├── LoadingSpinner.jsx
│   │       └── MetricCard.jsx          # Reusable stat card (label, value, subtitle)
│   ├── hooks/
│   │   ├── useMapData.js              # Fetch CB data on viewport change
│   │   ├── useAreaSummary.js          # Fetch aggregated stats for current viewport
│   │   └── useProviders.js            # Fetch provider breakdown
│   ├── services/
│   │   └── api.js                     # Axios/fetch wrappers for all backend endpoints
│   └── utils/
│       ├── colorScales.js             # Color ramps for each choropleth layer
│       └── formatters.js              # Currency, number, percentage formatters
├── package.json
└── .env                               # MAPBOX_TOKEN, API_BASE_URL
```

### What the Agent Needs to Build

1. **Map container with vector tile source.** Initialize a Mapbox GL JS map. Add a vector tile source pointing to the tile server (either pg_tileserv or the FastAPI tiles endpoint). The source should define minzoom 8 and maxzoom 16, with CB polygons rendering at zoom >= 12.

2. **Multiple choropleth layers.** The user should be able to toggle between these map visualizations using a layer control panel:
   - **Fiber Presence**: Green for CBs with fiber, gray for CBs without. Simple categorical coloring.
   - **Forecast Probability**: Continuous gradient from red (low probability) through yellow (medium) to green (high).
   - **Provider Heatmap**: Color-coded by the number of providers or by a specific selected provider.
   - **MHI Gradient**: Cool-to-warm ramp representing income levels across CBs.
   - **Housing/Population Density**: Density heat map at the CB level.

   Each layer should have a corresponding dynamic legend component that updates when the layer is toggled.

3. **Area search bar.** Implement a geocoding search bar (using Mapbox Geocoding API or similar) that lets the user type a city name, zip code, county name, or street address. On selection, fly the map to that location and trigger a data refresh for the new viewport.

4. **Viewport-driven data fetching.** When the map viewport changes (pan, zoom, search), extract the current bounding box, call the `/api/v1/area/summary` and `/api/v1/providers` endpoints in parallel, and populate the analytics panel. Use `@tanstack/react-query` for data fetching with automatic caching and deduplication. Debounce viewport change events to avoid excessive API calls during smooth panning.

5. **Analytics side panel.** This is the main data display area alongside the map. It should contain:
   - **Coverage Summary**: Two large metric cards showing fiber coverage percentage by census blocks and by households. Include the absolute counts (e.g., "1,247 of 3,891 blocks").
   - **Provider Breakdown Table**: A sortable table with columns for provider name, CBs served (all tech), CBs served (fiber), total coverage %, and fiber coverage %. Each row should optionally be clickable to highlight that provider's footprint on the map.
   - **Demographic Summary**: Metric cards for household-weighted average MHI (formatted as currency), total population, total households, and average housing density.
   - **Forecast Summary**: A donut or bar chart showing the count of unserved CBs predicted as High, Medium, and Low likelihood of gaining fiber. Show the percentage breakdown.
   - **Historical Trend Chart**: A line chart (using Recharts) showing the fiber coverage percentage across available filing periods for the current viewport area. This shows whether fiber has been expanding in this area over time.

6. **CB click/hover interaction.** When a user clicks on a census block polygon on the map, show a popup or detail panel with that specific CB's data: FIPS code, MHI, housing density, population density, households, fiber status, provider list, and if unserved, the forecast probability and top contributing features.

### Key Frontend Libraries

| Library | Purpose |
|---------|---------|
| `react` | UI framework |
| `mapbox-gl` | Map rendering with vector tiles |
| `recharts` | Charts (donut, line, bar) for the analytics panel |
| `@tanstack/react-query` | Data fetching, caching, deduplication |
| `axios` | HTTP client for API calls |
| `tailwindcss` | Utility-first CSS for layout and styling |

---

## Phase 8: Optimization, Testing & Deployment

**Goal:** Performance tuning, load testing, CI/CD setup, monitoring, and documentation.

**Deliverable:** Configuration files, test scripts, and deployment documentation.

### What the Agent Needs to Do

1. **Create a PostGIS materialized view** that pre-joins the geometry, demographics, provider features, and predictions into a single denormalized table. This is the table that all spatial API queries should hit. Add a GIST spatial index on the geometry and a B-tree index on `cb_fips` and `has_fiber`. Write a refresh command that can be triggered after data pipeline runs.

2. **Configure Redis cache strategy.** Set up cache TTLs: vector tiles at popular zoom levels get a 24-hour TTL, area summaries for major metros get 6 hours, provider breakdowns get 6 hours, and full GeoJSON responses for small bboxes get 1 hour. Configure `maxmemory-policy allkeys-lru` so Redis auto-evicts least-recently-used keys when memory is full.

3. **Implement geometry simplification** for large area queries. When the bounding box covers a very large area (e.g., state-level with > 50,000 CBs), apply PostGIS `ST_Simplify` to reduce polygon complexity before sending to the frontend. The simplification tolerance should increase as the area gets larger.

4. **Write a data refresh pipeline script** (or Airflow DAG outline) that orchestrates: ingest new FCC filing → rebuild provider features → retrain model → batch score → refresh materialized view → flush Redis cache.

5. **Add a data freshness indicator** to the API and frontend. The API should return the latest filing period date in every summary response. The frontend should display this as "Data as of: [date]" so users know how current the information is.

6. **Performance targets:**
   - API response time P95 < 500ms for metro-level bounding box queries
   - Vector tile load time < 200ms at zoom levels 12–14
   - Frontend initial map render < 2 seconds
   - Redis cache hit rate > 80% for repeat queries

7. **Monitoring.** Set up basic logging and error tracking. Log API response times, cache hit/miss ratios, and query row counts. Flag any queries that exceed 2 seconds.

---

## Quick Reference: Key Formulas

| Operation | Formula | Notes |
|-----------|---------|-------|
| MHI rolldown | `MHI_cb = MHI_cbg` | Uniform assignment — median is non-additive |
| CBG-to-CB join key | `cb_fips[:12] == cbg_fips` | String prefix match (first 12 chars) |
| Rolled-up CBG total | `cbg_rolled_hh = SUM(occupied_HH) across CBs in CBG` | Use this as denominator, not the ACS CBG estimate |
| Household share | `hh_share = CB_HH / cbg_rolled_hh` | Shares sum to exactly 1.0 per CBG |
| Population share | `pop_share = CB_Pop / cbg_rolled_pop` | Same logic, rolled-up denominator |
| Occupancy rate | `occ_rate = CBG_2020_HH / CBG_2020_HU` | Converts Housing Units → Households |
| HH projection rolldown | `proj_hh_cb = CBG_HU_Proj × hh_share × occ_rate` | Three-step: project → allocate → convert |
| Pop projection rolldown | `proj_pop_cb = CBG_Pop_Proj × pop_share` | Two-step: project → allocate |
| Housing density | `occupied_HH / area_sq_km` | Area from TIGER shapefiles (projected CRS) |
| Population density | `total_pop / area_sq_km` | Same area source |
| Fiber persistence correction | `has_fiber = 1 only if fiber persists through latest filing` | Corrects over-reporting; walk backward from latest |
| Neighbor fiber % | `mean(has_fiber_corrected) across adjacent CBs` | Uses corrected fiber flags; adjacency from ST_Touches |
| Prediction target | `y = 1 if CB gained fiber over 12-month window` | 12-mo pairs (Jun→Jun, Dec→Dec); corrected fiber flags |

## Notebook Dependency Chain

```
01_shapefile_processing.ipynb
    ↓ area_sq_km.csv, adjacency.parquet, geometry.geoparquet
02_demographics_assembly.ipynb
    ↓ cb_demographics.parquet (includes MHI, shares, projections, densities)
03_provider_features.ipynb  (also uses adjacency.parquet from 01)
    ↓ cb_provider_features.parquet (forward-persistence-corrected fiber flags)
04_feature_matrix_and_labels.ipynb  (merges 02 + 03 outputs; 12-month label pairs)
    ↓ feature_matrix_full.parquet, training_data.parquet
05_model_training.ipynb
    ↓ fiber_forecast_model.joblib, cb_predictions.parquet
        ↓
    Phase 6: Backend (loads all parquets into PostGIS)
        ↓
    Phase 7: Frontend (consumes backend API)
        ↓
    Phase 8: Optimization & Deployment
```