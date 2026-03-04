#!/bin/bash
# render_tiles.sh — Render Mandelbrot tiles and POST them to the dashboard
#
# Environment variables:
#   DASHBOARD_URL   - Base URL of dashboard (e.g., http://host:port)
#   SITE_ID         - Identifier for this compute site (e.g., site-1)
#   TILE_START      - First tile index (inclusive)
#   TILE_END        - Last tile index (exclusive)
#   GRID_SIZE       - Grid dimension (e.g., 8 for 8x8)
#   IMAGE_SIZE      - Tile resolution in pixels (e.g., 256)
#   PALETTE         - Color palette (default: electric)
#   CLUSTER_NAME    - PW cluster name (auto-discovered if empty)
#   SCHEDULER_TYPE  - Scheduler type (e.g., ssh, slurm)
#   NUM_WORKERS     - Number of parallel workers (default: auto-detect)

set -e

# Discover cluster name if not provided
if [ -z "${CLUSTER_NAME}" ]; then
    PW_CMD=""
    for cmd in pw ~/pw/pw; do
        command -v $cmd &>/dev/null && { PW_CMD=$cmd; break; }
        [ -x "$cmd" ] && { PW_CMD=$cmd; break; }
    done
    if [ -n "${PW_CMD}" ]; then
        # Find this resource's name from pw cluster list by matching hostname
        MY_HOST=$(hostname)
        CLUSTER_NAME=$(${PW_CMD} cluster list 2>/dev/null | awk '/^pw:\/\/'"${PW_USER}"'/ && /active/ {print $1}' | while IFS= read -r uri; do
            name="${uri##*/}"
            echo "${name}"
        done | head -1)
        # If we only found one match or hostname helps, use it
        [ -z "${CLUSTER_NAME}" ] && CLUSTER_NAME="${MY_HOST}"
    else
        CLUSTER_NAME="$(hostname -s)"
    fi
fi

echo "=========================================="
echo "Tile Renderer Starting: $(date)"
echo "=========================================="
echo "Site:       ${SITE_ID}"
echo "Cluster:    ${CLUSTER_NAME}"
echo "Scheduler:  ${SCHEDULER_TYPE:-unknown}"
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

# Determine number of workers
if [ -z "${NUM_WORKERS}" ]; then
    NUM_WORKERS=$(nproc 2>/dev/null || echo 4)
    # Cap at number of tiles to avoid idle workers
    TOTAL=$((TILE_END - TILE_START))
    [ "${NUM_WORKERS}" -gt "${TOTAL}" ] && NUM_WORKERS=${TOTAL}
    # Cap at a reasonable max
    [ "${NUM_WORKERS}" -gt 16 ] && NUM_WORKERS=16
fi

echo "Workers:    ${NUM_WORKERS}"
echo "Work dir:   ${WORK_DIR}"
echo ""

TOTAL=$((TILE_END - TILE_START))

# Shared counters via files
echo "0" > "${WORK_DIR}/completed"
echo "0" > "${WORK_DIR}/errors"
LOCK_DIR="${WORK_DIR}/lock"

# Atomic increment helper
atomic_inc() {
    local file="$1"
    while ! mkdir "${LOCK_DIR}" 2>/dev/null; do :; done
    local val=$(cat "$file")
    echo $((val + 1)) > "$file"
    echo $((val + 1))
    rmdir "${LOCK_DIR}"
}

# Worker function: render and POST a single tile
render_one() {
    local idx=$1
    local tile_x=$((idx % GRID_SIZE))
    local tile_y=$((idx / GRID_SIZE))
    local tile_file="${WORK_DIR}/tile_${tile_x}_${tile_y}.png"

    # Render tile
    local META
    META=$(${PYTHON_CMD} "${RENDERER}" \
        --tile-x "${tile_x}" \
        --tile-y "${tile_y}" \
        --grid-size "${GRID_SIZE}" \
        --width "${IMAGE_SIZE}" \
        --height "${IMAGE_SIZE}" \
        --palette "${PALETTE:-electric}" \
        --site-id "${SITE_ID}" \
        --cluster-name "${CLUSTER_NAME}" \
        --scheduler-type "${SCHEDULER_TYPE}" \
        --output "${tile_file}" \
    )

    # POST tile to dashboard
    local HTTP_CODE
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${DASHBOARD_URL}/api/tile" \
        -F "tile=@${tile_file}" \
        -F "metadata=${META}" \
        --connect-timeout 10 \
        --max-time 30 \
    ) || HTTP_CODE="000"

    local count
    count=$(atomic_inc "${WORK_DIR}/completed")

    if [ "${HTTP_CODE}" = "200" ]; then
        local render_ms
        render_ms=$(echo "${META}" | ${PYTHON_CMD} -c 'import sys,json;print(json.load(sys.stdin)["render_time_ms"])' 2>/dev/null || echo '?')
        echo "[${count}/${TOTAL}] Tile (${tile_x},${tile_y}) -> OK (${render_ms}ms)"
    else
        atomic_inc "${WORK_DIR}/errors" > /dev/null
        echo "[${count}/${TOTAL}] Tile (${tile_x},${tile_y}) -> FAILED (HTTP ${HTTP_CODE})"
    fi

    rm -f "${tile_file}"
}

export -f render_one atomic_inc
export PYTHON_CMD RENDERER GRID_SIZE IMAGE_SIZE PALETTE SITE_ID CLUSTER_NAME SCHEDULER_TYPE DASHBOARD_URL WORK_DIR TOTAL LOCK_DIR

# Launch tiles across workers using xargs for parallel execution
seq ${TILE_START} $((TILE_END - 1)) | xargs -P "${NUM_WORKERS}" -I{} bash -c 'render_one "$@"' _ {}

ERRORS=$(cat "${WORK_DIR}/errors")
COMPLETED=$(cat "${WORK_DIR}/completed")

echo ""
echo "=========================================="
echo "Rendering complete!"
echo "  Tiles rendered: ${COMPLETED}"
echo "  Workers: ${NUM_WORKERS}"
echo "  Errors: ${ERRORS}"
echo "=========================================="
