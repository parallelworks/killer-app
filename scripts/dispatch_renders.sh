#!/bin/bash
# dispatch_renders.sh — Dispatch tile rendering across N compute sites
#
# Runs on the dashboard host (first target). For each target site:
#   1. Checks out the repo via pw ssh
#   2. Runs setup
#   3. Launches render_tiles.sh with the site's tile range
#
# Environment variables:
#   TARGETS_JSON   - JSON array of target objects from workflow inputs
#   DASHBOARD_URL  - Dashboard URL (reachable from dashboard host)
#   DASHBOARD_PORT - Dashboard port (for tunnels)
#   TOTAL_TILES    - Total number of tiles to render
#   GRID_SIZE      - Grid dimension
#   IMAGE_SIZE     - Tile resolution
#   PALETTE        - Color palette
#   PARALLELISM    - Worker count ("auto" or number)

set -e

JOB_DIR="${PW_PARENT_JOB_DIR%/}"
SCRIPT_DIR="${JOB_DIR}/scripts"
WORK_DIR=$(mktemp -d)
trap "rm -rf ${WORK_DIR}" EXIT

# Find Python and pw
PYTHON_CMD=""
for cmd in python3 python; do
    command -v $cmd &>/dev/null && { PYTHON_CMD=$cmd; break; }
done
if [ -z "${PYTHON_CMD}" ]; then
    echo "[ERROR] Python not found"
    exit 1
fi

PW_CMD=""
for cmd in pw ~/pw/pw; do
    command -v $cmd &>/dev/null && { PW_CMD=$cmd; break; }
    [ -x "$cmd" ] && { PW_CMD=$cmd; break; }
done
if [ -z "${PW_CMD}" ]; then
    echo "[ERROR] pw CLI not found"
    exit 1
fi

# Parse targets JSON to get site list
SITES_JSON=$(${PYTHON_CMD} -c "
import json, sys, os

targets = json.loads(os.environ['TARGETS_JSON'])
sites = []
for i, t in enumerate(targets):
    res = t.get('resource', {})
    # Handle resource as string (CLI) or object (UI)
    if isinstance(res, str):
        res = {'name': res}
    sites.append({
        'index': i,
        'name': res.get('name', f'site-{i}'),
        'ip': res.get('ip', ''),
        'user': res.get('user', ''),
        'scheduler_type': res.get('schedulerType', ''),
    })
print(json.dumps(sites))
")

NUM_SITES=$(echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(len(json.load(sys.stdin)))")

echo "=========================================="
echo "Dispatch Renders: $(date)"
echo "=========================================="
echo "Sites:        ${NUM_SITES}"
echo "Total tiles:  ${TOTAL_TILES}"
echo "Grid:         ${GRID_SIZE}x${GRID_SIZE}"
echo "Image size:   ${IMAGE_SIZE}px"
echo "Dashboard:    ${DASHBOARD_URL}"

# Calculate tile ranges for each site
TILE_RANGES=$(${PYTHON_CMD} -c "
import json, sys, os, math

sites = json.loads('''${SITES_JSON}''')
total = int(os.environ['TOTAL_TILES'])
n = len(sites)

# Distribute tiles as evenly as possible
base = total // n
extra = total % n
start = 0
ranges = []
for i in range(n):
    count = base + (1 if i < extra else 0)
    ranges.append({'index': i, 'name': sites[i]['name'], 'start': start, 'end': start + count})
    start += count
print(json.dumps(ranges))
")

echo ""
echo "Tile assignments:"
echo "${TILE_RANGES}" | ${PYTHON_CMD} -c "
import sys, json
for r in json.load(sys.stdin):
    print(f\"  Site {r['index']} ({r['name']}): tiles {r['start']}-{r['end']-1} ({r['end']-r['start']} tiles)\")
"

REPO_URL="https://github.com/parallelworks/burst-render-demo.git"

# Render function for a single site
render_site() {
    local site_index=$1
    local site_name=$2
    local site_ip=$3
    local tile_start=$4
    local tile_end=$5

    local site_id="site-$((site_index + 1))"
    local num_tiles=$((tile_end - tile_start))

    echo ""
    echo "[${site_id}] Starting render on ${site_name} (${site_ip}): ${num_tiles} tiles"

    if [ "${site_index}" -eq 0 ]; then
        # First site = dashboard host, render locally (repo already checked out)
        echo "[${site_id}] Rendering locally on dashboard host..."
        (
            export DASHBOARD_URL="${DASHBOARD_URL}"
            export SITE_ID="${site_id}"
            export TILE_START="${tile_start}"
            export TILE_END="${tile_end}"
            export GRID_SIZE="${GRID_SIZE}"
            export IMAGE_SIZE="${IMAGE_SIZE}"
            export PALETTE="${PALETTE}"
            if [ "${PARALLELISM}" != "auto" ]; then
                export NUM_WORKERS="${PARALLELISM}"
            fi
            bash "${SCRIPT_DIR}/render_tiles.sh"
        )
    else
        # Remote site — checkout, setup, and render via SSH with reverse tunnel
        echo "[${site_id}] Dispatching to remote site ${site_name}..."

        # Allocate a port on the remote for the dashboard tunnel
        local tunnel_port
        tunnel_port=$(${PW_CMD} ssh "${site_name}" \
            'python3 -c "import socket; s=socket.socket(); s.bind((\"\",0)); print(s.getsockname()[1]); s.close()"' 2>/dev/null)

        if [ -z "${tunnel_port}" ] || ! [[ "${tunnel_port}" =~ ^[0-9]+$ ]]; then
            echo "[${site_id}] [ERROR] Failed to allocate tunnel port (got: '${tunnel_port}')"
            return 1
        fi
        echo "[${site_id}] Tunnel port: ${tunnel_port} (remote localhost -> dashboard)"

        # Build render script
        local script_file="${WORK_DIR}/render_${site_id}.sh"
        cat > "${script_file}" <<RENDER_SCRIPT
#!/bin/bash
set -e
WORK=\${PW_PARENT_JOB_DIR:-\${HOME}/pw/jobs/burst_render_remote}
mkdir -p "\${WORK}"
cd "\${WORK}"
export PW_PARENT_JOB_DIR="\${WORK}"

# Checkout if not already done
if [ ! -f scripts/render_tiles.sh ]; then
    echo 'Checking out scripts...'
    git clone --depth 1 --sparse --filter=blob:none ${REPO_URL} _checkout_tmp 2>/dev/null
    cd _checkout_tmp && git sparse-checkout set scripts 2>/dev/null && cd ..
    cp -r _checkout_tmp/scripts . && rm -rf _checkout_tmp
fi

# Setup
bash scripts/setup.sh

# Render — dashboard accessible via reverse tunnel on localhost
export DASHBOARD_URL='http://localhost:${tunnel_port}'
export SITE_ID='${site_id}'
export TILE_START=${tile_start}
export TILE_END=${tile_end}
export GRID_SIZE=${GRID_SIZE}
export IMAGE_SIZE=${IMAGE_SIZE}
export PALETTE='${PALETTE}'
$([ "${PARALLELISM}" != "auto" ] && echo "export NUM_WORKERS=${PARALLELISM}")

bash scripts/render_tiles.sh
RENDER_SCRIPT

        # Use raw ssh with pw as ProxyCommand to get -R (reverse tunnel) support
        # -R forwards remote's tunnel_port to dashboard host's DASHBOARD_PORT
        local script_content
        script_content=$(cat "${script_file}")
        ssh -i ~/.ssh/pwcli \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ExitOnForwardFailure=yes \
            -o ServerAliveInterval=15 \
            -o ProxyCommand="${PW_CMD} ssh --proxy-command %h" \
            -R "${tunnel_port}:localhost:${DASHBOARD_PORT}" \
            "${PW_USER}@${site_name}" \
            "${script_content}" 2>&1 | \
            sed "s/^/[${site_id}] /"
    fi
}

# Launch all sites in parallel
PIDS=()
SITE_NAMES=()
SITE_STATUSES=()

for i in $(seq 0 $((NUM_SITES - 1))); do
    site_name=$(echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}]['name'])")
    site_ip=$(echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}]['ip'])")
    tile_start=$(echo "${TILE_RANGES}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}]['start'])")
    tile_end=$(echo "${TILE_RANGES}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}]['end'])")

    render_site "${i}" "${site_name}" "${site_ip}" "${tile_start}" "${tile_end}" &
    PIDS+=($!)
    SITE_NAMES+=("${site_name}")
done

echo ""
echo "All ${NUM_SITES} sites dispatched, waiting for completion..."

# Wait for all and collect exit codes
FAILED=0
for i in "${!PIDS[@]}"; do
    if wait "${PIDS[$i]}"; then
        echo "[site-$((i+1))] ${SITE_NAMES[$i]}: COMPLETED"
    else
        echo "[site-$((i+1))] ${SITE_NAMES[$i]}: FAILED (exit $?)"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "=========================================="
echo "All renders complete!"
echo "  Sites: ${NUM_SITES}"
echo "  Failed: ${FAILED}"
echo "=========================================="

if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi
