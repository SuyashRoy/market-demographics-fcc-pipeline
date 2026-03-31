-- =============================================================================
-- PostGIS Database Initialization for Broadband Market Scanner
-- Creates geo schema, census_blocks table, and spatial indexes
-- Run: psql broadband_lookup -f infra/init-db.sql
-- =============================================================================

-- Enable PostGIS extension
CREATE EXTENSION IF NOT EXISTS postgis;

-- Create geo schema for spatial tables (separate from FCC data in public)
CREATE SCHEMA IF NOT EXISTS geo;

-- Drop table if it exists (for idempotent re-runs)
DROP TABLE IF EXISTS geo.census_blocks;

-- Create census_blocks table
-- Columns match the TIGER/Line shapefile attributes from shp2pgsql
CREATE TABLE geo.census_blocks (
    gid         serial PRIMARY KEY,
    statefp20   varchar(2),
    countyfp20  varchar(3),
    tractce20   varchar(6),
    blockce20   varchar(4),
    geoid20     varchar(15) NOT NULL,
    geoidfq20   varchar(25),
    name20      varchar(10),
    mtfcc20     varchar(5),
    ur20        varchar(1),
    uace20      varchar(5),
    funcstat20  varchar(1),
    aland20     bigint,
    awater20    bigint,
    intptlat20  varchar(11),
    intptlon20  varchar(12),
    housing20   bigint,
    pop20       bigint,
    geom        geometry(MultiPolygon, 4326)
);

-- Unique constraint on geoid20 (each census block has a unique FIPS code)
ALTER TABLE geo.census_blocks
    ADD CONSTRAINT census_blocks_geoid20_unique UNIQUE (geoid20);

-- GIST spatial index on geom for fast ST_Contains queries
CREATE INDEX idx_census_blocks_geom
    ON geo.census_blocks USING GIST (geom);

-- B-tree index on geoid20 for fast joins with block_availability
CREATE INDEX idx_census_blocks_geoid20
    ON geo.census_blocks USING BTREE (geoid20);

-- B-tree index on statefp20 for per-state filtering
CREATE INDEX idx_census_blocks_statefp20
    ON geo.census_blocks USING BTREE (statefp20);

\echo 'PostGIS extension enabled, geo schema and census_blocks table created.'
