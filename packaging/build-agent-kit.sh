#!/bin/bash
# Build first with ./build.sh build (universal arm64+x86_64). The kit contains no machine credentials.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# != 2 || ! "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "usage: $0 <updater-version> <new-output-directory>" >&2; exit 2
fi
VERSION="$1"
OUT="$2"
[[ -x "$ROOT/build/khu" && -x "$ROOT/build/khu-stub" ]] || { echo 'Run ./build.sh build first.' >&2; exit 1; }
# Both slices, or a Mac of the other architecture installs a helper that cannot launch.
# lipo resolves from PATH like every other command, so the packaging test can stand in a fake.
for bin in khu khu-stub; do
    archs="$(lipo -archs "$ROOT/build/$bin" 2>/dev/null || true)"
    if [[ " $archs " != *" arm64 "* || " $archs " != *" x86_64 "* ]]; then
        echo "build/$bin must be universal arm64+x86_64 (found: ${archs:-not a Mach-O}); run ./build.sh build." >&2
        exit 1
    fi
done
[[ ! -e "$OUT" && ! -L "$OUT" ]] || { echo 'Output already exists; choose a new directory.' >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
mkdir "$OUT"
mkdir "$OUT/bin"
cp "$ROOT/build/khu" "$ROOT/build/khu-stub" "$OUT/bin/"
# The icon only names the background bundles; a kit built before the app still installs.
if [[ -f "$ROOT/build/AppIcon.icns" ]]; then cp "$ROOT/build/AppIcon.icns" "$OUT/"; fi
cp "$ROOT/packaging/install-agent.sh" "$ROOT/packaging/fleet-roster.json" "$OUT/"
cp "$ROOT/packaging/com.khupdater.agent.plist" "$OUT/"
cp "$ROOT/examples/agent-config.json" "$OUT/agent-config.example.json"
printf '%s\n' "$VERSION" > "$OUT/VERSION"
chmod 755 "$OUT/install-agent.sh" "$OUT/bin/khu" "$OUT/bin/khu-stub"
if [[ -f "$OUT/AppIcon.icns" ]]; then chmod 644 "$OUT/AppIcon.icns"; fi
echo "Agent kit ready at $OUT (no credentials; architecture: $(/usr/bin/lipo -archs "$OUT/bin/khu"))"
