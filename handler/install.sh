#!/bin/bash
set -e

APP_NAME="ClaudeReview"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Claude Code Review - URL Handler Installer ==="
echo ""

# Remove old version if present
rm -rf "${APP_DIR}"

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
  <string>com.claude-code-review.handler</string>
  <key>CFBundleName</key>
  <string>ClaudeReview</string>
  <key>CFBundleDisplayName</key>
  <string>Claude Code Review</string>
  <key>CFBundleVersion</key>
  <string>1.0.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>ClaudeReview</string>
  <key>LSBackgroundOnly</key>
  <true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>Claude Code Review URL</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>claude-review</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Compile the Swift handler, replacing the home dir placeholder
echo "Compiling URL handler ..."
SWIFT_SRC=$(mktemp /tmp/claude-review-XXXXXX.swift)
sed "s|HOME_DIR_PLACEHOLDER|${HOME}|g" "${SCRIPT_DIR}/ClaudeReviewHandler.swift" > "$SWIFT_SRC"
swiftc -o "${APP_DIR}/Contents/MacOS/ClaudeReview" "$SWIFT_SRC" -framework Cocoa
rm -f "$SWIFT_SRC"

# Register the URL scheme with Launch Services
echo "Registering claude-review:// URL scheme ..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -R "${APP_DIR}"

echo ""
echo "Done! Installation complete."
echo ""
echo "What was installed:"
echo "  - ${APP_DIR} (URL scheme handler)"
echo "  - claude-review:// URL scheme registered"
echo ""
echo "Next steps:"
echo "  1. Load the Chrome extension from the extension/ directory"
echo "     (chrome://extensions > Developer mode > Load unpacked)"
echo "  2. Navigate to any GitHub PR"
echo "  3. Click the 'Review with Claude Code' button"
echo ""
echo "To uninstall:"
echo "  rm -rf '${APP_DIR}'"
