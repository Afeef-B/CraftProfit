#!/bin/sh
# Build dist/CraftProfit.zip containing only the addon folder.
set -e
cd "$(dirname "$0")/.."
mkdir -p dist
rm -f dist/CraftProfit.zip
zip -qr dist/CraftProfit.zip CraftProfit
echo "dist/CraftProfit.zip"
