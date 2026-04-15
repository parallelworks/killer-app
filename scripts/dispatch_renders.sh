#!/bin/bash
# dispatch_renders.sh — Dispatch tile rendering across N compute sites
#
# Runs on the dashboard host. For each target site:
#   1. Connects via SSH with reverse tunnel back to dashboard
#   2. Checks out the repo
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

# Parse targets JSON to get site list with scheduler config
SITES_JSON=$(${PYTHON_CMD} -c "
import json, sys, os

targets = json.loads(os.environ['TARGETS_JSON'])
sites = []
for i, t in enumerate(targets):
    res = t.get('resource', {})
    # Handle resource as string (CLI) or object (UI)
    if isinstance(res, str):
        res = {'name': res}
    # Scheduler config
    use_scheduler = t.get('scheduler', False)
    if isinstance(use_scheduler, str):
        use_scheduler = use_scheduler.lower() == 'true'
    scheduler_type = res.get('schedulerType', '')
    # Default to slurm when scheduler requested but type unknown
    if use_scheduler and not scheduler_type:
        scheduler_type = 'slurm'
    slurm = t.get('slurm', {}) or {}
    pbs = t.get('pbs', {}) or {}
    sites.append({
        'index': i,
        'name': res.get('name', f'site-{i}'),
        'ip': res.get('ip', ''),
        'user': res.get('user', ''),
        'scheduler_type': scheduler_type,
        'use_scheduler': use_scheduler,
        'slurm_partition': slurm.get('partition', ''),
        'slurm_account': slurm.get('account', ''),
        'slurm_qos': slurm.get('qos', ''),
        'slurm_time': slurm.get('time', '00:05:00'),
        'slurm_nodes': slurm.get('nodes', '1'),
        'slurm_directives': slurm.get('scheduler_directives', ''),
        'pbs_directives': pbs.get('scheduler_directives', ''),
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
import sys, json, os
ranges = json.load(sys.stdin)
sites = json.loads('''${SITES_JSON}''')
for r in ranges:
    s = sites[r['index']]
    mode = s.get('scheduler_type', 'ssh') if s.get('use_scheduler') else 'ssh'
    print(f\"  Site {r['index']} ({r['name']}): tiles {r['start']}-{r['end']-1} ({r['end']-r['start']} tiles) [{mode}]\")
"

REPO_URL="https://github.com/parallelworks/burst-render-demo.git"

# Render function for a single site
render_site() {
    local site_index=$1
    local site_name=$2
    local site_ip=$3
    local tile_start=$4
    local tile_end=$5
    local use_scheduler=$6
    local scheduler_type=$7
    local slurm_partition=$8
    local slurm_account=$9
    local slurm_qos=${10}
    local slurm_time=${11}
    local slurm_nodes=${12}
    local slurm_directives=${13}
    local pbs_directives=${14}

    local site_id="site-$((site_index + 1))"
    local num_tiles=$((tile_end - tile_start))
    local dispatch_mode="ssh"
    if [ "${use_scheduler}" = "true" ]; then
        dispatch_mode="${scheduler_type}"
    fi

    echo ""
    echo "[${site_id}] Starting render on ${site_name} (${site_ip}): ${num_tiles} tiles [${dispatch_mode}]"

    # All sites are remote — dispatch via SSH with reverse tunnel
    echo "[${site_id}] Dispatching to remote site ${site_name} [${dispatch_mode}]..."

    # Probe SSH reachability first — gives a clear error on fresh accounts
    # where site credentials / SSH keys may not be provisioned yet.
    echo "[${site_id}] Probing SSH to ${site_name} via: ${PW_CMD} ssh ${site_name} ..."
    local probe_stderr="${WORK_DIR}/probe_${site_id}.err"
    local probe_stdout
    set +e
    probe_stdout=$(${PW_CMD} ssh "${site_name}" 'echo PW_SSH_OK && hostname' 2>"${probe_stderr}")
    local probe_rc=$?
    set -e
    if [ ${probe_rc} -ne 0 ] || [[ "${probe_stdout}" != *PW_SSH_OK* ]]; then
        echo "[${site_id}] [ERROR] pw ssh to '${site_name}' failed (exit ${probe_rc})"
        echo "[${site_id}] [ERROR] stdout: ${probe_stdout:-<empty>}"
        if [ -s "${probe_stderr}" ]; then
            echo "[${site_id}] [ERROR] stderr:"
            sed "s/^/[${site_id}]   /" "${probe_stderr}"
        fi
        echo "[${site_id}] [HINT] Common causes on fresh accounts:"
        echo "[${site_id}] [HINT]   - ~/.ssh/pwcli key not yet provisioned (run 'pw ssh ${site_name} hostname' manually)"
        echo "[${site_id}] [HINT]   - Site '${site_name}' not authorized for this user (check Activate resource access)"
        echo "[${site_id}] [HINT]   - Site requires additional onboarding (PIV/CAC, Kerberos, HPC account)"
        return 1
    fi
    echo "[${site_id}] SSH OK — remote reports: ${probe_stdout}"

    # Allocate a port on the remote for the dashboard tunnel.
    # Use direct ssh (not `pw ssh`) because:
    #   - `pw ssh` does not reliably forward stdin to the remote command,
    #     so heredoc-piped Python produces no output.
    #   - Embedding the Python as a -c argument breaks under tcsh login
    #     shells (ERDC/ARL), which don't honor \" as an escape inside "...".
    # Using ssh over a `pw ssh --proxy-command` ProxyCommand forwards stdin
    # cleanly — same pattern used below for the main render dispatch.
    local tunnel_port tunnel_stderr="${WORK_DIR}/tunnel_${site_id}.err"
    set +e
    tunnel_port=$(ssh -i ~/.ssh/pwcli \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ProxyCommand="${PW_CMD} ssh --proxy-command %h" \
        "${PW_USER}@${site_name}" \
        python3 2>"${tunnel_stderr}" <<'PYEOF'
import socket
s = socket.socket()
s.bind(("", 0))
print(s.getsockname()[1])
s.close()
PYEOF
)
    local tunnel_rc=$?
    set -e

    if [ ${tunnel_rc} -ne 0 ] || [ -z "${tunnel_port}" ] || ! [[ "${tunnel_port}" =~ ^[0-9]+$ ]]; then
        echo "[${site_id}] [ERROR] Failed to allocate tunnel port (exit ${tunnel_rc}, got: '${tunnel_port}')"
        if [ -s "${tunnel_stderr}" ]; then
            echo "[${site_id}] [ERROR] stderr:"
            sed "s/^/[${site_id}]   /" "${tunnel_stderr}"
        fi
        return 1
    fi
    echo "[${site_id}] Tunnel port: ${tunnel_port} (remote localhost -> dashboard)"

    # Build srun command if using scheduler
    local srun_cmd=""
    if [ "${dispatch_mode}" = "slurm" ]; then
        srun_cmd="srun"
        [ -n "${slurm_partition}" ] && srun_cmd="${srun_cmd} --partition=${slurm_partition}"
        [ -n "${slurm_account}" ] && srun_cmd="${srun_cmd} --account=${slurm_account}"
        [ -n "${slurm_qos}" ] && srun_cmd="${srun_cmd} --qos=${slurm_qos}"
        [ -n "${slurm_time}" ] && srun_cmd="${srun_cmd} --time=${slurm_time}"
        local nodes="${slurm_nodes:-1}"
        srun_cmd="${srun_cmd} --nodes=${nodes} --ntasks=${nodes}"
    fi

    # Build render script
    local script_file="${WORK_DIR}/render_${site_id}.sh"

    if [ "${dispatch_mode}" = "slurm" ]; then
        # SLURM mode: run on login node, use srun to dispatch to compute node
        # Need a TCP proxy to expose the SSH tunnel to compute nodes since
        # the reverse tunnel only binds to localhost on the login node
        cat > "${script_file}" <<RENDER_SCRIPT
#!/bin/bash
set -e
WORK=\${PW_PARENT_JOB_DIR:-\${HOME}/pw/jobs/burst_render_remote}
mkdir -p "\${WORK}"
cd "\${WORK}"
export PW_PARENT_JOB_DIR="\${WORK}"

# Kill stale render/proxy processes from prior cancelled runs
echo 'Cleaning up stale processes from prior runs...'
pkill -f "render_tiles.sh" 2>/dev/null || true
pkill -f "python.*renderer.py" 2>/dev/null || true
for pf in "\${WORK}"/.proxy_*.pid; do
    [ -f "\${pf}" ] && kill \$(cat "\${pf}" 2>/dev/null) 2>/dev/null && rm -f "\${pf}" || true
done
pkill -f "proxy.*\${WORK}" 2>/dev/null || true
sleep 1

# Always fetch latest scripts
echo 'Checking out scripts...'
rm -rf _checkout_tmp scripts
git clone --depth 1 --sparse --filter=blob:none ${REPO_URL} _checkout_tmp 2>/dev/null
cd _checkout_tmp && git sparse-checkout set scripts 2>/dev/null && cd ..
cp -r _checkout_tmp/scripts . && rm -rf _checkout_tmp

# Setup
bash scripts/setup.sh

# Start TCP proxy to expose SSH tunnel to compute nodes
# The reverse tunnel binds to localhost:${tunnel_port} on this login node.
# Compute nodes need to reach it via the login node's hostname.
PROXY_PORT=\$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
python3 -c "
import socket, threading, sys, os
def proxy(src, dst):
    try:
        while True:
            d = src.recv(65536)
            if not d: break
            dst.sendall(d)
    except: pass
    finally: src.close(); dst.close()
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', int(sys.argv[1])))
s.listen(64)
# Write pid so parent can clean up
open(sys.argv[3], 'w').write(str(os.getpid()))
while True:
    c, _ = s.accept()
    r = socket.create_connection(('localhost', int(sys.argv[2])))
    threading.Thread(target=proxy, args=(c,r), daemon=True).start()
    threading.Thread(target=proxy, args=(r,c), daemon=True).start()
" \${PROXY_PORT} ${tunnel_port} "\${WORK}/.proxy_pid" &
sleep 1

LOGIN_HOST=\$(hostname)
echo "TCP proxy: \${LOGIN_HOST}:\${PROXY_PORT} -> localhost:${tunnel_port}"

cleanup() { kill \$(cat "\${WORK}/.proxy_pid" 2>/dev/null) 2>/dev/null; }
trap cleanup EXIT

# Render via srun — compute node reaches dashboard through login node proxy
export DASHBOARD_URL="http://\${LOGIN_HOST}:\${PROXY_PORT}"
export SITE_ID='${site_id}'
export TILE_START=${tile_start}
export TILE_END=${tile_end}
export GRID_SIZE=${GRID_SIZE}
export IMAGE_SIZE=${IMAGE_SIZE}
export PALETTE='${PALETTE}'
export SCHEDULER_TYPE='slurm'
$([ "${PARALLELISM}" != "auto" ] && echo "export NUM_WORKERS=${PARALLELISM}")

echo "Submitting to SLURM: ${srun_cmd} bash scripts/render_tiles.sh"
${srun_cmd} bash scripts/render_tiles.sh
RENDER_SCRIPT
    else
        # SSH mode: run directly on the remote host
        cat > "${script_file}" <<RENDER_SCRIPT
#!/bin/bash
set -e
WORK=\${PW_PARENT_JOB_DIR:-\${HOME}/pw/jobs/burst_render_remote}
mkdir -p "\${WORK}"
cd "\${WORK}"
export PW_PARENT_JOB_DIR="\${WORK}"

# Kill stale render/proxy processes from prior cancelled runs
echo 'Cleaning up stale processes from prior runs...'
pkill -f "render_tiles.sh" 2>/dev/null || true
pkill -f "python.*renderer.py" 2>/dev/null || true
for pf in "\${WORK}"/.proxy_*.pid; do
    [ -f "\${pf}" ] && kill \$(cat "\${pf}" 2>/dev/null) 2>/dev/null && rm -f "\${pf}" || true
done
pkill -f "proxy.*\${WORK}" 2>/dev/null || true
sleep 1

# Always fetch latest scripts
echo 'Checking out scripts...'
rm -rf _checkout_tmp scripts
git clone --depth 1 --sparse --filter=blob:none ${REPO_URL} _checkout_tmp 2>/dev/null
cd _checkout_tmp && git sparse-checkout set scripts 2>/dev/null && cd ..
cp -r _checkout_tmp/scripts . && rm -rf _checkout_tmp

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
    fi

    # Pipe script via stdin to avoid quoting issues with embedded Python/heredocs
    # -R forwards remote's tunnel_port to dashboard host's DASHBOARD_PORT
    ssh -i ~/.ssh/pwcli \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=4 \
        -o TCPKeepAlive=yes \
        -o ProxyCommand="${PW_CMD} ssh --proxy-command %h" \
        -R "${tunnel_port}:localhost:${DASHBOARD_PORT}" \
        "${PW_USER}@${site_name}" \
        'bash -s' < "${script_file}" 2>&1 | \
        sed "s/^/[${site_id}] /"
}

# Launch all sites in parallel
PIDS=()
SITE_NAMES=()
SITE_STATUSES=()

for i in $(seq 0 $((NUM_SITES - 1))); do
    site_name=$(echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}]['name'])")
    site_ip=$(echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}]['ip'])")
    site_scheduler=$(echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}]['scheduler_type'])")
    tile_start=$(echo "${TILE_RANGES}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}]['start'])")
    tile_end=$(echo "${TILE_RANGES}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}]['end'])")
    use_scheduler=$(echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(str(json.load(sys.stdin)[${i}].get('use_scheduler',False)).lower())")
    scheduler_type=$(echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}].get('scheduler_type',''))")
    slurm_partition=$(echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}].get('slurm_partition',''))")
    slurm_account=$(echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}].get('slurm_account',''))")
    slurm_qos=$(echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}].get('slurm_qos',''))")
    slurm_time=$(echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}].get('slurm_time','00:05:00'))")
    slurm_nodes=$(echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}].get('slurm_nodes','1'))")
    slurm_directives=$(echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}].get('slurm_directives',''))")
    pbs_directives=$(echo "${SITES_JSON}" | ${PYTHON_CMD} -c "import sys,json;print(json.load(sys.stdin)[${i}].get('pbs_directives',''))")

    # Notify dashboard this site is pending (before dispatch begins)
    curl -s -X POST "http://localhost:${DASHBOARD_PORT}/api/worker/pending" \
        -H "Content-Type: application/json" \
        -d "{\"site_id\": \"site-$((i + 1))\", \"cluster_name\": \"${site_name}\", \"scheduler_type\": \"${site_scheduler}\"}" \
        >/dev/null 2>&1 || true

    render_site "${i}" "${site_name}" "${site_ip}" "${tile_start}" "${tile_end}" \
        "${use_scheduler}" "${scheduler_type}" \
        "${slurm_partition}" "${slurm_account}" "${slurm_qos}" "${slurm_time}" \
        "${slurm_nodes}" "${slurm_directives}" \
        "${pbs_directives}" &
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
