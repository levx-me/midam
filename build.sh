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
# The wanjang plugin, attached only to the Claude conversations Midam starts (--plugin-dir).
# Only what the plugin loads: its manifest, agents, skills, hooks and the scripts and files those use.
WANJANG=${WANJANG_DIR:-$HOME/workspace/wanjang}
if [ -f "$WANJANG/.claude-plugin/plugin.json" ]; then
  mkdir -p "$APP/Contents/Resources/wanjang"
  for f in .claude-plugin agents skills hooks bin playbooks ROUTING.md LICENSE; do
    if [ -e "$WANJANG/$f" ]; then cp -R "$WANJANG/$f" "$APP/Contents/Resources/wanjang/"; fi
  done
  find "$APP/Contents/Resources/wanjang" -name .DS_Store -delete
  # Midam never touches ~/.claude: leave out the hooks that write there: ledger (appends to
  # ~/.claude/wanjang), provider-fail (rewrites settings.json) and next (keeps state in ~/.claude/wanjang/next).
  HOOKS="$APP/Contents/Resources/wanjang/hooks/hooks.json"
  [ ! -f "$HOOKS" ] || /usr/bin/python3 - "$HOOKS" <<'PY'
import json, sys
path = sys.argv[1]
config = json.load(open(path))
for groups in config["hooks"].values():
    for g in groups:
        g["hooks"] = [h for h in g["hooks"]
                      if not any(f"/bin/{name}\"" in h.get("command", "") for name in ("ledger", "provider-fail", "next"))]
    groups[:] = [g for g in groups if g["hooks"]]
config["hooks"] = {event: groups for event, groups in config["hooks"].items() if groups}
json.dump(config, open(path, "w"), indent=2)
PY
else
  echo "warning: no wanjang plugin at $WANJANG; building without it" >&2
fi
# A local "Midam Dev" identity, when this Mac has one, keeps the signature the same across builds,
# so macOS keeps its file-access answers; otherwise ad hoc (each build asks again).
IDENTITY=-
security find-identity -p codesigning 2>/dev/null | grep -q '"Midam Dev"' && IDENTITY="Midam Dev"
codesign --force -s "$IDENTITY" "$APP"
echo "Built $APP"
[ "$INSTALL" = 1 ] || exit 0
# Replace rather than merge, so files dropped from the bundle don't linger and break the seal.
rm -rf /Applications/Midam.app
ditto "$APP" /Applications/Midam.app
codesign -v /Applications/Midam.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Midam.app
echo "Installed /Applications/Midam.app"
