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

# Keep every build cache inside the repo and never download a Python.
export UV_PYTHON_DOWNLOADS=never
export UV_CACHE_DIR=$REPO/.cache/uv
export PYINSTALLER_CONFIG_DIR=$REPO/.cache/pyinstaller
cd "$REPO"

uv sync --frozen --python '3.14+gil'
uv run --frozen pytest -q

build() {
    uv run --frozen pyinstaller --noconfirm --clean --onefile --log-level WARN \
        --name "$1" --paths "$REPO/src" \
        --distpath "$REPO/build/dist" --workpath "$REPO/build/work" --specpath "$REPO/build/spec" \
        "$REPO/packaging/$2"
    # Hardened runtime ignores DYLD_* variables and refuses debugger attach,
    # so nothing can inject code into the process that holds Full Disk Access.
    codesign --force --options runtime --entitlements "$REPO/packaging/entitlements.plist" \
        --sign - "$REPO/build/dist/$1"
}
build messages-reader-service service_entry.py
build messages-read client_entry.py

stop_service
mkdir -p "$REPO/bin" "$(dirname "$CLIENT_BIN")" "$(dirname "$PLIST")" "$(dirname "$LOG")"
install_file "$REPO/build/dist/messages-reader-service" "$SERVICE_BIN"
install_file "$REPO/build/dist/messages-read" "$CLIENT_BIN"

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
    [[ -S $HOME/.local/state/messages-reader/messages-reader.sock ]] && break
    sleep 0.1
done
env -i PATH=/usr/bin:/bin "$CLIENT_BIN" check || true

cat <<EOF

Installed. Grant Full Disk Access to this exact file (needed again after every rebuild):
  $SERVICE_BIN
  cdhash: $(codesign -dvvv "$SERVICE_BIN" 2>&1 | sed -n 's/^CDHash=//p')
then run: launchctl kickstart -k $DOMAIN/$LABEL
EOF
