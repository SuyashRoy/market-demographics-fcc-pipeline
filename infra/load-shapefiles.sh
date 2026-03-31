#!/usr/bin/env bash
# =============================================================================
# Load Census Block shapefiles into PostGIS (geo.census_blocks)
# Reprojects from NAD83 (EPSG:4269) to WGS84 (EPSG:4326) during load.
# Run: bash infra/load-shapefiles.sh
# =============================================================================

set -euo pipefail

DB="broadband_lookup"
SCHEMA="geo"
TABLE="census_blocks"
TARGET="${SCHEMA}.${TABLE}"

# Project root (script lives in infra/)
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHAPE_DIR="${PROJECT_DIR}/data/Shape Files"

# State FIPS codes and names (parallel arrays for bash 3 compat)
STATE_FIPS="06 13 17 36 48"
get_state_name() {
    case "$1" in
        06) echo "California" ;;
        13) echo "Georgia" ;;
        17) echo "Illinois" ;;
        36) echo "New York" ;;
        48) echo "Texas" ;;
    esac
}

echo "============================================="
echo "Loading Census Block shapefiles into PostGIS"
echo "Database: ${DB} | Table: ${TARGET}"
echo "============================================="

FIRST=true
TOTAL_LOADED=0

for FIPS in $STATE_FIPS; do
    STATE_NAME="$(get_state_name "$FIPS")"
    SHP_DIR="${SHAPE_DIR}/tl_2025_${FIPS}_tabblock20"
    SHP_FILE="${SHP_DIR}/tl_2025_${FIPS}_tabblock20.shp"

    if [ ! -f "$SHP_FILE" ]; then
        echo "ERROR: Shapefile not found: ${SHP_FILE}"
        exit 1
    fi

    echo ""
    echo "--- Loading ${STATE_NAME} (FIPS: ${FIPS}) ---"
    echo "    Source: ${SHP_FILE}"

    if [ "$FIRST" = true ]; then
        echo "    Mode: Truncate + Insert (first state)"
        psql -d "$DB" -c "TRUNCATE ${TARGET} RESTART IDENTITY;"
        shp2pgsql -s 4269:4326 -a "$SHP_FILE" "$TARGET" \
            | psql -d "$DB" -q
        FIRST=false
    else
        echo "    Mode: Append"
        shp2pgsql -s 4269:4326 -a "$SHP_FILE" "$TARGET" \
            | psql -d "$DB" -q
    fi

    # Count rows loaded for this state
    COUNT=$(psql -d "$DB" -t -A -c \
        "SELECT COUNT(*) FROM ${TARGET} WHERE statefp20 = '${FIPS}';")
    echo "    Rows loaded for ${STATE_NAME}: ${COUNT}"
    TOTAL_LOADED=$((TOTAL_LOADED + COUNT))
done

echo ""
echo "============================================="
echo "All states loaded. Running VACUUM ANALYZE..."
echo "============================================="
psql -d "$DB" -c "VACUUM ANALYZE ${TARGET};"

# Final totals
echo ""
echo "============================================="
echo "LOAD SUMMARY"
echo "============================================="
for FIPS in $STATE_FIPS; do
    STATE_NAME="$(get_state_name "$FIPS")"
    COUNT=$(psql -d "$DB" -t -A -c \
        "SELECT COUNT(*) FROM ${TARGET} WHERE statefp20 = '${FIPS}';")
    printf "  %-15s (FIPS %s): %10d blocks\n" "$STATE_NAME" "$FIPS" "$COUNT"
done

TOTAL=$(psql -d "$DB" -t -A -c "SELECT COUNT(*) FROM ${TARGET};")
echo "  -------------------------------------------"
printf "  %-15s           %10d blocks\n" "TOTAL" "$TOTAL"
echo ""
echo "Done."
