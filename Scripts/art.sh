#!/usr/bin/env bash
#
# Packs the game's asset catalogs into its Android art (index.json and its
# pages) with Tools/Art/pack.js: the packer under its memory guard, the ASTC
# encoder built the first time, and an optional cache keyed by the inputs.
# A game runs it through its own Android/Scripts/art.sh, its catalogs and
# output in runtime.sh (README, "Packing a game's art").
#
#   Scripts/art.sh [--png] [--out <dir>] [--cache <dir>]
set -euo pipefail
exec node "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Tools/Art/pack.js" "$@"
