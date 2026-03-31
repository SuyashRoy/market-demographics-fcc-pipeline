-- =============================================================================
-- PostGIS Verification Queries for Census Block Spatial Lookups
-- Run: psql broadband_lookup -f infra/verify-spatial.sql
-- =============================================================================

\echo ''
\echo '============================================='
\echo '1. ROW COUNTS BY STATE'
\echo '============================================='

SELECT
    statefp20 AS state_fips,
    CASE statefp20
        WHEN '06' THEN 'California'
        WHEN '13' THEN 'Georgia'
        WHEN '17' THEN 'Illinois'
        WHEN '36' THEN 'New York'
        WHEN '48' THEN 'Texas'
    END AS state_name,
    COUNT(*) AS block_count
FROM geo.census_blocks
GROUP BY statefp20
ORDER BY statefp20;

SELECT COUNT(*) AS total_blocks FROM geo.census_blocks;

\echo ''
\echo '============================================='
\echo '2. SAMPLE ST_Contains QUERY — Google HQ, Mountain View, CA'
\echo '   Expected: A census block in Santa Clara County (statefp20=06)'
\echo '============================================='

SELECT
    geoid20 AS block_geoid,
    statefp20,
    countyfp20,
    tractce20,
    blockce20,
    intptlat20,
    intptlon20,
    ST_Area(geom::geography)::int AS area_sq_m
FROM geo.census_blocks
WHERE ST_Contains(
    geom,
    ST_SetSRID(ST_MakePoint(-122.0842, 37.4220), 4326)
);

\echo ''
\echo '============================================='
\echo '3. SAMPLE ST_Contains QUERY — Empire State Building, NYC'
\echo '   Expected: A census block in New York County (statefp20=36)'
\echo '============================================='

SELECT
    geoid20 AS block_geoid,
    statefp20,
    countyfp20,
    tractce20,
    blockce20,
    intptlat20,
    intptlon20
FROM geo.census_blocks
WHERE ST_Contains(
    geom,
    ST_SetSRID(ST_MakePoint(-73.9857, 40.7484), 4326)
);

\echo ''
\echo '============================================='
\echo '4. EXPLAIN ANALYZE — Verify spatial index usage'
\echo '   Look for "Index Scan using idx_census_blocks_geom"'
\echo '============================================='

EXPLAIN ANALYZE
SELECT geoid20
FROM geo.census_blocks
WHERE ST_Contains(
    geom,
    ST_SetSRID(ST_MakePoint(-122.0842, 37.4220), 4326)
);

\echo ''
\echo '============================================='
\echo '5. CROSS-CHECK: geoid20 linkage with block_availability'
\echo '   Shows how many census blocks have matching FCC data'
\echo '============================================='

SELECT
    cb.statefp20 AS state_fips,
    COUNT(DISTINCT cb.geoid20) AS census_blocks,
    COUNT(DISTINCT ba.block_geoid) AS blocks_with_fcc_data,
    ROUND(
        100.0 * COUNT(DISTINCT ba.block_geoid) / NULLIF(COUNT(DISTINCT cb.geoid20), 0),
        1
    ) AS match_pct
FROM geo.census_blocks cb
LEFT JOIN public.block_availability ba ON ba.block_geoid = cb.geoid20
GROUP BY cb.statefp20
ORDER BY cb.statefp20;

\echo ''
\echo '============================================='
\echo '6. END-TO-END: Address -> Census Block -> Broadband Providers'
\echo '   Google HQ, Mountain View, CA (-122.0842, 37.4220)'
\echo '============================================='

SELECT
    cb.geoid20 AS block_geoid,
    ba.brand_name,
    ba.technology_name,
    ba.max_download,
    ba.max_upload,
    ba.low_latency
FROM geo.census_blocks cb
JOIN public.block_availability ba ON ba.block_geoid = cb.geoid20
WHERE ST_Contains(
    cb.geom,
    ST_SetSRID(ST_MakePoint(-122.0842, 37.4220), 4326)
)
ORDER BY ba.max_download DESC
LIMIT 15;

\echo ''
\echo '============================================='
\echo 'Verification complete.'
\echo '============================================='
