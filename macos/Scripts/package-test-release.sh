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

TEST_CERTIFICATE="$ROOT/Resources/TestSigning.crt"
IDENTITY="$(openssl x509 -in "$TEST_CERTIFICATE" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
SIGNING_SHA256="$(openssl x509 -in "$TEST_CERTIFICATE" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')"
if ! security find-identity -v -p codesigning | grep -Fq "$IDENTITY"; then
	echo 'The fixed test-signing certificate and private key are missing; refusing an ad-hoc fallback.' >&2
	exit 1
fi

# Keep the Developer ID/notarized release path and the application's storage identity unchanged.
IDENTITY="$IDENTITY" DISTRIBUTION=0 STORAGE_MODE=shared CONFIG=release \
	ARCHS="arm64 x86_64" VERSION="$VERSION" APP_PATH="$APP" \
	BUILD_NUMBER="${GITHUB_RUN_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")}" \
	bash "$ROOT/Scripts/make-app.sh"

codesign --verify --strict -R="certificate leaf = H\"$IDENTITY\"" "$APP"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p' > "$OUTPUT/signing-requirement.txt"
test -s "$OUTPUT/signing-requirement.txt"
cp "$TEST_CERTIFICATE" "$OUTPUT/TEST-SIGNING.crt"

STAGING="$(mktemp -d "$ROOT/dist/test-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
# A changed build must satisfy the old signing requirement, and vice versa (Apple TN3127).
UPGRADE_APP="$STAGING/upgrade-check/$APP_BUNDLE_NAME"
ditto "$APP" "$UPGRADE_APP"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CURRENT_BUILD.1" "$UPGRADE_APP/Contents/Info.plist"
codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements "$UPGRADE_APP"
codesign --verify --deep --strict -R "$OUTPUT/signing-requirement.txt" "$UPGRADE_APP"
codesign -d -r- "$UPGRADE_APP" 2>&1 | sed -n 's/^designated => //p' > "$STAGING/upgrade-requirement.txt"
test -s "$STAGING/upgrade-requirement.txt"
codesign --verify --strict -R "$STAGING/upgrade-requirement.txt" "$APP"
rm -rf "$STAGING/upgrade-check" "$STAGING/upgrade-requirement.txt"
echo 'Upgrade signing requirements are mutually compatible.'

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
printf 'tag=%s\ncommit=%s\narchitectures=arm64 x86_64\nsigning=fixed-self-signed\nsigning-certificate-sha256=%s\nnotarized=false\n' \
	"$TAG" "$(git -C "$REPO_ROOT" rev-parse HEAD)" "$SIGNING_SHA256" > "$OUTPUT/build-info.txt"
swift --version >> "$OUTPUT/build-info.txt"
cd "$OUTPUT"
shasum -a 256 "$(basename "$DMG")" *.wechatflow-scene.json "$SCENES_ZIP" \
	TESTING.zh-CN.md SOURCE-REVIEW.zh-CN.md build-info.txt TEST-SIGNING.crt signing-requirement.txt > SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt
