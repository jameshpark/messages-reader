# messages-reader

Read-only access to this Mac's iMessage/SMS history for local bots, without
giving the bots Full Disk Access.

- `bin/messages-reader-service` is the only thing with Full Disk Access. A
  LaunchAgent (`com.jamespark.messages-reader`) keeps it running. It listens
  on `~/.local/state/messages-reader/messages-reader.sock` (socket 0600,
  directory 0700, peer uid checked) and answers a fixed set of read requests.
  It has no send, write or delete operation, opens `chat.db` and the
  AddressBook databases with SQLite `mode=ro`, `PRAGMA query_only=ON` and an
  authorizer that denies everything except reads, and makes no network calls.
- `~/.local/bin/messages-read` is the client. It only talks to the socket and
  has no runtime dependencies, so it works from a bare shell:
  `env -i PATH=/usr/bin:/bin ~/.local/bin/messages-read check`.

Both are single PyInstaller binaries, so neither needs Python, uv, mise or a
venv at runtime. The service binary is signed with hardened runtime, which
ignores `DYLD_*` injection and blocks debugger attach.

## Usage

```
messages-read check                         # can the service read Messages?
messages-read recent [--hours 24] [--limit 50]
messages-read search TEXT [--days 365] [--limit 50]
messages-read thread TARGET [--limit 50]    # phone, email, contact name, or chat:<id>
messages-read contact QUERY [--limit 10]    # name, phone or email
messages-read chats [--limit 30]
messages-read attachments [TARGET] [--days 30] [--limit 50]   # metadata only
messages-read --json <command> ...          # raw JSON instead of text
```

`thread` with a phone, email or name returns that person's one-to-one chats
(iMessage and SMS together). Use `chats` to find a group's `chat:<id>`.

Limits: requests over 4 KiB are rejected, each message's text is capped at
4000 characters, and responses are capped at 4 MiB (oldest rows dropped,
marked `truncated`). Exit codes: 0 ok, 1 service error, 2 usage, 3 service
unreachable.

The library this was going to wrap, `mac_messages_mcp`, keeps its read and
send functions in one module and re-exports `send_message`, so it isn't
used. The queries here are written from scratch; only the `attributedBody`
decoder is adapted from it (MIT).

## Build, install, rebuild

Needs `uv` and Homebrew's Python 3.14 (the build never downloads a Python and
keeps its caches in `.cache/`).

```
./install.sh
```

This runs the tests, builds both binaries, installs the client and the
LaunchAgent plist, restarts the service and prints `check`. Run it again to
rebuild after any change.

**Full Disk Access must be granted again after every rebuild.** The binary is
ad-hoc signed, so each build has a new code signature and macOS treats it as a
different program. After `./install.sh`:

1. System Settings -> Privacy & Security -> Full Disk Access.
2. Remove the old `messages-reader-service` entry, click +, press Cmd-Shift-G,
   and add `~/repos/personal/messages-reader/bin/messages-reader-service`.
3. `launchctl kickstart -k gui/$(id -u)/com.jamespark.messages-reader`
4. `messages-read check` should say `full_disk_access: True`.

## Upgrade

- Dependencies are build-only (PyInstaller, pytest): `uv lock --upgrade`, then
  `./install.sh`, then redo the Full Disk Access grant.
- Python: when Homebrew moves to a new Python, change `3.14+gil` in
  `install.sh` and `requires-python` if needed, then rebuild.
- After a macOS update, run `messages-read check` and `messages-read recent`.
  If text comes back blank, the `attributedBody` format changed; see
  `decode_attributed_body` in `src/messages_reader/store.py`.

## Operate

- Logs: `~/Library/Logs/messages-reader.log` (op name, outcome and timing
  only; never arguments or message contents).
- Status: `launchctl print gui/$(id -u)/com.jamespark.messages-reader`
- Restart: `launchctl kickstart -k gui/$(id -u)/com.jamespark.messages-reader`
- Remove: `./install.sh uninstall`, then delete the Full Disk Access entry.
