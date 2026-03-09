<p align="center">
  <img src="/docs/assets/synctray-logo.png" alt="SyncTray Logo" height="300">
</p>

<h1 align="center">SyncTray</h1>

<p align="center">
  <strong>Google Drive-style folder sync for any cloud</strong><br>
  A native macOS menu bar app with three sync modes: two-way sync, one-way backup, and on-demand streaming.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13.0+-blue" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/Swift-5-orange" alt="Swift 5">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="License: MIT">
</p>

<p align="center">
  <img src="/docs/assets/profile-settings.png" alt="SyncTray Settings" height="600">
</p>

---

## What is SyncTray?

SyncTray brings the convenience of Google Drive or Dropbox sync to **any cloud storage** supported by [rclone](https://rclone.org/) - that's over 70 providers including:

- **Cloud Storage**: S3, Google Drive, OneDrive, Dropbox, iCloud Drive
- **Self-Hosted**: Synology NAS, NextCloud, WebDAV, SFTP servers
- **Object Storage**: Backblaze B2, Wasabi, MinIO

Instead of running complex terminal commands, SyncTray gives you:

- A **menu bar icon** showing sync status at a glance
- **Three sync modes** to match your workflow
- **Automatic scheduled syncing** that runs in the background
- **Real-time notifications** when files change
- **Multiple sync profiles** for different folders/remotes

---

## Sync Modes

SyncTray offers three ways to connect your files to the cloud:

| Mode | Best For | How It Works |
|------|----------|--------------|
| **Two-Way Sync** | Active working files | Changes on either side sync to the other |
| **One-Way Sync** | Backups & mirrors | Source overwrites destination |
| **Stream (Mount)** | Large media libraries | Files appear locally but stream on-demand |

<p align="center">
  <img src="/docs/assets/profile-two-way.png" alt="Two-Way Sync Configuration" height="600">
</p>

### Two-Way Sync (Bisync)

Perfect for files you actively edit on multiple devices. Uses rclone's bisync to keep both sides synchronized.

- Edit a file locally → syncs to cloud
- Edit on another device → syncs back down
- Conflicts are resolved automatically (newer wins, old version backed up)

### One-Way Sync

Mirror files in one direction only. Choose your direction:

- **Local → Remote**: Backup your local files to the cloud
- **Remote → Local**: Mirror cloud files to your Mac

The destination always matches the source exactly.

### Stream (Mount)

Access cloud files without downloading them. Files appear in a folder on your Mac but are streamed on-demand when opened.

- No local storage used (beyond cache)
- Ideal for large media libraries or archives
- Configurable VFS cache for performance

<p align="center">
  <img src="/docs/assets/profile-stream.png" alt="Stream (Mount) Configuration" height="600">
</p>

> **Note**: Mount mode requires [macFUSE](#mount-mode-setup) and the official rclone binary.

---

## Features

### Live Status Monitoring
- Menu bar icon shows current state (idle, syncing, error, drive not mounted)
- **Real-time progress** during sync: bytes transferred, percentage, ETA
- Per-profile status indicators

During sync, see detailed transfer progress:

<p align="center">
  <img src="/docs/assets/profile-syncing-transfer-details.png" alt="Sync Progress" height="600">
</p>

View sync output and logs directly in the app:

<p align="center">
  <img src="/docs/assets/profile-syncing-with-logs.png" alt="Sync Logs" height="600">
</p>

### Smart Notifications
- Batched file change notifications (lists 1-3 files, summarizes 4+)
- Click notifications to open the sync directory
- Error notifications with actionable details

### Multi-Profile Support
- Create unlimited sync profiles (Work, Personal, Archive, etc.)
- Each profile syncs on its own schedule
- Independent enable/disable per profile
- Per-profile status indicators in the menu

### Recent Changes
- View last 20 synced files in the menu dropdown
- See operation type: Copied, Updated, Deleted, Renamed
- Click any file to reveal it in Finder

<p align="center">
  <img src="/docs/assets/status-bar-recent-changes.png" alt="Recent Changes" height="600">
</p>

### Automatic Background Sync

- Configurable sync interval (5-60 minutes per profile)
- Uses native macOS launchd - syncs even when app is closed
- Lock file prevents overlapping syncs
- Smart external drive detection - pauses when unmounted

### One-Click Actions
- **Sync Now**: Trigger immediate sync for all enabled profiles
- **Open Directory**: Jump to your local sync folder
- **View Log**: Open the sync log for troubleshooting

## Requirements

- **macOS 13.0** or later
- **[rclone](https://rclone.org/)** installed and configured with at least one remote

### Installing rclone

```bash
# Using Homebrew
brew install rclone

# Configure your first remote
rclone config
```

See [rclone's documentation](https://rclone.org/docs/) for detailed setup guides for each provider.

### Mount Mode Setup

Stream (Mount) mode requires additional components:

#### 1. Install macFUSE

```bash
brew install --cask macfuse
```

After installation:
1. **Restart your Mac**
2. Go to **System Settings → Privacy & Security**
3. Approve the macFUSE kernel extension

#### 2. Install Official rclone Binary

> **Important**: Homebrew's rclone doesn't support mount mode. You need the official binary.

```bash
# Remove Homebrew version (if installed)
brew uninstall rclone

# Download and install official binary
curl -O https://downloads.rclone.org/rclone-current-osx-arm64.zip
unzip rclone-current-osx-arm64.zip
cd rclone-*-osx-arm64
sudo cp rclone /usr/local/bin/
sudo chmod +x /usr/local/bin/rclone

# Verify installation
rclone version
```

---

## Installation

### Option 1: Homebrew (Recommended)

```bash
brew tap mthines/synctray
brew install --cask synctray
```

### Option 2: Download Release

Download the latest `.zip` from [Releases](../../releases), extract, and drag `SyncTray.app` to `/Applications`.

**Note:** Since the app isn't notarized, you'll need to allow it once:

```bash
xattr -cr /Applications/SyncTray.app
```

### Option 3: Build from Source

```bash
git clone https://github.com/mthines/sync-tray.git
cd sync-tray
xcodebuild -scheme SyncTray -configuration Release build
```

---

## Getting Started

### 1. Launch SyncTray
The app icon appears in your menu bar. A yellow gear indicates setup is needed.

### 2. Create a Sync Profile
1. Click the menu bar icon → **Settings**
2. Click **+** to add a new profile

<p align="center">
  <img src="/docs/assets/new-profile-wizard-intro.png" alt="New Profile Wizard" height="600">
</p>

3. Select your cloud provider:

<p align="center">
  <img src="/docs/assets/new-profile-wizard-providers.png" alt="Select Provider" height="600">
</p>

4. Configure:
   - **Name**: Give it a descriptive name (e.g., "Work Documents")
   - **Remote**: Select from your configured rclone remotes
   - **Remote Path**: Choose which folder on the remote to sync
   - **Local Path**: Pick the local folder to sync to
   - **Sync Interval**: How often to sync (default: 15 minutes)

### 3. Install the Profile
Click **Install** to activate the profile. SyncTray will:
- Create the local directory if needed
- Set up sync check files for safety
- Install a background scheduler (launchd agent)
- Start monitoring for changes

### 4. You're Done!
Your folder will now sync automatically on schedule. The menu bar shows sync status, and you'll get notifications when files change.

### Using Mount Mode

Mount mode is different from sync modes - it creates a virtual drive instead of syncing files:

1. **Select Mount Mode**: When creating a profile, choose "Stream (Mount)" as the sync mode
2. **Configure Mount Settings**:
   - **Cache Mode**: Choose how aggressively to cache (Full recommended)
   - **Cache Size**: Set maximum cache size (default: 10G)
   - **Cache Directory**: Where cached files are stored (default: ~/.cache/rclone/vfs)
3. **Mount Point**: The local path becomes your mount point (where files appear)
4. **Install and Mount**: Click Install, then Mount in the menu bar

**Mount vs Sync**:
- Mount: Files stream on-demand, mount runs continuously
- Sync: Files copied locally, sync runs periodically

**Unmounting**: Click the eject button in the menu bar for the profile, or disable the profile.

## Menu Bar States

<p align="center">
  <img src="/docs/assets/status-bar-idle.png" alt="Menu Bar" height="600">
</p>

| Icon | State | Meaning |
|------|-------|---------|
| Gray sync arrows | Idle | All syncs complete, system ready |
| Blue sync arrows (animated) | Syncing | Sync in progress |
| Red warning triangle | Error | Last sync failed - check logs |
| Orange drive with X | Drive Not Mounted | External drive disconnected |
| Yellow gear | Setup Required | No profiles configured |

## Advanced Configuration

### Additional rclone Flags
Each profile supports custom rclone flags. Common options:
- `--exclude "*.tmp"` - Exclude patterns
- `--bwlimit 1M` - Limit bandwidth
- `--dry-run` - Test without making changes

### External Drive Sync

When syncing to an external drive:

1. Enable "External Drive" toggle in profile settings
2. SyncTray auto-detects the mount point
3. Syncs pause when the drive is unmounted
4. Resume automatically when reconnected

### Resync (Reset Sync State)
If sync gets out of sync or shows persistent errors:
1. Open Settings → Select the profile
2. Click **Resync**
3. This resets rclone's bisync cache and performs a fresh comparison

### Conflict Resolution

SyncTray uses rclone bisync with smart conflict handling:

- Newer file wins by default
- Conflicts create backup copies with `-sync-conflict-` suffix
- Check the log file for conflict details

## File Locations

SyncTray creates these files (per profile):

| Location | Purpose |
|----------|---------|
| `~/.local/bin/synctray-sync.sh` | Shared sync script |
| `~/.config/synctray/profiles/{id}.json` | Profile configuration |
| `~/.local/log/synctray-sync-{id}.log` | Sync log output |
| `~/Library/LaunchAgents/com.synctray.sync.{id}.plist` | Background scheduler |

## Troubleshooting

### "App can't be opened" warning

macOS blocks unsigned apps. Fix with:

**Fix (run once in Terminal):**
```bash
xattr -cr /Applications/SyncTray.app
```

### Sync shows error state
1. Click **View Log** in the menu to see detailed error messages
2. Common issues:
   - Remote not accessible (check network/credentials)
   - Check file missing (click Resync to recreate)
   - Conflicting changes detected (check log for details)

### Sync not running on schedule
1. Verify the profile is installed (green checkmark in Settings)
2. Check if launchd agent is loaded:
   ```bash
   launchctl list | grep synctray
   ```
3. Try uninstalling and reinstalling the profile

### Files not appearing in Recent Changes
- Only files actually transferred appear (unchanged files are skipped)
- Check that `--use-json-log` is being used (automatic with SyncTray)

### Mount mode: "macFUSE not installed" or mount fails

Mount mode requires macFUSE to create virtual filesystems:

```bash
brew install --cask macfuse
```

After installation:
1. Reboot your Mac
2. Go to System Settings → Security & Privacy
3. Approve the macFUSE kernel extension
4. Try mounting again

### Mount mode: Stale mount or "Device busy" error

If a mount fails to unmount cleanly:

```bash
# Force unmount
diskutil unmount force /path/to/mount/point

# Or restart SyncTray (auto-cleans stale mounts)
```

### Mount mode: Slow file access

Try adjusting cache settings:
- Increase cache size (e.g., from 10G to 20G)
- Use "Full" cache mode for better read performance
- Check network speed to remote (mount streams over network)

## Development

### Building

```bash
git clone https://github.com/mthines/sync-tray.git
cd sync-tray
xcodebuild -scheme SyncTray -configuration Debug build
```

### Architecture

- **SyncManager**: Orchestrates sync operations and state
- **ProfileStore**: Persists profiles to UserDefaults
- **LogWatcher**: Real-time log monitoring via DispatchSource
- **LogParser**: Parses rclone JSON logs
- **SyncSetupService**: Generates scripts and launchd plists
- **NotificationService**: Smart batched notifications

### Commit Convention

Uses [Conventional Commits](https://www.conventionalcommits.org/):

| Prefix | Version Bump | Example |
|--------|-------------|---------|
| `feat:` | Minor (0.X.0) | `feat: add dark mode support` |
| `fix:` | Patch (0.0.X) | `fix: resolve crash on launch` |
| `feat!:` | Major (X.0.0) | `feat!: redesign settings API` |

### Creating a Release

```bash
./scripts/release.sh           # Auto-detect from commits
./scripts/release.sh --minor   # Force minor bump
./scripts/release.sh v1.2.3    # Exact version
```

---

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [rclone](https://rclone.org/) - The powerful sync engine
- [macFUSE](https://osxfuse.github.io/) - Virtual filesystem support
- Apple's SwiftUI and MenuBarExtra APIs
