# Troubleshooting

Start with a health check — it covers rclone, the config, and every profile's agent, lock, and remote:

```bash
synctray doctor
```

Every `[fail]` line names the profile and the problem.
If `synctray` isn't found, see [Install the CLI](cli.md#install-the-cli).

- [A sync shows an error](#a-sync-shows-an-error)
- [Syncs don't run on schedule](#syncs-dont-run-on-schedule)
- [Files are missing from Recent Changes](#files-are-missing-from-recent-changes)
- [A Stream profile won't mount](#a-stream-profile-wont-mount)
- [Finder says "Server connections interrupted"](#finder-says-server-connections-interrupted)
- [Streaming is slow for files that are already cached](#streaming-is-slow-for-files-that-are-already-cached)
- [Cache Only is on, but the mount is still streaming](#cache-only-is-on-but-the-mount-is-still-streaming)
- [The Finder "Available Offline" menu is missing](#the-finder-available-offline-menu-is-missing)
- [macOS says the app can't be opened](#macos-says-the-app-cant-be-opened)

## A sync shows an error

Open the profile in **Settings…** — the error is shown with a button for the usual fix — or read the log with **View Log** or `synctray logs <name>`.

| Error                                  | What it means and what to do                                                                   |
| -------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Remote unreachable                     | rclone can't reach the remote. Check the network and credentials; `synctray test-remote <name>` prints rclone's own error. |
| Too many deletes                       | A two-way sync would delete more than half the files, so it stopped. Choose **Delete from Remote** if the deletion was intended, or **Restore from Remote** to bring the files back. |
| Out of sync / cannot find prior listings | Two-way sync lost track of its last state. **Fix Sync Issues** runs a safe resync where the newer copy of each file wins. With auto-fix on (the default), SyncTray does this by itself. |
| Prior lock file found                  | A previous run left its lock behind. **Remove Lock & Continue** removes this profile's lock once no run is using it, then retries the sync. |
| Folder is not empty (Stream)           | The mount point already has files in it. Empty the folder, or choose **Mount Anyway** to mount over it. |

SyncTray never starts a second run of the same profile while one is going, so these buttons tell you when a sync is still in progress instead of starting another.

## Syncs don't run on schedule

1. Check the profile is enabled and installed: `synctray status <name>` should show `enabled=true agent=loaded`.
2. If the agent is `unloaded`, run `synctray install <name>`, or click **Reinstall** in the profile.
3. Check the profile isn't paused, and — for a folder on an external drive — that the drive is connected.

You can also look at the launchd agent directly:

```bash
launchctl list | grep synctray
```

## Files are missing from Recent Changes

Recent Changes lists files that were actually transferred.
Files that were already the same on both sides are skipped, so a sync with nothing to do adds nothing to the list.

## A Stream profile won't mount

Stream needs nothing beyond rclone with the default NFS backend.

1. Run `synctray doctor` and check that rclone is found and the remote is reachable.
2. Run `synctray mount <name>`. If rclone stops, it prints the end of the sync log with the reason.
3. If the cache directory is on an external drive, connect it. SyncTray refuses to mount without a writable cache rather than streaming with no cache at all, and mounts on its own once the drive is back.
4. A large cache can take several minutes to scan at startup. `synctray status <name>` shows `state=mounting` during that time; `synctray status <name> --wait mounted` waits for it.

If the profile uses the **macFUSE** backend, macFUSE must be installed and approved, and Homebrew's rclone replaced with the official binary — see [Optional: macFUSE backend](user-guide.md#optional-macfuse-backend).

## Finder says "Server connections interrupted"

The rclone process behind the mount stopped answering.
`synctray status <name>` shows `state=stale`.

1. Remount: `synctray unmount <name>`, then `synctray mount <name>`, or restart SyncTray, which cleans up stale mounts.
2. If it can't unmount: `diskutil unmount force /path/to/mount/point`.
3. If it keeps happening on Wi-Fi, set a **Bandwidth Limit** on the profile and lower **Download Connections** to 1 or 2, so the mount doesn't saturate the link. Keep **Resilient Mount** on.

When every Stream profile reports this at the same moment, look at what they share — usually the cache disk — rather than at each remote.

## Streaming is slow for files that are already cached

First check whether the slow file comes from the network or from the cache.
A file read from the network isn't cached yet: make its folder **Available Offline**, and check it doesn't match one of the profile's **Don't Download** patterns.

**Cached files that are still slow usually point at the cache disk.**
The NFS backend reads in 32 KB requests, and rclone treats each request as a fresh file open, rewriting that file's small cache record (`vfsMeta/`) every time.
On a fast local filesystem that costs nothing.
On a slow one, such as an **exFAT or FAT external drive** or any spinning USB disk, it dominates.
For one ~100 GB cache on an exFAT USB hard drive:

| Cache location        | Cached read speed through the mount                      |
| --------------------- | -------------------------------------------------------- |
| Internal APFS SSD     | ~108 MB/s                                                |
| exFAT USB hard drive  | ~6.6 MB/s (as low as ~0.2 MB/s with a large, busy cache) |

The same files read straight off the exFAT drive ran at ~105 MB/s, so the drive itself wasn't the bottleneck.
Options, most effective first:

- **Put the cache on APFS.** Use the internal SSD if the cache fits, or reformat the external drive as APFS (you lose Linux and Windows compatibility). Move the existing cache with **Move Cache…** or `synctray cache move <name> --to <path>`.
- **Use two-way sync instead of Stream for that folder.** Files become ordinary files on disk and apps read them at disk speed, with no rclone in the read path.
- **Switch the profile to the macFUSE backend.** FUSE keeps each file open across reads, so the per-read rewrite goes away. It needs macFUSE.

The mount also reads ahead of what an app asks for, so briefly touching an **uncached** file — a Finder preview, Spotlight — can download more than was actually read.

## Cache Only is on, but the mount is still streaming

When Cache Only can't build its list of partly cached files, the mount falls back to streaming rather than risk showing incomplete files.
`synctray status <name>` shows `cache_only_fallback=true` in that case, and the sync log says "Cache Only unavailable".
Before switching, `synctray offline status <name>` shows how much of the profile is cached.

## The Finder "Available Offline" menu is missing

1. Enable the extension once under **System Settings → General → Login Items & Extensions → Extensions** (it's listed as **SyncTray Offline**).
2. Right-click a folder **inside** a mounted Stream profile — the menu only appears there.
3. After an install or upgrade SyncTray reloads Finder for you. If the menu still doesn't appear, run `killall Finder`.

## macOS says the app can't be opened

Releases are signed and notarized, so this should only happen with an old release or an unofficial build.
Update to the latest release.
To open a build you trust anyway, try to open it once, then allow it under **System Settings → Privacy & Security → Open Anyway**.
Avoid `xattr -cr` on a downloaded app: it strips the quarantine flag and skips Gatekeeper's checks entirely.

## Still stuck?

Turn on **Debug Logging** in App Settings, reproduce the problem, and bring the log from `synctray logs <name>` to the [SyncTray Discord](https://discord.gg/KBp8kb3EwP) or a [GitHub issue](https://github.com/mthines/sync-tray/issues).
