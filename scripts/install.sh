#!/bin/bash
# Build and install SyncTray to Applications folder

set -e
cd "$(dirname "$0")/.."

APP_NAME="SyncTray"
BUILD_DIR="$(pwd)/build"
BUILD_PATH="$BUILD_DIR/Debug/SyncTray.app"
INSTALL_PATH="/Applications/$APP_NAME.app"

# Build the app
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
