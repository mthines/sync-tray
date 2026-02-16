#!/bin/bash
# SyncTray Development Script
# Watches for file changes and rebuilds/relaunches the app
#
# Usage: ./scripts/dev.sh
#
# Requirements:
#   - fswatch (install with: brew install fswatch)
#
# For true hot-reloading (injecting code without restart), consider:
#   - Injection III: https://github.com/johnno1962/InjectionIII
#   - Install from Mac App Store or GitHub releases
#   - Add this to your app's initialization:
#       #if DEBUG
#       Bundle(path: "/Applications/InjectionIII.app/Contents/Resources/iOSInjection.bundle")?.load()
#       #endif

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEME="SyncTray"
BUILD_DIR="$PROJECT_DIR/build/Debug"
APP_NAME="SyncTray.app"
APP_PATH="$BUILD_DIR/$APP_NAME"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[DEV]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[DEV]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[DEV]${NC} $1"
}

log_error() {
    echo -e "${RED}[DEV]${NC} $1"
}

# Check for fswatch
if ! command -v fswatch &> /dev/null; then
    log_error "fswatch is required but not installed."
    echo "Install with: brew install fswatch"
    exit 1
fi

# Kill any existing SyncTray processes
kill_app() {
    pkill -x "SyncTray" 2>/dev/null || true
}

# Build the app
build_app() {
    log_info "Building $SCHEME..."

    if xcodebuild \
        -scheme "$SCHEME" \
        -configuration Debug \
        -derivedDataPath "$PROJECT_DIR/build" \
        -destination "platform=macOS" \
        build 2>&1 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)"; then

        if [ -d "$APP_PATH" ]; then
            log_success "Build succeeded"
            return 0
        fi
    fi

    log_error "Build failed"
    return 1
}

# Launch the app
launch_app() {
    if [ -d "$APP_PATH" ]; then
        log_info "Launching $APP_NAME..."
        open "$APP_PATH"
        log_success "App launched"
    else
        log_error "App not found at $APP_PATH"
    fi
}

# Handle file changes
on_change() {
    local changed_file="$1"

    # Skip non-source files
    case "$changed_file" in
        *.swift|*.xib|*.storyboard|*.xcassets|*.plist)
            ;;
        *)
            return
            ;;
    esac

    echo ""
    log_info "File changed: $(basename "$changed_file")"

    kill_app

    if build_app; then
        launch_app
    fi
}

# Cleanup on exit
cleanup() {
    log_info "Stopping dev server..."
    kill_app
    # Kill fswatch if running
    pkill -P $$ 2>/dev/null || true
    exit 0
}

trap cleanup SIGINT SIGTERM

# Main
echo ""
echo "╔════════════════════════════════════════╗"
echo "║       SyncTray Development Mode        ║"
echo "╠════════════════════════════════════════╣"
echo "║  Watching for changes...               ║"
echo "║  Press Ctrl+C to stop                  ║"
echo "╚════════════════════════════════════════╝"
echo ""

cd "$PROJECT_DIR"

# Initial build and launch
if build_app; then
    launch_app
else
    log_warning "Initial build failed, waiting for changes..."
fi

echo ""
log_info "Watching for file changes in SyncTray/..."

# Watch for changes
fswatch -0 -r \
    --include='\.swift$' \
    --include='\.xib$' \
    --include='\.storyboard$' \
    --include='\.xcassets$' \
    --include='\.plist$' \
    --exclude='.*' \
    "$PROJECT_DIR/SyncTray" | while read -d "" file; do
    on_change "$file"
done
