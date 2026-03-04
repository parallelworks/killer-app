#!/bin/bash
# setup_tunnel.sh — Create a reverse SSH tunnel from on-prem to cloud
#
# Environment variables:
#   CLOUD_RESOURCE  - Name of the cloud resource (e.g., googlerockyv3)
#   DASHBOARD_PORT  - Port of the dashboard on this machine
#   PW_USER         - ACTIVATE username for SSH

set -e

echo "=========================================="
echo "Setting up reverse tunnel: $(date)"
echo "=========================================="
echo "Cloud resource: ${CLOUD_RESOURCE}"
echo "Dashboard port: ${DASHBOARD_PORT}"
echo "PW user: ${PW_USER}"

JOB_DIR="${PW_PARENT_JOB_DIR%/}"

# Allocate a port on the cloud side for the tunnel
echo "Allocating port on cloud..."
TUNNEL_PORT=$(pw ssh "${CLOUD_RESOURCE}" 'python3 -c "import socket; s=socket.socket(); s.bind((\"\",0)); print(s.getsockname()[1]); s.close()"' 2>/dev/null)

if [ -z "${TUNNEL_PORT}" ] || ! [[ "${TUNNEL_PORT}" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Failed to allocate port on cloud (got: '${TUNNEL_PORT}')"
    exit 1
fi

echo "Tunnel port on cloud: ${TUNNEL_PORT}"
echo "${TUNNEL_PORT}" > "${JOB_DIR}/TUNNEL_PORT"

# Start reverse SSH tunnel: cloud:TUNNEL_PORT -> onprem:DASHBOARD_PORT
echo "Establishing reverse SSH tunnel..."
ssh -i ~/.ssh/pwcli \
    -o StrictHostKeyChecking=no \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ProxyCommand="pw ssh --proxy-command %h" \
    -R "${TUNNEL_PORT}:localhost:${DASHBOARD_PORT}" \
    -N "${PW_USER}@${CLOUD_RESOURCE}" &
TUNNEL_PID=$!
sleep 3

if kill -0 ${TUNNEL_PID} 2>/dev/null; then
    echo "=========================================="
    echo "Reverse tunnel ESTABLISHED (PID ${TUNNEL_PID})"
    echo "  Cloud localhost:${TUNNEL_PORT} -> On-prem localhost:${DASHBOARD_PORT}"
    echo "=========================================="
    echo "TUNNEL_PORT=${TUNNEL_PORT}" >> "${OUTPUTS}"

    # Keep tunnel alive until render completes
    while kill -0 ${TUNNEL_PID} 2>/dev/null; do
        sleep 5
    done
    echo "Tunnel process exited"
else
    echo "[ERROR] Failed to establish tunnel"
    exit 1
fi
