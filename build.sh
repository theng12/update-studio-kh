#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
IDENTITY="${KHU_SIGN_IDENTITY:-KH Studio Local Signing}"
[ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] || { echo 'A stable signing identity is required' >&2; exit 1; }
mkdir -p build
# Versioned shared inputs keep isolated builds and scoped test receipts reproducible.
python3 -B -I packaging/generate-ui.py
CORE=(Sources/KHUStub/*.swift Sources/KHUpdaterCore/*.swift build/Changelog.swift)
FLOOR="apple-macos13.0" # Match the app’s declared minimum, not this build Mac’s OS.
ARCHS="arm64 x86_64"    # Both slices: a launchd job on the other architecture must still run.

# swiftc's -target is single-arch (a second -target silently wins), so compile each arch
# into a thin sibling and merge. The kit and launcher both consume these binaries.
universal() {
  local out="$1"; shift
  local thin=() arch
  for arch in $ARCHS; do
    swiftc -parse-as-library -O -target "${arch}-${FLOOR}" -o "${out}.${arch}" "$@"
    thin+=("${out}.${arch}")
  done
  lipo -create "${thin[@]}" -output "$out"
  codesign --force --sign "$IDENTITY" --timestamp=none "$out"
  codesign --verify --strict "$out"
}
case "${1:-build}" in
  build)
    universal build/khu "${CORE[@]}" Sources/khu/*.swift
    universal build/khu-stub Sources/KHUStub/*.swift Sources/khu-stub/*.swift
    echo "built build/khu build/khu-stub (universal: $(lipo -archs build/khu))"
    ;;
  test)
    python3 -B -I Tests/test_startup_refusal.py --output "build/startup-refusal-$(uuidgen)"
    universal build/khu "${CORE[@]}" Sources/khu/*.swift
    swiftc -parse-as-library -O -target "$(uname -m)-${FLOOR}" -o build/khu-tests "${CORE[@]}" Tests/Runner/*.swift
    ./build/khu-tests
    ;;
  *)
    echo "usage: $0 [build|test]" >&2; exit 2 ;;
esac