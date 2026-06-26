#!/usr/bin/env bash
set -euo pipefail

# Build an unsigned macOS .pkg installer.
#
# The package installs:
#   /usr/local/bin/doubao-voice
#   /usr/local/bin/doubao-voice-authorize
#   /Applications/DoubaoVoiceCLI.app
#   /usr/local/share/doubao-ime-cli/docs/*
#
# It also runs packaging/scripts/postinstall, which opens the Accessibility
# permission flow for the logged-in user. The script cannot approve permission
# automatically because macOS requires explicit user consent.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
LANGUAGE="${LANGUAGE:-zh-Hans}"
BINARY="${BINARY:-doubao-voice}"
IDENTIFIER="${IDENTIFIER:-dev.doubao-ime-cli.doubao-voice}"
export COPYFILE_DISABLE=1

case "$LANGUAGE" in
  zh|zh-Hans|zh_CN|zh-CN|chinese)
    LANGUAGE="zh-Hans"
    PKG_SUFFIX=""
    INSTALLER_TITLE="豆包输入法 CLI"
    APP_DISPLAY_NAME="豆包 Voice CLI"
    MICROPHONE_USAGE="用于智能判停：本地检测你是否开始/停止说话，不上传音频。"
    ;;
  en|en-US|english)
    LANGUAGE="en"
    PKG_SUFFIX="-en"
    INSTALLER_TITLE="Doubao Voice CLI"
    APP_DISPLAY_NAME="Doubao Voice CLI"
    MICROPHONE_USAGE="Used for smart endpointing: detect locally whether you start or stop speaking. Audio is not uploaded."
    ;;
  *)
    echo "Unsupported LANGUAGE: $LANGUAGE" >&2
    echo "Use LANGUAGE=zh-Hans or LANGUAGE=en" >&2
    exit 2
    ;;
esac

BUILD_DIR="$ROOT_DIR/build"
FSMN_RUNTIME_DIR="$BUILD_DIR/fsmn-runtime"
PKG_ROOT="$BUILD_DIR/pkg-root"
APP_ROOT="$BUILD_DIR/app-root"
PKG_SCRIPTS="$BUILD_DIR/pkg-scripts"
APP_BUNDLE_NAME="DoubaoVoiceCLI.app"
CLI_PKG="$BUILD_DIR/doubao-ime-cli-cli.pkg"
APP_PKG="$BUILD_DIR/doubao-ime-cli-helper.pkg"
APP_COMPONENT_PLIST="$BUILD_DIR/helper-component.plist"
DISTRIBUTION_XML="$BUILD_DIR/Distribution.xml"
RESOURCES_DIR="$BUILD_DIR/pkg-resources"
DIST_DIR="$ROOT_DIR/dist"
PKG_PATH="$DIST_DIR/doubao-ime-cli-$VERSION$PKG_SUFFIX.pkg"
PKGBUILD_FILTERS=(--filter '(^|/)\._' --filter '(^|/)\.DS_Store$')

cd "$ROOT_DIR"
make build BINARY="$BINARY" VERSION="$VERSION"
"$ROOT_DIR/scripts/build-fsmn-runtime.sh" "$FSMN_RUNTIME_DIR"

rm -rf "$PKG_ROOT" "$APP_ROOT" "$PKG_SCRIPTS"
mkdir -p "$PKG_ROOT/usr/local/bin"
mkdir -p "$APP_ROOT/Applications"
mkdir -p "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs"
mkdir -p "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/zh-Hans"
mkdir -p "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/en"
mkdir -p "$PKG_ROOT/usr/local/share/doubao-ime-cli/scripts"
mkdir -p "$PKG_SCRIPTS" "$DIST_DIR"

rm -rf "$RESOURCES_DIR"
mkdir -p "$RESOURCES_DIR"
cp -R "$ROOT_DIR/packaging/resources/en.lproj" "$RESOURCES_DIR/"
cp -R "$ROOT_DIR/packaging/resources/zh_CN.lproj" "$RESOURCES_DIR/"

install -m 0755 "$BUILD_DIR/$BINARY" "$PKG_ROOT/usr/local/bin/doubao-voice"
install -m 0755 "$ROOT_DIR/scripts/doubao-voice-authorize.sh" "$PKG_ROOT/usr/local/bin/doubao-voice-authorize"
install -m 0755 "$ROOT_DIR/scripts/doubao-voice-install-fsmn-vad.sh" "$PKG_ROOT/usr/local/bin/doubao-voice-install-fsmn-vad"
install -m 0755 "$ROOT_DIR/scripts/fsmn_vad_worker.py" "$PKG_ROOT/usr/local/share/doubao-ime-cli/scripts/fsmn_vad_worker.py"
/usr/bin/ditto --norsrc --noextattr "$FSMN_RUNTIME_DIR" "$PKG_ROOT/usr/local/share/doubao-ime-cli/fsmn-runtime"
/usr/bin/ditto --norsrc --noextattr "$BUILD_DIR/$APP_BUNDLE_NAME" "$APP_ROOT/Applications/$APP_BUNDLE_NAME"
/usr/bin/plutil -replace CFBundleDisplayName -string "$APP_DISPLAY_NAME" "$APP_ROOT/Applications/$APP_BUNDLE_NAME/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string "$APP_DISPLAY_NAME" "$APP_ROOT/Applications/$APP_BUNDLE_NAME/Contents/Info.plist"
/usr/bin/plutil -replace DoubaoVoiceDefaultLanguage -string "$LANGUAGE" "$APP_ROOT/Applications/$APP_BUNDLE_NAME/Contents/Info.plist"
/usr/bin/plutil -replace NSMicrophoneUsageDescription -string "$MICROPHONE_USAGE" "$APP_ROOT/Applications/$APP_BUNDLE_NAME/Contents/Info.plist"
if [ "$LANGUAGE" = "en" ]; then
  /usr/bin/plutil -replace CFBundleDevelopmentRegion -string "en" "$APP_ROOT/Applications/$APP_BUNDLE_NAME/Contents/Info.plist"
else
  /usr/bin/plutil -replace CFBundleDevelopmentRegion -string "zh_CN" "$APP_ROOT/Applications/$APP_BUNDLE_NAME/Contents/Info.plist"
fi

install -m 0644 "$ROOT_DIR/README.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/README.zh-Hans.md"
install -m 0644 "$ROOT_DIR/README.en.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/README.en.md"

install -m 0644 "$ROOT_DIR/docs/USAGE.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/zh-Hans/USAGE.md"
install -m 0644 "$ROOT_DIR/docs/VOICE_ASSISTANT_PROMPT.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/zh-Hans/VOICE_ASSISTANT_PROMPT.md"
install -m 0644 "$ROOT_DIR/docs/REVERSE_ENGINEERING.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/zh-Hans/REVERSE_ENGINEERING.md"
install -m 0644 "$ROOT_DIR/docs/DIRECT_ENTRY_RESEARCH.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/zh-Hans/DIRECT_ENTRY_RESEARCH.md"

install -m 0644 "$ROOT_DIR/docs/en/USAGE.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/en/USAGE.md"
install -m 0644 "$ROOT_DIR/docs/en/VOICE_ASSISTANT_PROMPT.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/en/VOICE_ASSISTANT_PROMPT.md"
install -m 0644 "$ROOT_DIR/docs/en/REVERSE_ENGINEERING.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/en/REVERSE_ENGINEERING.md"
install -m 0644 "$ROOT_DIR/docs/en/DIRECT_ENTRY_RESEARCH.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/en/DIRECT_ENTRY_RESEARCH.md"

if [ "$LANGUAGE" = "en" ]; then
  install -m 0644 "$ROOT_DIR/README.en.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/README.md"
  install -m 0644 "$ROOT_DIR/docs/en/USAGE.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/USAGE.md"
  install -m 0644 "$ROOT_DIR/docs/en/VOICE_ASSISTANT_PROMPT.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/VOICE_ASSISTANT_PROMPT.md"
  install -m 0644 "$ROOT_DIR/docs/en/REVERSE_ENGINEERING.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/REVERSE_ENGINEERING.md"
  install -m 0644 "$ROOT_DIR/docs/en/DIRECT_ENTRY_RESEARCH.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/DIRECT_ENTRY_RESEARCH.md"
else
  install -m 0644 "$ROOT_DIR/README.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/README.md"
  install -m 0644 "$ROOT_DIR/docs/USAGE.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/USAGE.md"
  install -m 0644 "$ROOT_DIR/docs/VOICE_ASSISTANT_PROMPT.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/VOICE_ASSISTANT_PROMPT.md"
  install -m 0644 "$ROOT_DIR/docs/REVERSE_ENGINEERING.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/REVERSE_ENGINEERING.md"
  install -m 0644 "$ROOT_DIR/docs/DIRECT_ENTRY_RESEARCH.md" "$PKG_ROOT/usr/local/share/doubao-ime-cli/docs/DIRECT_ENTRY_RESEARCH.md"
fi

install -m 0755 "$ROOT_DIR/packaging/scripts/postinstall" "$PKG_SCRIPTS/postinstall"
/usr/bin/sed -i '' "s/^PACKAGE_LANGUAGE=.*/PACKAGE_LANGUAGE=\"$LANGUAGE\"/" "$PKG_SCRIPTS/postinstall"

cat > "$APP_COMPONENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>BundleHasStrictIdentifier</key>
    <true/>
    <key>BundleIsRelocatable</key>
    <false/>
    <key>BundleIsVersionChecked</key>
    <true/>
    <key>BundleOverwriteAction</key>
    <string>upgrade</string>
    <key>RootRelativeBundlePath</key>
    <string>Applications/$APP_BUNDLE_NAME</string>
  </dict>
</array>
</plist>
EOF

find "$PKG_ROOT" "$APP_ROOT" "$PKG_SCRIPTS" -name '._*' -delete
xattr -cr "$PKG_ROOT" "$APP_ROOT" "$PKG_SCRIPTS" 2>/dev/null || true
find "$PKG_ROOT" "$APP_ROOT" "$PKG_SCRIPTS" -exec xattr -d com.apple.provenance {} \; 2>/dev/null || true
find "$PKG_ROOT" "$APP_ROOT" "$PKG_SCRIPTS" -name '._*' -delete
rm -f "$PKG_PATH" "$CLI_PKG" "$APP_PKG" "$DISTRIBUTION_XML"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  pkgbuild \
    "${PKGBUILD_FILTERS[@]}" \
    --root "$PKG_ROOT" \
    --scripts "$PKG_SCRIPTS" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location "/" \
    --sign "$SIGN_IDENTITY" \
    "$CLI_PKG"
  pkgbuild \
    "${PKGBUILD_FILTERS[@]}" \
    --root "$APP_ROOT" \
    --component-plist "$APP_COMPONENT_PLIST" \
    --identifier "dev.doubao-ime-cli.helper" \
    --version "$VERSION" \
    --install-location "/" \
    --sign "$SIGN_IDENTITY" \
    "$APP_PKG"
else
  pkgbuild \
    "${PKGBUILD_FILTERS[@]}" \
    --root "$PKG_ROOT" \
    --scripts "$PKG_SCRIPTS" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location "/" \
    "$CLI_PKG"
  pkgbuild \
    "${PKGBUILD_FILTERS[@]}" \
    --root "$APP_ROOT" \
    --component-plist "$APP_COMPONENT_PLIST" \
    --identifier "dev.doubao-ime-cli.helper" \
    --version "$VERSION" \
    --install-location "/" \
    "$APP_PKG"
fi

cat > "$DISTRIBUTION_XML" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>INSTALLER_TITLE</title>
  <welcome file="Welcome.html" mime-type="text/html"/>
  <readme file="ReadMe.html" mime-type="text/html"/>
  <conclusion file="Conclusion.html" mime-type="text/html"/>
  <options customize="never" require-scripts="true" hostArchitectures="arm64,x86_64"/>
  <choices-outline>
    <line choice="default"/>
  </choices-outline>
  <choice id="default" title="CHOICE_TITLE" description="CHOICE_DESC">
    <pkg-ref id="$IDENTIFIER"/>
    <pkg-ref id="dev.doubao-ime-cli.helper"/>
  </choice>
  <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">doubao-ime-cli-cli.pkg</pkg-ref>
  <pkg-ref id="dev.doubao-ime-cli.helper" version="$VERSION" onConclusion="none">doubao-ime-cli-helper.pkg</pkg-ref>
</installer-gui-script>
EOF

if [ -n "${SIGN_IDENTITY:-}" ]; then
  productbuild \
    --distribution "$DISTRIBUTION_XML" \
    --resources "$RESOURCES_DIR" \
    --package-path "$BUILD_DIR" \
    --sign "$SIGN_IDENTITY" \
    "$PKG_PATH"
else
  productbuild \
    --distribution "$DISTRIBUTION_XML" \
    --resources "$RESOURCES_DIR" \
    --package-path "$BUILD_DIR" \
    "$PKG_PATH"
fi

echo
echo "Built installer:"
echo "  $PKG_PATH"
echo "Language:"
echo "  $LANGUAGE"
echo
echo "Install with:"
echo "  sudo installer -pkg \"$PKG_PATH\" -target /"
