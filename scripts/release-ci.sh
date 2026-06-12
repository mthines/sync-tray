#!/bin/bash
#
# CI Release Script for SyncTray
#
# Runs in GitHub Actions after the version tag has been created.
# Builds SyncTray.app, zips it, creates a GitHub release, and updates the
# Homebrew tap (mthines/homebrew-synctray).
#
# Required env:
#   RELEASE_VERSION     - e.g. v0.35.0 or v0.35.0-beta.42.1
#   IS_BETA             - "true" | "false"
#   GITHUB_TOKEN        - For `gh release create`
#   HOMEBREW_TAP_TOKEN  - PAT with repo scope on mthines/homebrew-synctray
#   DASH0_AUTH_TOKEN    - Embedded into the Release build (optional but warns if missing)
#
# Optional env:
#   PR_NUMBER           - Required when IS_BETA=true
#   DRY_RUN             - "true" to skip publishing steps
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1" >&2; exit 1; }

if [ -z "${CI:-}" ]; then
  log_error "This script is designed to run in CI only. For local releases use: pnpm release"
fi

VERSION="${RELEASE_VERSION#v}"
TAG="v${VERSION}"

PROJECT_NAME="SyncTray"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
XCODEPROJ="$PROJECT_DIR/SyncTray.xcodeproj"

cd "$PROJECT_DIR"

log_info "CI release ${TAG} (beta=${IS_BETA})"

if [ -z "${DASH0_AUTH_TOKEN:-}" ]; then
  log_warning "DASH0_AUTH_TOKEN not set — telemetry token will not be embedded"
fi

# =============================================================================
# Build Release .app
# =============================================================================
log_info "Building Release configuration..."
mkdir -p "$BUILD_DIR"

xcodebuild -project "$XCODEPROJ" \
  -scheme "$PROJECT_NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  clean build \
  ONLY_ACTIVE_ARCH=NO \
  DASH0_AUTH_TOKEN="${DASH0_AUTH_TOKEN:-}" \
  | tail -20

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release/${PROJECT_NAME}.app"
BINARY="$APP_PATH/Contents/MacOS/${PROJECT_NAME}"

if [ ! -f "$BINARY" ]; then
  log_error "Binary not found at $BINARY — build produced an empty app bundle"
fi

ARCH_INFO=$(lipo -info "$BINARY" 2>/dev/null | sed 's/.*: //' || echo "unknown")
log_success "Build OK ($ARCH_INFO)"

if ! codesign -v "$APP_PATH" 2>/dev/null; then
  log_warning "App bundle has invalid code signature (expected for unsigned builds)"
fi

# =============================================================================
# Zip
# =============================================================================
ZIP_NAME="${PROJECT_NAME}-${TAG}-macOS.zip"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

# Verify zip can be extracted and contains binary
VERIFY_DIR=$(mktemp -d)
ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
if [ ! -f "$VERIFY_DIR/${PROJECT_NAME}.app/Contents/MacOS/${PROJECT_NAME}" ]; then
  rm -rf "$VERIFY_DIR"
  log_error "Zip verification failed — extracted app has no binary"
fi
rm -rf "$VERIFY_DIR"

ZIP_SHA=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
ZIP_SIZE=$(du -h "$ZIP_PATH" | cut -f1)
log_success "Created $ZIP_NAME ($ZIP_SIZE, sha256=${ZIP_SHA:0:12}...)"

# Expose for downstream workflow steps
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "ZIP_SHA=$ZIP_SHA" >> "$GITHUB_ENV"
  echo "ZIP_PATH=$ZIP_PATH" >> "$GITHUB_ENV"
fi

# =============================================================================
# Changelog
# =============================================================================
PREVIOUS_TAG=$(git tag -l "v*" --sort=-version:refname \
  | grep -E "^v[0-9]" \
  | grep -v "beta" \
  | grep -v "^${TAG}$" \
  | head -n 1 || echo "")

if [ -z "$PREVIOUS_TAG" ]; then
  COMMIT_RANGE="HEAD"
else
  COMMIT_RANGE="${PREVIOUS_TAG}..${TAG}"
fi

# Categorize commits into features / fixes / other
FEATURES=$(git log "$COMMIT_RANGE" --pretty=format:"%s|%h" --no-merges 2>/dev/null | grep -E "^feat(\(.+\))?: " || true)
FIXES=$(git log "$COMMIT_RANGE" --pretty=format:"%s|%h" --no-merges 2>/dev/null | grep -E "^fix(\(.+\))?: " || true)
OTHERS=$(git log "$COMMIT_RANGE" --pretty=format:"%s|%h" --no-merges 2>/dev/null \
  | grep -vE "^(feat|fix|chore|ci|docs|style|refactor|test)(\(.+\))?: " || true)

CHANGELOG="## What's Changed in ${TAG}"$'\n\n'

if [ -n "$FEATURES" ]; then
  CHANGELOG+="### ✨ Features"$'\n'
  while IFS='|' read -r message hash; do
    [ -z "$message" ] && continue
    clean=$(echo "$message" | sed -E 's/^feat(\(.+\))?: //')
    CHANGELOG+="- ${clean} (\`${hash}\`)"$'\n'
  done <<< "$FEATURES"
  CHANGELOG+=$'\n'
fi

if [ -n "$FIXES" ]; then
  CHANGELOG+="### 🐛 Bug Fixes"$'\n'
  while IFS='|' read -r message hash; do
    [ -z "$message" ] && continue
    clean=$(echo "$message" | sed -E 's/^fix(\(.+\))?: //')
    CHANGELOG+="- ${clean} (\`${hash}\`)"$'\n'
  done <<< "$FIXES"
  CHANGELOG+=$'\n'
fi

if [ -n "$OTHERS" ]; then
  CHANGELOG+="### 📦 Other Changes"$'\n'
  while IFS='|' read -r message hash; do
    [ -z "$message" ] && continue
    CHANGELOG+="- ${message} (\`${hash}\`)"$'\n'
  done <<< "$OTHERS"
  CHANGELOG+=$'\n'
fi

CHANGELOG+=$'\n---\n\n### Installation\n\n'

if [ "$IS_BETA" = "true" ]; then
  CHANGELOG+='**Via Homebrew (beta tap):**'$'\n'
  CHANGELOG+='```bash'$'\n'
  CHANGELOG+='brew tap mthines/synctray'$'\n'
  CHANGELOG+='brew install --cask mthines/synctray/synctray-beta              # latest beta'$'\n'
  CHANGELOG+="brew install --cask mthines/synctray/synctray-beta@${VERSION}    # this exact version"$'\n'
  CHANGELOG+='```'$'\n'
else
  CHANGELOG+='**Via Homebrew (recommended):**'$'\n'
  CHANGELOG+='```bash'$'\n'
  CHANGELOG+='brew tap mthines/synctray'$'\n'
  CHANGELOG+='brew install --cask synctray'$'\n'
  CHANGELOG+='```'$'\n'
fi

CHANGELOG+=$'\n'
CHANGELOG+='**Manual:** download '"\`${ZIP_NAME}\`"' below, unzip, drag SyncTray.app to /Applications.'$'\n\n'
CHANGELOG+='**Requirements:** macOS 13.0+, [rclone](https://rclone.org/) installed.'$'\n'

# =============================================================================
# GitHub release
# =============================================================================
log_info "Creating GitHub release..."

PRERELEASE_FLAG=""
TITLE="${PROJECT_NAME} ${TAG}"
if [ "$IS_BETA" = "true" ]; then
  PRERELEASE_FLAG="--prerelease"
  TITLE="${PROJECT_NAME} ${TAG} (beta)"
fi

if [ "${DRY_RUN:-}" = "true" ]; then
  log_warning "DRY_RUN: would create release $TAG"
  echo "$CHANGELOG" | head -30
else
  echo "$CHANGELOG" | gh release create "$TAG" \
    $PRERELEASE_FLAG \
    --title "$TITLE" \
    --notes-file - \
    "$ZIP_PATH"
  log_success "GitHub release created"
fi

# =============================================================================
# Update homebrew tap
# =============================================================================
if [ -z "${HOMEBREW_TAP_TOKEN:-}" ]; then
  log_warning "HOMEBREW_TAP_TOKEN not set — skipping tap update"
  exit 0
fi

if [ "${DRY_RUN:-}" = "true" ]; then
  log_warning "DRY_RUN: would update tap repo"
  exit 0
fi

log_info "Updating mthines/homebrew-synctray..."

TAP_DIR="/tmp/homebrew-synctray-ci"
rm -rf "$TAP_DIR"
git clone "https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/mthines/homebrew-synctray.git" "$TAP_DIR"

cd "$TAP_DIR"
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

if [ "$IS_BETA" = "true" ]; then
  # synctray-beta.rb — always points to the latest beta
  BETA_CASK="Casks/synctray-beta.rb"
  if [ ! -f "$BETA_CASK" ]; then
    log_info "Creating $BETA_CASK from stable cask template"
    mkdir -p Casks
    cp "Casks/synctray.rb" "$BETA_CASK"
    sed -i '' 's/cask "synctray"/cask "synctray-beta"/' "$BETA_CASK"
  fi
  sed -i '' "s/version \"[^\"]*\"/version \"${VERSION}\"/" "$BETA_CASK"
  sed -i '' "s/sha256 \"[^\"]*\"/sha256 \"${ZIP_SHA}\"/" "$BETA_CASK"

  # synctray-beta@VERSION.rb — pinned beta for reproducible installs
  VERSIONED_CASK="Casks/synctray-beta@${VERSION}.rb"
  cp "$BETA_CASK" "$VERSIONED_CASK"
  sed -i '' "s/cask \"synctray-beta\"/cask \"synctray-beta@${VERSION}\"/" "$VERSIONED_CASK"

  git add "$BETA_CASK" "$VERSIONED_CASK"
  git commit -m "synctray-beta: update to ${TAG}"
  log_success "Updated synctray-beta.rb + synctray-beta@${VERSION}.rb"
else
  # synctray.rb — stable
  STABLE_CASK="Casks/synctray.rb"
  sed -i '' "s/version \"[^\"]*\"/version \"${VERSION}\"/" "$STABLE_CASK"
  sed -i '' "s/sha256 \"[^\"]*\"/sha256 \"${ZIP_SHA}\"/" "$STABLE_CASK"

  git add "$STABLE_CASK"
  git commit -m "synctray: update to ${TAG}"
  log_success "Updated synctray.rb"
fi

git remote set-url origin "https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/mthines/homebrew-synctray.git"
git push origin main

cd "$PROJECT_DIR"
rm -rf "$TAP_DIR"

log_success "Released ${TAG}"
echo "Release URL: https://github.com/mthines/sync-tray/releases/tag/${TAG}"
