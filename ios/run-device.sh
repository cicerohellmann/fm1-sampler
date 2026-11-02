#!/bin/zsh
# Build, install and launch on a connected iPhone (USB or Wi-Fi):  ./run-device.sh [Debug|Release] [KEY=VALUE ...]
# The KEY=VALUE pairs go into the launch environment (FM1_DIAG, FM1_SNAP, FM1_SCRIPT, FM1_NETMIDI, FM1_MIDI_MATCH; see Backend.mm).
# DEVICE=<CoreDevice id> picks the phone (default: the first available iPhone). The console stays attached until the app exits.
set -e
cd "${0:A:h}"
CONF=${1:-Release}; shift || true
DEVICE=${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /available/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) {print $i; exit}}')}
[ -n "$DEVICE" ] || { echo "no iPhone found"; exit 1; }
echo "device: $(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE" | sed -E 's/ {2,}/ | /g')"
xcodegen -q
xcodebuild -project FM1Sampler.xcodeproj -scheme FM1Sampler -configuration $CONF -destination "id=$DEVICE" -derivedDataPath build \
  -allowProvisioningUpdates build 2>&1 | grep -E "^[^ ].*(error|warning): |BUILD (SUCCEEDED|FAILED)" | grep -v "/engine/" || true
APP=build/Build/Products/$CONF-iphoneos/FM1Sampler.app
[ -d "$APP" ] || exit 1
xcrun devicectl device install app --device $DEVICE "$APP" | grep -E "App installed|error" || true
ENVJSON="{\"OS_ACTIVITY_DT_MODE\":\"YES\""
for kv in "$@"; do ENVJSON="$ENVJSON,\"${kv%%=*}\":\"${kv#*=}\""; done
ENVJSON="$ENVJSON}"
exec xcrun devicectl device process launch --device $DEVICE --terminate-existing --console --environment-variables "$ENVJSON" ca.dallasgroot.fm1sampler
