#!/bin/bash
set -euo pipefail
SSD_ROOT="$(cd "$(dirname "$0")" && pwd)"
exec /bin/bash "$SSD_ROOT/1 Install Apps/0 - Start here - Studio Launcher KH/update-from-ssd.sh" "$SSD_ROOT"
