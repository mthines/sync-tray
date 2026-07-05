# Local development setup

Run these **once per clone** before building — they wire up signing (needed for the
Finder extension) and the safety hook that keeps your Apple Team ID out of git.

```bash
# 1. Activate the pre-commit hook that blocks committing a personal signing team.
git config core.hooksPath .githooks

# 2. Create your local signing override (gitignored — never committed).
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
#    then edit it and set your Apple Developer Team ID:
#    DEVELOPMENT_TEAM = XXXXXXXXXX      (developer.apple.com/account → Membership → Team ID)
```

That's enough to **build and run** the app (⌘R in Xcode, or the `xcodebuild` line in the
root `CLAUDE.md`). CI and release builds are unsigned by design, so no team is required
there — your Team ID lives only in `Config/Signing.local.xcconfig`.

## Testing the Finder "Available Offline" extension locally

macOS only loads a Finder extension from a **code-signed** app, so:

1. In Xcode, set your **Team** on **both** the `SyncTray` and `SyncTrayFinderSync` targets
   (Signing & Capabilities → Automatically manage signing). With the xcconfig from step 2
   the team is pre-filled; just confirm both targets show the `group.com.synctray.app`
   App Group.
2. **⌘R** to build & run (the menu-bar app launches).
3. Enable the extension: **System Settings → General → Login Items & Extensions →
   Extensions → SyncTray Offline**.
4. Mount a **Stream (Mount)** profile, then right-click a folder **inside the mount** →
   **SyncTray ▸ Available Offline**.

Verify registration from the terminal:

```bash
pluginkit -m -i com.synctray.app.findersync     # a leading "+" means enabled
```

**After every rebuild that touches the extension, restart Finder** so it reloads the new
binary — otherwise the menu silently disappears:

```bash
killall Finder
```

This rebuild-churn is a local-dev-only annoyance; end users install a signed release once
and never hit it.

> Shipping the extension to users (signed + notarized release) is a separate, one-time
> setup — see [release-signing.md](./release-signing.md).
