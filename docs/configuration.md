# Configuration files

SyncTray keeps its configuration in plain files under `~/.config/synctray/`.
They are the source of truth: edit one, and the running app applies the change within about a second, through the same path as the **Save** button.

## The config folder

| Path                                         | Contents                                                              | Edit it? |
| -------------------------------------------- | --------------------------------------------------------------------- | -------- |
| `profiles/{shortId}.profile.json`            | One profile: folders, remote, mode, schedule, and every setting       | Yes      |
| `settings.json`                              | App settings: launch at login, usage data, debug logging, auto-fix    | Yes      |
| `schema/profile.schema.json`                 | JSON Schema for profile files                                         | No — rewritten at every launch |
| `schema/settings.schema.json`                | JSON Schema for `settings.json`                                       | No — rewritten at every launch |
| `profiles/{shortId}.json`                    | A subset of the profile, generated for the sync script                | No — generated |
| `profiles/{shortId}-exclude.txt`             | rclone filter rules for two-way and one-way profiles                   | Outside SyncTray's marked blocks only |

`{shortId}` is the first 8 characters of the profile's `id`, lowercased.

The schemas are also published in this repository: [`profile.schema.json`](../SyncTray/Resources/Schemas/profile.schema.json) and [`settings.schema.json`](../SyncTray/Resources/Schemas/settings.schema.json).

## Credentials

No file in `~/.config/synctray/` holds a password, token, or key.
Remotes and their secrets live in rclone's own config, `~/.config/rclone/rclone.conf`.
A profile only names a remote, for example `"rcloneRemote": "nas:"`.

## Profile files

### Create a profile by dropping a file

Write a new `*.profile.json` into `~/.config/synctray/profiles/` with an `id` SyncTray hasn't seen, and SyncTray creates that profile.
If the file name isn't `{shortId}.profile.json`, SyncTray renames it.

Only five keys are required:

```json
{
  "id": "6F1C2B9E-3A4D-4E5F-8A7B-1C2D3E4F5A6B",
  "name": "Projects",
  "rcloneRemote": "nas:",
  "remotePath": "Projects",
  "localSyncPath": "/Users/me/Projects"
}
```

That's a two-way sync every 5 minutes, saved but not yet running.
To start it, set `"isEnabled": true` in the file, or run `synctray profile enable Projects`.

- Generate the `id` with `uuidgen`. Never change it afterwards — a new `id` is a new profile.
- Use absolute paths for `localSyncPath`.
- The launchd agent is installed only when `isEnabled` is `true` and `name`, `rcloneRemote`, `remotePath`, and `localSyncPath` are all non-empty.

### Profile fields

| Field                     | Default                | Applies to       | What it controls                                                                 |
| ------------------------- | ---------------------- | ---------------- | -------------------------------------------------------------------------------- |
| `id`                      | required               | all              | Stable UUID for the profile                                                      |
| `name`                    | required               | all              | Display name                                                                     |
| `rcloneRemote`            | required               | all              | rclone remote name, with or without the trailing `:`                             |
| `remotePath`              | required               | all              | Folder on the remote                                                             |
| `localSyncPath`           | required               | all              | Local folder, or the mount point for Stream                                      |
| `isEnabled`               | `false`                | all              | Whether the launchd agent is installed and running                               |
| `syncMode`                | `bisync`               | all              | `bisync` (two-way), `sync` (one-way), or `mount` (Stream)                        |
| `syncDirection`           | `localToRemote`        | one-way          | `localToRemote` or `remoteToLocal`                                               |
| `syncIntervalMinutes`     | `5`                    | two-way, one-way | Minutes between scheduled syncs                                                  |
| `isMuted`                 | `false`                | all              | Mute change notifications                                                        |
| `drivePathToMonitor`      | `""`                   | all              | External drive to watch; syncs skip while it's unplugged                        |
| `additionalRcloneFlags`   | `""`                   | all              | Extra flags for every rclone command, split like a shell would — never evaluated |
| `bandwidthLimit`          | `""` (unlimited)       | all              | rclone `--bwlimit`: `10M`, `1M:512k`, a number in KiB/s, or `off`                |
| `fallbackRemote`          | `""`                   | two-way, one-way | Remote to use when the primary can't be reached                                  |
| `fallbackRemotePath`      | `""` (same path)       | two-way, one-way | Path on the fallback remote, when it differs                                     |
| `syncExcludePatterns`     | `[]`                   | two-way, one-way | "Don't Sync" patterns, such as `*.bak` or `**/BACKUP/**`                         |
| `syncIncludeFolders`      | `[]` (everything)      | two-way, one-way | "Sync Only These Folders": folder paths relative to the profile's root           |
| `mountBackend`            | `nfs`                  | Stream           | `nfs` (no kernel extension) or `macfuse`                                         |
| `vfsCacheMode`            | `full`                 | Stream           | rclone cache mode: `off`, `minimal`, `writes`, or `full`                         |
| `vfsCacheMaxSize`         | `10G`                  | Stream           | Maximum cache size                                                               |
| `vfsCacheMaxAge`          | `168h`                 | Stream           | How long a file stays cached after you last opened it                            |
| `vfsCachePath`            | `~/.cache/rclone`      | Stream           | Cache directory                                                                  |
| `pinnedDirectories`       | `[]`                   | Stream           | Folders kept available offline                                                   |
| `warmExcludePatterns`     | `[]`                   | Stream           | "Don't Download" patterns for offline folders                                    |
| `downloadConnections`     | `2`                    | Stream           | Parallel downloads, 1–16. Keep 1–2 on Wi-Fi; raise it on a fast wired link       |
| `mountAtStartup`          | `true`                 | Stream           | Mount at login and when the app starts                                           |
| `mountResilient`          | `true`                 | Stream           | Time out a stalled server in about 30 s instead of freezing Finder               |
| `streamCacheOnly`         | `false`                | Stream           | Serve only cached files and queue edits for upload (Cache Only)                  |
| `allowNonEmptyMount`      | `false`                | Stream           | Mount over a folder that already has files (macFUSE only)                        |
| `rcPort`                  | derived from `id`      | Stream           | Port for the mount's rclone remote-control API                                   |
| `fallbackRequiresCacheRebuild` | computed          | two-way, one-way | Set by SyncTray when you save; don't edit                                        |

The schema is authoritative: when this table and [`profile.schema.json`](../SyncTray/Resources/Schemas/profile.schema.json) disagree, the schema wins.

### What a change does

| You change                                             | SyncTray                                                               |
| ------------------------------------------------------ | ---------------------------------------------------------------------- |
| `isEnabled`                                            | Installs or removes the launchd agent                                  |
| Paths, remote, mode, schedule, mount settings          | Regenerates the script and agent, and remounts a mounted Stream profile |
| `syncExcludePatterns`                                  | Rewrites the filter file; applies from the next sync, no reinstall     |
| `syncIncludeFolders` on a two-way profile              | Rewrites the filter file and schedules one safe resync, where the newer copy of a file wins |
| `pinnedDirectories`, `warmExcludePatterns`             | Updates offline folders on a mounted profile, no remount               |
| `vfsCachePath`                                         | Points the mount at the new directory; cached files stay behind. Use `synctray cache move` to bring them. |

## `settings.json`

| Key                    | What it controls                                                    |
| ---------------------- | ------------------------------------------------------------------- |
| `launchAtLogin`        | Start SyncTray at login                                             |
| `telemetryEnabled`     | Share pseudonymous usage data (off until you opt in)                |
| `autoFixSyncIssues`    | Run a safe resync by itself when two-way sync reports it's out of sync (on by default) |
| `debugLoggingEnabled`  | Write verbose debug lines to the sync logs                          |

## Files SyncTray creates

| Path                                                          | What it is                                     |
| ------------------------------------------------------------- | ---------------------------------------------- |
| `~/.local/bin/synctray`                                       | The `synctray` CLI shim, refreshed at every launch |
| `~/.local/bin/synctray-sync.sh`                               | The sync script all profiles share             |
| `~/Library/LaunchAgents/com.synctray.sync.{shortId}.plist`    | The profile's launchd schedule or mount job    |
| `~/.local/log/synctray-sync-{shortId}.log`                    | The profile's sync log                         |
| `/tmp/synctray-sync-{shortId}.lock`                           | Held while a run is in progress                |
| `~/Library/Caches/rclone/bisync/`                             | rclone's two-way sync history                  |
| `{vfsCachePath}/vfs/` and `{vfsCachePath}/vfsMeta/`           | Stream cache: file data and what's downloaded  |
| `{vfsCachePath}/synctray-overlay/{shortId}/`                  | Files created or edited in Cache Only, until they upload |

Uninstalling with `brew uninstall --zap --cask synctray` removes `~/.config/synctray`, the logs, and the launch agents.
Your synced folders, rclone's config, and the Stream cache are left in place.
