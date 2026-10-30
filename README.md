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

Both are single Swift executables that link only macOS system libraries
(Foundation, the Swift runtime in `/usr/lib/swift`, and `/usr/lib/libsqlite3`).
Nothing is unpacked or loaded from a writable location at runtime.

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

The queries are written from scratch; only the `attributedBody` decoder is
adapted from `mac_messages_mcp` (MIT).

## Build, install, rebuild

Needs Xcode or the Command Line Tools (Swift 6). No other dependencies.

```
./install.sh
```

This runs `swift test`, builds both binaries in release mode, removes their
rpaths, signs them, refuses to install unless each one is ad hoc signed with
the hardened runtime, has no entitlements, no rpaths and links only
`/usr/lib` and `/System/Library`, then installs the client and the
LaunchAgent plist, restarts the service and prints `check`. Run it again to
rebuild after any change.

**Full Disk Access must be granted again after every rebuild.** After
`./install.sh`:

1. System Settings -> Privacy & Security -> Full Disk Access.
2. Remove the old `messages-reader-service` entry, click +, press Cmd-Shift-G,
   and add `~/repos/personal/messages-reader/bin/messages-reader-service`.
3. `launchctl kickstart -k gui/$(id -u)/com.jamespark.messages-reader`
4. `messages-read check` should say `full_disk_access: True`.
5. After the first grant, run `scripts/verify-fda-pinning.sh` once (below).

### Why ad hoc signing, and why the grant needs redoing

`bin/` is writable by anything running as you, so the grant must not follow
the path. TCC records the designated requirement (DR) of the program you
grant and checks it on every access (Apple TN3127). For an ad hoc signature
the DR is the code's hash (`cdhash H"..."`, shown by `codesign -d -r-`), so
the grant covers exactly one build: any other file at that path, or this file
with a single byte changed, fails the check and gets no access. That is also
why every rebuild needs a new grant.

A Developer ID or Apple Development signature would keep the grant across
rebuilds, because its DR names the identifier and signing team instead of a
hash. It would also let anything that can use your signing identity (any
process running as you, if the key is in your login keychain) sign its own
program to satisfy the grant. Ad hoc keeps the grant pinned to one build.

The hardened runtime with no entitlements means `DYLD_*` variables are
ignored, only Apple-signed or same-signature libraries load, and debuggers
can't attach, so nothing can inject code into the process that holds access.

`scripts/verify-fda-pinning.sh` checks the pinning on a real grant: it renames
a re-signed copy (same code, different cdhash) into the install path and
expects `check` to lose access, then restores the original and expects access
back.

## Upgrade

- After an Xcode or macOS update, `./install.sh` rebuilds with the new
  toolchain; then redo the Full Disk Access grant.
- After a macOS update, run `messages-read check` and `messages-read recent`.
  If text comes back blank, the `attributedBody` format changed; see
  `decodeAttributedBody` in `Sources/ReaderCore/Text.swift`.

## Operate

- Logs: `~/Library/Logs/messages-reader.log` (op name, outcome and timing
  only; never arguments or message contents).
- Status: `launchctl print gui/$(id -u)/com.jamespark.messages-reader`
- Restart: `launchctl kickstart -k gui/$(id -u)/com.jamespark.messages-reader`
- Remove: `./install.sh uninstall`, then delete the Full Disk Access entry.
