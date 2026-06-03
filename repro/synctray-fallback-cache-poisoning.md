# Repro: SyncTray bisync cache poisoning on SMB→SFTP fallback (NFD/NFC encoding divergence)

## Summary

When a SyncTray profile is configured with an SMB primary remote and an SFTP
fallback remote, and `fallbackRemotePath` is empty (same path assumed), the
pre-fix code used the env-var-override path on fallback activation. This
preserved the bisync cache from the SMB session — but the SFTP server returns
filenames in NFC byte encoding while the SMB client normalised them to NFD on
the wire. On the second bisync run, rclone compared the NFD-era cached listings
against NFC fresh listings, treated them as different files, and aborted.

**Log symptom:**
```
Bisync critical error: path1 and path2 are out of sync, run --resync to recover
```

## Environment

| Component | Value |
|-----------|-------|
| SyncTray version | pre-fix/bisync-cache-poisoning-nfc-nfd |
| rclone version | 1.66+ |
| macOS | 14+ (Sonoma) |
| Primary remote | `synology` — `type = smb`, server `192.168.86.188` |
| Fallback remote | `synology-sftp` — `type = sftp`, same NAS via port 22 |
| `fallbackRemotePath` | empty (same path as primary `remotePath`) |

## Setup

1. Configure two rclone remotes in `~/.config/rclone/rclone.conf`:

   ```ini
   [synology]
   type = smb
   host = 192.168.86.188
   user = kaiju

   [synology-sftp]
   type = sftp
   host = 192.168.86.188
   user = kaiju
   key_file = ~/.ssh/id_ed25519
   ```

2. Create a SyncTray profile with:
   - **Rclone Remote**: `synology` (or `synology:`)
   - **Remote Path**: `Kaiju`
   - **Fallback Remote**: `synology-sftp`
   - **Fallback Remote Path**: _(empty)_

3. Install the profile (triggers `SyncSetupService.install`).

4. Run at least one successful bisync with the primary remote to populate the
   bisync cache in `~/Library/Caches/rclone/bisync/`.

## Trigger (pre-fix)

Block or bring down the SMB service at `192.168.86.188:445`:

```bash
# Option A: firewall rule (pf)
echo "block out proto tcp from any to 192.168.86.188 port 445" | sudo pfctl -f -
sudo pfctl -e

# Option B: physically disconnect from the LAN (or disable the NAS's SMB service)
```

Then trigger a sync (either wait for the launchd schedule or manually):

```bash
~/.local/bin/synctray-sync.sh ~/.config/synctray/profiles/<shortId>.json
```

## Observed behaviour (pre-fix, second run)

**First fallback run** completes successfully — bisync runs against
`synology-sftp` using env-var-overrides (remote name `synology` unchanged).
The cache files written by this run contain NFC-encoded filenames from SFTP.

**Second fallback run** aborts:

```
2024-xx-xx xx:xx:xx - Primary remote unreachable, using fallback: synology-sftp
...
NOTICE: Bisync critical error: path1 and path2 are out of sync, run --resync to recover
Bisync failed with exit code 1
```

## Evidence files

| File | Description |
|------|-------------|
| `~/.local/log/synctray-sync-c6169dcc.log` lines 2621–2636 | Live failure log — "out of sync" abort |
| `~/Library/Caches/rclone/bisync/synology_Kaiju_KAIJU_Reaper..Volumes_SeagateHD_Kaiju_Reaper.path2.lst-err` | NFD-encoded listing written by SFTP run |
| `~/Library/Caches/rclone/bisync/synology_Kaiju_KAIJU_Reaper..Volumes_SeagateHD_Kaiju_Reaper.path1.lst-err` | NFC-encoded listing written by local-path scan |

### Encoding delta

The same audio file appears as two distinct byte sequences in the two listing
files:

| Encoding | Bytes | Human-readable |
|----------|-------|----------------|
| NFC (local path scan) | `Ella Metal (4 \xC3\xA5r).mp3` | `Ella Metal (4 år).mp3` |
| NFD (SFTP — macOS SMB cache) | `Ella Metal (4 a\xCC\x8Ar).mp3` | `Ella Metal (4 år).mp3` |

The `å` character (`U+00E5`) is represented as a single precomposed codepoint
(NFC: `\xC3\xA5`) in the local filesystem listing, but as the decomposed
sequence `a` + combining ring above (NFD: `a\xCC\x8A`) in the bisync cache
written from the SMB session. SFTP passes filename bytes verbatim from the NAS,
which preserves the NFD normalisation applied by the SMB client.

## Fix

`SyncSetupService.computeFallbackRequiresCacheRebuild(profile:)` compares
`provider.rcloneType` for primary and fallback at profile install/save time and
writes `fallbackRequiresCacheRebuild: true` into the profile JSON when the wire
types differ. The bash script then branches on this field in addition to
`FALLBACK_PATH`:

```bash
if [[ -z "$FALLBACK_PATH" && "$FALLBACK_REQUIRES_CACHE_REBUILD" != "true" && "$FALLBACK_REQUIRES_CACHE_REBUILD" != "True" ]]; then
    # env-var override: same wire type, no path change, preserve bisync cache
else
    # REMOTE swap: different wire type OR explicit path change
    REMOTE="${FALLBACK_REMOTE}:${FALLBACK_PATH:-$REMOTE_PATH}"
fi
```

## Fix verification

1. Re-save the profile in SyncTray (triggers re-install, which calls
   `computeFallbackRequiresCacheRebuild`).

2. Inspect the generated profile JSON:

   ```bash
   cat ~/.config/synctray/profiles/<shortId>.json | python3 -m json.tool \
     | grep -E 'fallbackRequiresCacheRebuild|remotePath'
   ```

   Expected output:
   ```json
   "fallbackRequiresCacheRebuild": true,
   "remotePath": "Kaiju",
   ```

3. Inspect the generated script:

   ```bash
   grep -E 'FALLBACK_REQUIRES_CACHE_REBUILD|REMOTE_PATH|FALLBACK_PATH' \
     ~/.local/bin/synctray-sync.sh
   ```

   Expected lines:
   ```bash
   FALLBACK_REQUIRES_CACHE_REBUILD=$(parse_json "fallbackRequiresCacheRebuild" "false")
   REMOTE_PATH=$(parse_json "remotePath" "")
   if [[ -z "$FALLBACK_PATH" && "$FALLBACK_REQUIRES_CACHE_REBUILD" != "true" && "$FALLBACK_REQUIRES_CACHE_REBUILD" != "True" ]]; then
   ```

4. Block the SMB service and trigger a sync. The script now executes the REMOTE
   swap branch:

   ```
   REMOTE="synology-sftp:Kaiju"
   ```

   bisync uses a different cache key (`synology-sftp_Kaiju_…`) — no NFD/NFC
   collision. Second fallback run completes without abort.

## Backward compatibility

Profiles created before this fix have no `fallbackRequiresCacheRebuild` field.
The `parse_json` call defaults to `"false"`, preserving the env-var-override
behaviour until the user next saves the profile (which triggers re-evaluation of
the wire types).

**Python capitalisation note:** `parse_json` uses `python3 -c "… print(d.get(…))"`.
Python's `json` module deserialises JSON `true` as a Python `bool`, which prints
as `"True"` (capital T) — not `"true"`. The bash condition therefore guards against
both: `!= "true" && != "True"`. The default value (`"false"`) is a Python string
literal returned as-is (lowercase), so old profiles without the field correctly
evaluate as `False` (not triggering the swap).
