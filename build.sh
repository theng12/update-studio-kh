#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
CORE=(Sources/KHUStub/*.swift Sources/KHUpdaterCore/*.swift)
case "${1:-build}" in
  build)
    swiftc -parse-as-library -O -o build/khu "${CORE[@]}" Sources/khu/*.swift
    swiftc -parse-as-library -O -o build/khu-stub Sources/KHUStub/*.swift Sources/khu-stub/*.swift
    echo "built build/khu build/khu-stub"
    ;;
  test)
    swiftc -parse-as-library -O -o build/khu "${CORE[@]}" Sources/khu/*.swift
    swiftc -parse-as-library -O -o build/khu-tests "${CORE[@]}" Tests/Runner/*.swift
    ./build/khu-tests
    ;;
  *)
    echo "usage: $0 [build|test]" >&2; exit 2 ;;
esac
