#!/bin/sh
# Gives the Yomi server on the phone its Apple push key, so iPhones get message
# notifications while Yomi is closed. Run it once, after downloading the key:
#
#   sh app/scripts/setup_apns.sh ~/Downloads/AuthKey_ABC123DEFG.p8
#
# Create the key at https://developer.apple.com/account/resources/authkeys/add
# (tick "Apple Push Notifications service (APNs)", download the .p8). Apple only
# offers the download once, so keep a copy somewhere safe. The key stays on the
# phone in a file only the service can read; it never goes into the repository.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/push_setup_common.sh"

KEY_FILE=${1:-}
TEAM_ID=${YOMI_TEAM_ID:-5W29Q45NKL}
TOPIC=${YOMI_BUNDLE_ID:-com.brajanzalta.yomi}
REMOTE_DIR=/data/local/tmp/yomi
BB=/data/local/tmp/busybox
HEALTH_URL=${YOMI_HEALTH_URL:-http://100.88.180.104:4534/health}

if [ -z "$KEY_FILE" ] || [ ! -f "$KEY_FILE" ]; then
  echo "Usage: $0 /path/to/AuthKey_XXXXXXXXXX.p8" >&2
  exit 2
fi
NAME=$(basename "$KEY_FILE")
KEY_ID=${NAME#AuthKey_}
KEY_ID=${KEY_ID%.p8}
case "$KEY_ID" in
  *[!A-Z0-9]*|"") echo "Keep Apple's file name (AuthKey_<KeyID>.p8) so the Key ID can be read from it." >&2; exit 2 ;;
esac
# Fails here, not on the phone, if the file isn't an EC private key.
openssl pkey -in "$KEY_FILE" -noout

# The phone's shell can't make temporary files, so files are written here and copied.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
scp -O "$KEY_FILE" "homelab:$REMOTE_DIR/apns.p8"
ssh homelab "chmod 600 $REMOTE_DIR/apns.p8"
sync_push_settings "$WORK" \
  "YOMI_APNS_KEY_FILE=$REMOTE_DIR/apns.p8" \
  "YOMI_APNS_KEY_ID=$KEY_ID" \
  "YOMI_APNS_TEAM_ID=$TEAM_ID" \
  "YOMI_APNS_TOPIC=$TOPIC"

# Restart; the watchdog brings it back within a minute.
ssh homelab "$BB pkill -f '^./yomi-upload\$'" || true
for _ in $(seq 1 30); do
  sleep 4
  if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
    if ssh homelab "tail -n 40 $REMOTE_DIR/yomi-upload.log | grep -q 'apns: pushing'"; then
      echo "Done: the server will push to iPhones as $TOPIC (key $KEY_ID)."
      exit 0
    fi
  fi
done
echo "The server restarted but did not report APNs as ready. Check $REMOTE_DIR/yomi-upload.log." >&2
exit 1
