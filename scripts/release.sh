#!/bin/bash
set -e

# =============================================================================
# SyncTray Release Script
# Automates versioning based on conventional commits and creates GitHub releases
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_NAME="SyncTray"
SCHEME="SyncTray"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
XCODEPROJ="$PROJECT_DIR/SyncTray.xcodeproj"

# =============================================================================
# Helper Functions
# =============================================================================

log_info() { echo -e "${BLUE}ℹ${NC} $1" >&2; }
log_success() { echo -e "${GREEN}✓${NC} $1" >&2; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1" >&2; }
log_error() { echo -e "${RED}✗${NC} $1" >&2; exit 1; }

# Get the latest git tag (version)
get_latest_tag() {
    git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0"
}

# Parse version string into components
parse_version() {
    local version="${1#v}"  # Remove 'v' prefix
    IFS='.' read -r major minor patch <<< "$version"
    echo "$major $minor $patch"
}

# Determine version bump based on conventional commits
determine_bump() {
    local last_tag="$1"
    local bump="patch"

    # Get commits since last tag
    local commits
    if [ "$last_tag" = "v0.0.0" ]; then
        commits=$(git log --pretty=format:"%s" 2>/dev/null)
    else
        commits=$(git log "${last_tag}..HEAD" --pretty=format:"%s" 2>/dev/null)
    fi

    # Check for BREAKING CHANGE or ! after type (major bump)
    if echo "$commits" | grep -qE "(BREAKING CHANGE|^[a-z]+(\(.+\))?!:)"; then
        bump="major"
    # Check for feat: (minor bump)
    elif echo "$commits" | grep -qE "^feat(\(.+\))?:"; then
        bump="minor"
    # Everything else (fix:, chore:, docs:, etc.) is patch
    fi

    echo "$bump"
}

# Calculate new version
calculate_new_version() {
    local current="$1"
    local bump="$2"

    read -r major minor patch <<< "$(parse_version "$current")"

    case "$bump" in
        major)
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        minor)
            minor=$((minor + 1))
            patch=0
            ;;
        patch)
            patch=$((patch + 1))
            ;;
    esac

    echo "v${major}.${minor}.${patch}"
}

# Generate changelog from commits
generate_changelog() {
    local last_tag="$1"
    local new_version="$2"

    echo "## What's Changed in ${new_version}"
    echo ""

    local commits
    if [ "$last_tag" = "v0.0.0" ]; then
        commits=$(git log --pretty=format:"%s|%h" 2>/dev/null)
    else
        commits=$(git log "${last_tag}..HEAD" --pretty=format:"%s|%h" 2>/dev/null)
    fi

    local features=""
    local fixes=""
    local others=""

    while IFS='|' read -r message hash; do
        [ -z "$message" ] && continue

        if [[ "$message" =~ ^feat(\(.+\))?:\ (.+) ]]; then
            features+="- ${BASH_REMATCH[2]} (\`$hash\`)"$'\n'
        elif [[ "$message" =~ ^fix(\(.+\))?:\ (.+) ]]; then
            fixes+="- ${BASH_REMATCH[2]} (\`$hash\`)"$'\n'
        elif [[ ! "$message" =~ ^(chore|ci|docs|style|refactor|test)(\(.+\))?:  ]]; then
            # Include non-conventional commits too
            others+="- $message (\`$hash\`)"$'\n'
        fi
    done <<< "$commits"

    if [ -n "$features" ]; then
        echo "### ✨ Features"
        echo "$features"
    fi

    if [ -n "$fixes" ]; then
        echo "### 🐛 Bug Fixes"
        echo "$fixes"
    fi

    if [ -n "$others" ]; then
        echo "### 📦 Other Changes"
        echo "$others"
    fi

    echo ""
    echo "---"
    echo ""
    echo "### Installation"
    echo "1. Download \`${PROJECT_NAME}-${new_version}-macOS.zip\`"
    echo "2. Unzip and drag \`${PROJECT_NAME}.app\` to \`/Applications\`"
    echo "3. Launch and configure via Settings"
    echo ""
    echo "**Requirements:** macOS 13.0+"
}

# Update version in Info.plist
update_plist_version() {
    local version="${1#v}"  # Remove 'v' prefix
    local plist="$PROJECT_DIR/SyncTray/Info.plist"

    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
    log_success "Updated Info.plist version to $version"
}

# Build the release
build_release() {
    log_info "Building release..."

    mkdir -p "$BUILD_DIR"

    xcodebuild -project "$XCODEPROJ" \
        -scheme "$SCHEME" \
        -configuration Release \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        clean build \
        ONLY_ACTIVE_ARCH=NO \
        2>&1 | tail -5

    log_success "Build completed"
}

# Create release zip
create_zip() {
    local version="$1"
    local app_path="$BUILD_DIR/DerivedData/Build/Products/Release/${PROJECT_NAME}.app"
    local zip_name="${PROJECT_NAME}-${version}-macOS.zip"
    local zip_path="$BUILD_DIR/$zip_name"

    if [ ! -d "$app_path" ]; then
        log_error "App not found at $app_path"
    fi

    cd "$BUILD_DIR/DerivedData/Build/Products/Release"
    zip -rq "$zip_path" "${PROJECT_NAME}.app"

    log_success "Created $zip_name ($(du -h "$zip_path" | cut -f1))"
    echo "$zip_path"
}

# Create GitHub release
create_github_release() {
    local version="$1"
    local zip_path="$2"
    local changelog="$3"

    if ! command -v gh &> /dev/null; then
        log_warning "GitHub CLI (gh) not installed. Skipping GitHub release."
        log_info "Install with: brew install gh"
        log_info "Then run: gh release create $version \"$zip_path\" --title \"$PROJECT_NAME $version\" --notes-file -"
        return
    fi

    log_info "Creating GitHub release..."

    echo "$changelog" | gh release create "$version" \
        "$zip_path" \
        --title "${PROJECT_NAME} ${version}" \
        --notes-file -

    log_success "GitHub release created: $version"
}

# =============================================================================
# Main Script
# =============================================================================

main() {
    cd "$PROJECT_DIR"

    echo ""
    echo "🚀 ${PROJECT_NAME} Release Script"
    echo "=================================="
    echo ""

    # Check for uncommitted changes
    if [ -n "$(git status --porcelain)" ]; then
        log_error "Working directory has uncommitted changes. Please commit or stash them first."
    fi

    # Get current version and determine bump
    local current_version=$(get_latest_tag)
    log_info "Current version: $current_version"

    local bump=$(determine_bump "$current_version")
    log_info "Detected bump type: $bump"

    local new_version=$(calculate_new_version "$current_version" "$bump")
    log_info "New version: $new_version"

    echo ""

    # Allow manual override
    if [ "$1" = "--major" ]; then
        new_version=$(calculate_new_version "$current_version" "major")
    elif [ "$1" = "--minor" ]; then
        new_version=$(calculate_new_version "$current_version" "minor")
    elif [ "$1" = "--patch" ]; then
        new_version=$(calculate_new_version "$current_version" "patch")
    elif [ -n "$1" ] && [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        new_version="$1"
    fi

    # Confirm with user
    read -p "Release ${new_version}? (Y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        log_warning "Aborted."
        exit 0
    fi

    echo ""

    # Update version in plist
    update_plist_version "$new_version"

    # Commit version bump
    git add -A
    git commit -m "chore(release): bump version to ${new_version}" || true

    # Create git tag
    git tag -s "$new_version" -m "Release ${new_version}"
    log_success "Created git tag: $new_version"

    # Build release
    build_release

    # Create zip
    local zip_path=$(create_zip "$new_version")

    # Generate changelog
    local changelog=$(generate_changelog "$current_version" "$new_version")

    echo ""
    echo "📋 Changelog Preview:"
    echo "----------------------"
    echo "$changelog"
    echo "----------------------"
    echo ""

    # Push to remote
    read -p "Push to remote and create GitHub release? (Y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        git push origin main
        git push origin "$new_version"
        log_success "Pushed to remote"

        create_github_release "$new_version" "$zip_path" "$changelog"
    else
        log_info "Skipped push. Run manually:"
        log_info "  git push origin main"
        log_info "  git push origin $new_version"
    fi

    echo ""
    log_success "Release ${new_version} complete!"
    echo ""
    echo "📦 Artifacts:"
    echo "   - Git tag: $new_version"
    echo "   - Zip: $zip_path"
    echo ""
}

# Run with optional version override
main "$@"
