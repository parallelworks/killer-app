#!/bin/bash
# render_tiles.sh — Render Mandelbrot tiles and POST them to the dashboard
#
# Environment variables:
#   DASHBOARD_URL  - Base URL of dashboard (e.g., http://host:port)
#   SITE_ID        - Identifier for this compute site
#   TILE_START     - First tile index (inclusive)
#   TILE_END       - Last tile index (exclusive)
#   GRID_SIZE      - Grid dimension (e.g., 8 for 8x8)
#   IMAGE_SIZE     - Tile resolution in pixels (e.g., 256)
#   PALETTE        - Color palette (default: electric)

set -e

echo "=========================================="
echo "Tile Renderer Starting: $(date)"
echo "=========================================="
echo "Site:       ${SITE_ID}"
echo "Dashboard:  ${DASHBOARD_URL}"
echo "Tiles:      ${TILE_START} to ${TILE_END}"
echo "Grid:       ${GRID_SIZE}x${GRID_SIZE}"
echo "Image size: ${IMAGE_SIZE}x${IMAGE_SIZE}"
echo "Palette:    ${PALETTE:-electric}"

# Find Python
PYTHON_CMD=""
for cmd in python3 python; do
    command -v $cmd &>/dev/null && { PYTHON_CMD=$cmd; break; }
done
if [ -z "${PYTHON_CMD}" ]; then
    echo "[ERROR] Python not found"
    exit 1
fi

# Script directory — checkout places scripts under $PW_PARENT_JOB_DIR/scripts/
SCRIPT_DIR="${PW_PARENT_JOB_DIR%/}/scripts"
RENDERER="${SCRIPT_DIR}/renderer.py"

if [ ! -f "${RENDERER}" ]; then
    echo "[ERROR] renderer.py not found at ${RENDERER}"
    exit 1
fi

# Working directory for temp tiles
WORK_DIR=$(mktemp -d)
trap "rm -rf ${WORK_DIR}" EXIT

echo "Work dir: ${WORK_DIR}"
echo ""

TOTAL=$((TILE_END - TILE_START))
COUNT=0
ERRORS=0

for idx in $(seq ${TILE_START} $((TILE_END - 1))); do
    tile_x=$((idx % GRID_SIZE))
    tile_y=$((idx / GRID_SIZE))
    tile_file="${WORK_DIR}/tile_${tile_x}_${tile_y}.png"

    # Render tile
    META=$(${PYTHON_CMD} "${RENDERER}" \
        --tile-x "${tile_x}" \
        --tile-y "${tile_y}" \
        --grid-size "${GRID_SIZE}" \
        --width "${IMAGE_SIZE}" \
        --height "${IMAGE_SIZE}" \
        --palette "${PALETTE:-electric}" \
        --site-id "${SITE_ID}" \
        --output "${tile_file}" \
    )

    COUNT=$((COUNT + 1))

    # POST tile to dashboard
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${DASHBOARD_URL}/api/tile" \
        -F "tile=@${tile_file}" \
        -F "metadata=${META}" \
        --connect-timeout 10 \
        --max-time 30 \
    ) || HTTP_CODE="000"

    if [ "${HTTP_CODE}" = "200" ]; then
        echo "[${COUNT}/${TOTAL}] Tile (${tile_x},${tile_y}) -> OK ($(echo "${META}" | ${PYTHON_CMD} -c 'import sys,json;print(json.load(sys.stdin)["render_time_ms"])' 2>/dev/null || echo '?')ms)"
    else
        ERRORS=$((ERRORS + 1))
        echo "[${COUNT}/${TOTAL}] Tile (${tile_x},${tile_y}) -> FAILED (HTTP ${HTTP_CODE})"
    fi

    # Clean up tile file
    rm -f "${tile_file}"
done

echo ""
echo "=========================================="
echo "Rendering complete!"
echo "  Tiles rendered: ${COUNT}"
echo "  Errors: ${ERRORS}"
echo "=========================================="
