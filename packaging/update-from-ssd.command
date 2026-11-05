#!/bin/bash
set -euo pipefail
SSD_ROOT="$(cd "$(dirname "$0")" && pwd)"
exec /usr/bin/python3 -I "$SSD_ROOT/1 Install Apps/0 - Start here - Studio Launcher KH/update-from-ssd.py" "$SSD_ROOT"
