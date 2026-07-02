# Native File Provider streaming (Phase 2) — design & implementation guide

> **Status: design + scaffolding.** This document and the `FileProviderExtension/`
> skeleton describe the native, kext-free Google-Drive-File-Stream experience for
> SyncTray. The extension target is **not yet wired into `SyncTray.xcodeproj`** — that
> step (new target, entitlements, App Group, signing) must be done in Xcode on a Mac.
> Nothing here is compiled by CI yet. See [Build wiring](#build-wiring-do-this-on-a-mac).

## Why File Provider (and why it's separate from Phase 1)

Phase 1 (PR #28) made Stream mode kext-free by switching the mount backend to
`rclone nfsmount`. That unblocks corporate/MDM Macs, but the result is still *a
mounted drive*: SyncTray draws its own badges, and "available offline" is a cache
the app has to babysit (read files to warm them, keep touching pinned paths so LRU
eviction doesn't drop them — rclone has no native pin).

Apple's **File Provider** framework is the mechanism Google Drive, Dropbox, OneDrive,
and Box all use today (after dropping their kexts). It is the *only* approach that
gives, natively and OS-enforced:

- **Kext-free** — a normal app extension (`appex`), no kernel/system extension, no
  admin approval. Works under MDM that blocks kexts.
- **On-demand streaming** — files are dataless placeholders; the system materializes
  them by calling our extension's `fetchContents` when opened.
- **Native Finder UX** — the cloud/download status icons, and the right-click
  **Download Now / Remove Download** items, are drawn and wired by macOS.
- **Real offline pinning** — `NSFileProviderItem.contentPolicy =
  .downloadEagerlyAndKeepDownloaded` keeps an item downloaded and **never evicted**;
  lazy items auto-evict under disk pressure. This is the genuine "Make Available
  Offline" that Phase 1 can only approximate.

Trade-off: it is materially more engineering than a mount, and FinderSync and File
Provider are **mutually exclusive** extension points — going File Provider means the
native menus replace any custom FinderSync menu.

## Architecture

```
┌─────────────────────────────┐         ┌──────────────────────────────────┐
│ SyncTray.app (host, SwiftUI)│         │ FileProviderExtension.appex        │
│                             │         │ (NSFileProviderReplicatedExtension)│
│ • Profile config / UI       │  XPC    │ • enumerator (working set + dirs)  │
│ • Registers NSFileProvider  │◀───────▶│ • fetchContents / fetchPartial     │
│   Domain per mount profile  │ App     │ • create/modify/delete item        │
│ • Pin/unpin (contentPolicy) │ Group   │ • item model + sync anchors        │
│ • Starts rclone daemon      │         │            │                       │
└──────────────┬──────────────┘         └────────────┼───────────────────────┘
               │                                      │ rclone RC (HTTP, localhost)
               ▼                                      ▼
        ┌──────────────────────────────────────────────────────┐
        │ rclone rcd  (one daemon, `rclone rcd --rc-addr ...`)   │
        │  serves: operations/list, /cat, /uploadfile, etc.      │
        │  reuses the existing rclone.conf remotes               │
        └──────────────────────────────────────────────────────┘
```

### Why a daemon, not a subprocess

A File Provider extension runs **sandboxed** and cannot freely `posix_spawn` the
`rclone` CLI. Two viable options:

1. **`rclone rcd` daemon (recommended for v1).** The *host app* (not the sandboxed
   appex) launches one `rclone rcd --rc-addr=127.0.0.1:<port> --rc-no-auth` process
   (the same pattern Phase 1 already uses for `--rc`). Both the app and the extension
   talk to it over the RC HTTP API on loopback. Lowest risk, reuses Phase 1's RC
   plumbing and the user's existing `rclone.conf`.
2. **`librclone` via FFI (v2).** Link `librclone` (rclone's RC API compiled as a C
   library) directly into the extension and call it in-process. No daemon, but more
   build complexity (vendored static lib, cgo bridging header) and the appex memory
   limit applies.

Start with (1). The `RcloneRCClient` in the skeleton wraps the RC endpoints and is
the single seam to swap to (2) later.

### Mapping rclone → File Provider concepts

| File Provider concept | rclone backing |
|---|---|
| `NSFileProviderDomain` (one per account, a Finder sidebar entry) | One per **mount-mode SyncProfile** (`identifier` = profile UUID, `displayName` = profile name) |
| Item identifier | Remote-relative path (root = `NSFileProviderItemIdentifier.rootContainer`) |
| Directory enumeration | `operations/list` (`fs`, `remote`, `opt.recurse=false`) |
| `fetchContents(itemIdentifier:)` | `operations/cat` (or a ranged read) → write to the temp URL the system gives us |
| `createItem` / `modifyItem` (upload) | `operations/uploadfile` / `operations/copyfile` |
| `deleteItem` | `operations/deletefile` / `operations/purge` |
| Remote→local change detection (working set) | Poll `operations/list` per dir (or rclone's `vfs/changenotify`); bump the **sync anchor** when the listing hash changes, then `signalEnumerator(for: .workingSet)` |
| Pin / "Available Offline" | `contentPolicy = .downloadEagerlyAndKeepDownloaded` on the item (+ descendants) |
| Unpin | `contentPolicy = .downloadLazily…` and/or `NSFileProviderManager.evictItem` |

### Sync model (the hard part)

- **Enumeration** is paginated; return items + a page cursor, then a final
  `currentSyncAnchor`.
- **Changes** use the *working set*: when the remote changes, the provider calls
  `signalEnumerator(for: .workingSet)`. macOS then calls
  `enumerateChanges(from: syncAnchor:)`, and we return changed/deleted items plus a
  fresh anchor (an opaque cursor — here, a monotonically increasing counter persisted
  per domain, paired with a per-directory listing hash).
- rclone has no cheap global change feed for most remotes, so v1 polls listings on an
  interval (reuse SyncTray's existing watcher cadence). `vfs/changenotify` works for
  remotes that support polling and is a later optimization.

## Pinning / "Make Available Offline" UX

- The **Download Now / Remove Download** items appear automatically on File Provider
  items — we do **not** add them (and cannot use FinderSync alongside this).
- A *durable* "Keep Offline" pin is set programmatically:
  `item.contentPolicy = .downloadEagerlyAndKeepDownloaded`. Apply it to a folder and
  propagate to enumerated descendants to "pin a directory" — there is no atomic
  subtree-pin API.
- This **replaces** Phase 1's app-managed `pinnedDirectories` warming: instead of the
  app reading files to keep them warm, the OS guarantees pinned items stay downloaded
  and never evicts them. SyncTray's existing `pinnedDirectories` list maps directly to
  the set of identifiers we mark `downloadEagerlyAndKeepDownloaded`.

## Entitlements & configuration

Host app **and** extension:
- App Sandbox (`com.apple.security.app-sandbox`).
- A shared **App Group** (`group.com.synctray.fileprovider`) — the extension's
  `Info.plist` `NSExtensionFileProviderDocumentGroup` points at it; both sides read/
  write the per-domain anchor + config there.
- File Provider capability. Extension `NSExtensionPointIdentifier =
  `com.apple.fileprovider-nonui`. A `FileProviderUI` (`FPUIActionExtension`) target is
  optional, only for custom actions needing UI.
- For local development without a provisioning profile that has the FP capability, the
  `com.apple.developer.fileprovider.testing-mode` boolean (on both targets) allows
  test domains. Confirm the exact production entitlement keys in Xcode — Apple's docs
  are the source of truth.

## Build wiring (do this on a Mac)

The skeleton in `FileProviderExtension/` is **not** referenced by the Xcode project,
so CI does not compile it. To make it real:

1. In Xcode: **File ▸ New ▸ Target ▸ File Provider Extension** → name
   `FileProviderExtension`. This creates the target, `Info.plist`, and entitlements
   with the right extension point.
2. Replace the generated `FileProviderExtension.swift` with the skeleton files here
   (or add them to the new target).
3. Add the **App Group** to both the app and the extension; set
   `NSExtensionFileProviderDocumentGroup` to it.
4. Add host-app code to register a domain per mount profile:
   `NSFileProviderManager.add(NSFileProviderDomain(identifier:displayName:))`, and to
   launch/stop the shared `rclone rcd` daemon (reuse Phase 1's RC port logic).
5. Wire pin/unpin in the app UI to set `contentPolicy` / call `requestDownloadForItem`
   / `evictItem`.
6. Smoke-test against a small remote; verify badges, Download Now/Remove Download, and
   that an eagerly-kept folder survives an eviction sweep.

## Reference implementations to crib from

- Apple "FruitBasket" sample (WWDC21 session 10182, *Sync files to the cloud with
  FileProvider on macOS*).
- Nextcloud desktop macOS VFS client (open source, `NSFileProviderReplicatedExtension`
  over WebDAV).
- ownCloud iOS `FileProviderExtension`.
- Claudio Cambra, *Build your own cloud sync* (replicated-extension walkthrough).

## Phased rollout

- **v1** — read-only streaming: domain registration, enumerator, `fetchContents` via
  `rclone rcd`, native badges. Pin via `contentPolicy`. (Biggest user value, smallest
  surface.)
- **v2** — writes: `createItem`/`modifyItem`/`deleteItem` → rclone uploads; conflict
  handling.
- **v3** — `librclone` in-process (drop the daemon), `vfs/changenotify` for push-style
  change detection where the remote supports it.
