# FileProviderExtension (scaffolding)

**Not yet part of the Xcode build.** These files are a starting skeleton for the
native File Provider streaming feature described in
[`docs/file-provider-streaming.md`](../docs/file-provider-streaming.md). They are
intentionally **not referenced by `SyncTray.xcodeproj`**, so CI does not compile them.

To turn this into a real target, follow *Build wiring (do this on a Mac)* in the design
doc: create a File Provider Extension target in Xcode, add these sources to it, set up
the App Group + entitlements, and register a domain per mount profile from the host app.

Files:
- `RcloneRCClient.swift` — thin client over `rclone rcd`'s RC HTTP API (the seam to
  later swap for in-process `librclone`).
- `FileProviderItem.swift` — `NSFileProviderItem` model backed by an rclone listing entry.
- `FileProviderEnumerator.swift` — directory + working-set enumerator (paged listings,
  sync anchors).
- `FileProviderExtension.swift` — `NSFileProviderReplicatedExtension` entry point
  (item lookup, `fetchContents`, create/modify/delete stubs).

Every place that needs a real Mac/SDK to finish is marked `// TODO(mac):`.
