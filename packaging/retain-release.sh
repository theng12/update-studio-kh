#!/bin/sh
# Run only after installed acceptance and quiet/dependency checks; pins own acceptance.
set -eu
exec python3 -I "${KHU_RELEASE_DIST_TOOL:-$HOME/Developer/Shared Tools/portfolio/tools/release-dist.py}" "$@"
