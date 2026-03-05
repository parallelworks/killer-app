#!/bin/bash
# setup.sh — Controller-side setup (runs before start scripts)
# Verifies dependencies and bootstraps uv package manager.

set -e

echo "=========================================="
echo "Burst Renderer Setup: $(date)"
echo "=========================================="
echo "Hostname: $(hostname)"
echo "Job dir:  ${PW_PARENT_JOB_DIR:-$(pwd)}"

JOB_DIR="${PW_PARENT_JOB_DIR%/}"

# =============================================================================
# Verify Python
# =============================================================================
PYTHON_CMD=""
for cmd in python3 python; do
    command -v $cmd &>/dev/null && { PYTHON_CMD=$cmd; break; }
done

if [ -z "${PYTHON_CMD}" ]; then
    echo "[ERROR] Python not found in PATH"
    echo "  Searched: python3, python"
    echo "  PATH=${PATH}"
    exit 1
fi

PYTHON_VERSION=$(${PYTHON_CMD} --version 2>&1)
echo "Python: ${PYTHON_CMD} (${PYTHON_VERSION})"

# =============================================================================
# Bootstrap uv (fast Python package manager)
# =============================================================================
UV_DIR="${JOB_DIR}/.uv"
UV_BIN="${UV_DIR}/uv"

install_uv() {
    if [ -x "${UV_BIN}" ]; then
        echo "uv: ${UV_BIN} (cached)"
        return 0
    fi

    mkdir -p "${UV_DIR}"
    echo "Installing uv to ${UV_DIR}..."

    # Try downloading uv standalone binary
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64)  arch="x86_64" ;;
        aarch64) arch="aarch64" ;;
        *)
            echo "  [WARN] Unsupported architecture: ${arch}, skipping uv install"
            return 1
            ;;
    esac

    local url="https://github.com/astral-sh/uv/releases/latest/download/uv-${arch}-unknown-linux-gnu.tar.gz"

    # Try curl, then wget
    if command -v curl &>/dev/null; then
        curl -fsSL "${url}" | tar -xz -C "${UV_DIR}" --strip-components=1 2>/dev/null
    elif command -v wget &>/dev/null; then
        wget -qO- "${url}" | tar -xz -C "${UV_DIR}" --strip-components=1 2>/dev/null
    else
        echo "  [WARN] Neither curl nor wget available, skipping uv install"
        return 1
    fi

    if [ -x "${UV_BIN}" ]; then
        echo "  uv installed: $(${UV_BIN} --version 2>&1)"
        return 0
    else
        echo "  [WARN] uv download failed (no internet?), will fall back to pip"
        return 1
    fi
}

if install_uv; then
    echo "${UV_BIN}" > "${JOB_DIR}/UV_PATH"
fi

# Mark setup complete
touch "${JOB_DIR}/SETUP_COMPLETE"
echo "Setup complete!"
