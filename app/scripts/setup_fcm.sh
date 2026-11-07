#!/bin/sh
# Sets up Android push end to end: a Firebase project, the Android app entry, the
# app's google-services.json, and the service account the server signs in with.
# One thing needs you: sign in to Google once with `gcloud auth login`.
# Safe to run again; it reuses what it already made.
set -eu

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PACKAGE=${YOMI_ANDROID_PACKAGE:-com.yomi.yomi}
PROJECT=${YOMI_FIREBASE_PROJECT:-}
STATE_FILE="$HOME/.yomi-signing/firebase-project"
REMOTE_DIR=/data/local/tmp/yomi
HEALTH_URL=${YOMI_HEALTH_URL:-http://100.88.180.104:4534/health}

if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | grep -q .; then
  echo "Sign in first:  gcloud auth login" >&2
  exit 1
fi

mkdir -p "$(dirname "$STATE_FILE")"
if [ -z "$PROJECT" ] && [ -f "$STATE_FILE" ]; then PROJECT=$(cat "$STATE_FILE"); fi
if [ -z "$PROJECT" ]; then
  PROJECT="yomi-push-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  echo "Creating Google Cloud project $PROJECT"
  gcloud projects create "$PROJECT" --name="Yomi" --quiet
fi
echo "$PROJECT" > "$STATE_FILE"

TOKEN() { gcloud auth print-access-token; }
api() { # method url [body]
  curl -fsS -X "$1" "$2" -H "Authorization: Bearer $(TOKEN)" -H "X-Goog-User-Project: $PROJECT" \
    -H 'Content-Type: application/json' ${3:+-d "$3"}
}
wait_operation() { # name
  for _ in $(seq 1 40); do
    out=$(api GET "https://firebase.googleapis.com/v1beta1/$1")
    if printf '%s' "$out" | grep -q '"done": *true'; then printf '%s' "$out"; return 0; fi
    sleep 3
  done
  echo "Timed out waiting for $1" >&2; return 1
}

echo "Turning on Firebase and push"
gcloud services enable firebase.googleapis.com fcm.googleapis.com iam.googleapis.com \
  --project="$PROJECT" --quiet
if ! api GET "https://firebase.googleapis.com/v1beta1/projects/$PROJECT" >/dev/null 2>&1; then
  op=$(api POST "https://firebase.googleapis.com/v1beta1/projects/$PROJECT:addFirebase" '{}')
  wait_operation "$(printf '%s' "$op" | python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])')" >/dev/null
fi

APP_ID=$(api GET "https://firebase.googleapis.com/v1beta1/projects/$PROJECT/androidApps" |
  python3 -c "
import json,sys
apps=json.load(sys.stdin).get('apps',[])
print(next((a['appId'] for a in apps if a['packageName']=='$PACKAGE'),''))")
if [ -z "$APP_ID" ]; then
  op=$(api POST "https://firebase.googleapis.com/v1beta1/projects/$PROJECT/androidApps" \
    "{\"packageName\":\"$PACKAGE\",\"displayName\":\"Yomi\"}")
  done=$(wait_operation "$(printf '%s' "$op" | python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])')")
  APP_ID=$(printf '%s' "$done" | python3 -c 'import json,sys;print(json.load(sys.stdin)["response"]["appId"])')
fi

echo "Writing the app's google-services.json"
api GET "https://firebase.googleapis.com/v1beta1/projects/$PROJECT/androidApps/$APP_ID/config" |
  python3 -c "
import base64,json,sys
print(base64.b64decode(json.load(sys.stdin)['configFileContents']).decode(),end='')" \
  > "$APP_DIR/android/app/google-services.json"

SA="yomi-push@$PROJECT.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$SA" --project="$PROJECT" >/dev/null 2>&1; then
  gcloud iam service-accounts create yomi-push --display-name="Yomi push sender" \
    --project="$PROJECT" --quiet
fi
gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA" \
  --role=roles/firebasecloudmessaging.admin --condition=None --quiet >/dev/null

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
gcloud iam service-accounts keys create "$WORK/fcm-service-account.json" \
  --iam-account="$SA" --project="$PROJECT" --quiet

echo "Giving the server its key"
scp -O "$WORK/fcm-service-account.json" "homelab:$REMOTE_DIR/fcm-service-account.json"
ssh homelab "chmod 600 $REMOTE_DIR/fcm-service-account.json"
scp -O "homelab:$REMOTE_DIR/push.env" "$WORK/push.env"
if ! grep -q YOMI_FCM_SERVICE_ACCOUNT "$WORK/push.env"; then
  printf 'export YOMI_FCM_SERVICE_ACCOUNT=%s/fcm-service-account.json\n' "$REMOTE_DIR" >> "$WORK/push.env"
  scp -O "$WORK/push.env" "homelab:$REMOTE_DIR/push.env.new"
  ssh homelab "chmod 600 $REMOTE_DIR/push.env.new && mv $REMOTE_DIR/push.env.new $REMOTE_DIR/push.env"
fi

ssh homelab "/data/local/tmp/busybox pkill -f '^./yomi-upload\$'" || true
for _ in $(seq 1 30); do
  sleep 4
  if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1 &&
    ssh homelab "tail -n 40 $REMOTE_DIR/yomi-upload.log | grep -q 'fcm: pushing'"; then
    echo "Done. Project $PROJECT; the server now pushes to Android. Rebuild the Android app to pick up google-services.json."
    exit 0
  fi
done
echo "The server restarted but did not report FCM as ready. Check $REMOTE_DIR/yomi-upload.log." >&2
exit 1
