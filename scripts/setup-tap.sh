#!/bin/bash
# =============================================================================
# Homebrew Tap Setup Script
# Creates the homebrew-synctray tap repository for distribution
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; exit 1; }

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAP_DIR="${1:-$PROJECT_DIR/../homebrew-synctray}"

echo ""
echo "🍺 Homebrew Tap Setup"
echo "====================="
echo ""

# Check if tap directory already exists
if [ -d "$TAP_DIR" ]; then
    log_warning "Tap directory already exists: $TAP_DIR"
    read -p "Update existing tap? (Y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        exit 0
    fi
else
    # Create tap directory
    mkdir -p "$TAP_DIR"
    log_success "Created tap directory: $TAP_DIR"

    # Initialize git repo
    cd "$TAP_DIR"
    git init
    log_success "Initialized git repository"
fi

cd "$TAP_DIR"

# Create Casks directory
mkdir -p Casks

# Copy cask file
cp "$PROJECT_DIR/Casks/synctray.rb" Casks/
log_success "Copied synctray.rb to Casks/"

# Create README
cat > README.md << 'EOF'
# Homebrew Tap for SyncTray

This is the official Homebrew tap for [SyncTray](https://github.com/mthines/sync-tray), a macOS menu bar app for Google Drive-style folder sync using rclone.

## Installation

```bash
brew tap mthines/synctray
brew install --cask synctray
```

## Updating

```bash
brew upgrade --cask synctray
```

## Uninstalling

```bash
brew uninstall --cask synctray
brew untap mthines/synctray
```

## Requirements

- macOS 13.0 (Ventura) or later
- [rclone](https://rclone.org/) (`brew install rclone`)

## About

SyncTray turns rclone into a seamless, automated sync experience with:
- Menu bar status indicator
- Automatic scheduled syncing
- Real-time notifications
- Multi-profile support

See the [main repository](https://github.com/mthines/sync-tray) for full documentation.
EOF
log_success "Created README.md"

# Show next steps
echo ""
log_success "Tap setup complete!"
echo ""
echo "📋 Next steps:"
echo ""
echo "1. Create a GitHub repository named 'homebrew-synctray'"
echo "   https://github.com/new"
echo ""
echo "2. Push the tap:"
echo "   cd $TAP_DIR"
echo "   git add ."
echo "   git commit -m 'Initial tap setup'"
echo "   git remote add origin https://github.com/mthines/homebrew-synctray.git"
echo "   git push -u origin main"
echo ""
echo "3. Users can then install with:"
echo "   brew tap mthines/synctray"
echo "   brew install --cask synctray"
echo ""
