#!/bin/bash
# Build the service and client binaries and (re)install the LaunchAgent.
#
#   ./install.sh            test, build, install, restart the service
#   ./install.sh uninstall  stop the service, remove the plist and the client
#
# Installs only:
#   bin/messages-reader-service                (in this repo; grant it Full Disk Access)
#   ~/.local/bin/messages-read
#   ~/Library/LaunchAgents/com.jamespark.messages-reader.plist
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd -P)
LABEL=com.jamespark.messages-reader
SERVICE_BIN=$REPO/bin/messages-reader-service
CLIENT_BIN=$HOME/.local/bin/messages-read
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
LOG=$HOME/Library/Logs/messages-reader.log
SOCKET=$HOME/.local/state/messages-reader/messages-reader.sock
DOMAIN=gui/$(id -u)

stop_service() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    for _ in $(seq 50); do
        launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    echo "service $LABEL did not stop" >&2
    return 1
}

# Copy to a temp name and rename, so a running or cached binary is never
# overwritten in place (macOS kills processes whose signed pages change).
install_file() {
    install -m 0755 "$1" "$2.tmp.$$"
    mv -f "$2.tmp.$$" "$2"
}

if [[ ${1:-} == uninstall ]]; then
    stop_service
    rm -f "$PLIST" "$CLIENT_BIN"
    echo "Uninstalled. $SERVICE_BIN is left in place; remove its Full Disk Access entry in System Settings."
    exit 0
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [uninstall]" >&2
    exit 2
fi

cd "$REPO"
swift test
swift build -c release --product messages-reader-service
swift build -c release --product messages-read
OUT=$(swift build -c release --show-bin-path)

fail() {
    echo "refusing to install: $*" >&2
    exit 1
}

# Sign ad hoc with the hardened runtime and no entitlements, then check the
# result. Ad hoc means the designated requirement is the binary's cdhash, so a
# Full Disk Access grant covers this exact build and nothing else. Hardened
# runtime with no entitlements keeps library validation on, ignores DYLD_*
# variables and refuses debugger attach. Only system libraries are linked and
# there are no rpaths, so nothing loads from a writable location.
seal() {
    local bin=$1 id=$2 rpath
    while rpath=$(otool -l "$bin" | awk '$1 == "cmd" && $2 == "LC_RPATH" {getline; getline; print $2; exit}') \
        && [[ -n $rpath ]]; do
        # (It warns that this invalidates the signature; we re-sign next.)
        install_name_tool -delete_rpath "$rpath" "$bin" 2>/dev/null || fail "$bin: cannot delete rpath $rpath"
    done
    codesign --force --options runtime --identifier "$id" --sign - "$bin"

    codesign --verify --strict "$bin" || fail "$bin: signature does not verify"
    # Capture before matching: grep -q exits early and pipefail would count
    # the writer's SIGPIPE as a failure.
    local info loads
    info=$(codesign -dv "$bin" 2>&1)
    [[ $info == *$'\n'"CodeDirectory "*"flags="*"(adhoc,runtime)"* ]] || fail "$bin: not ad hoc with hardened runtime"
    [[ -z $(codesign -d --entitlements - "$bin" 2>/dev/null) ]] || fail "$bin: has entitlements"
    loads=$(otool -l "$bin")
    [[ $loads != *LC_RPATH* ]] || fail "$bin: still has an LC_RPATH"
    local lib
    while read -r lib _; do
        [[ $lib == /usr/lib/* || $lib == /System/Library/* ]] || fail "$bin links $lib"
    done < <(otool -L "$bin" | tail -n +2)
}
mkdir -p "$REPO/.build/sealed"
cp "$OUT/messages-reader-service" "$OUT/messages-read" "$REPO/.build/sealed/"
seal "$REPO/.build/sealed/messages-reader-service" "$LABEL-service"
seal "$REPO/.build/sealed/messages-read" "$LABEL-client"

stop_service
mkdir -p "$REPO/bin" "$(dirname "$CLIENT_BIN")" "$(dirname "$PLIST")" "$(dirname "$LOG")"
install_file "$REPO/.build/sealed/messages-reader-service" "$SERVICE_BIN"
install_file "$REPO/.build/sealed/messages-read" "$CLIENT_BIN"

cat >"$PLIST.tmp.$$" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$SERVICE_BIN</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>StandardOutPath</key>
	<string>$LOG</string>
	<key>StandardErrorPath</key>
	<string>$LOG</string>
</dict>
</plist>
EOF
plutil -lint -s "$PLIST.tmp.$$"
mv -f "$PLIST.tmp.$$" "$PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST"

for _ in $(seq 100); do
    [[ -S $SOCKET ]] && break
    sleep 0.1
done
env -i PATH=/usr/bin:/bin "$CLIENT_BIN" check || true

cat <<EOF

Installed. Grant Full Disk Access to this exact file (needed again after every rebuild):
  $SERVICE_BIN
  cdhash: $(codesign -dvvv "$SERVICE_BIN" 2>&1 | sed -n 's/^CDHash=//p')
  designated requirement: $(codesign -d -r- "$SERVICE_BIN" 2>&1 | sed -n 's/^# designated => //p')
then run: launchctl kickstart -k $DOMAIN/$LABEL
EOF
