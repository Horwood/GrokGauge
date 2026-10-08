#!/usr/bin/env bash
# Build GrokGauge.app with Swift Package Manager only (Xcode not required).
#
#   ./scripts/build-app.sh                  # universal (arm64 + x86_64) when possible
#   ARCHS=arm64 ./scripts/build-app.sh      # Apple silicon only
#   VERSION=1.2.3 ./scripts/build-app.sh    # override version (defaults to ./VERSION)
#   REQUIRE_UNIVERSAL=1 ...                 # fail instead of falling back to fewer archs (CI)
#   CODESIGN_IDENTITY="Developer ID Application: …"  # default "-" (ad-hoc)
#   SWIFT_BUILD_SYSTEM=swiftbuild           # default "native" (the newer swiftbuild engine
#                                           # fails to initialize with Command Line Tools only)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="GrokGauge"
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCHS="${ARCHS:-arm64 x86_64}"
MIN_MACOS="14.0"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
IDENTITY="${CODESIGN_IDENTITY:--}"
BUILD_SYSTEM="${SWIFT_BUILD_SYSTEM:-native}"

echo "==> GrokGauge $VERSION ($BUILD_NUMBER) for: $ARCHS"
rm -rf "$DIST"
mkdir -p "$DIST"

binaries=()
for arch in $ARCHS; do
  triple="${arch}-apple-macosx${MIN_MACOS}"
  echo "==> swift build ($triple)"
  if swift build -c release --build-system "$BUILD_SYSTEM" --product "$APP_NAME" --triple "$triple"; then
    bin_dir="$(swift build -c release --build-system "$BUILD_SYSTEM" --triple "$triple" --show-bin-path)"
    binaries+=("$bin_dir/$APP_NAME")
  elif [[ "${REQUIRE_UNIVERSAL:-0}" == "1" ]]; then
    echo "error: build for $arch failed" >&2
    exit 1
  else
    echo "warning: build for $arch failed; continuing without it" >&2
  fi
done
[[ ${#binaries[@]} -gt 0 ]] || { echo "error: nothing built" >&2; exit 1; }

echo "==> Assembling $APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" \
  Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/retrocombs-logo.png "$APP/Contents/Resources/retrocombs-logo.png"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Codesigning (identity: $IDENTITY)"
sign_args=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then sign_args+=(--options runtime --timestamp); fi
codesign "${sign_args[@]}" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "==> Zipping"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

echo "==> Done"
lipo -archs "$APP/Contents/MacOS/$APP_NAME" | sed 's/^/    archs: /'
echo "    app:   $APP"
echo "    zip:   $ZIP"
echo "    sha256: $(cut -d' ' -f1 < "$ZIP.sha256")"
