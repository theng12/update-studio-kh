#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
# CHANGELOG.md is compiled in, so the status page shows this build's version and what's new.
{ printf 'public enum Changelog {\n    public static let text = #"""\n'; cat CHANGELOG.md; printf '"""#\n    public static let launcher = #"""\n'; cat CHANGELOG-launcher.md; printf '"""#\n}\n'; } > build/Changelog.swift
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
}
case "${1:-build}" in
  build)
    universal build/khu "${CORE[@]}" Sources/khu/*.swift
    universal build/khu-stub Sources/KHUStub/*.swift Sources/khu-stub/*.swift
    echo "built build/khu build/khu-stub (universal: $(lipo -archs build/khu))"
    ;;
  test)
    universal build/khu "${CORE[@]}" Sources/khu/*.swift
    swiftc -parse-as-library -O -target "$(uname -m)-${FLOOR}" -o build/khu-tests "${CORE[@]}" Tests/Runner/*.swift
    ./build/khu-tests
    ;;
  *)
    echo "usage: $0 [build|test]" >&2; exit 2 ;;
esac