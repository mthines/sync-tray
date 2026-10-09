# `synctray` CLI reference

Every command the `synctray` CLI accepts, what it prints, and how it exits.
For a guided walkthrough, see [Agent setup](agent-setup.md).

## Install the CLI

SyncTray writes a small shim to `~/.local/bin/synctray` every time the app launches.
Launch the app once, then put `~/.local/bin` on your `PATH`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
exec zsh
synctray help
```

The shim runs the CLI built into `SyncTray.app`, so it stays in step with the installed app version.
The CLI never opens a window or starts the app's own watchers and timers — the syncs and mounts it installs run under launchd.
Every command runs whether or not the menu bar app is open.

## Targeting a profile

Commands that take `<name|id>` accept either:

- the profile's **short id** — the first 8 characters of its `id`, lowercased (for example `6f1c2b9e`), or
- its **name**, matched case-insensitively.

The short id is tried first.
A target that matches nothing, or a name shared by two profiles, exits `1` with `error: no profile matches "<target>"`.
Use the short id to tell same-named profiles apart.

## Inspect

These commands are read-only.

| Command                                    | What it does                                                                                           |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| `synctray doctor`                          | Health report: rclone, config schemas, and per profile the derived config, launchd agent, stale lock, and remote reachability. |
| `synctray status [name\|id] [--json]`      | Live state of one or all profiles.                                                                     |
| `synctray status <name\|id> --wait <state>[,<state>] [--timeout s]` | Block until the profile reaches one of the states (default timeout 600 s).    |
| `synctray offline status [name\|id] [--json]` | How much of a Stream profile is cached and ready to use offline.                                    |
| `synctray profiles`                        | One line per profile: name, short id, mode, `enabled=`, `remote=`. `profile list` is an alias.         |
| `synctray profile show <name\|id>`         | The profile's full config as pretty JSON — the same shape as its `.profile.json`.                      |
| `synctray logs <name\|id> [--follow]`      | Print the profile's sync log, or follow it like `tail -f`.                                             |
| `synctray test-remote <name\|id>`          | Probe the profile's remote path with a hard timeout.                                                   |
| `synctray listremotes`                     | Pass-through to `rclone listremotes`.                                                                  |
| `synctray help`                            | Print the usage summary.                                                                               |

### `doctor`

Prints one `[ok]`, `[warn]`, or `[fail]` line per check and exits `1` if any check failed.
Warnings never fail the run.

```console
$ synctray doctor
[ok] rclone: rclone v1.73.2
[ok] config schemas: installed
[ok] profile "Projects" (6f1c2b9e): derived config present
[ok] profile "Projects" (6f1c2b9e): launchd agent loaded
[ok] profile "Projects" (6f1c2b9e): no stale lock
[ok] profile "Projects" (6f1c2b9e): remote reachable
```

### `status`

Prints one tab-separated line per profile:

```console
$ synctray status
Projects  6f1c2b9e  enabled=true  agent=loaded  running=false  last=completed  state=idle
Media     a41c09d2  enabled=true  agent=loaded  running=true   last=none       state=mounted  mode=streaming  pending_uploads=0
```

| Field              | Values                                                                                          |
| ------------------ | ----------------------------------------------------------------------------------------------- |
| `enabled`          | `true` or `false`                                                                               |
| `agent`            | `loaded`, `unloaded`, or `n/a` for a disabled profile                                           |
| `running`          | `true` while the profile's lock file exists                                                     |
| `last`             | `started`, `completed`, `failed`, or `none`, read from the end of the sync log                  |
| `state`            | The field to branch on — see the table below                                                    |
| `mode`             | Stream profiles, while rclone runs: `streaming`, `cache-only-manual`, `cache-only-pending`, or `cache-only-offline` |
| `pending_uploads`  | Stream profiles: files created or edited in Cache Only that haven't uploaded yet                |
| `cache_only_fallback` | `true` when a Stream profile asked for Cache Only but is streaming instead                   |

| `state`     | Applies to | Meaning                                                                                         |
| ----------- | ---------- | ----------------------------------------------------------------------------------------------- |
| `disabled`  | all        | The profile is turned off                                                                       |
| `idle`      | sync       | Enabled, nothing running                                                                        |
| `syncing`   | sync       | A run holds the lock                                                                            |
| `mounting`  | Stream     | rclone is running but the volume isn't attached yet — the startup cache scan can take minutes on a large cache |
| `mounted`   | Stream     | The volume is attached and served                                                               |
| `stale`     | Stream     | The volume is in the mount table but nothing serves it (Finder's "Server connections interrupted") |
| `unmounted` | Stream     | Enabled, not mounted                                                                            |

`--json` prints the same facts as a JSON array with sorted keys: `name`, `shortId`, `syncMode`, `enabled`, `agent`, `running`, `last`, `state`, and for Stream profiles `mountMode`, `pendingUploads`, and `cacheOnlyFallback`.

`--wait` blocks until the profile reaches one of the listed states, then exits `0`.
On timeout it exits `1`.
Either way it prints the last state it saw.

```bash
synctray status Media --wait mounted,stale --timeout 300
```

### `offline status`

For each Stream profile: whether it's mounted, how many files and bytes are still missing from the cache, how many are already cached, and `ready=true` when every non-excluded file is cached.
The scope is the profile's offline folders, or the whole mount when none are set.
An unmounted profile reports `mounted=false ready=unknown`, because its files can't be listed.
A non-Stream target exits `1`.

```console
$ synctray offline status Media
Media  a41c09d2  mounted=true  missing_files=12  missing_bytes=734003200  cached_files=4810  cached_bytes=96636764160  ready=false
```

## Configure

These commands change files under `~/.config/synctray/` and install or remove launchd agents directly.
If the app is running, it sees the same file change and ends up in the same state — running both is redundant, not conflicting.

| Command                                                  | What it does                                                                         |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `synctray profile create --from <file>`                  | Create a profile from a `.profile.json` file.                                        |
| `synctray profile create -`                              | Same, reading the JSON from stdin.                                                   |
| `synctray profile set <name\|id> <key> <value> [...]`    | Change fields on an existing profile, then reinstall or remount if the change needs it. |
| `synctray profile enable <name\|id>`                     | Set `isEnabled` to `true` and install the launchd agent.                             |
| `synctray profile disable <name\|id>`                    | Set `isEnabled` to `false` and remove the launchd agent.                             |
| `synctray profile delete <name\|id>`                     | Remove the agent (unmounting first for Stream) and delete the profile file.          |
| `synctray install <name\|id>`                            | Install an enabled profile's agent again, for example after it went missing. Never changes `isEnabled`. |
| `synctray reinstall <name\|id>`                          | Regenerate the script and launchd plist and reinstall the agent. Remounts a mounted Stream profile. |

### `profile create`

The file must decode as a profile: `id` (a UUID), `name`, `rcloneRemote`, `remotePath`, and `localSyncPath` are required, and every other field has a default.
See [Configuration files](configuration.md#profile-files) for the format.

- An `id` or short id that already exists exits `1`. Edit the existing profile instead.
- The profile file is always written.
- The launchd agent is installed only when the profile is `isEnabled` and every required field is non-empty.

```console
$ synctray profile create --from projects.profile.json
created Projects (6f1c2b9e) — not installed (disabled or incomplete)
```

### `profile set`

Takes one or more `key value` pairs.
All of them are validated against a copy of the profile first, so an unknown key or a bad value exits `65` and writes nothing.

```console
$ synctray profile set Projects syncIntervalMinutes 15 syncExcludePatterns '*.tmp,**/node_modules/**'
updated Projects (6f1c2b9e) — syncIntervalMinutes, syncExcludePatterns
```

Any field from [Configuration files → Profile fields](configuration.md#profile-fields) can be set, except `id`, `isEnabled`, and `fallbackRequiresCacheRebuild`.
List fields such as `syncExcludePatterns`, `syncIncludeFolders`, `pinnedDirectories`, and `warmExcludePatterns` take a comma-separated value.
Booleans accept `true`/`false`, `yes`/`no`, `on`/`off`, or `1`/`0`.

A `vfsCachePath` change only re-points the cache — use `cache move` to bring the cached files along.
Use `profile enable` and `profile disable` for `isEnabled`.
`id` can't be changed.

## Operate

| Command                                                         | What it does                                                                 |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `synctray sync <name\|id>`                                      | Run one sync now and wait for it. Exits with the sync script's exit code.    |
| `synctray mount <name\|id> [--timeout s]`                       | Mount a Stream profile and wait until it attaches (default 600 s).           |
| `synctray unmount <name\|id>`                                   | Unmount a Stream profile and stop its rclone process.                         |
| `synctray cache move <name\|id> --to <path> [--include-overlapping]` | Move a Stream profile's cache, cached files included, and wait for it.   |

- `sync` runs exactly what the app's **Sync Now** runs, guarded by the same lock as scheduled runs. It refuses Stream profiles.
- `mount` exits `0` once the volume is attached, or right away if it already is. On timeout it tells you whether rclone is still starting — resume with `status <name> --wait mounted` — or never came up. If rclone isn't running for 60 seconds in a row, it fails early and prints the end of the sync log.
- `cache move` refuses while files in Cache Only are still waiting to upload. When another profile shares the same cached files, it refuses unless you pass `--include-overlapping` to move both.

## Exit codes

| Code | Meaning                                                                 |
| ---- | ----------------------------------------------------------------------- |
| `0`  | Success                                                                 |
| `1`  | The command ran and failed — unmatched profile, failed check, timeout, refused action |
| `64` | Usage error — unknown command or missing argument                       |
| `65` | Invalid data — a profile that doesn't decode, an unknown key, a bad value |
| `66` | The input file or stdin couldn't be read                                |

`sync` returns the sync script's own exit code.

## Privacy

CLI output goes only to your terminal.
If you've opted in to usage data, each command records its verb, result, exit code, and duration — never its arguments, paths, profile names, or remotes.
