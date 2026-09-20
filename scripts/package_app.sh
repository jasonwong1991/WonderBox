#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${CONFIGURATION:-release}"
APP="$ROOT/build/WonderBox.app"
CONTENTS="$APP/Contents"
BIN_DIR="$ROOT/.build/$CONFIGURATION"

cd "$ROOT"
swift build -c "$CONFIGURATION"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources"
cp "$BIN_DIR/WonderBox" "$CONTENTS/MacOS/WonderBox"
cp "$BIN_DIR/WonderFanHelper" "$CONTENTS/Helpers/WonderFanHelper"
cp "$BIN_DIR/WonderMaintenanceHelper" "$CONTENTS/Helpers/WonderMaintenanceHelper"
cp "Sources/WonderBox/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "Sources/WonderBox/Resources/PrivacyInfo.xcprivacy" "$CONTENTS/Resources/PrivacyInfo.xcprivacy"
cp "Sources/WonderBox/Resources/com.wondercraft.WonderBox.FanHelper.plist" "$CONTENTS/Resources/com.wondercraft.WonderBox.FanHelper.plist"

swift scripts/generate_icon.swift "$ROOT/build/AppIcon-1024.png"
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/build/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ROOT/build/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
rm -rf "$ICONSET"

codesign --force --sign - "$CONTENTS/Helpers/WonderFanHelper"
codesign --force --sign - "$CONTENTS/Helpers/WonderMaintenanceHelper"
codesign --force --deep --sign - "$APP"

echo "$APP"
