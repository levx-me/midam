#!/bin/sh
# Builds dist/Midam-<version>-{apple-silicon,intel}.zip: one single-arch, ad-hoc signed Midam.app each.
set -eu
cd "$(dirname "$0")"
V=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
rm -rf dist
mkdir -p dist
for pair in arm64:apple-silicon x86_64:intel; do
  arch=${pair%%:*}; name=${pair##*:}
  stage=dist/stage-$arch
  ./build.sh --arch "$arch" --out "$stage"
  zip=dist/Midam-$V-$name.zip
  ditto -c -k --keepParent "$stage/Midam.app" "$zip"
  # Verify: exact arch, valid signature, Midam.app at the zip's top level.
  [ "$(lipo -archs "$stage/Midam.app/Contents/MacOS/Midam")" = "$arch" ] || { echo "wrong arch in $zip" >&2; exit 1; }
  codesign -v "$stage/Midam.app"
  unzip -Z1 "$zip" | grep -q '^Midam.app/' || { echo "Midam.app not at top of $zip" >&2; exit 1; }
  unzip -Z1 "$zip" | grep -qv '^Midam.app/' && { echo "stray top-level entries in $zip" >&2; exit 1; }
  echo "$name: $(lipo -archs "$stage/Midam.app/Contents/MacOS/Midam"), codesign ok"
done
rm -rf dist/stage-*
(cd dist && shasum -a 256 Midam-*.zip && ls -l Midam-*.zip)
