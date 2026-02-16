#!/bin/bash
# Build and install SyncTray to Applications folder

set -e
cd "$(dirname "$0")/.."

APP_NAME="SyncTray"
BUILD_DIR="$(pwd)/build"
BUILD_PATH="$BUILD_DIR/Debug/SyncTray.app"
INSTALL_PATH="/Applications/$APP_NAME.app"

# Clean and build the app
echo "Cleaning build artifacts..."
rm -rf "$BUILD_DIR"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
if ls "$DERIVED_DATA"/SyncTray-* 1>/dev/null 2>&1; then
    echo "Removing DerivedData: $(ls -d "$DERIVED_DATA"/SyncTray-*)"
    rm -rf "$DERIVED_DATA"/SyncTray-*
fi
xcodebuild -scheme SyncTray clean -quiet 2>/dev/null || true

echo "Building $APP_NAME..."
xcodebuild -scheme SyncTray -configuration Debug build -quiet SYMROOT="$BUILD_DIR"
echo "Build succeeded"

# Kill running app if present
pkill -x "$APP_NAME" 2>/dev/null && echo "Stopped running $APP_NAME" && sleep 1

# Remove old installation
if [ -d "$INSTALL_PATH" ]; then
    rm -rf "$INSTALL_PATH"
    echo "Removed old installation"
fi

# Copy new build
cp -R "$BUILD_PATH" "$INSTALL_PATH"
echo "Installed $APP_NAME to $INSTALL_PATH"

# Optionally launch
if [ "$1" = "--launch" ] || [ "$1" = "-l" ]; then
    open "$INSTALL_PATH"
    echo "Launched $APP_NAME"
fi
