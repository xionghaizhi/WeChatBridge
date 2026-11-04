#!/usr/bin/env bash
set -euo pipefail

TAG="${1:?Usage: package-test-release.sh vX.Y.Z[-test.N]}"
if [[ ! "$TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-test\.[0-9]+)?$ ]]; then
	echo 'Use vX.Y.Z or vX.Y.Z-test.N.' >&2
	exit 1
fi
VERSION="${BASH_REMATCH[1]}"
if [ "$(uname -s)" != Darwin ]; then
	echo 'This package requires macOS and Xcode.' >&2
	exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
source "$ROOT/Scripts/share-slots.sh"
OUTPUT="$ROOT/dist/test-release"
APP="$ROOT/dist/$APP_BUNDLE_NAME"
mkdir -p "$OUTPUT"
cd "$ROOT"

# Keep the certificate-based, notarized release path separate and unchanged.
IDENTITY=- DISTRIBUTION=0 STORAGE_MODE=shared CONFIG=release \
	ARCHS="arm64 x86_64" VERSION="$VERSION" APP_PATH="$APP" \
	BUILD_NUMBER="${GITHUB_RUN_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")}" \
	bash "$ROOT/Scripts/make-app.sh"

STAGING="$(mktemp -d "$ROOT/dist/test-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/$APP_BUNDLE_NAME"
ln -s /Applications "$STAGING/Applications"
DMG="$OUTPUT/WeChatBridge-$TAG-macos-universal-test.dmg"
# A plain DMG avoids Finder automation on a headless CI runner.
hdiutil create -volname "WeChatBridge $VERSION Test" -srcfolder "$STAGING" \
	-format UDZO -ov "$DMG"
hdiutil verify "$DMG"

cp "$REPO_ROOT/shared/Scenes/"*.wechatflow-scene.json "$OUTPUT/"
SCENES_ZIP="WeChatBridge-$TAG-scenes.zip"
/usr/bin/zip -j "$OUTPUT/$SCENES_ZIP" "$REPO_ROOT/shared/Scenes/"*.wechatflow-scene.json
cp "$REPO_ROOT/docs/macos-test-release.zh-CN.md" "$OUTPUT/TESTING.zh-CN.md"
cp "$REPO_ROOT/docs/macos-source-review.zh-CN.md" "$OUTPUT/SOURCE-REVIEW.zh-CN.md"
printf 'tag=%s\ncommit=%s\narchitectures=arm64 x86_64\nsigning=ad-hoc\nnotarized=false\n' \
	"$TAG" "$(git -C "$REPO_ROOT" rev-parse HEAD)" > "$OUTPUT/build-info.txt"
swift --version >> "$OUTPUT/build-info.txt"
cd "$OUTPUT"
shasum -a 256 "$(basename "$DMG")" *.wechatflow-scene.json "$SCENES_ZIP" \
	TESTING.zh-CN.md SOURCE-REVIEW.zh-CN.md build-info.txt > SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt
