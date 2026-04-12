#!/bin/bash
set -euo pipefail

# DMG build script for Nano Banana Helper
# Follows patterns from the industry-proven create-dmg tool:
#   - Two-step process: UDRW → customize → UDZO
#   - Mount in /Volumes for Finder visibility
#   - Pass volume name to AppleScript as argument
#   - Wait for .DS_Store before unmounting
#   - Retry logic for detach

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="Nano Banana Helper"
SCHEME="Nano Banana Helper"
TEAM="46BZ85ALNS"
DERIVED_DATA_DIR="$PROJECT_DIR/DerivedData"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log()  { echo "$@"; }
ok()   { echo -e "${GREEN}✓${NC} $@"; }
fail() { echo -e "${RED}✗${NC} $@"; exit 1; }

# ── 1. Clean derived data ───────────────────────────────────────────
log "Cleaning derived data..."
rm -rf "$DERIVED_DATA_DIR/Nano_Banana_Helper-"*
ok "Derived data cleaned"

# ── 2. Build Release ────────────────────────────────────────────────
log "Building Release..."
cd "$PROJECT_DIR"
BUILD_OUTPUT=$(xcodebuild \
    -project "$PROJECT_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    DEVELOPMENT_TEAM="$TEAM" \
    MACOSX_DEPLOYMENT_TARGET=26.2 \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    2>&1)

echo "$BUILD_OUTPUT" | tail -3
echo "$BUILD_OUTPUT" | grep -q "BUILD SUCCEEDED" || fail "Build failed"

# Find the built app
APP_PATH=$(find "$DERIVED_DATA_DIR" -path "*/Release/$PROJECT_NAME.app" -type d | head -1)
[ -z "$APP_PATH" ] && fail "Could not find built .app"

# ── 3. Stage contents ───────────────────────────────────────────────
STAGING=$(mktemp -d)
DMG_PATH="$PROJECT_DIR/$PROJECT_NAME.dmg"
DMG_TEMP="$PROJECT_DIR/rw.dmg"

log "Preparing DMG layout..."
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# ── 4. Create read-write DMG ────────────────────────────────────────
log "Creating read-write DMG..."
rm -f "$DMG_TEMP"
hdiutil create \
    -volname "$PROJECT_NAME" \
    -fs HFS+ \
    -srcfolder "$STAGING" \
    -format UDRW \
    -ov \
    "$DMG_TEMP" >/dev/null 2>&1 \
    || fail "Failed to create read-write DMG"

rm -rf "$STAGING"

# ── 5. Mount and customize Finder layout ────────────────────────────
# Clean up any stale mounts from previous runs
hdiutil detach "/Volumes/$PROJECT_NAME" 2>/dev/null || true
hdiutil detach "/Volumes/$PROJECT_NAME 1" 2>/dev/null || true

log "Mounting DMG..."
MOUNT_DIR="/Volumes/$PROJECT_NAME"
DEV_NAME=$(hdiutil attach \
    "$DMG_TEMP" \
    -mountpoint "$MOUNT_DIR" \
    -readwrite \
    -noverify \
    -noautoopen \
    2>&1 | grep -E '^/dev/' | sed 1q | awk '{print $1}')

[ -z "$DEV_NAME" ] && fail "Could not mount DMG"
log "Mounted at: $MOUNT_DIR (device: $DEV_NAME)"

# Workaround for "Can't get disk (-1728)" — give Finder time to register
sleep 2

log "Configuring DMG layout..."
osascript -e "
on run argv
    set volumeName to item 1 of argv
    tell application \"Finder\"
        tell disk (volumeName as string)
            open
            delay 1
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {100, 100, 760, 500}
            set viewOptions to icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 128
            set position of item \"$PROJECT_NAME.app\" to {148, 220}
            set position of item \"Applications\" to {512, 220}
            close
            open
            delay 1
            close
        end tell
        -- Wait for .DS_Store to be written
        set dsStore to \"/Volumes/\" & volumeName & \"/.DS_Store\"
        set waitTime to 0
        repeat while true
            delay 1
            set waitTime to waitTime + 1
            try
                do shell script \"test -f \" & quoted form of dsStore
                exit repeat
            on error
                if waitTime > 10 then exit repeat
            end try
        end repeat
    end tell
end run
" "$PROJECT_NAME" 2>&1 || fail "Failed to configure DMG layout via Finder"

# ── 6. Unmount with retry ───────────────────────────────────────────
log "Unmounting..."
ATTEMPTS=0
MAX_ATTEMPTS=5
until
    ATTEMPTS=$((ATTEMPTS + 1))
    hdiutil detach "$DEV_NAME" -quiet 2>&1 && exit_code=0 || exit_code=$?
    [ "$exit_code" -eq 0 ]
do
    if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
        fail "Could not unmount after $MAX_ATTEMPTS attempts"
    fi
    log "Unmount busy, retrying in $((ATTEMPTS * 2))s..."
    sleep $((ATTEMPTS * 2))
done

# ── 7. Convert to compressed read-only DMG ──────────────────────────
log "Compressing DMG..."
hdiutil convert "$DMG_TEMP" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$DMG_PATH" >/dev/null 2>&1 \
    || fail "Failed to compress DMG"

rm -f "$DMG_TEMP"

ok "DMG created: $DMG_PATH"
ls -lh "$DMG_PATH"
