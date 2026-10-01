#!/bin/bash
# Builds dist/OrbitDrop.app from the Swift package.
#
#   bash scripts/build-app.sh           build the bundle
#   bash scripts/build-app.sh --sign    also apply an ad hoc code signature
#
# The script only writes inside this repository's .build/ and dist/ folders.
# It does not install, launch, notarize or change any system setting.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIGN=0
for argument in "$@"; do
    case "$argument" in
        --sign) SIGN=1 ;;
        -h|--help)
            sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $argument" >&2
            exit 2
            ;;
    esac
done

VERSION="0.1.0"
BUNDLE_ID="life.nftstory.orbitdrop"
APP="$ROOT/dist/OrbitDrop.app"

echo "==> swift build (release)"
swift build -c release --product OrbitDrop
swift build -c release --product orbitdrop-cli
BIN="$(swift build -c release --show-bin-path)"

echo "==> assembling $APP"
# Only the previously generated bundle inside dist/ is replaced.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/OrbitDrop" "$APP/Contents/MacOS/OrbitDrop"
cp "$BIN/orbitdrop-cli" "$APP/Contents/Helpers/orbitdrop-cli"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>OrbitDrop</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>OrbitDrop</string>
    <key>CFBundleDisplayName</key>
    <string>OrbitDrop</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License. OrbitDrop contributors.</string>
</dict>
</plist>
PLIST

# Optional icon, drawn natively by scripts/make-icon.swift. The app works
# without it (the menu bar item uses an SF Symbol).
ICONSET="$ROOT/.build/AppIcon.iconset"
rm -rf "$ICONSET"
if swift "$ROOT/scripts/make-icon.swift" "$ICONSET" >/dev/null 2>&1 \
    && iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET" >/dev/null 2>&1; then
    echo "==> icon generated"
else
    echo "==> icon skipped (generation unavailable); continuing without one"
fi

if [ "$SIGN" -eq 1 ]; then
    echo "==> ad hoc code signature"
    codesign --force --sign - "$APP/Contents/Helpers/orbitdrop-cli"
    codesign --force --sign - "$APP"
fi

echo "==> done: $APP"
echo "    Not installed and not launched. Open it yourself when ready:"
echo "    open \"$APP\""
