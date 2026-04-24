#!/bin/bash
set -e

APP_NAME="AgentPRReview"
LEGACY_APP_NAME="GitHubPRReview"
OLDEST_LEGACY_APP_NAME="ClaudeReview"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
LEGACY_APP_DIR="$HOME/Applications/${LEGACY_APP_NAME}.app"
OLDEST_LEGACY_APP_DIR="$HOME/Applications/${OLDEST_LEGACY_APP_NAME}.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Agent PR Review Launcher - URL Handler Installer ==="
echo ""

# Remove current and legacy versions if present
rm -rf "${APP_DIR}"
rm -rf "${LEGACY_APP_DIR}"
rm -rf "${OLDEST_LEGACY_APP_DIR}"

echo "Creating ${APP_NAME}.app in ~/Applications/ ..."
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Write Info.plist
cat > "${APP_DIR}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.agent-pr-review.handler</string>
  <key>CFBundleName</key>
  <string>AgentPRReview</string>
  <key>CFBundleDisplayName</key>
  <string>Agent PR Review</string>
  <key>CFBundleVersion</key>
  <string>1.0.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>AgentPRReview</string>
  <key>LSBackgroundOnly</key>
  <true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>Agent PR Review URL</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>agent-pr-review</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Compile the Swift handler, replacing the home dir placeholder
echo "Compiling URL handler ..."
SWIFT_SRC=$(mktemp /tmp/agent-pr-review-XXXXXX.swift)
sed "s|HOME_DIR_PLACEHOLDER|${HOME}|g" "${SCRIPT_DIR}/ClaudeReviewHandler.swift" > "$SWIFT_SRC"
swiftc -o "${APP_DIR}/Contents/MacOS/AgentPRReview" "$SWIFT_SRC" -framework Cocoa
rm -f "$SWIFT_SRC"

# Register the URL scheme with Launch Services
echo "Registering agent-pr-review:// URL scheme ..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -R "${APP_DIR}"

echo ""
echo "Done! Installation complete."
echo ""
echo "What was installed:"
echo "  - ${APP_DIR} (URL scheme handler)"
echo "  - agent-pr-review:// URL scheme registered"
echo ""
echo "Next steps:"
echo "  1. Load the Chrome extension from the extension/ directory"
echo "     (chrome://extensions > Developer mode > Load unpacked)"
echo "  2. Navigate to any GitHub PR"
echo "  3. Use the review launcher in the PR header"
echo ""
echo "To uninstall:"
echo "  rm -rf '${APP_DIR}' '${LEGACY_APP_DIR}' '${OLDEST_LEGACY_APP_DIR}'"
