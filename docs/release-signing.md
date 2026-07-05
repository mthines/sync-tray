# Release signing & notarization

The **Finder "Available Offline" extension only loads in a Developer-ID-signed,
notarized app.** The brew release is ad-hoc signed today, so Gatekeeper rejects it
and macOS never registers the extension. This guide turns on real signing.

The CI pipeline is already wired (`scripts/release-ci.sh` + `.github/workflows/ci.yml`):
it **stays unsigned until the secrets below exist**, then automatically signs +
notarizes every release. So nothing breaks while you complete the one-time setup.

- [Part 1 — Apple Developer account (one-time)](#part-1--apple-developer-account-one-time)
- [Part 2 — GitHub repository secrets](#part-2--github-repository-secrets)
- [Part 3 — What the pipeline does](#part-3--what-the-pipeline-does)
- [Part 4 — Verify & troubleshoot the first signed release](#part-4--verify--troubleshoot-the-first-signed-release)

Team ID for this project: **`7HVK85DZG7`**.

---

## Part 1 — Apple Developer account (one-time)

> Requires a **paid** Apple Developer membership.

### 1a. Register the App Group and App IDs

At <https://developer.apple.com/account/resources>:

1. **Identifiers → App Groups → +** → register `group.com.synctray.app` (if not already).
2. **Identifiers → App IDs** — make sure both exist and have **App Groups** enabled and
   assigned to `group.com.synctray.app`:
   - `com.synctray.app` (the app)
   - `com.synctray.app.findersync` (the extension)

### 1b. Create a Developer ID Application certificate

Easiest via Xcode: **Settings → Accounts → (your team) → Manage Certificates → + →
Developer ID Application**. Then export it **with its private key**:

- Keychain Access → **My Certificates** → right-click *"Developer ID Application: … (7HVK85DZG7)"*
  → **Export** → `.p12`, set a strong password (you'll store it as a secret).

Base64-encode it for GitHub:

```bash
base64 -i DeveloperID_Application.p12 | pbcopy   # now on your clipboard
```

### 1c. Create an App Store Connect API key (for notarization)

At <https://appstoreconnect.apple.com/access/integrations/api> → **+**:

- Access role: **Developer** (enough for notarization).
- Download the **`.p8`** (one-time download). Note the **Key ID** and the **Issuer ID**
  (shown above the keys table).

Base64-encode the key:

```bash
base64 -i AuthKey_XXXXXXXX.p8 | pbcopy
```

---

## Part 2 — GitHub repository secrets

Repo → **Settings → Secrets and variables → Actions → New repository secret**. Add all five:

| Secret | Value |
|--------|-------|
| `MACOS_CERTIFICATE_P12_BASE64` | base64 of the Developer ID `.p12` (step 1b) |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `NOTARY_KEY_P8_BASE64` | base64 of the App Store Connect `.p8` (step 1c) |
| `NOTARY_KEY_ID` | the API Key ID |
| `NOTARY_ISSUER_ID` | the API Issuer ID |

That's it — the next release picks them up automatically. (Signing runs if the two
`MACOS_CERTIFICATE_*` secrets are present; notarization runs if the three `NOTARY_*`
secrets are also present.)

---

## Part 3 — What the pipeline does

`scripts/release-ci.sh`, when the secrets are set:

1. Imports the `.p12` into a throwaway keychain and finds the *Developer ID Application* identity.
2. Signs inside-out with **hardened runtime** + secure timestamp: nested frameworks →
   `SyncTrayFinderSync.appex` (with its entitlements) → `SyncTray.app` (with its entitlements).
3. Zips, **notarizes** via `notarytool submit --wait`, **staples** the ticket, and re-zips
   so the published archive is Gatekeeper-clean offline.
4. Publishes the release and updates the Homebrew tap exactly as before.

No project files change — signing is applied post-build, so local/dev builds are unaffected.

---

## Part 4 — Verify & troubleshoot the first signed release

After a signed beta publishes and you `brew install --cask --force mthines/synctray/synctray-beta`:

```bash
codesign -dvv /Applications/SyncTray.app 2>&1 | grep Authority   # → Developer ID Application: … (7HVK85DZG7)
spctl -a -vvv /Applications/SyncTray.app                          # → accepted, source=Notarized Developer ID
xcrun stapler validate /Applications/SyncTray.app                 # → The validate action worked!
pluginkit -m -i com.synctray.app.findersync                       # → now lists the /Applications appex
```

Then enable it once: **System Settings → General → Login Items & Extensions → Extensions →
SyncTray Offline**, mount a Stream profile, and right-click a folder inside it.

**If the extension loads but can't reach the App Group** (pins don't reach the app):
macOS is rejecting the `com.apple.security.application-groups` entitlement. That means the
App Group isn't associated with the App IDs — recheck step 1a, or (rarely) a Developer ID
**provisioning profile** that includes the group must be created and embedded in each target.
Everything else (signing, notarization) is unaffected by this.

**`notarytool` fails:** run `xcrun notarytool log <submission-id> --key … --key-id … --issuer …`
to see the per-file rejection (almost always a component missing hardened runtime or a
secure timestamp — both are already set in `release-ci.sh`).
