cask "synctray" do
  version "0.61.0"
  sha256 "675ab131b233941f0798e3758dc8f07d33794d56a4e05839e04b2569cb159a53"

  url "https://github.com/mthines/sync-tray/releases/download/v#{version}/SyncTray-v#{version}-macOS.zip"
  name "SyncTray"
  desc "Menu bar app for automatic two-way folder sync with 70+ cloud providers via rclone"
  homepage "https://github.com/mthines/sync-tray"

  depends_on macos: :ventura

  # Remove quarantine attribute (app is not notarized yet)
  preflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{staged_path}/SyncTray.app"]
  end

  app "SyncTray.app"

  # Quit SyncTray before upgrading/uninstalling so its quit handler terminates the
  # Finder extension process — otherwise Finder keeps serving the pre-upgrade extension
  # binary until it's relaunched. Combined with the app relaunching Finder on a version
  # change, upgrades need no manual Finder restart.
  uninstall quit: "com.synctray.app"

  zap trash: [
    "~/.config/synctray",
    "~/.local/log/synctray-*",
    "~/Library/LaunchAgents/com.synctray.sync.*.plist",
  ]

  caveats <<~EOS
    SyncTray provides Google Drive-style automatic folder sync using rclone.
    Works with Dropbox, OneDrive, S3, SFTP, NAS, and 70+ other providers.

    Prerequisites:
      1. Install rclone:  brew install rclone
      2. Configure a remote:  rclone config

    Then launch SyncTray and create a sync profile in Settings.

    Finder "Available Offline" menu:
      Stream (mount) profiles add a right-click "SyncTray > Available Offline" menu
      in Finder. SyncTray reloads Finder for you after an install or upgrade, but if
      the menu doesn't appear, restart Finder manually:

        killall Finder

      On a first install you must also enable the extension once under
      System Settings > General > Login Items & Extensions > Extensions.
  EOS
end
