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
# Remove ALL SyncTray DerivedData to force full recompile
rm -rf "$DERIVED_DATA"/SyncTray-* 2>/dev/null && echo "Removed DerivedData cache"
# Also clean via xcodebuild
xcodebuild -scheme SyncTray clean -quiet 2>/dev/null || true

echo "Building $APP_NAME (full rebuild)..."
# Build with explicit derived data path to ensure clean state
xcodebuild -scheme SyncTray -configuration Debug build \
    SYMROOT="$BUILD_DIR" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    2>&1 | grep -E "(error:|warning:.*error|BUILD)" || true

if [ ! -d "$BUILD_PATH" ]; then
    echo "ERROR: Build failed - no app bundle found"
    exit 1
fi
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
