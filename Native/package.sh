#!/bin/bash
# Run from any directory. Builds for iPhone; does not sign or install.
set -euo pipefail
cd "$(dirname "$0")"
out="${1:-$HOME/Downloads/CyMusic-Native}"
mkdir -p "$out"
build=$(mktemp -d "${TMPDIR%/}/cymusic-build.XXXXXX")
trap 'rm -rf "$build"' EXIT
xcodebuild -project CyMusicNative.xcodeproj -scheme CyMusic -configuration Release -destination generic/platform=iOS -derivedDataPath "$build/Derived" CODE_SIGNING_ALLOWED=NO build
mkdir "$build/Payload"
cp -R "$build/Derived/Build/Products/Release-iphoneos/CyMusic.app" "$build/Payload/"
app="$build/Payload/CyMusic.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Info.plist")
number=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Info.plist")
ipa="CyMusic-native-$version-$number-unsigned.ipa"
(cd "$build" && zip -qry -X "$ipa" Payload)
unzip -tq "$build/$ipa"
xcrun vtool -show-build "$app/CyMusic"
test -f "$app/Assets.car" && test -f "$app/PlugIns/CyMusicShare.appex/CyMusicShare"
cp "$build/$ipa" "$out/$ipa"
shasum -a 256 "$out/$ipa"
