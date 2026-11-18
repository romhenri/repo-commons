#!/bin/sh
# Builds dist/RepoCommons.app (unsigned) and dist/RepoCommons.zip from the Swift package. No Xcode needed.
set -eu
VERSION="${VERSION:-0.1.0}"
APP=dist/RepoCommons.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS"
# Universal binary: one build per arch, then lipo (`--arch a --arch b` would need Xcode's xcbuild).
for arch in arm64 x86_64; do swift build -c release --triple "$arch-apple-macosx14.0"; done
lipo -create -output "$APP/Contents/MacOS/RepoCommons" \
  .build/arm64-apple-macosx/release/RepoCommons .build/x86_64-apple-macosx/release/RepoCommons
# App icon: render the 1024px master, downscale into an iconset, pack as .icns.
ICONSET=.build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET" "$APP/Contents/Resources"
"$APP/Contents/MacOS/RepoCommons" --render-icon .build/icon-1024.png
for px in 16 32 128 256 512; do
  sips -z $px $px .build/icon-1024.png --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) .build/icon-1024.png --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>repo-commons</string>
  <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
  <key>CFBundleLocalizations</key><array><string>pt-BR</string></array>
  <key>CFBundleIdentifier</key><string>org.repocommons.RepoCommons</string>
  <key>CFBundleExecutable</key><string>RepoCommons</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" # ad-hoc: required to launch on Apple Silicon, not a Developer ID
(cd dist && ditto -c -k --keepParent RepoCommons.app RepoCommons.zip)
echo "built $APP"
