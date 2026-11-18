#!/bin/bash
# Uso: ./build.sh <arm64|x86_64> <apple-silicon|intel>
set -euo pipefail
ARCH="$1"; LABEL="$2"; NAME="Workout Designer"

swift build -c release --arch "$ARCH"
BIN="$(swift build -c release --arch "$ARCH" --show-bin-path)/WorkoutDesigner"

OUT="build/$LABEL"; APP="$OUT/$NAME.app"
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WorkoutDesigner"
cp Resources/index.html "$APP/Contents/Resources/index.html"
cp Info.plist "$APP/Contents/Info.plist"

# Icono
ICONSET="$OUT/AppIcon.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Firma ad hoc (obligatoria para que arranque en Apple Silicon)
codesign --force --deep --sign - "$APP"

# DMG con acceso directo a Aplicaciones
STAGE="$OUT/dmg"; mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "WorkoutDesigner-$LABEL.dmg"
echo "Listo: WorkoutDesigner-$LABEL.dmg"
