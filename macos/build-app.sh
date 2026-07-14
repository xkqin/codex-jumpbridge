#!/bin/bash

set -eu

VERSION="${1:-1.4.2}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${2:-${ROOT}/dist}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-jumpbridge-release.XXXXXX")"
APP_NAME='Codex JumpBridge.app'
APP_DIR="${WORK_DIR}/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
DMG_ROOT="${WORK_DIR}/dmg"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

mkdir -p \
    "$MACOS_DIR" \
    "${RESOURCES_DIR}/macos" \
    "${RESOURCES_DIR}/shared" \
    "$DMG_ROOT" \
    "$OUTPUT_DIR"

cp "${SCRIPT_DIR}/app-launcher.sh" "${MACOS_DIR}/CodexJumpBridge"
for name in \
    codex-jumpbridge.sh \
    doctor-macos.sh \
    install.sh \
    repair-thread-assignments.sh \
    setup-macos.sh \
    uninstall.sh; do
    cp "${SCRIPT_DIR}/${name}" "${RESOURCES_DIR}/macos/${name}"
done
cp "${ROOT}/shared/remote-prepare.sh" \
    "${RESOURCES_DIR}/shared/remote-prepare.sh"

chmod 755 \
    "${MACOS_DIR}/CodexJumpBridge" \
    "${RESOURCES_DIR}/macos/"*.sh \
    "${RESOURCES_DIR}/shared/remote-prepare.sh"

cat >"${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>Codex JumpBridge</string>
    <key>CFBundleExecutable</key>
    <string>CodexJumpBridge</string>
    <key>CFBundleIdentifier</key>
    <string>com.xkqin.codex-jumpbridge</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Codex JumpBridge</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

plutil -lint "${CONTENTS_DIR}/Info.plist"
/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

ZIP_OUTPUT="${OUTPUT_DIR}/Codex-JumpBridge-macOS-v${VERSION}.app.zip"
DMG_OUTPUT="${OUTPUT_DIR}/Codex-JumpBridge-macOS-v${VERSION}.dmg"
rm -f "$ZIP_OUTPUT" "$DMG_OUTPUT"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_OUTPUT"

cp -R "$APP_DIR" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
    -volname "Codex JumpBridge ${VERSION}" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDZO \
    "$DMG_OUTPUT"

printf '%s\n%s\n' "$ZIP_OUTPUT" "$DMG_OUTPUT"
