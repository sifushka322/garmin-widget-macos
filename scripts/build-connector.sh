#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONNECTOR_PYTHON="${CONNECTOR_PYTHON:-$PROJECT_DIR/.venv/bin/python}"
CONNECTOR_DIST_DIR="${CONNECTOR_DIST_DIR:-$PROJECT_DIR/build/connector-dist}"
CONNECTOR_WORK_DIR="${CONNECTOR_WORK_DIR:-$PROJECT_DIR/build/connector-work}"
export PYINSTALLER_CONFIG_DIR="$PROJECT_DIR/build/pyinstaller-cache"

if [[ ! -x "$CONNECTOR_PYTHON" ]]; then
    echo "Missing build Python. Create .venv and install Connector/requirements-build.txt." >&2
    exit 1
fi

"$CONNECTOR_PYTHON" -m PyInstaller --noconfirm \
    --distpath "$CONNECTOR_DIST_DIR" --workpath "$CONNECTOR_WORK_DIR" \
    "$PROJECT_DIR/Connector/garmin-bridge.spec"
"$CONNECTOR_PYTHON" "$PROJECT_DIR/Connector/collect_notices.py" \
    "$CONNECTOR_DIST_DIR/THIRD_PARTY_NOTICES.txt"
printf 'Connector built: %s\n' "$CONNECTOR_DIST_DIR/garmin-bridge/garmin-bridge"
