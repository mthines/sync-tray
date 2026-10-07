# Set up SyncTray with an AI agent

SyncTray is built to be configured by an agent as easily as by a person.
Every profile is a JSON file with a published schema, and the `synctray` CLI covers creating, checking, changing, and running profiles — with machine-readable output.
This guide walks through a full setup, from an empty Mac to a running sync, the way an agent like Claude Code, Codex, or Cursor would do it.

## Before you start

1. **Install SyncTray and rclone.**

   ```bash
   brew install rclone
   brew install --cask mthines/synctray/synctray
   ```

2. **Launch SyncTray once.** That writes the `synctray` CLI to `~/.local/bin/` and the JSON Schemas to `~/.config/synctray/schema/`.
3. **Put `~/.local/bin` on your `PATH`** so the agent can run `synctray`:

   ```bash
   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
   ```

After that, the menu bar app doesn't need to be open — the CLI works on its own.

## Hand it to your agent

Paste this, with your own goal filled in:

```text
Set up SyncTray for me using its `synctray` CLI (in ~/.local/bin).

Goal: <two-way sync /Users/me/Projects with the "Projects" folder on my "nas" rclone remote>

- Start with `synctray help`, `synctray doctor`, and `rclone listremotes`.
- If the remote I need doesn't exist yet, walk me through `rclone config`.
  Credentials only ever live in rclone's config, never in SyncTray's files.
- Write the profile against ~/.config/synctray/schema/profile.schema.json,
  with a fresh `uuidgen` id, absolute paths, and "isEnabled": false.
- Create it with `synctray profile create --from <file>`, show me
  `synctray profile show <name>`, and wait for my OK.
- Then run `synctray profile enable <name>` and confirm with `synctray status <name>`.
```

Some goals to try:

- "Back up `~/Pictures/Export` to my `b2` bucket every hour, one way."
- "Stream my NAS `Media` share to `~/NAS/Media` and keep the `Current Projects` folder available offline."
- "My `Projects` sync keeps failing — find out why and fix it."
- "Stop syncing `node_modules` folders in every profile."

## What the agent does, step by step

You can follow the same steps by hand.

### 1. Check the current state

```bash
synctray doctor        # rclone, schemas, and every profile's health
synctray profiles      # what's configured
rclone listremotes     # which remotes exist
```

`doctor` exits `1` when any check fails, so an agent can tell a healthy setup from a broken one without parsing the text.

### 2. Make sure the remote exists

SyncTray syncs through rclone remotes; it doesn't store credentials itself.
If the remote is missing, create it with `rclone config` — interactively, or with `rclone config create` for a scripted setup.
See [rclone's docs](https://rclone.org/docs/) for each provider's options.

Then confirm rclone can reach the folder:

```bash
rclone lsjson --stat nas:Projects
```

### 3. Write the profile

Profiles follow `~/.config/synctray/schema/profile.schema.json`.
Only `id`, `name`, `rcloneRemote`, `remotePath`, and `localSyncPath` are required; [Configuration files](configuration.md#profile-fields) lists every field and its default.

**Two-way sync** (the default mode):

```json
{
  "id": "6F1C2B9E-3A4D-4E5F-8A7B-1C2D3E4F5A6B",
  "name": "Projects",
  "rcloneRemote": "nas:",
  "remotePath": "Projects",
  "localSyncPath": "/Users/me/Projects",
  "syncExcludePatterns": ["**/node_modules/**", "*.tmp"],
  "isEnabled": false
}
```

**One-way backup**, hourly:

```json
{
  "id": "0B7E4C21-9F3A-4D6B-B1E8-5A2C7D9E3F40",
  "name": "Photos backup",
  "rcloneRemote": "b2:",
  "remotePath": "my-bucket/photos",
  "localSyncPath": "/Users/me/Pictures/Export",
  "syncMode": "sync",
  "syncDirection": "localToRemote",
  "syncIntervalMinutes": 60,
  "isEnabled": false
}
```

**Stream**, with one folder kept offline:

```json
{
  "id": "A41C09D2-77E5-4B3C-9D10-2F6E8B4A1C55",
  "name": "Media",
  "rcloneRemote": "nas:",
  "remotePath": "Media",
  "localSyncPath": "/Users/me/NAS/Media",
  "syncMode": "mount",
  "vfsCacheMaxSize": "200G",
  "pinnedDirectories": ["Current Projects"],
  "isEnabled": false
}
```

For Stream, `localSyncPath` is the mount point: use an empty folder, or one that doesn't exist yet.
`pinnedDirectories` are relative to it.

### 4. Create it disabled, and review

```console
$ synctray profile create --from projects.profile.json
created Projects (6f1c2b9e) — not installed (disabled or incomplete)

$ synctray profile show Projects
```

A profile that doesn't decode exits `65` with the decode error and writes nothing — read the message, fix the JSON, and try again.
`profile show` prints the full profile with every default filled in, which is the thing to review before anything runs.

Instead of the CLI, you can also write the file straight into `~/.config/synctray/profiles/`.
The running app picks it up within about a second.

### 5. Enable it

```console
$ synctray profile enable Projects
enabled Projects (6f1c2b9e)
```

That installs the launchd agent, and the first run starts right away.
A two-way profile's first run compares both sides and copies what's missing in each direction; where a file exists on both sides and differs, the newer copy wins.

### 6. Confirm it works

```bash
synctray status Projects                    # state=syncing, then state=idle
synctray logs Projects                      # the sync log so far
synctray status Media --wait mounted        # Stream: block until the volume is attached
synctray offline status Media               # Stream: how much is cached
```

Use `status --json` when the agent needs to parse the result.
The `state` field is the one to branch on; the [CLI reference](cli.md#status) lists every value.

### 7. Change it later

```bash
synctray profile set Projects syncIntervalMinutes 15
synctray profile set Projects syncIncludeFolders 'Active,Archive/2026'
synctray profile disable Projects
```

`profile set` validates every change before writing anything, then reinstalls or remounts only when the change needs it.

## Ground rules for agents

These keep an automated setup from doing damage.
They're worth copying into your agent's instructions file (`AGENTS.md`, `CLAUDE.md`, or similar):

```markdown
## SyncTray
- Manage SyncTray with the `synctray` CLI (~/.local/bin). Run `synctray help` for commands.
- Profiles live in ~/.config/synctray/profiles/*.profile.json; validate against
  ~/.config/synctray/schema/profile.schema.json.
- Never put credentials in SyncTray files. Remotes and secrets belong in `rclone config`.
- Create new profiles with "isEnabled": false, show them to me, and enable only after I agree.
- Never edit the generated profiles/{shortId}.json, and never delete files in
  ~/Library/Caches/rclone/bisync/ — that's two-way sync history.
- Add broad "Don't Sync" patterns in small steps: excluding more than half of a two-way
  profile's files trips rclone's 50% deletion safety stop.
- Move a Stream cache with `synctray cache move`, not by editing vfsCachePath.
- After any change, check `synctray status <name>` and `synctray doctor`.
```

## When something fails

| Signal                                        | Next step                                                                 |
| --------------------------------------------- | ------------------------------------------------------------------------- |
| `doctor`: `remote unreachable`                | `synctray test-remote <name>` prints rclone's real error                   |
| `doctor`: `launchd agent not loaded`          | `synctray install <name>`                                                 |
| `doctor`: `stale lock file present`           | Usually left by a run that was killed; SyncTray clears stale locks at launch |
| `status`: `last=failed`                       | `synctray logs <name>` and look at the last error                         |
| `status`: `state=stale`                       | The mount's server stopped. `synctray unmount <name>`, then `synctray mount <name>` |
| `status`: `cache_only_fallback=true`          | Cache Only couldn't start and the mount is streaming; see the sync log     |
| Exit code `64`                                | Wrong command or arguments — run `synctray help`                          |
| Exit code `65`                                | The JSON or a value is invalid; the message says which                    |

More fixes are in [Troubleshooting](troubleshooting.md).
