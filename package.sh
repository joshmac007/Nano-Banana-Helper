#!/bin/bash

# Nano Banana Helper Packaging Script
# Requires 'create-dmg' (brew install create-dmg)

APP_NAME="Nano Banana Helper"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="NanoBananaHelper.dmg"
ICON_PATH="Nano Banana Helper/Assets.xcassets/AppIcon.appiconset/512.png"

# Ensure we are in the project root
cd "$(dirname "$0")"

# Check for create-dmg
if ! command -v create-dmg &> /dev/null; then
    echo "Error: 'create-dmg' is not installed."
    echo "Please install it using: brew install create-dmg"
    exit 1
fi

# Verify app bundle exists
if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: $APP_BUNDLE not found."
    echo "Please build the app in Xcode first."
    exit 1
fi

echo "--- Packaging $APP_NAME ---"

# Remove existing DMG
if [ -f "$DMG_NAME" ]; then
    echo "Removing existing $DMG_NAME..."
    rm "$DMG_NAME"
fi

# Create DMG
echo "Generating DMG..."
create-dmg \
  --volname "${APP_NAME}" \
  --volicon "${ICON_PATH}" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "${APP_BUNDLE}" 150 175 \
  --hide-extension "${APP_BUNDLE}" \
  --app-drop-link 450 175 \
  "${DMG_NAME}" \
  "${APP_BUNDLE}"

if [ $? -eq 0 ]; then
    echo "--------------------------"
    echo "SUCCESS: $DMG_NAME created."
    echo "--------------------------"
else
    echo "FAILURE: Failed to create DMG."
    exit 1
fi
