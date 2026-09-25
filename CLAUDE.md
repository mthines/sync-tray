# SyncTray Development Guidelines

## Project Overview

SyncTray is a macOS menu bar application that provides Google Drive-style background folder sync using rclone's bisync feature. It enables seamless two-way synchronization between local folders and any of rclone's 70+ supported cloud providers (Dropbox, OneDrive, Google Drive, S3, SFTP, etc.).

### Key Features
- **Multi-profile support**: Configure multiple sync pairs (local folder ↔ cloud remote)
- **Three sync modes**: Two-way sync (bisync), one-way sync (upload/download), and stream (mount)
- **Background sync via launchd**: Scheduled syncs run automatically at configurable intervals
- **Real-time file monitoring**: FSEvents-based directory watching triggers syncs on local changes
- **External drive support**: Auto-detects when external drives are mounted/unmounted
- **Live progress tracking**: Parses rclone JSON logs for real-time transfer progress
- **macOS notifications**: Batch notifications for file changes with "Open Directory" action
- **Fallback remote**: Automatic failover to an alternative remote when the primary is unreachable
- **Auto-fix sync issues**: Automatically runs `--resync` recovery when bisync detects an out-of-sync state (app-wide setting, default ON). Skipped when the profile's external drive is unmounted — a `--resync` against a missing/empty local path can't safely fix anything, so the profile is left in `.driveNotMounted` and resumes normally once the drive reconnects.

### Sync Modes

| Mode | rclone Command | Description |
|------|----------------|-------------|
| Two-Way Sync | `rclone bisync` | Bidirectional sync - changes on either side sync to the other |
| One-Way Upload | `rclone sync local remote` | Local is authoritative, uploads to remote |
| One-Way Download | `rclone sync remote local` | Remote is authoritative, downloads to local |
| Stream (Mount) | `rclone nfsmount` (default) or `rclone mount` | Virtual filesystem - files stream on-demand without local copy |

#### Mount Mode Backends
Stream (Mount) mode supports two backends, chosen per-profile via `mountBackend`
(`MountBackend` enum). Both share the same VFS cache layer, so caching, retention,
pinned-directory warming, and the RC API behave identically across them.

| Backend | rclone command | Requirements | When to use |
|---------|----------------|--------------|-------------|
| **NFS** (`nfs`, default for new profiles) | `rclone nfsmount` | None beyond rclone itself | **Kext-free.** rclone runs a local NFS server and mounts it via the built-in macOS NFS client. No macFUSE, no kernel/system extension, no admin approval — works on locked-down / MDM-managed Macs where kexts are blocked. |
| **macFUSE** (`macfuse`, legacy) | `rclone mount` | macFUSE + official rclone binary | Classic FUSE mount. Broader filesystem compatibility, but needs a kernel extension. Profiles created before the NFS backend existed default here so their behaviour is unchanged on upgrade. |

**Backend defaults & migration:** the default backend is `nfs` everywhere — for
newly created profiles and for profiles persisted before this field existed. A
legacy profile with no `mountBackend` key decodes as `nfs` (the Swift model default)
and the sync script applies the **same `nfs` fallback** when the key is absent from a
profile's JSON, so the app and the generated script never disagree. This means a
profile that previously mounted via macFUSE switches to the kext-free NFS backend on
its next mount (the VFS cache is shared, so no re-download); users who specifically
want FUSE can select **macFUSE** in the profile editor, which re-installs the launchd
agent with `rclone mount`. Legacy profiles also pick up the new `--vfs-cache-max-age`
default (168h) on the next script run — previously the flag was unset and rclone used
its built-in 1h default; total cache size stays bounded by `--vfs-cache-max-size`.

**Auto-mount on startup (`mountAtStartup`, default true):** a per-profile toggle for
whether a Stream profile mounts on its own. It gates the launchd plist's `RunAtLoad`
and `KeepAlive` (both `<true/>` only when enabled) — macOS reloads every LaunchAgent
plist at each login, so those keys, not merely whether the app `launchctl load`ed the
agent, decide login/reboot auto-mount. When enabled: mounts at login and the app also
re-mounts it on launch (`mountProfilesAtStartup`, a safety net if the agent was
unloaded). When disabled: the plist won't auto-start, so the profile mounts only when
the user clicks **Mount** — which does `launchctl load` **plus** `launchctl kickstart`
(`SyncSetupService.startAgent`), because with `RunAtLoad=false` loading alone won't
start the job. `mountAtStartup` is an app/launchd-level setting and is deliberately
**not** written to the script's `{shortId}.json` (the script never reads it); it does
force a plist regeneration on save (part of `needsReinstall`).

**The generated per-profile config (`{shortId}.json`) is the script's single source
of truth.** `SyncSetupService.generateProfileConfig` writes this file (read by the
sync script via `parse_json`); it is *separate* from the full `SyncProfile` that
`ProfileStore` persists to `UserDefaults`. Any mount setting the script consumes
(`mountBackend`, `vfsCacheMaxAge`, `vfsCacheMode`, `downloadConnections`, …) **must be emitted by
`generateProfileConfig`** — a field present in the model, UI, and `Codable` but
missing from this writer silently never reaches the script, which then falls back to
its default. (This was the cause of the "NFS selected but macFUSE still runs" bug:
`mountBackend`/`vfsCacheMaxAge` were added everywhere except `generateProfileConfig`.)

**Cache retention (`vfsCacheMaxAge`):** the "Keep Cached For" setting maps to
rclone's `--vfs-cache-max-age` (default `168h` = 7 days). A used file stays in the
VFS cache until this long has passed *since it was last accessed* (the timer resets
on each open); `--vfs-cache-max-size` still bounds total cache size with LRU
eviction. There is no rclone-native per-file "pin" — `pinnedDirectories` are kept
warm app-side via the RC API + reads (see Offline Files).

**Offline use — read the warm cache and record with no internet, sync on return.**
A Stream mount is a *long-lived, always-up* process (its launchd agent is
`RunAtLoad`+`KeepAlive`), so the intended offline workflow is served entirely by the
live mount, not by unmounting: with a full warm cache and no network, rclone serves
fully-cached file **data** straight from disk, new files **recorded** into the mount
land in the VFS cache as dirty and rclone retries the **write-back** until the remote
returns. Two things make this reliable:
- `--vfs-cache-mode full` (SyncTray's default) — required for both cache-served reads
  and dirty-write queueing.
- `--dir-cache-time 1000h` (~41 days, in `SyncSetupService`'s mount command) — folder
  **listings** must survive the offline period too, or Finder browsing breaks when the
  cache expires and rclone tries to re-list from the unreachable remote. The window is
  deliberately long, not infinite; freshness is preserved by SyncTray's explicit
  recursive `/vfs/refresh` on startup/mount and offline-warm (SMB has no
  `--poll-interval` change notification), so remote-side additions still surface. Do
  NOT symlink-swap the mount point to expose the cache offline: a file written into the
  raw cache tree has no `vfsMeta` sidecar, so rclone never uploads it (the recording is
  lost), and mounting NFS onto a symlink fails with `mount_nfs` exit 66.

**In practice `rclone nfsmount` over SMB does not always ride out a network drop** —
the backend connection can die, the NFS server stall, and macOS drop the volume
("Server connections interrupted"), so the always-up live mount is not a fully
dependable offline surface on its own. A prior release addressed this with a
read-only `"<mount-name> (Offline)"` symlink sitting beside the mount point; that
sibling browse point is retired (`LegacyOfflineLink` only removes what it left
behind on an upgrading install — see "Cache-Only overlay mode" below, which
replaced it with a mount that keeps the SAME mount point usable, read-write, with
no network at all).

**Download connections (`downloadConnections`, default 2, range 1–16):** a per-profile
"Download Connections" control (Advanced Options, mount mode only) that sets how many
files download in parallel. It drives BOTH the mount's `--transfers` and the app-side
offline-warm concurrency (`VFSCacheService`) from a single value — the two are kept in
lockstep. Higher saturates a fast wired link; **1–2 is faster on a contended
wireless/mesh backhaul or a spinning-disk cache**, where extra parallel transfers fight
each other for airtime/seeks and *collapse* aggregate throughput (measured on one Wi-Fi
mesh: 1 stream ≈ 4.7 MB/s, 8 streams ≈ 0.46 MB/s). The default is **2** — a safe value
for the common NAS-over-Wi-Fi case; a profile omitting the key (any profile from before
this field existed) decodes to 2, and users on a fast wired link raise it. Changing it
is in `reconcileAction`'s reinstall set, so it remounts the stream to apply the new
`--transfers`; a hand-edited value is clamped to 1–16 by the decoder.

**NFS backend caveats:** writes require `--vfs-cache-mode` ≥ `writes` (default is
`full`, so this is satisfied). The NFS client couples access/modification times,
which can occasionally cause an extra re-upload after a file is merely viewed in
Finder. `--allow-non-empty` is a FUSE-only option and is ignored for the NFS backend.

The **macFUSE** backend additionally requires the official rclone binary
(Homebrew's rclone can't mount):

```bash
# Only needed for the macFUSE backend — the NFS backend needs none of this.
brew install --cask macfuse
# Restart Mac

# Replace Homebrew rclone with official binary
brew uninstall rclone
curl -O https://downloads.rclone.org/rclone-current-osx-arm64.zip
unzip rclone-current-osx-arm64.zip
cd rclone-*-osx-arm64
sudo cp rclone /usr/local/bin/
sudo chmod +x /usr/local/bin/rclone
```

#### Cache Directory Migration

`rclone mount`/`nfsmount` keeps **two fixed-name sibling trees** under
`--cache-dir` (`vfsCachePath`): `{root}/vfs/{key}` holds the cached file
**data**, and `{root}/vfsMeta/{key}` is a mirror tree of per-file JSON
sidecars — under `--vfs-cache-mode full` (SyncTray's default) this includes
the **downloaded byte-range list**, so `vfsMeta` is load-bearing, not
incidental: relocating `vfs` without it makes rclone treat the cache as
unpopulated and re-download everything. `{key}` is the mounted Fs's **name**
joined with its **root**, e.g. `synology/Kaiju/KAIJU`; the single home for
deriving it is `VFSCacheService.cacheRelativePath(for:)`, called by
`cacheDirectory(for:)`/`cacheSubtreeRoots(for:)`, `CacheMigrationPlanner`, and
`ProfileDetailView`'s Cache Directory move UI, so they cannot disagree about
which subtree a profile owns. Which *name* that first component is, is the
subject of the next section.

#### Cache key — pinned to the primary remote name, no pinning machinery needed

rclone derives the cache location from the Fs it is handed, and an Fs's name is
the **remote name**. `SyncProfile.primaryRemoteName` (the profile's
`rcloneRemote`, colon stripped) is that name, and it is what the mount is
ALWAYS keyed by: `{vfsCachePath}/vfs/{primaryRemoteName}/{remotePath}/…` plus the
`vfsMeta` sidecar tree. There is no per-profile "pinned identity" field, no
migration, and nothing to configure — the mount's Fs is always defined directly
from the primary remote reference (`rcloneRemote:remotePath`), so the cache key
is invariant by construction. This is also why mount mode never streams via a
fallback remote (see "Fallback Remote Pipeline" below) — swapping the Fs is
exactly what would make the key move.

**Known failure mode this guards against.** Defining a remote through
`RCLONE_CONFIG_<NAME>_*` environment variable overrides — the mechanism a PRIOR
release used to keep the cache under the primary's name while actually
connecting through a fallback's transport — makes rclone log "detected
overridden config - adding {hash} suffix to name" and land the cache at
`vfs/synology{jzZaN}/…` instead of `vfs/synology/…` (the retired
`stableCacheIdentity`/`cacheIdentity` fields and `CacheIdentityMigration` type
existed to reconcile this; both are gone). Because mount mode no longer defines
its remote through env-var overrides at all, this can't recur for a mount
going forward — but a tree a PAST run left behind under a suffixed name is
still on disk for upgrading installs.

**Cache key consolidation (`SyncSetupService`'s generated script, "CACHE KEY
CONSOLIDATION").** On every mount start — install, app launch, login, or the
Mount button, so a login mount that runs standalone under launchd (no app in
the loop) is covered too — the script scans `{cache}/vfs/` for a directory
matching `{primary}{suffix}` (`suffix` alphanumeric/`_`/`-`, from the
`{hash}`-suffix pattern above), picks the most-recently-modified candidate if
more than one exists, and renames both its `vfs` and `vfsMeta` subtree into the
unsuffixed `{primary}` location — an atomic same-directory rename, instant even
for a multi-GB cache. It never merges: if the unsuffixed destination is already
populated the stray suffixed tree is left in place untouched (reconciling two
partial `vfsMeta` byte-range sets is how you'd end up serving corrupt bytes).
`vfsMeta` is adopted before `vfs`, so an interrupted run can only ever lose
metadata — the direction rclone recovers from by re-fetching — never leave data
without the byte-ranges that prove it complete. Deferred entirely (not run) while
another rclone mount process already has the same `--cache-dir` open, since
racing a live mount's cache with a rename mid-flight is not safe; it retries on
the next mount start.

#### Cache-Only overlay mode — a union mount that stays usable with no network

**`streamCacheOnly` ("Cache Only" / "Resume Syncing" button next to Unmount in
the Stream status card, default false)** is for the case where the cache is
warm and the remote is slow, far away, or gone. Unlike a read-only mode, this
mount stays fully usable: files can be created and edited while offline, and
the SAME mount point stays valid (a project referencing absolute paths under
the mount point never needs relinking to a sibling folder).

**The mechanism is an rclone `union` remote**, `synctray_cacheonly`, generated
per-profile into a chmod-0600 config at `cacheOnlyConfigPath`
(`{shortId}.cacheonly.rclone.conf`, beside the other per-profile config files —
never inside the overlay tree). Its `upstreams` list has exactly two entries,
order load-bearing (the overlay MUST be listed first — base-first was tried and
returned stale reads from the base):

1. **`overlayPath`** (`{vfsCachePath}/synctray-overlay/{shortId}`, writable) — every
   new file and every edit lands here. Never touches the read-only streaming
   cache.
2. **`{dataPath}:ro`** (the streaming cache's `vfs` data tree, read-only) —
   already-downloaded bytes, served straight from disk.

`action_policy` / `create_policy` / `search_policy` are all `ff` ("first
found") so a listing merges both trees with no duplicates: editing a base file
writes the edit into the overlay and reads it back from there; deleting or
renaming a base-only file fails with a clean "permission denied" (the base is
read-only, by design — there are no whiteout markers, so a deleted overlay
file that shadowed a base file "undeletes" back to the base version); an
atomic save (temp file + rename over the target, Reaper's own pattern) works
because both halves land in the overlay.

**Partial files stay hidden.** Regenerated on every Cache-only mount start:
`cacheOnlyExcludePath` (`{shortId}.exclude.txt`) lists one line per
partially-downloaded file under the streaming cache's data tree, so a
truncated read never surfaces through the union mount.

**Four mount-mode tokens** (`MountMode` in `SyncState.swift`), written to
`mountModePath` (`/tmp/synctray-mount-{shortId}.mode`) right before rclone
starts, all mounting the SAME union remote — the token only changes what the
status card shows and what auto-resume watches for:

| Token | Entered by | Meaning |
|-------|-----------|---------|
| `streaming` | default | Talking to the remote directly through the VFS cache |
| `cache-only-manual` | the user's own "Cache Only" toggle | Never auto-exited |
| `cache-only-pending` | AUTOMATIC — files are still queued in the overlay from a previous Cache Only session | Uploads are draining |
| `cache-only-offline` | AUTOMATIC — the primary remote failed all 3 reachability probe attempts at mount time (a first `--contimeout 3s --timeout 8s` probe, then 2 retries ~5 s apart each capped at 5 s; the retries run only on the unreachable path, so a reachable primary adds no delay and an unreachable one at most ~20 s) | Primary is unreachable right now |

A derived config written by an older app build has no cache-only keys
(`mountModePath` empty) and degrades to streaming-only rather than half-apply a
mode that build doesn't know how to fully wire.

**Sync-back (`OverlaySyncService`).** Switching Cache Only → Streaming (the
"Resume Syncing" button, or automatically — see below) detaches the union
mount and uploads the overlay with a Swift engine before remounting Streaming:
verify-then-delete per file (an overlay file is deleted only after its upload
is confirmed, so a failed or partial upload just leaves it queued — visible as
a pending-upload count in the status card and menu bar), and a conflict check
against the remote's current fingerprint. If the remote's version differs from
the version recorded at cache time (or at the last upload), the local copy
uploads as a **conflict copy** named
`dir/stem.sync-conflict-YYYYMMDD-HHMMSS.ext` (local time, last extension only,
`-2`/`-3`… appended on a name collision) and the remote's version is left
alone — never silently overwritten. **Upload Now** pushes the overlay to the
remote WITHOUT leaving Cache Only — it resolves whichever of primary/fallback
is reachable (`resolveUploadTransport`), so a fallback remote can serve as an
Upload Now target even though mount mode never streams through it (see
"Fallback Remote Pipeline" below) — tracked in `overlayManifestPath`
(`{shortId}.manifest.json`, path + size + mtime at upload time) so a later
drain can tell an already-uploaded, unchanged file from one needing re-upload.

**Automatic offline entry and exit.** The mount enters Cache Only on its own
(`cache-only-offline`) when the primary is still unreachable after the
mount-time probe and its 2 retries (see the table above; the retries ride out
the login race where launchd starts the agent before Wi-Fi/DNS is up) — no user
action needed to keep working. On the way back, `SyncManager`'s auto-resume
monitor (`Self.autoResumeDecision`, pure and unit-tested) only ever acts on an
AUTOMATIC mode (never `.cacheOnlyManual` — that changes only via the user's own
toggle): it reuses the same primary-reachability probe as fallback recovery,
running every **2 minutes**, and requires 3 consecutive stable probes (~6
minutes total) before treating the primary as back. Once stable, it checks
`lsof` on the mount point for anything with a file open (macOS's own
Finder/Spotlight indexing daemons are ignored, since they are always touching
a mounted volume); nothing open resumes immediately, something open instead
posts a one-time "Back on your network" notification and waits. The busy check
**fails closed**: if `lsof` cannot confirm the mount is idle — it failed to
launch, timed out, exited with an unexpected status, or exited 1 with anything
on stderr (e.g. `status error` on an unreadable/stale mount, as opposed to the
silent exit 1 that means "nothing open") — the decision is `.notify`, never an
automatic resume, so a mount is never force-unmounted under an app that might
be mid-write (`SyncManager.lsofBusyCheckResult`, covered by AC-AO2).

**Known limits** (also documented in the Advanced Options caption in the UI):

- Deleting or renaming an already-cached (base) file is unsupported while in
  Cache Only — the base upstream is read-only by rclone's own `union`
  semantics, so this always fails with "permission denied", not a SyncTray bug.
- Switching modes remounts the union/streaming rclone process, which is a
  brief hiccup — not seamless.
- A file uploaded via Upload Now or on resume is **not** carried forward into
  the streaming VFS cache — after remounting Streaming, opening that same file
  re-downloads it once, since the bytes only ever lived in the overlay, not in
  `vfs/`.
- Reaper's `.rpp-bak` backup-file behaviour while saving inside Cache Only has
  not been independently verified — treat it as unconfirmed until checked
  against a real project.
- The pre-existing bisync/sync fallback's cache-suffix issue (documented in
  "Fallback Remote Pipeline" below) is unrelated to and unaffected by any of
  the above — it only affects bisync/sync profiles, never mount mode.

It is an operating mode, not a staged setting: the button applies immediately
(`ProfileDetailView.setCacheOnly`) by persisting **only** `streamCacheOnly` onto
the saved profile and reinstalling with exactly that profile, so unsaved edits
elsewhere in the form are neither applied nor discarded. A **cache-directory
move is refused** while the overlay has pending (undrained) files — both the
CLI (`cache move`) and the save-time prompt check `OverlaySyncService.pendingCount`
and error out rather than relocating an overlay that still owes an upload.

#### Mount preflight — never mount with the cache silently disabled

When `--cache-dir` is not writable, rclone logs `Failed to create vfs cache -
disabling` and **mounts anyway, with no cache at all**. Every read becomes a
remote round trip, which presents as "streaming got mysteriously slow" rather
than as a failure. The usual trigger is a cache directory on an external drive
that is not attached: `/Volumes/<Drive>` is then a root-owned placeholder and
the `mkdir` fails with EPERM. The script's mount branch now preflights the
cache directory and refuses the mount with a logged error instead; launchd's
`KeepAlive` brings the profile up by itself once the drive is back, cache
intact. It releases the lock file *before* its back-off sleep, so a manual
Mount during that window isn't silently swallowed.

The script also expands a leading `~` in `vfsCachePath` **once**, up front, and
uses the result for both the preflight and `--cache-dir`. The field is stored
raw (the CLI and file-backed config keep a user-written `~`, and Swift read
sites expand on read), but the shell passes it through quoted — so an
unexpanded value made rclone create a directory literally named `~` in its
working directory, putting the cache somewhere neither the app nor the
preflight looks. Checking one path while rclone uses another would have made
the preflight worse than useless.

Changing a Stream profile's Cache Directory only re-points rclone by
default — the already-downloaded bytes at the old location are abandoned.
**Cache Directory Migration** physically relocates both trees (copy →
verify byte size → delete per file, with a same-volume atomic-rename fast
path, a free-space preflight, live progress, cancellation, resume, and
auto-rollback on an integrity failure) so a warm cache survives a directory
change. Two profiles can address the **same on-disk bytes** when one
remote path nests inside another's (e.g. `Kaiju/KAIJU` and
`Kaiju/KAIJU/Reaper` sharing a cache root) — `CacheMigrationPlanner`
classifies siblings into **overlapping** (same bytes; an unresolved
overlap rejects the move) vs merely **same-root** (disjoint bytes; offered
as an optional, separate co-migration).

Three entry points, all going through `SyncManager.startCacheMigration` /
`migrateCacheDirectory`:

- **Save-time prompt** — changing Cache Directory and pressing Save in
  `ProfileDetailView` opens `CacheMoveSheet`, offering *Move existing
  cached files* / *Leave them behind* / *Start fresh (clear the old
  cache)*; the move (with progress and cancel) runs BEFORE the profile
  remounts. `SyncManager.cachePathChangeIntent` (`ConfigReconciler.swift`,
  `nonisolated static` — the headless CLI reasons about the same overlap
  classification without a MainActor context) decides whether Save needs
  to prompt at all.
- **Offline Files "Move Cache…"** — `OfflineFilesSection` opens the same
  sheet in destination-picker mode, without editing the profile form.
- **CLI** — `synctray cache move <name|shortId> --to <path>
  [--include-overlapping]`, blocking until done; refuses an unresolved
  overlap unless `--include-overlapping` is passed (there's nobody to
  prompt non-interactively).

The orchestration (`SyncManager.migrateCacheDirectory`) cancels any
in-flight offline warm for the affected profiles first (a warm actively
reads through the mount — racing a move is a corruption path), uses the
existing `SyncSetupService.uninstall` graceful volume detach before moving,
runs the engine off the main actor, persists the new `vfsCachePath`
**only** on a `.completed` outcome (so a `.profile.json` never names an
incomplete cache), then re-installs on **every** exit path — completed,
failed, cancelled, or a thrown error — and re-pushes the FinderSync App
Group data. An external `~/.config/synctray/profiles/*.profile.json` edit
of `vfsCachePath` deliberately does NOT trigger a migration (there's no one
to prompt and a multi-hour unattended relocation from a file write would be
a hostile surprise) — it keeps today's re-point-only `.reinstall` behavior.

New source files: `SyncTray/Services/CacheMigrationPlanner.swift` (pure —
subtree/overlap/exclusion planning, no I/O), `SyncTray/Services/CacheMigrationService.swift`
(the injected-filesystem copy → verify → delete engine), `SyncTray/Models/CacheMigrationProgress.swift`
(published per-profile progress), and `SyncTray/Views/Settings/CacheMoveSheet.swift`
(the shared sheet for both UI entry points).

### How It Works
1. User configures a profile: local path, rclone remote, and sync interval
2. SyncTray generates a shell script and launchd plist for scheduled syncs
3. LogWatcher monitors the sync log file for state changes and progress
4. DirectoryWatcher monitors the local folder for file changes (triggers immediate sync)
5. NotificationService batches and displays file change notifications

## Architecture

```
SyncTray/
├── Models/           # Data models and state types
├── Services/         # Business logic and background services
├── Views/            # SwiftUI views
├── Assets.xcassets/  # App icons and images
└── SyncTrayApp.swift # App entry point and AppDelegate
SyncTrayFinderSync/   # FinderSync app extension (kext-free, sandboxed)
├── FinderSyncExtension.swift # FIFinderSync subclass — contextual menu, badges, IPC
├── Info.plist        # NSExtension point: com.apple.FinderSync
├── SyncTrayFinderSync.entitlements # App sandbox + App Group (7HVK85DZG7.group.com.synctray.app)
└── Assets.xcassets/  # Badge images (badge-cloud, badge-downloaded)
```

### FinderSync Extension

The `SyncTrayFinderSync` app extension adds a right-click Finder contextual menu
(**SyncTray ▸ Available Offline**, a single checkmarked toggle: checked = kept offline,
unchecked = streams online-only) plus cloud/checkmark file badges, for directories
inside rclone NFS mount paths. Release extension bundle ID: `com.synctray.app.findersync`.
Requires no kernel extension (kext-free NFS backend only).

#### App Group IPC Contract

Two distinct IPC mechanisms are used. Both use App Group ID `7HVK85DZG7.group.com.synctray.app`:

| Direction | Mechanism | Key / File | Contents |
|-----------|-----------|------------|----------|
| Host → Extension | `UserDefaults(suiteName: "7HVK85DZG7.group.com.synctray.app")` | `com.synctray.app.mountPaths` | `[String]` — active NFS mount paths |
| Host → Extension | `UserDefaults(suiteName: "7HVK85DZG7.group.com.synctray.app")` | `com.synctray.app.profileData` | `[[String:Any]]` — profileId, pinnedDirectories, vfsCachePath per profile |
| Extension → Host | JSON file in App Group container | `pending-pin-request.json` | `{action, profileId, paths[]}` |
| Extension ↔ Host | Darwin distributed notification | `com.synctray.app.pinRequest` | Zero-payload wake signal — **bidirectional** |

The `com.synctray.app.pinRequest` notification is used **both ways**: the extension posts
it to wake the host when a pin/unpin request file is pending; the host posts it
(`SyncManager.notifyFinderSyncReload`) after it updates the App Group data (on pin/unpin
**and** whenever mount paths change in `updateAppGroupMountPaths`) so the extension
reloads its `directoryURLs` and repaints badges. The host reads/deletes
`pending-pin-request.json` on each notification and on a 1-second fallback poll timer
(active only when mount profiles exist); its own posts find no file → harmless no-op.

#### Extension lifecycle — loading & auto-refresh

Finder (not SyncTray) owns the extension process and **does not reload the plug-in when
the app bundle is replaced** (e.g. by `brew upgrade`) — it keeps serving the pre-upgrade
binary until Finder is relaunched. SyncTray manages this so the user needn't restart
Finder by hand:

- **On quit** (`applicationWillTerminate`) it `pkill`s `SyncTrayFinderSync`, so no stale
  extension process lingers.
- **On launch** (`refreshFinderSyncExtensionIfNeeded`) it re-registers the appex with
  `pluginkit -a`, and — if the app version changed since `SyncTraySettings.finderSetupVersion`
  **and** the extension is enabled — relaunches Finder so it loads the new binary. Gated
  on *enabled* (no Finder flicker for non-Stream users) and *version changed* (at most
  once per upgrade).
- The launch relaunch can race the NFS mount coming up; the extension is re-woken when
  mount paths are written (see the bidirectional notification above), so it re-registers
  `directoryURLs` once the mount establishes.
- The cask's `uninstall quit: "com.synctray.app"` quits the app before an upgrade so the
  quit handler fires. The cask `caveats` still tells users to `killall Finder` as a manual
  fallback. **On a brand-new install the user must enable the extension once** in System
  Settings — a macOS consent gate no app can bypass; the in-app card guides it.

#### Code signing — required to test the extension; disabled on CI/release

macOS **will not load a Finder extension (or grant App Group access) in an unsigned
app**. So the FinderSync menu only appears in a **code-signed** build:

- **Local testing:** set your **Team** on *both* the `SyncTray` and `SyncTrayFinderSync`
  targets (Signing & Capabilities → Automatic), confirm the `7HVK85DZG7.group.com.synctray.app`
  App Group is on both, then Build & Run. Enable it once under System Settings →
  General → Login Items & Extensions → Extensions, and right-click a folder **inside a
  mounted Stream profile's path** (FinderSync only decorates registered mount dirs).
  `pluginkit -m -i com.synctray.app.dev.findersync` should list it once loaded.
- **Debug builds use a `.dev` bundle id** so a dev build never collides with an
  installed release. `BUNDLE_ID_SUFFIX` (`Config/Signing.xcconfig`, `[config=Debug] = .dev`)
  gives Debug the ids `com.synctray.app.dev` / `com.synctray.app.dev.findersync`;
  Release keeps `com.synctray.app` / `com.synctray.app.findersync`. Both extensions
  register independently, so `nr synctray:dev` no longer hijacks the brew app's Finder
  registration (previously the shared id made whichever built last invalidate the other).
  Caveat: if you enable **both** the dev and release extensions, Finder shows two
  "SyncTray" submenus — disable one while iterating. `scripts/dev.sh` targets the `.dev`
  id and the in-app enabled-check switches id via `#if DEBUG`.
- **CI / release build unsigned on purpose.** `CODE_SIGNING_ALLOWED=NO` is **not**
  hardcoded in the project — it is passed on the `xcodebuild` command line by both the
  CI `test` job (`.github/workflows/ci.yml`) and `scripts/release-ci.sh`. This keeps the
  build gate green without signing credentials while letting local dev sign normally.
  Consequence: the brew-distributed (unsigned) app **cannot** show the offline menu —
  shipping it requires Developer ID signing + notarization + App Group provisioning.
  The release pipeline (`scripts/release-ci.sh`) does this automatically when the
  signing secrets are present; setup is documented in [`docs/release-signing.md`](docs/release-signing.md).
  Local dev-setup steps live in [`DEVELOPMENT.md`](DEVELOPMENT.md).

#### Cross-Target String Constants

`kAppGroupID` (`7HVK85DZG7.group.com.synctray.app`), `kMountPathsKey`, and
`kPinRequestNotificationName` (`com.synctray.app.pinRequest`) are defined as string
literals in **both** `FinderSyncExtension.swift` and `SyncManager.swift` independently.
The two targets are separate compilation units. If you rename either constant, rename both.

#### VFS Content Warming (Bug Fix)

`VFSCacheService.warmDirectory(_:for:)` fixes a pre-existing bug: the old
`refreshPinnedDirectories` only called `/vfs/refresh` (listing-cache metadata), which
does not populate the rclone VFS content cache. `warmDirectory` now:

1. Calls `/vfs/refresh` first (listing cache pre-step).
2. Walks `profile.localSyncPath/<dir>` via `FileManager.enumerator`.
3. Opens each file ≤ 100 MB via `FileHandle` and reads 64 KB chunks — the act of
   reading through the NFS mount populates `~/.cache/rclone/vfs/…`.

I/O budget: sequential reads (not concurrent), 2 GB total ceiling per call, cancellable
between files via `try Task.checkCancellation()`.

**Skip files already fully cached (only download the missing delta).** Both
`warmDirectory` and `estimateWarmWork` check each file against the on-disk VFS cache
before reading it, and skip any that are already fully present. The decision is the pure
`VFSCacheService.isCacheComplete(metaJSON:expectedSize:)`: it reads the file's `vfsMeta`
sidecar and returns true iff the recorded `Size` matches, `Dirty` is false, and the
downloaded byte ranges (`Rs`) contiguously cover `[0, size)`. The estimate excludes cached
files from `filesTotal`/`bytesTotal` and reports them as `filesAlreadyCached`/
`bytesAlreadyCached` (surfaced in `OfflineFilesSection` as "N already offline" / "All N
files already offline"), so a re-warm of a warm cache is near-instant instead of re-fetching
the whole pinned set. `cacheSubtreeRoots(for:)` derives the `{vfs, vfsMeta}` roots purely
from the profile (sharing `cacheRelativePath(for:)` with `cacheDirectory(for:)`), and the
per-file lookup keys on the **mount-relative** path. Covered by `ConfigSelfTest`'s AC-23.

**Warm on mount detection, not just app-driven mounts.** A Stream profile with
`mountAtStartup` is mounted by launchd at login/reboot (`RunAtLoad`) *without the app*,
so when the app later launches it finds the volume already mounted and
`mountProfilesAtStartup` skips it — meaning the app-driven mount warm never runs and
files added to the remote while away are never pulled into the offline cache. The 5s
mount monitor (`reconcileMountStatesOffMain`) closes this: when it first observes a
pinned mount-mode profile mounted, it fires a one-time `startWarm(trigger: "startup")`
(whose step 1 is a recursive `/vfs/refresh`, so newly-added remote files become visible
and download as uncached). The decision is the pure `SyncManager.shouldAutoWarmOnMount`,
gated by an `autoWarmedMounts` set so it warms **exactly once per mount session** — not
every 5s tick (`startWarm` supersedes rather than coalesces, so per-tick calls would
thrash) — and re-arms when the profile is seen unmounted, so a later remount warms again.
The app-driven mount path (`mountProfile`) sets the same flag so the two can't double-fire.
This also covers a slow fallback mount that established after `mountProfile`'s poll gave
up. Covered by `ConfigSelfTest` AC-24.

**The check deliberately ignores modtime — and that is the whole point.** Under
`--vfs-cache-mode full` rclone re-validates a `size,modtime` fingerprint on every open;
on a **fingerprint-unstable backend (SMB especially)** the modtime drifts, the fingerprint
check fails, and rclone re-downloads a *complete* cache copy. That is exactly the bug this
guards against (observed: a manual warm re-fetching all 12,179 files / ~95 GB over SMB at
~1.2 MB/s ≈ 22 h, per the `synctray.offline.warm.*` telemetry), so gating the app-side skip
on modtime would re-inherit it. By skipping the open entirely for a byte-complete cache
entry, rclone never gets the chance to needlessly re-fetch. Trade-off: a **same-size**
in-place remote edit won't re-warm until the cache entry is otherwise invalidated (a
different-size edit still does, since the size check fails). On the **fallback** remote the
primary-derived cache roots may not resolve, in which case the skip simply doesn't apply and
the warmer reads as before — safe degradation.

### Models/

| File | Purpose |
|------|---------|
| `SyncProfile.swift` | Profile model with sync paths, remote config, fallback remote config, computed file paths |
| `SyncState.swift` | Sync state enum, progress struct, file change model, `ActiveTransport`, `MountMode` (the four Cache-only-aware mount states), `SyncLogPatterns` for log parsing |
| `RcloneLogEntry.swift` | JSON models for parsing rclone `--use-json-log` output |
| `Settings.swift` | Global app settings (debug logging toggle, auto-fix sync issues toggle) |
| `CacheMigrationProgress.swift` | Published per-profile progress for a cache-directory move (`CacheMigrationProgress`, shared `TransferFormat` byte/rate/elapsed helpers) |

### Services/

| File | Purpose |
|------|---------|
| `SyncManager.swift` | Central orchestrator - manages all profile states, log watchers, directory watchers |
| `ProfileStore.swift` | File-backed, file-authoritative profile persistence — reads/writes per-profile `{shortId}.profile.json` files (see "File-Backed Configuration" below); dual-writes the legacy `syncProfiles` UserDefaults blob write-only |
| `SyncSetupService.swift` | Generates sync scripts, launchd plists, manages agent install/uninstall |
| `LogWatcher.swift` | FSEvents + polling hybrid file watcher for rclone log files |
| `LogParser.swift` | Parses plain text and JSON log lines into typed `ParsedLogEvent` |
| `DirectoryWatcher.swift` | FSEvents-based directory monitoring with debouncing |
| `ConfigFileWatcher.swift` | FSEvents watcher on `~/.config/synctray` for external profile/settings edits; self-write suppression via `ConfigSelfWriteRegistry` |
| `ConfigReconciler.swift` | `SyncManager.reconcileAction` (shared launchd install/uninstall/reinstall delta logic), `SyncManager.applyExternalCreateIfNeeded`/`ExternalCreateOutcome` (create-from-file decision), `warmReconcileNeeded`/`applyWarmReconcileIfNeeded` (orthogonal app-side warm delta — pinned dirs / warm-exclude globs), and `SettingsReconciler` (isolated launch-at-login apply) |
| `AppSettingsFileStore.swift` | Reads/writes `~/.config/synctray/settings.json` — an enumerated safe-key mirror of `SyncTraySettings` (no secrets, no telemetry IDs) |
| `ConfigSchemaInstaller.swift` | Copies the committed JSON Schemas into `~/.config/synctray/schema/` at launch |
| `ConfigSelfTest.swift` | `#if DEBUG` host self-test suite (`SyncTray --self-test`) — round-trip (incl. `warmExcludePatterns`), migration + migration-integrity, reconcile-delta, warm-reconcile-trigger, warm-skips-cached, self-write, isolated-login, external-create, and CLI assertions |
| `NotificationService.swift` | Batched macOS notifications with action support |
| `TelemetryService.swift` | Opt-in OTel telemetry (traces, metrics, logs) via OTLP/HTTP |
| `CacheMigrationPlanner.swift` | Pure cache-directory-move planning — `CacheTreeKind` (`vfs`/`vfsMeta`), subtree/overlap/exclusion resolution, no I/O; refuses a move while the profile's Cache-only overlay has pending files |
| `CacheMigrationService.swift` | The cache-move engine — injected `CacheMigrationFileSystem`, free-space preflight, copy → verify → delete per file with a same-volume rename fast path, cancellation, resume, rollback |
| `OverlaySyncService.swift` | Cache-only overlay sync-back engine — scans the overlay, plans per-file upload/conflict decisions (`plan`), uploads with verify-then-delete (`run`, `.drain`/`.keep` modes), conflict-copy naming, and the manifest read/write "Upload Now" relies on |
| `LegacyOfflineLink.swift` | Cleans up the retired "(Offline)" sibling browse point left behind by an upgrading install; never creates anything |

### CLI/

| File | Purpose |
|------|---------|
| `SyncTrayCLI.swift` | Headless `synctray` CLI — `CLICommand`, `parse`/`execute`/`run` (pure over `CLIEnvironment`), `doctorChecks`, `resolveProfile`, `applyProfileAssignment` (bounded `profile set` key set); mutating commands (`profile create`/`show`/`set`/`enable`/`disable`/`delete`, `sync`, `mount`/`unmount`, `install`/`reinstall`) drive `ProfileStore.writeProfileFile` + `SyncSetupService`; `runMeasured` records one `synctray.cli.invoked` event + flushes; dispatched from `SyncTrayApp.init` before SwiftUI/`SyncManager` |
| `CLIShimInstaller.swift` | Writes/refreshes the `~/.local/bin/synctray` shim on every launch; marker-guarded so it never clobbers a non-SyncTray file |

### File-Backed Configuration

`~/.config/synctray/` is the editable, authoritative surface for SyncTray's
configuration: an external agent or human can hand-edit these files and the
running app applies the change live, without a restart.

| Path | Contents | Notes |
|------|----------|-------|
| `profiles/{shortId}.profile.json` | Full `SyncProfile`, including `isEnabled`, `isMuted`, `mountAtStartup`, and the app-side warm fields `pinnedDirectories` / `warmExcludePatterns` | NEW authoritative file. Written by `ProfileStore.save()` (encodes the whole model, so any new `SyncProfile` field flows in automatically); read by `ProfileStore.load()` (file-authoritative). References `../schema/profile.schema.json` via `$schema`. |
| `profiles/{shortId}.json` | Derived, script-only subset (frozen key set) | Unchanged, byte-for-byte — this is `SyncSetupService.generateProfileConfig`'s output, consumed only by the sync shell script. The app never reads it back. |
| `settings.json` | Enumerated safe subset of `SyncTraySettings` (`debugLoggingEnabled`, `autoFixSyncIssues`, `telemetryEnabled`, `launchAtLogin`) | Written by `AppSettingsFileStore`. Never contains secrets or telemetry identifiers (`installationId`, `anonymousUserId`). |
| `schema/profile.schema.json`, `schema/settings.schema.json` | Committed JSON Schemas | Copied out of the app bundle by `ConfigSchemaInstaller` at every launch. Kept in lockstep with `SyncProfile.CodingKeys` by the fail-closed `scripts/check-schema-in-sync.sh`, run locally and in CI. |

**Live apply, not a struct swap.** A single `ConfigFileWatcher` (FSEvents,
~1s debounce) watches the whole `~/.config/synctray` directory. Every edit —
from the UI's Save button or an external file write — routes through the SAME
reconcile path (`SyncManager.applyExternalProfileEdit` /
`applyExternalSettingsEdit`), which mirrors the reinstall/enable/disable
decision `ProfileDetailView.saveProfile` used to compute inline (now shared
via `SyncManager.reconcileAction`, `ConfigReconciler.swift`). A watcher that
only swapped the in-memory struct would leave a running launchd agent stale
after an external edit — this is why the file, not memory, is authoritative,
and why both paths share one decision function.

**Creation via file, not just editing.** Dropping a NEW `*.profile.json` whose
`id` is UNKNOWN to `ProfileStore` creates that profile — this is no longer
silently ignored. `applyExternalProfileEdit` routes an unknown-but-decodable id
to `SyncManager.applyExternalCreateIfNeeded` (`ConfigReconciler.swift`): the
profile is always persisted; the launchd agent is installed only when it's
`isEnabled && isValid`, so an agent can stage a profile and flip it on in a
second edit. A dropped file whose basename isn't the canonical
`{shortId}.profile.json` is rewritten to the canonical name and the original
pruned (the canonical write notes its own hash in `ConfigSelfWriteRegistry`, so
this can never loop). See `ConfigSelfTest`'s AC-C1–AC-C5 for the exact
enabled/disabled/garbage/canonicalize/telemetry matrix.

**Threat model — this is a conscious acceptance, not an oversight.** Creating and
installing a launchd agent from a dropped file is the deliberate goal: an agent or
a human edits files under `~/.config/synctray` to set SyncTray up. It does not
widen the trust boundary. Every writer of `~/.config/synctray/profiles/` already
runs as the user, and a same-user process can write a `~/Library/LaunchAgents/*.plist`
and `launchctl load` it directly — SyncTray adds no privilege the attacker lacked.
The profile files are also credential-free: rclone remotes and secrets live in
`~/.config/rclone/rclone.conf`, never here, so a malicious drop can schedule an
agent but can't exfiltrate or forge credentials through this path.

**Warm reconcile is orthogonal to the launchd reconcile.** Editing an app-side
warm field — `warmExcludePatterns` or `pinnedDirectories` — changes what the VFS
warmer downloads, not the launchd script/plist/agent, so `reconcileAction`
returns `.none` for it. `applyExternalProfileEdit` therefore ALSO runs a separate
app-side warm reconcile (`applyWarmReconcileIfNeeded` → `applyWarmReconcile`): on
a currently-mounted mount-mode profile it re-pushes the App Group data and
re-warms via `VFSCacheService`, reusing the exact primitives the in-app
pin/unpin path uses (`updateAppGroupMountPaths` + `startWarm`) so the two can't
drift. A warm-only edit NEVER reinstalls the agent or remounts.

**Self-write suppression.** `ConfigSelfWriteRegistry` tracks the content hash
of every file SyncTray itself writes; `ConfigFileWatcher.shouldReconcile`
drops an FSEvent whose file content hash matches a just-noted self-write, so
the app never reacts to its own writes.

**Launch-at-login isolation.** `settings.json`'s `launchAtLogin` key is
read-write via `SMAppService.register`/`unregister`, applied through
`SettingsReconciler` in a path ISOLATED from every other safe key and from all
profile state — a thrown `SMAppService` error can never corrupt profile
reconcile or another setting.

**Migration v4 — retired.** `MigrationV4Retired` (`MigrationRunner.swift`) is a
kept-but-no-op placeholder for the removed cache-pinning migration (see "Cache
key" above) — kept, not deleted, so the schema-version numbering stays
monotonic for a machine that already ran v4; deleting the slot would make its
`schemaVersion == 4` skip whatever migration claims v4 next.

**Migration.** `MigrationV3BlobToPerProfileFiles` (`MigrationRunner.swift`)
moves the legacy `syncProfiles` UserDefaults blob to per-profile files on
first launch. The blob is retained as a write-only mirror for one release
(rollback safety) — `ProfileStore.load()` only reads it back when NO
per-profile file exists yet, so the mirror can never create a split-brain.
`writeProfileFiles` returns a `WriteResult` and debug-logs an integrity mismatch
when the number of files accounted for on disk is fewer than the profiles in the
source blob, so a silent partial migration is observable.

**Testing.** SyncTray has no XCTest target (Option A — see `docs/` if this
changes). `ConfigSelfTest.swift` (`#if DEBUG`) runs as `SyncTray --self-test`
and exits non-zero on any failed assertion; `scripts/check-schema-in-sync.sh`
is the separate, fail-closed schema-drift gate.

### Views/

| File | Purpose |
|------|---------|
| `MenuBarView.swift` | Menu bar dropdown with profile status, recent changes, quick actions |
| `SettingsView.swift` | Settings window with profile list and detail editor |
| `AppSettingsView.swift` | Global app settings — launch at login, telemetry toggle, debug logging |
| `ProfileListView.swift` | Sidebar list of profiles with add/delete controls |
| `StatusHeaderView.swift` | Header showing current sync state and progress |
| `SyncProgressDetailView.swift` | Detailed per-file transfer progress during sync |
| `RecentChangesView.swift` | List of recently synced files |
| `TelemetryOptInBanner.swift` | Dismissable banner prompting telemetry opt-in (consent-versioned) |
| `TelemetryDetailsSheet.swift` | Full privacy disclosure sheet — reachable from wizard, banner, and settings |
| `SetupWizardView.swift` | New-profile creation wizard, including optional `.helpImprove` epilogue step |

## Agent-Editable Configuration & CLI

`~/.config/synctray/` (see **File-Backed Configuration** above) and the
headless `synctray` CLI together make SyncTray fully scriptable by an agent —
bootstrapping a new sync, checking health, and introspecting profiles, all
without opening the app UI.

### Bootstrapping a profile by dropping a file

A `*.profile.json` written into `~/.config/synctray/profiles/` with a NEW,
well-formed `id` CREATES that profile (see **Creation via file, not just
editing** above) — an agent no longer has to go through the UI to start a
sync. Validate the file against `~/.config/synctray/schema/profile.schema.json`
before writing it; the schema's top-level `description` documents the
creation behavior. Only FIVE keys are required — `id`, `name`, `rcloneRemote`,
`remotePath`, `localSyncPath` — so an agent can author a minimal profile and
let every other field take its default (the decoder fills `syncMode=bisync`,
`mountBackend=nfs`, `syncIntervalMinutes=5`, `isEnabled=false`, …, all mirrored
from the memberwise-init defaults; an app-written file that emits every key
still round-trips unchanged). A profile is created whenever the file decodes
successfully and `id` is a well-formed UUID; the launchd agent installs (i.e.
the sync actually starts running) only when the profile is also `isEnabled`
and `isValid` (non-empty `name`/`rcloneRemote`/`remotePath`/`localSyncPath`) —
so an agent can stage a profile disabled, then flip `isEnabled` in a follow-up
edit once it's confident the fields are correct.

### The `synctray` CLI

SyncTray installs a shim at `~/.local/bin/synctray` on every launch
(`CLIShimInstaller`, called from `AppDelegate.applicationDidFinishLaunching`)
that `exec`s the running app's binary with whatever subcommand you pass —
**`~/.local/bin` must be on `PATH`** for the bare `synctray` command to
resolve (matches the existing `~/.local/bin/synctray-sync.sh` convention). The
shim is idempotent and marker-guarded: it refreshes on every launch (so it
survives a `brew upgrade`/app move) but is never written over a file that
isn't SyncTray's own.

**Inspect** (read-only):

| Command | Purpose |
|---------|---------|
| `synctray doctor` | Health report: rclone found + version, config schemas installed, per-profile derived-config presence, launchd agent loaded (enabled profiles), stale lock files, remote reachability. Exits non-zero iff any check is `[fail]`; `[warn]` never fails the run. |
| `synctray status [name\|shortId]` | One tab-separated line per profile (or a single one): `enabled=`, `agent=loaded\|unloaded\|n/a`, `running=` (lock present), `last=started\|completed\|failed\|none` (from the log tail via the shared `SyncLogPatterns`). |
| `synctray profiles` | List every profile: name, shortId, mode, `enabled=`, `remote=` — no secrets. (`profile list` is an alias.) |
| `synctray profile show <name\|shortId>` | Print one profile's FULL config as pretty, sorted-key JSON — the same shape as its `.profile.json`, so an agent can `show` → edit → `profile create`/`profile set` round-trip. No secrets (credentials live in `rclone.conf`). |
| `synctray logs <name\|shortId> [--follow]` | Print (or `tail -f`) that profile's sync log. |
| `synctray test-remote <name\|shortId>` | Probe one profile's remote with `rclone lsd` under a hard timeout; prints `reachable: <remote>` or the real rclone stderr. |
| `synctray listremotes` | `rclone listremotes`, passthrough. |

**Configure** (mutating — headless-capable, no running app required):

| Command | Purpose |
|---------|---------|
| `synctray profile create --from <file>` / `... create -` | Create a profile from a `.profile.json` file (or stdin `-`). Validates by decoding (a bad file exits `65` with the decode error — the feedback an agent needs); refuses a colliding `id`/`shortId` (`1`); writes the authoritative file, then installs the launchd agent iff `isEnabled && isValid` — the SAME persist-then-install rule as the file-watcher create path (`applyExternalCreateIfNeeded`). |
| `synctray profile enable <name\|shortId>` | Set `isEnabled=true`, rewrite the file, install the agent. |
| `synctray profile disable <name\|shortId>` | Set `isEnabled=false`, rewrite the file, uninstall the agent. |
| `synctray profile set <name\|shortId> <key> <value> [<key> <value> …]` | Edit fields on an existing profile from a BOUNDED key set (mirrors `SyncProfile.CodingKeys` minus `id`/`isEnabled`/`fallbackRequiresCacheRebuild`; positional `key value` pairs, comma-separated lists), rewrite the authoritative `.profile.json`, then drive the launchd delta `SyncManager.reconcileAction` dictates (reinstall/remount as needed). Validates ALL assignments against a copy first — an unknown key or invalid value exits `65` and writes nothing. Use `enable`/`disable` for `isEnabled`; a `vfsCachePath` change re-points only (`cache move` for a warm relocation). |
| `synctray profile delete <name\|shortId>` | Uninstall the agent (detaching a mounted volume first) and remove the `.profile.json`. |
| `synctray install <name\|shortId>` | Install an already-enabled profile's launchd agent (idempotent; runs `SyncSetupService.install`). Complements `profile enable`, which early-returns without installing when the profile is ALREADY enabled — so `install` re-creates an agent that went missing. Refuses a disabled or incomplete profile. Never flips `isEnabled`. |
| `synctray reinstall <name\|shortId>` | Regenerate script+plist and reinstall the agent (uninstall → install), i.e. the settings-save reinstall path; for a mounted Stream profile this detaches then remounts. Works for any sync mode. Refuses a disabled profile. |

**Operate:**

| Command | Purpose |
|---------|---------|
| `synctray sync <name\|shortId>` | Run one sync now and BLOCK until it finishes, returning the script's exit code — exactly what the app's `triggerManualSync` runs (`bash <sharedScript> <configPath>`), lock-file-guarded against a concurrent scheduled run. Refuses a Stream (mount) profile (use `mount`). |
| `synctray mount <name\|shortId>` | Mount a Stream (mount-mode) profile now — `loadAgent` + `startAgent` (`launchctl kickstart -k`, the same pair the app's `mountProfile` uses) — then BLOCK polling `isMounted` up to ~60s. Returns `nil`/exit 0 on a confirmed mount (or if already mounted), else exits non-zero with the tail of the sync log so the real reason (auth, unreachable remote) is visible. Refuses a non-mount profile. |
| `synctray unmount <name\|shortId>` | Unmount a mounted Stream profile — graceful+forced `diskutil unmount` then unload the agent so `rclone nfsmount` actually exits (`SyncSetupService.unmount`). Refuses a non-mount profile. |
| `synctray cache move <name\|shortId> --to <path> [--include-overlapping]` | Relocate a Stream profile's rclone VFS cache (both the `vfs` content tree and the `vfsMeta` byte-range-list tree) to `<path>` and BLOCK until it finishes, returning non-zero on rejection or failure. Detaches/reinstalls around the move like the app does. Refuses a non-mount profile, and refuses an overlapping sibling profile (same on-disk bytes) unless `--include-overlapping` is passed — there's nobody to prompt non-interactively. See "Cache Directory Migration" above. |

`<name|shortId>` resolution tries an exact `shortId` match first, then a
case-insensitive `name` match; an unmatched (or ambiguous) target exits
non-zero with a greppable `error: no profile matches "<target>"`.

**The mutating commands operate through the file-backed config, so they work
whether or not the menu-bar app is running:** they write the authoritative
`.profile.json` and drive `SyncSetupService` install/uninstall directly (the
launchd delta chosen by the shared `SyncManager.reconcileAction`). When the app
IS running, its `ConfigFileWatcher` also sees the write and reconciles — the two
converge on identical files and one loaded agent, so running both is redundant,
not conflicting. Profile files stay credential-free (rclone secrets live in
`~/.config/rclone/rclone.conf`), so nothing the CLI writes carries a credential.

**Dispatch and safety.** `SyncTrayCLI.dispatch` is checked at the very top of
`SyncTrayApp.init` — before `--self-test`, before `MigrationRunner`,
`TelemetryService.configure()`, or `SyncManager()` — and `exit()`s the process
before any of that runs. A CLI invocation NEVER opens a window and NEVER
starts a background watcher or timer; `dispatch` returns `nil` (falling
through to the normal app launch) for a bare launch and for `-`-prefixed args
(`--self-test`, macOS's `-psn_…`), except `-h`/`--help`.

**Measurable.** Every real invocation records exactly one `synctray.cli.invoked`
counter + `CLI invoked` structured log (bounded command verb + `ok`/`error` +
exit code + duration — never args, paths, profile names, or remotes) and flushes
before exit (`runMeasured` → `TelemetryService.recordCLIInvocation` +
`flushForExit`). It is gated on the user's telemetry opt-in, so a disabled CLI
does no setup, no network, and prints nothing extra. The self-test path
(`execute` with a fake `CLIEnvironment`) never touches telemetry.

**Pure core / impure shell.** `SyncTrayCLI.parse`/`execute`/`run`/`doctorChecks`
are pure over an injected `CLIEnvironment` (rclone invocation, profile reads +
writes, install/uninstall, sync-script run, `launchctl`, stdio) — `ConfigSelfTest`'s
AC-CLI1–AC-CLI6 drive the full dispatch/doctor/resolution/shim-install AND the
create/enable/disable/delete/sync side-effect routing against spies, with no real
process/filesystem/launchd touched. Every real `rclone` invocation runs through a
hard-timeout watchdog (mirrors `RcloneLocator`'s login-shell probe), since
SMB/WebDAV remotes can hang past their own timeouts.

**Privacy.** The CLI's output goes to the invoking terminal, not telemetry —
`test-remote`/`profiles` printing a remote name to stdout is fine; CLI mode
never calls `TelemetryService.configure()`, so nothing from a CLI invocation
is ever sent anywhere.

## Data Flow

### Sync Monitoring Pipeline
```
launchd triggers sync script
        ↓
Script writes to log file (~/.local/log/synctray-sync-{shortId}.log)
        ↓
LogWatcher detects file changes (FSEvents + polling fallback)
        ↓
LogParser parses lines → ParsedLogEvent (syncStarted, stats, fileChange, syncCompleted, etc.)
        ↓
SyncManager updates state dictionaries (profileStates, profileProgress, etc.)
        ↓
SwiftUI views react to @Published changes
```

### File Change Detection Pipeline
```
User modifies file in local sync folder
        ↓
DirectoryWatcher receives FSEvents callback
        ↓
Filters out metadata files (.DS_Store, ._*, .tmp, etc.)
        ↓
Debounces rapid changes (15 second window)
        ↓
SyncManager.triggerManualSync() called
        ↓
Sync script executed → log written → monitoring pipeline picks up
```

### Fallback Remote Pipeline
```
Sync script starts
        ↓
Check if FALLBACK_REMOTE is configured (from profile JSON)
        ↓
If set: rclone lsd primary remote (3s connect timeout)
        ↓
Unreachable? → Log "using fallback: X"
    ├─ Same wire type + no path change (fallbackRequiresCacheRebuild=false):
    │   env var overrides swap transport (preserves bisync cache)
    └─ Different wire type OR explicit path (fallbackRequiresCacheRebuild=true):
        swap entire REMOTE reference (bisync rebuilds listings, ~12s)
        ↓
Reachable? → Log "Using primary remote: X"
        ↓
LogParser detects transport message → SyncManager.profileTransports updated
        ↓
MenuBarView shows transport icon (wifi=primary, antenna=fallback)
```

**Primary recovery (fallback → primary switch-back).** The reachability check above runs
once per *script execution*. Sync/bisync profiles re-run on their `StartInterval`, so they
naturally return to the primary on the next scheduled sync once it's reachable. A **mount**
is a long-lived `rclone nfsmount` that picks its remote once at mount time (its launchd
agent is `RunAtLoad`+`KeepAlive`, no `StartInterval`), so it would otherwise stay on the
fallback until the next relaunch/login/manual remount. `SyncManager.startPrimaryRecoveryMonitor`
closes that gap: a 2-minute timer probes the primary (`isRemoteReachable`, hard-timeout —
SMB can hang past its own timeouts) for any mounted mount-mode profile currently on the
fallback (`ActiveTransport.fallback`), and when the primary is reachable again it remounts
on the primary (`remountOnPrimary` = unmount → mount, so the script re-picks the remote).
The switch causes a brief mount hiccup; `recoveringToPrimary` guards against stacking remounts.

**Bisync cache preservation:** When primary and fallback remotes share the same
rclone wire type (e.g., WebDAV LAN → WebDAV QuickConnect, both `type = webdav`)
and `fallbackRemotePath` is empty, the sync script uses `RCLONE_CONFIG_*`
environment variable overrides to change the transport while keeping the rclone
remote name unchanged. This means bisync's listing cache (keyed by remote name +
path) remains valid across failover events.

When primary and fallback have **different** wire types (e.g., SMB → SFTP), the
script swaps the full remote reference to `<fallbackRemote>:<path>` regardless of
whether `fallbackRemotePath` is set. This forces bisync to rebuild listings on
the first switch (~12s for 85K files, no data re-download) but avoids cache
poisoning from byte-level filename encoding differences (macOS SMB normalises to
NFD; SFTP passes NFC verbatim — same human-readable name, different byte
sequence).

**Mount mode is excluded from this branch entirely — it never streams via a
fallback remote, full stop.** The script guards the whole fallback block with
`SYNC_MODE != "mount"`, so a mount's Fs is always defined directly from the
primary `rcloneRemote:remotePath` reference; there is no env-var-override path
and no full-remote-swap path for mount. This is deliberate: the VFS cache is
keyed by `{vfsCachePath}/vfs/{primaryRemoteName}/{remotePath}/…` (see "Cache
key" above), and EITHER kind of remote swap would risk moving that key —
env-var overrides make rclone suffix the cache name (`vfs/synology{jzZaN}/…`,
the failure mode "Cache key consolidation" cleans up), and a full swap would
land the fallback's cache in a second `vfs/{fallback}/` tree and re-download
every file (observed: `vfs/synology` 640K vs `vfs/synology-sftp` 6.7G for one
profile). A mount with a fallback configured instead reacts to an unreachable
primary by entering `cache-only-offline` (see "Cache-Only overlay mode" above)
— it stays mounted on the primary's own Fs, never resolving the fallback into
a connection at all. `fallbackRemotePath` therefore stays meaningful only for
bisync/sync profiles, whose fallback branching is unchanged and still carries
the NFD/NFC cache-suffix caveat documented below.

The branching condition is determined at profile install/save time by comparing
`provider.rcloneType` for the primary and fallback remotes (read via
`RcloneConfigService.readRemoteConfig`), stored as `fallbackRequiresCacheRebuild`
in the profile JSON. Profiles created before this field was added default to
`false` (legacy env-var-override behaviour). The field re-evaluates on every
profile save, so users can correct it by re-saving the profile.

## Key Design Patterns

### Multi-Profile State Management

SyncManager maintains parallel dictionaries keyed by profile UUID:

```swift
@Published private(set) var profileStates: [UUID: SyncState] = [:]
@Published private(set) var profileProgress: [UUID: SyncProgress] = [:]
@Published private(set) var profileErrors: [UUID: String] = [:]
@Published private(set) var profileTransports: [UUID: ActiveTransport] = [:]
private var logWatchers: [UUID: LogWatcher] = [:]
private var directoryWatchers: [UUID: DirectoryWatcher] = [:]
// Auto-fix backoff (in-memory, not persisted):
private var autoFixAttempts: [UUID: [Date]] = [:]     // timestamps of recent fix attempts
private var autoFixSuppressed: Set<UUID> = []          // profiles where auto-fix is paused
```

This allows independent state tracking per profile while maintaining a single source of truth.

### @MainActor Thread Safety

SyncManager is marked `@MainActor` to ensure all state mutations happen on the main thread:

```swift
@MainActor
final class SyncManager: ObservableObject {
    // All @Published properties are safely mutated on main thread
}
```

Background work (process execution, file I/O) happens on dispatch queues with results marshaled back to main actor.

### Hybrid File Monitoring

LogWatcher uses FSEvents as primary mechanism with polling fallback:

1. **FSEvents**: Low-latency file change detection via `DispatchSource.makeFileSystemObjectSource`
2. **Polling fallback**: Timer-based check every 2.5-5 seconds catches missed events
3. **Inode tracking**: Detects file replacement (atomic writes) and reopens file handle

### Centralized Log Pattern Matching

`SyncLogPatterns` enum in `SyncState.swift` provides single source of truth for log parsing:

```swift
SyncLogPatterns.isSyncStarted(message)
SyncLogPatterns.isSyncCompleted(message)
SyncLogPatterns.isSyncFailed(message)
SyncLogPatterns.extractExitCode(from: message)
SyncLogPatterns.cleanErrorMessage(message)
```

Used by both `LogParser` and `SyncManager` for consistent behavior.

## Critical Rules

### 1. Threading & Main Thread Safety
**NEVER access @State, @Binding, @Published, or any UI-related properties from a background thread.**

When dispatching work to background threads:
1. Capture ALL needed values from state properties BEFORE dispatching
2. Use explicit `self.` when updating state from within closures
3. ALWAYS update UI state on the main thread via `DispatchQueue.main.async`

```swift
// CORRECT
func doBackgroundWork() {
    // Capture values on main thread FIRST
    let capturedValue = self.someStateProperty
    let capturedPath = self.localSyncPath

    DispatchQueue.global(qos: .userInitiated).async {
        // Use captured values, not state properties
        let result = process(capturedPath)

        // Update UI on main thread
        DispatchQueue.main.async {
            self.isLoading = false
            self.result = result
        }
    }
}

// WRONG - will cause freezing/crashes
func doBackgroundWork() {
    DispatchQueue.global(qos: .userInitiated).async {
        let path = self.localSyncPath  // BAD: accessing @State from background
        // ...
        isLoading = false  // BAD: updating @State from background
    }
}
```

### 2. Process Execution
- Always run external processes (rclone, shell commands) on background threads
- Use `Process` with pipes for stdout/stderr
- Set `readabilityHandler` for real-time output streaming
- Remember to nil out handlers after process completes

### 3. SwiftUI Best Practices
- Use `.controlSize(.small)` or `.controlSize(.mini)` for inline spinners in buttons
- Avoid `scaleEffect()` for sizing ProgressView - it causes layout issues
- Keep views focused and extract complex logic into helper functions
- Use `@State` for view-local state, `@ObservedObject` for shared state

### 4. File Operations
- Use FileManager for local file operations
- Handle errors gracefully with user-friendly messages
- Create directories with `withIntermediateDirectories: true`
- Always check if files/directories exist before operations

### 5. Error Handling
- Provide actionable error messages to users
- Log detailed errors for debugging
- Offer recovery actions when possible (e.g., "Fix Sync Issues" button)
- **Clear cached errors** when config changes or fix operations start:
  ```swift
  syncManager.clearError(for: profile.id)
  ```

### 6. State Consistency
- When updating profile configuration, clear related cached state:
  ```swift
  // Profile paths changed - clear any stale errors
  syncManager.clearError(for: profile.id)
  // Restart watchers with new paths
  syncManager.refreshSettings()
  ```
- Use `SyncLogPatterns` for all log message categorization to maintain consistency

## Debugging

### Enable Debug Logging
In Settings, toggle "Debug Logging" to enable verbose output. Debug messages are written via `SyncTraySettings.debugLog()` and appear in the sync log files.

### Inspect launchd Agents
```bash
# List SyncTray agents
launchctl list | grep synctray

# Check agent status
launchctl print gui/$(id -u)/com.synctray.sync.{shortId}

# View agent definition
cat ~/Library/LaunchAgents/com.synctray.sync.*.plist
```

### View Sync Logs
```bash
# Tail live log
tail -f ~/.local/log/synctray-sync-{shortId}.log

# View profile config
cat ~/.config/synctray/profiles/{shortId}.json
```

### rclone bisync Cache
rclone bisync maintains state in:
```
~/.cache/rclone/bisync/
```

To force a fresh sync, use "Fix Sync Issues" in the app (runs `--resync`).

### Lock Files
If sync appears stuck, check for stale lock files:
```bash
ls -la /tmp/synctray-sync-*.lock
```

The app automatically cleans stale locks on startup.

## Build & Test

```bash
# Build the project
xcodebuild -scheme SyncTray -destination 'platform=macOS' build

# Build with verbose output
xcodebuild -scheme SyncTray -destination 'platform=macOS' build 2>&1 | xcbeautify

# Run the app
open ~/Library/Developer/Xcode/DerivedData/SyncTray-*/Build/Products/Debug/SyncTray.app
```

## Key Files Reference

| File | Purpose |
|------|---------|
| `SyncProfile.swift` | Profile model with computed paths (configPath, logPath, plistPath, etc.) |
| `SyncSetupService.swift` | Script generation, launchd management, profile installation |
| `SyncManager.swift` | Central state manager, LogWatcher/DirectoryWatcher coordination |
| `SettingsView.swift` | Main settings UI with profile editing |
| `ProfileStore.swift` | File-backed profile persistence — authoritative `{shortId}.profile.json` per profile, write-only blob mirror (see "File-Backed Configuration") |
| `ConfigFileWatcher.swift` | Live-apply watcher for `~/.config/synctray` (profiles + settings); routes an unknown-id `.profile.json` to create-via-file |
| `SyncTrayCLI.swift` | Headless `synctray` CLI: inspect (`doctor`/`status`/`profiles`/`profile show`/`logs`/`test-remote`/`listremotes`), configure (`profile create`/`set`/`enable`/`disable`/`delete`, `install`/`reinstall`), operate (`sync`/`mount`/`unmount`/`cache move`); dispatched from `SyncTrayApp.init` (see "Agent-Editable Configuration & CLI") |
| `CLIShimInstaller.swift` | Installs the `~/.local/bin/synctray` shim (`~/.local/bin` must be on `PATH`) |
| `SyncLogPatterns` | Centralized log message pattern matching (includes `isOutOfSyncError`) |
| `TelemetryService.swift` | OTel singleton — traces, metrics, logs via OTLP/HTTP |
| `TelemetryDetailsSheet.swift` | Shared privacy disclosure sheet for wizard, banner, and settings |
| `Settings.swift` | Global settings including `installationId`, `anonymousUserId`, and `autoFixSyncIssues` |

## Telemetry

Anonymous, opt-in telemetry using OpenTelemetry (opentelemetry-swift 1.17.1). All methods are no-ops unless `SyncTraySettings.telemetryEnabled` is true. See `.claude/rules/telemetry.md` for the full instrumentation guide and how to add new telemetry.

### Three signals
- **Traces**: Sync lifecycle spans with real duration (start→complete/fail), mount/unmount spans
- **Metrics**: 20 instruments — sync duration + check phase histograms, operation counters (sync, mount, file ops, contention, recovery, volume events, filter stats, offline pin/unpin), profile gauge (delta temporality, 30s export interval)
- **Logs**: Structured log records for all key events (sync lifecycle, mount, transport changes, errors, config snapshots, session heartbeat, stale lock cleanup, precondition failures)

### User correlation
- `service.instance.id` — random UUID per install (changes on reinstall)
- `enduser.id` — HMAC-SHA256 of hardware UUID (stable across reinstalls, not reversible)

### Deployment correlation
- `service.version` — `<marketing>+<build>.g<gitSHA>` (e.g. `0.34.0+1.gabc1234`); the git SHA is injected by the `Embed Git Metadata` Xcode build phase. Primary key Dash0 uses to correlate telemetry to a release.
- `deployment.environment.name` — `development` (DEBUG) / `production` (Release), overridable via `OTEL_RESOURCE_ATTRIBUTES`.
- `App upgraded` log on version change between launches → Dash0 dashboard annotations.

### Source correlation
- `vcs.repository.url.full` — canonical https URL of the `origin` remote, normalised at build time (scp-style SSH converted, embedded credentials stripped, trailing `.git` dropped).
- `vcs.ref.head.revision` — full commit SHA the binary was built from.
- Both are injected into `Info.plist` by the `Embed Git Metadata` build phase alongside `GitCommitSHA`, and are simply absent when building from a non-git source tree. Together they let a backend resolve any signal to the exact source revision that produced it — the attribute Dash0 and agentic tooling look for to jump from a log line to the code.
- `host.arch` — `arm64` / `amd64`, resolved at compile time so a universal binary reports the executing slice; omitted entirely on any other architecture rather than sending an undocumented value.

### Privacy
No file paths, sync remote names, or credentials in telemetry. File operations tracked by normalized extension only. Error messages categorized into low-cardinality types. Profile names are user-chosen display names, not paths. Carve-out: `vcs.repository.url.full` (the source repo's origin URL, credentials stripped at build time) is exempt — it identifies the codebase, not a user's sync destination.

### Configuration
Priority: process env vars > `~/.config/synctray/.env` > Info.plist. Key vars: `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS`, `DASH0_AUTH_TOKEN`.

## Generated Files (per profile)

| Path | Purpose |
|------|---------|
| `~/.config/synctray/profiles/{shortId}.json` | Profile config |
| `~/.config/synctray/profiles/{shortId}-exclude.txt` | Exclude filter (user-editable) |
| `~/.local/bin/synctray-sync.sh` | Shared sync script (all profiles) |
| `~/Library/LaunchAgents/com.synctray.sync.{shortId}.plist` | launchd schedule |
| `~/.local/log/synctray-sync-{shortId}.log` | Sync logs |
| `/tmp/synctray-sync-{shortId}.lock` | Lock file (prevents concurrent syncs) |
| `/tmp/synctray-mount-{shortId}.mode` | Mount mode only — the currently active `MountMode` token (`streaming`/`cache-only-manual`/`cache-only-pending`/`cache-only-offline`), rewritten on every mount start |
| `~/.config/synctray/profiles/{shortId}.cacheonly.rclone.conf` | Mount mode only — chmod-0600 `union` remote config for the Cache-only overlay mount |
| `{vfsCachePath}/vfs/{primaryRemoteName}/{path}/…` | Mount mode only — VFS cached file **data**, keyed by the profile's own primary remote name (see "Cache key" above) |
| `{vfsCachePath}/vfsMeta/{primaryRemoteName}/{path}/…` | Mount mode only — VFS metadata sidecars, including the `--vfs-cache-mode full` downloaded byte-range list. Load-bearing for Cache Directory Migration: moving `vfs` without `vfsMeta` makes rclone re-download everything. |
| `{vfsCachePath}/synctray-overlay/{shortId}/…` | Mount mode only — the Cache-only overlay: every file created or edited while in Cache Only, until uploaded |
| `{vfsCachePath}/synctray-overlay/{shortId}.manifest.json` | Mount mode only — Upload Now's manifest (path + size + mtime at upload time) |
| `{vfsCachePath}/synctray-overlay/{shortId}.exclude.txt` | Mount mode only — partial-file exclude list, regenerated on every Cache-only mount start |
| `{vfsCachePath}/synctray-overlay/{shortId}.vfscache` | Mount mode only — the Cache-only union mount's own small `--vfs-cache-mode writes` bookkeeping directory (never the streaming cache) |
