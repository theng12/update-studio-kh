#!/bin/bash
# Build first with ./build.sh build. The kit contains no machine credentials.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# != 2 || ! "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "usage: $0 <updater-version> <new-output-directory>" >&2; exit 2
fi
VERSION="$1"
OUT="$2"
[[ -x "$ROOT/build/khu" && -x "$ROOT/build/khu-stub" ]] || { echo 'Run ./build.sh build first.' >&2; exit 1; }
[[ ! -e "$OUT" && ! -L "$OUT" ]] || { echo 'Output already exists; choose a new directory.' >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
mkdir "$OUT"
mkdir "$OUT/bin"
cp "$ROOT/build/khu" "$ROOT/build/khu-stub" "$OUT/bin/"
cp "$ROOT/packaging/install-agent.sh" "$OUT/"
cp "$ROOT/packaging/com.khupdater.agent.plist" "$OUT/"
cp "$ROOT/examples/agent-config.json" "$OUT/agent-config.example.json"
printf '%s\n' "$VERSION" > "$OUT/VERSION"
chmod 755 "$OUT/install-agent.sh" "$OUT/bin/khu" "$OUT/bin/khu-stub"
echo "Agent kit ready at $OUT (no credentials; architecture: $(/usr/bin/lipo -archs "$OUT/bin/khu"))"
