cask "synctray" do
  version "0.10.1"
  sha256 "05ebd4964ab1ff7c3dd8020b31588faa6861e5338c1a1e94e7d4e7a24b826d67"

  url "https://github.com/mthines/sync-tray/releases/download/v#{version}/SyncTray-v#{version}-macOS.zip"
  name "SyncTray"
  desc "macOS menu bar app for Google Drive-style folder sync using rclone bisync"
  homepage "https://github.com/mthines/sync-tray"

  depends_on macos: ">= :ventura"

  # Remove quarantine attribute (app is not notarized yet)
  preflight do
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{staged_path}/SyncTray.app"]
  end

  app "SyncTray.app"

  zap trash: [
    "~/.config/synctray",
    "~/.local/log/synctray-*",
    "~/Library/LaunchAgents/com.synctray.sync.*.plist",
  ]

  caveats <<~EOS
    SyncTray requires rclone to be installed:
      brew install rclone

    After installation, configure rclone remotes:
      rclone config
  EOS
end
