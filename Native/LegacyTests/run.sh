#!/bin/sh
set -eu
native=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/Sources"
cp "$native/App/Song.swift" "$native/Library/Library.swift" "$native/Library/LegacyMigration.swift" "$native/LegacyTests/LegacyMigrationTests.swift" "$tmp/Sources/"
ln -s "$native/Vendor/MMKV" "$tmp/MMKV"
cp "$native/LegacyTests/Harness.swiftmanifest" "$tmp/Package.swift"
swift run --package-path "$tmp" Probe
