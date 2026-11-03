#!/bin/sh
# Builds build/Midam.app and installs it to /Applications (skip with --no-install).
# Never launches or quits the app: if Midam is running, relaunch it to see the new build.
set -eu
cd "$(dirname "$0")"
INSTALL=1
SWIFTFLAGS=""
OUT=build
# --arch/--out are used by release.sh: a single-arch build in its own scratch path, never installed.
while [ $# -gt 0 ]; do
  case "$1" in
    --no-install) INSTALL=0 ;;
    --arch) [ $# -ge 2 ] || { echo "--arch needs a value" >&2; exit 2; }; INSTALL=0; SWIFTFLAGS="--arch $2 --scratch-path .build-$2"; shift ;;
    --out) [ $# -ge 2 ] || { echo "--out needs a value" >&2; exit 2; }; OUT=$2; shift ;;
    *) echo "usage: $0 [--no-install] [--arch arm64|x86_64 --out DIR]" >&2; exit 2 ;;
  esac
  shift
done
# shellcheck disable=SC2086
swift build -c release $SWIFTFLAGS
APP=$OUT/Midam.app
mkdir -p "$OUT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp "$(swift build -c release $SWIFTFLAGS --show-bin-path)/Midam" "$APP/Contents/MacOS/Midam"
cp -R Resources/ "$APP/Contents/Resources/"
# The ink accent (Assets.xcassets/AccentColor, named by NSAccentColorName in Info.plist).
xcrun actool Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --output-partial-info-plist "$OUT/assets-partial.plist" >/dev/null
codesign --force -s - "$APP"
echo "Built $APP"
[ "$INSTALL" = 1 ] || exit 0
# Replace rather than merge, so files dropped from the bundle don't linger and break the seal.
rm -rf /Applications/Midam.app
ditto "$APP" /Applications/Midam.app
codesign -v /Applications/Midam.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Midam.app
echo "Installed /Applications/Midam.app"
