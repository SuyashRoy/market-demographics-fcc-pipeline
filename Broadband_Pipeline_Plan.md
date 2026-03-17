# Broadband Availability Lookup Pipeline — Comprehensive Plan

## Project Goal

Build a system where a user enters an address, the app geocodes it, identifies the census block it falls in, and returns all broadband providers, technologies, and speeds available in that area — powered by downloaded FCC Broadband Data Collection (BDC) data for 5 states.

---

## Architecture Overview

```
User enters address
        │
        ▼
┌──────────────────┐
│  Your Frontend    │  (existing UI)
│  (React / HTML)   │
└────────┬─────────┘
         │ API call with address string
         ▼
┌──────────────────────────────────────────────┐
│              Your Backend (Python/Flask or    │
│              Node/Express)                    │
│                                              │
│  1. Geocode address → lat/lon                │
│     (Google Maps Geocoding API)              │
│                                              │
│  2. Reverse-geocode lat/lon → Census Block   │
│     FIPS (FCC Census Block API or            │
│     US Census Geocoder)                      │
│                                              │
│  3. Query PostgreSQL with FIPS code          │
│     → providers, technologies, speeds        │
│                                              │
│  4. Return JSON results to frontend          │
└────────┬─────────────────────────────────────┘
         │
         ▼
┌──────────────────┐
│   PostgreSQL DB   │
│   (FCC BDC data   │
│    indexed by     │
│    census block)  │
└──────────────────┘
```

---

## Phase 1: Data Preparation (One-Time ETL)

This phase transforms the raw FCC location-level CSV files into a clean, census-block-level dataset ready for fast querying.

### Step 1.1 — Download the FCC Data

Go to https://broadbandmap.fcc.gov/data-download and download **fixed broadband availability** CSV files for your 5 target states. Each state will have separate files by technology type (Fiber, Cable, DSL, Fixed Wireless, Satellite). Download all technology types for each state.

You'll get CSV files with columns like:

| Column | Description |
|--------|-------------|
| `frn` | FCC Registration Number (provider ID) |
| `provider_id` | Unique provider identifier |
| `brand_name` | Consumer-facing provider name (e.g., "Xfinity", "AT&T Fiber") |
| `location_id` | FCC Fabric location identifier |
| `technology` | Technology code (e.g., 50 = Cable, 70 = Fiber, etc.) |
| `max_advertised_download_speed` | Max download in Mbps |
| `max_advertised_upload_speed` | Max upload in Mbps |
| `low_latency` | Whether the service is low-latency |
| `business_residential_code` | "B", "R", or "X" (both) |
| `state_usps` | State abbreviation |
| `block_geoid` | **15-digit Census Block FIPS code** ← this is your key field |

The `block_geoid` field is the critical link — it's the Census Block FIPS code that connects this data to a geographic location.

### Step 1.2 — Technology Code Reference

Map the numeric technology codes to human-readable names. The FCC uses these codes:

| Code | Technology |
|------|-----------|
| 10 | Copper Wire (DSL) |
| 40 | Cable (DOCSIS) |
| 50 | Cable (Other) |
| 60 | Fiber to the Premises (FTTP) |
| 70 | Fiber (other, e.g., FTTN) |
| 71 | Licensed Fixed Wireless |
| 72 | Licensed-by-Rule Fixed Wireless |
| 0 | Other |

(Check the FCC's data specification for the latest codes — they may have updated since this writing.)

### Step 1.3 — Roll Up to Census Block Level

Write a Python script to aggregate location-level records to the census block level. The logic:

```
For each unique combination of (block_geoid, provider_id, brand_name, technology):
    → Take the MAX of max_advertised_download_speed
    → Take the MAX of max_advertised_upload_speed
    → Flag whether residential, business, or both are served
```

This dramatically reduces the data volume. Instead of millions of location-level rows, you'll have thousands of census-block-level rows.

**Python pseudocode:**

```python
import pandas as pd
import glob

# Load all CSVs for all states and technology types
all_files = glob.glob("fcc_data/*.csv")
df = pd.concat([pd.read_csv(f) for f in all_files])

# Roll up to census block level
block_level = df.groupby(
    ['block_geoid', 'provider_id', 'brand_name', 'technology']
).agg(
    max_download=('max_advertised_download_speed', 'max'),
    max_upload=('max_advertised_upload_speed', 'max'),
    serves_residential=('business_residential_code', lambda x: any(v in ['R', 'X'] for v in x)),
    serves_business=('business_residential_code', lambda x: any(v in ['B', 'X'] for v in x)),
    low_latency=('low_latency', 'max')
).reset_index()

# Save to CSV for loading into PostgreSQL
block_level.to_csv("block_level_availability.csv", index=False)
```

**Expected data reduction:** For 5 states, you might go from 50–100 million location-level rows down to 2–5 million block-level rows. This is a manageable dataset for PostgreSQL.

### Step 1.4 — Validate the Rollup

Before loading into the database, sanity-check your data:

- Pick 5–10 addresses, look them up on the FCC Broadband Map website manually, and compare the providers/speeds shown there against what your rolled-up data shows for that census block. They should match closely (the FCC map is location-level, so your block-level data may show a superset of providers, but it shouldn't be missing any).
- Check for null or malformed `block_geoid` values — these are unusable rows and should be dropped.
- Verify that your technology code mapping covers all codes present in the data.

---

## Phase 2: Database Setup (PostgreSQL)

### Step 2.1 — Install PostgreSQL

**On your development machine:**

```bash
# macOS (using Homebrew)
brew install postgresql@16
brew services start postgresql@16

# Ubuntu/Debian
sudo apt update
sudo apt install postgresql postgresql-contrib
sudo systemctl start postgresql

# Windows
# Download installer from https://www.postgresql.org/download/windows/
```

**For production**, consider a managed service: AWS RDS, Google Cloud SQL, or Supabase (free tier available, PostgreSQL-based, and has a REST API built in which could simplify your backend).

### Step 2.2 — Create the Database and Tables

Connect to PostgreSQL and set up the schema:

```sql
-- Create the database
CREATE DATABASE broadband_lookup;

-- Connect to it
\c broadband_lookup

-- Main availability table (your rolled-up FCC data)
CREATE TABLE block_availability (
    id              SERIAL PRIMARY KEY,
    block_geoid     VARCHAR(15) NOT NULL,   -- 15-digit Census Block FIPS
    state_fips      VARCHAR(2) NOT NULL,    -- first 2 digits of block_geoid
    county_fips     VARCHAR(5) NOT NULL,    -- first 5 digits of block_geoid
    tract_fips      VARCHAR(11) NOT NULL,   -- first 11 digits of block_geoid
    provider_id     VARCHAR(20) NOT NULL,
    brand_name      VARCHAR(255) NOT NULL,
    technology      INTEGER NOT NULL,
    technology_name VARCHAR(100) NOT NULL,  -- human-readable name
    max_download    NUMERIC(10,2),
    max_upload      NUMERIC(10,2),
    serves_residential BOOLEAN DEFAULT TRUE,
    serves_business    BOOLEAN DEFAULT FALSE,
    low_latency     BOOLEAN DEFAULT FALSE
);

-- Technology lookup table
CREATE TABLE technology_types (
    code    INTEGER PRIMARY KEY,
    name    VARCHAR(100) NOT NULL
);

INSERT INTO technology_types VALUES
    (10, 'Copper Wire (DSL)'),
    (40, 'Cable (DOCSIS)'),
    (50, 'Cable (Other)'),
    (60, 'Fiber to the Premises'),
    (70, 'Fiber (Other)'),
    (71, 'Licensed Fixed Wireless'),
    (72, 'Licensed-by-Rule Fixed Wireless'),
    (0, 'Other');

-- Provider summary table (optional, for quick provider info lookups)
CREATE TABLE providers (
    provider_id VARCHAR(20) PRIMARY KEY,
    brand_name  VARCHAR(255) NOT NULL,
    states_served TEXT[]  -- array of state abbreviations
);
```

### Step 2.3 — Create Indexes

These indexes are what make your queries fast. Without them, PostgreSQL would scan the entire table for every request.

```sql
-- PRIMARY index: this is the one your app will query on every request
CREATE INDEX idx_block_geoid ON block_availability (block_geoid);

-- SECONDARY indexes: useful for filtering and analytics
CREATE INDEX idx_state_fips ON block_availability (state_fips);
CREATE INDEX idx_county_fips ON block_availability (county_fips);
CREATE INDEX idx_tract_fips ON block_availability (tract_fips);
CREATE INDEX idx_provider ON block_availability (brand_name);
CREATE INDEX idx_technology ON block_availability (technology);

-- Composite index for common query patterns
CREATE INDEX idx_block_residential ON block_availability (block_geoid, serves_residential)
    WHERE serves_residential = TRUE;
```

### Step 2.4 — Load the Data

Use PostgreSQL's COPY command for fast bulk loading:

```sql
-- If your CSV has headers matching the column names:
COPY block_availability (
    block_geoid, state_fips, county_fips, tract_fips,
    provider_id, brand_name, technology, technology_name,
    max_download, max_upload, serves_residential, serves_business, low_latency
)
FROM '/path/to/block_level_availability.csv'
WITH (FORMAT csv, HEADER true);
```

Alternatively, from Python:

```python
import psycopg2

conn = psycopg2.connect(dbname="broadband_lookup", user="your_user")
cur = conn.cursor()

with open("block_level_availability.csv", "r") as f:
    next(f)  # skip header
    cur.copy_expert(
        "COPY block_availability (...columns...) FROM STDIN WITH CSV",
        f
    )

conn.commit()
```

### Step 2.5 — Verify the Load

```sql
-- Check row count
SELECT COUNT(*) FROM block_availability;

-- Check state distribution
SELECT state_fips, COUNT(*) FROM block_availability GROUP BY state_fips;

-- Check a specific block
SELECT brand_name, technology_name, max_download, max_upload
FROM block_availability
WHERE block_geoid = '060371978003006'  -- example LA block
ORDER BY max_download DESC;

-- Test query speed (should be < 10ms with the index)
EXPLAIN ANALYZE
SELECT * FROM block_availability WHERE block_geoid = '060371978003006';
```

---

## Phase 3: The Geocoding Pipeline (Address → Census Block)

This is the bridge between the user's address and your database. You need to convert a street address into a 15-digit Census Block FIPS code.

### Step 3.1 — Geocode the Address (Get Lat/Lon)

You already have Google Maps API working, so use the Geocoding API:

```
GET https://maps.googleapis.com/maps/api/geocode/json?
    address=1600+Amphitheatre+Parkway,+Mountain+View,+CA
    &key=YOUR_API_KEY
```

This gives you `lat` and `lng` in the response.

### Step 3.2 — Convert Lat/Lon to Census Block FIPS

**Option A: US Census Bureau Geocoder (Free, Recommended)**

The Census Bureau has a free geocoder that returns the Census Block FIPS code directly from coordinates:

```
GET https://geocoding.geo.census.gov/geocoder/geographies/coordinates?
    x=-122.0842&y=37.4220
    &benchmark=Public_AR_Current
    &vintage=Census2020_Current
    &format=json
```

The response includes:
```json
{
  "result": {
    "geographies": {
      "Census Blocks": [{
        "GEOID": "060855012003005",   ← this is your block_geoid
        "STATE": "06",
        "COUNTY": "085",
        "TRACT": "501200",
        "BLOCK": "3005"
      }]
    }
  }
}
```

**Pros:** Free, official, returns the exact FIPS code you need.
**Cons:** Rate-limited (unclear on exact limits, but generally fine for reasonable usage), can be slow (500ms–2s per request).

**Option B: Census Geocoder for Address Directly (Skip Google for this step)**

The Census Geocoder can also take a raw address string and return the FIPS code directly, skipping the Google Geocoding step:

```
GET https://geocoding.geo.census.gov/geocoder/geographies/address?
    street=1600+Amphitheatre+Parkway
    &city=Mountain+View&state=CA
    &benchmark=Public_AR_Current
    &vintage=Census2020_Current
    &format=json
```

This means you could potentially eliminate the Google Geocoding API call entirely for the census block lookup, saving cost and latency. However, the Census Geocoder's address matching is less robust than Google's — it may fail on addresses that Google handles fine. A good hybrid approach: try the Census Geocoder first; if it fails or doesn't match, fall back to Google Geocoding → Census coordinate lookup.

**Option C: Local FIPS Lookup with Census Block Shapefiles (Fastest, Most Robust)**

For maximum speed and zero external API dependency at query time, download Census Block shapefiles and do the lookup locally using PostGIS (PostgreSQL's spatial extension):

```bash
# Install PostGIS
sudo apt install postgis postgresql-16-postgis-3

# In PostgreSQL
CREATE EXTENSION postgis;
```

Download Census Block shapefiles from https://www.census.gov/cgi-bin/geo/shapefiles/index.php (select "Census Blocks" and your 5 states), then load them:

```bash
shp2pgsql -s 4326 tl_2020_06_tabblock20.shp census_blocks | psql broadband_lookup
```

Then query:

```sql
SELECT geoid20 AS block_geoid
FROM census_blocks
WHERE ST_Contains(
    geom,
    ST_SetSRID(ST_MakePoint(-122.0842, 37.4220), 4326)
);
```

**Pros:** Sub-millisecond lookups, no external API calls, works offline.
**Cons:** Requires PostGIS, shapefile download (~200MB per state), more setup.

### Recommendation

For a **prototype/MVP**: Use Option A or B (Census Bureau Geocoder API). Simple, free, no extra infrastructure.

For **production**: Use Option C (PostGIS with local shapefiles). Eliminates a network dependency, faster, and more reliable at scale.

---

## Phase 4: Backend API

### Step 4.1 — Choose Your Stack

**Python (Flask or FastAPI)** — recommended if you're comfortable with Python. FastAPI is preferred for async support and automatic API documentation.

**Node.js (Express)** — fine if your frontend is already in the JS ecosystem.

### Step 4.2 — Backend Structure (FastAPI Example)

```
backend/
├── main.py                 # FastAPI app entry point
├── config.py               # DB connection strings, API keys
├── routers/
│   └── broadband.py        # /api/broadband/lookup endpoint
├── services/
│   ├── geocoder.py          # Address → lat/lon → FIPS
│   └── availability.py     # FIPS → providers/speeds from DB
├── db/
│   └── connection.py       # PostgreSQL connection pool
└── models/
    └── schemas.py          # Pydantic response models
```

### Step 4.3 — The Core Lookup Endpoint

```python
# routers/broadband.py (simplified)

@router.get("/api/broadband/lookup")
async def lookup_broadband(address: str):

    # Step 1: Geocode the address
    lat, lon = await geocode_address(address)  # Google Maps API
    
    # Step 2: Get Census Block FIPS
    block_geoid = await get_census_block(lat, lon)  # Census Geocoder API
    
    # Step 3: Query database
    providers = await get_availability(block_geoid)
    
    # Step 4: Return structured response
    return {
        "address": address,
        "coordinates": {"lat": lat, "lon": lon},
        "census_block": block_geoid,
        "state": block_geoid[:2],
        "county": block_geoid[:5],
        "providers": providers  # list of provider objects
    }
```

### Step 4.4 — Database Query Function

```python
# services/availability.py

async def get_availability(block_geoid: str):
    query = """
        SELECT
            brand_name,
            technology_name,
            max_download,
            max_upload,
            serves_residential,
            serves_business,
            low_latency
        FROM block_availability
        WHERE block_geoid = $1
          AND serves_residential = TRUE
        ORDER BY max_download DESC
    """
    rows = await db.fetch_all(query, [block_geoid])
    
    # Group by provider for cleaner output
    providers = {}
    for row in rows:
        name = row['brand_name']
        if name not in providers:
            providers[name] = {
                'name': name,
                'services': []
            }
        providers[name]['services'].append({
            'technology': row['technology_name'],
            'max_download_mbps': float(row['max_download']),
            'max_upload_mbps': float(row['max_upload']),
            'low_latency': row['low_latency']
        })
    
    return list(providers.values())
```

### Step 4.5 — Example API Response

```json
{
  "address": "1600 Amphitheatre Parkway, Mountain View, CA",
  "coordinates": {"lat": 37.4220, "lon": -122.0842},
  "census_block": "060855012003005",
  "state": "06",
  "county": "06085",
  "providers": [
    {
      "name": "AT&T California",
      "services": [
        {
          "technology": "Fiber to the Premises",
          "max_download_mbps": 5000,
          "max_upload_mbps": 5000,
          "low_latency": true
        },
        {
          "technology": "Copper Wire (DSL)",
          "max_download_mbps": 100,
          "max_upload_mbps": 20,
          "low_latency": true
        }
      ]
    },
    {
      "name": "Comcast",
      "services": [
        {
          "technology": "Cable (DOCSIS)",
          "max_download_mbps": 1200,
          "max_upload_mbps": 35,
          "low_latency": true
        }
      ]
    }
  ]
}
```

---

## Phase 5: Frontend Integration

Your frontend already exists. You just need to call the backend endpoint and display the results.

### Step 5.1 — Call the Backend

```javascript
async function lookupBroadband(address) {
    const response = await fetch(
        `/api/broadband/lookup?address=${encodeURIComponent(address)}`
    );
    const data = await response.json();
    return data;
}
```

### Step 5.2 — Display Considerations

When presenting the results to users, consider:

- **Sort providers by max download speed** (highest first) since that's what most consumers care about.
- **Show technology type prominently** — users should know if they'd get Fiber vs. Cable vs. DSL, as this affects reliability and upload speeds.
- **Flag low-latency services** — important for gamers and remote workers.
- **Add a disclaimer** that this is based on FCC-reported data, which reflects what providers claim to offer, not necessarily what's available at every unit in the block. Include the data as-of date.

---

## Phase 6: Known Limitations and Mitigations

### Limitation 1: Census Block Granularity vs. Address-Level Accuracy

**The problem:** Rolling up to census block means that if Provider X serves 1 out of 500 homes in a block, your app will show Provider X as available for all 500 homes. This is the "over-reporting" issue.

**Mitigations:**
- Census blocks are generally small in urban areas (often a single city block), so this is less of a problem in dense areas where most of your users likely are.
- Add a disclaimer: "Based on FCC data for your census block. Actual availability at your specific address may vary. Contact providers to confirm."
- Consider keeping the location-level data in a secondary table and doing a two-tier lookup: first check if the user's exact location ID exists in the location-level data; if not, fall back to block-level.

### Limitation 2: Data Freshness

**The problem:** FCC data is published roughly twice a year, so new provider deployments won't appear for months.

**Mitigations:**
- Show the "data as of" date prominently.
- Set up a reminder or automated check to re-download and reload when the FCC publishes new data (they announce it on the BDC website).
- Consider supplementing with live ISP serviceability checks for the biggest providers (AT&T, Comcast, Spectrum) for addresses where freshness matters most.

### Limitation 3: Only 5 States

**The problem:** Users outside your 5 states get no results.

**Mitigations:**
- Detect the state from the geocoded address and return a clear message: "We currently cover [State A, B, C, D, E]. Coverage for additional states is coming soon."
- The architecture you're building scales to all 50 states — it's just a matter of downloading more CSVs and loading them.

---

## Implementation Timeline (Suggested)

| Week | Tasks |
|------|-------|
| **Week 1** | Download FCC data for all 5 states. Write the Python rollup script. Validate the output against the FCC website. |
| **Week 2** | Set up PostgreSQL. Create the schema and indexes. Load the rolled-up data. Test queries manually. |
| **Week 3** | Build the backend API (geocoding pipeline + database query). Test end-to-end with sample addresses. |
| **Week 4** | Integrate the frontend with the backend API. Polish the UI for displaying results. Add error handling and edge cases. |
| **Week 5** | Testing, performance tuning, add disclaimers and data-as-of dates, deploy. |

---

## Tech Stack Summary

| Layer | Technology | Purpose |
|-------|-----------|---------|
| **Frontend** | Your existing UI | User input and display |
| **Backend** | Python (FastAPI) or Node.js (Express) | API layer, orchestration |
| **Geocoding** | Google Maps Geocoding API | Address → lat/lon |
| **Census Block Lookup** | US Census Geocoder API (or PostGIS) | lat/lon → FIPS |
| **Database** | PostgreSQL (+ PostGIS if using Option C) | FCC data storage and querying |
| **Data Pipeline** | Python (Pandas) | One-time ETL of FCC CSVs |

---

## Quick-Start Checklist

- [ ] Download FCC BDC availability CSVs for your 5 states (all technology types)
- [ ] Write rollup script (Python/Pandas) — aggregate to census block level
- [ ] Validate rollup against FCC Broadband Map website for 5+ addresses
- [ ] Install PostgreSQL (local dev) or provision managed instance
- [ ] Create database schema (tables + indexes as specified above)
- [ ] Bulk-load the rolled-up CSV into PostgreSQL
- [ ] Test database queries — confirm sub-10ms response on block_geoid lookup
- [ ] Register for Census Bureau Geocoder (no key required) or set up PostGIS
- [ ] Build backend endpoint: address → geocode → FIPS → DB query → JSON
- [ ] Connect frontend to backend API
- [ ] Add error handling for: out-of-coverage states, geocode failures, no data found
- [ ] Add disclaimers about data freshness and block-level granularity
- [ ] Deploy (consider Supabase for hosted PostgreSQL + API, or Railway/Render for a simple backend)