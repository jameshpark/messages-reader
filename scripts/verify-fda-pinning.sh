#!/bin/bash
# Run after granting Full Disk Access to bin/messages-reader-service.
#
# Proves the grant is pinned to the signature, not the path: a different
# binary renamed into the install path (here, the same code re-signed with
# another identifier, so only its cdhash differs) must lose access, and the
# original must get it back. Restores the original binary on any exit.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
LABEL=com.jamespark.messages-reader
SERVICE_BIN=$REPO/bin/messages-reader-service
CLIENT_BIN=$HOME/.local/bin/messages-read
SOCKET=$HOME/.local/state/messages-reader/messages-reader.sock
DOMAIN=gui/$(id -u)
ORIG=$SERVICE_BIN.orig.$$
SWAP=$SERVICE_BIN.swap.$$

cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

restart() {
    rm -f "$SOCKET"
    launchctl kickstart -k "$DOMAIN/$LABEL"
    for _ in $(seq 100); do
        [[ -S $SOCKET ]] && return 0
        sleep 0.1
    done
    echo "service did not come back" >&2
    return 1
}

# Prints true or false.
fda() {
    env -i PATH=/usr/bin:/bin "$CLIENT_BIN" --json check \
        | sed -En 's/.*"full_disk_access" *: *(true|false).*/\1/p'
}

restore() {
    if [[ -e $ORIG ]]; then
        mv -f "$ORIG" "$SERVICE_BIN"
        restart || true
    fi
    rm -f "$SWAP"
}
trap restore EXIT

original=$(cdhash "$SERVICE_BIN")
echo "installed binary: $SERVICE_BIN (cdhash $original)"
[[ $(fda) == true ]] || { echo "the installed binary has no Full Disk Access yet; grant it first" >&2; exit 1; }
echo "1. installed binary has access: true"

cp "$SERVICE_BIN" "$SWAP"
codesign --force --options runtime --identifier "$LABEL-service.swapped" --sign - "$SWAP"
swapped=$(cdhash "$SWAP")
[[ $swapped != "$original" ]] || { echo "swapped copy has the same cdhash" >&2; exit 1; }

cp -p "$SERVICE_BIN" "$ORIG"
mv -f "$SWAP" "$SERVICE_BIN"
restart
result=$(fda)
echo "2. swapped binary at the same path (cdhash $swapped) has access: $result"

mv -f "$ORIG" "$SERVICE_BIN"
restart
restored=$(fda)
echo "3. original binary restored (cdhash $(cdhash "$SERVICE_BIN")) has access: $restored"

if [[ $result != false ]]; then
    echo "FAIL: a swapped binary kept Full Disk Access, so the grant is not pinned. Do not rely on this setup." >&2
    exit 1
elif [[ $restored != true ]]; then
    echo "INCONCLUSIVE: the original binary did not get access back; check the grant and rerun." >&2
    exit 1
fi
echo "PASS: the grant is pinned to the signature; a swapped binary loses Full Disk Access."
